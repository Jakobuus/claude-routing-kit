import { spawn, type ChildProcess } from "node:child_process";
import { constants } from "node:fs";
import { access, readdir, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { delimiter, join, sep } from "node:path";
import { parseKitQuota } from "../shared/parse";
import type { UsageSnapshot } from "../shared/usage";

/** kit-quota may wait up to 10 s on the jules CLI; leave it room. */
const TIMEOUT_MS = 20_000;
/** The Paseo server runs with a minimal PATH; kit-quota needs these to find `codex` and `jules`. */
const EXTRA_BINS = ["/opt/homebrew/bin", "/usr/local/bin"];
/** Deep enough for cache/<marketplace>/routing-kit/<version>/bin and marketplaces/<m>/plugins/routing-kit/bin. */
const MAX_PLUGIN_DEPTH = 7;

export function kitQuotaPath(pathEnv: string | undefined): string {
  const parts = (pathEnv ?? "").split(delimiter).filter(Boolean);
  for (const bin of EXTRA_BINS) if (!parts.includes(bin)) parts.push(bin);
  return parts.join(delimiter);
}

async function isExecutableFile(path: string): Promise<boolean> {
  try {
    await access(path, constants.X_OK);
    return (await stat(path)).isFile();
  } catch {
    return false;
  }
}

/** First executable `kit-quota` on the given PATH, or null. */
export async function findOnPath(pathEnv: string): Promise<string | null> {
  for (const dir of pathEnv.split(delimiter).filter(Boolean)) {
    const candidate = join(dir, "kit-quota");
    if (await isExecutableFile(candidate)) return candidate;
  }
  return null;
}

/** Newest (by mtime) executable `…/routing-kit/…/bin/kit-quota` under the Claude plugins folder, or null. */
export async function findInPlugins(
  pluginsDir = join(process.env.CLAUDE_CONFIG_DIR ?? join(homedir(), ".claude"), "plugins"),
): Promise<string | null> {
  let best: { path: string; mtimeMs: number } | null = null;
  const walk = async (dir: string, depth: number): Promise<void> => {
    let entries;
    try {
      entries = await readdir(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      const path = join(dir, entry.name);
      if (entry.isDirectory()) {
        if (depth < MAX_PLUGIN_DEPTH && entry.name !== "node_modules" && entry.name !== ".git") {
          await walk(path, depth + 1);
        }
      } else if (
        entry.name === "kit-quota" &&
        dir.endsWith(`${sep}bin`) &&
        path.includes(`${sep}routing-kit${sep}`) &&
        (await isExecutableFile(path))
      ) {
        const { mtimeMs } = await stat(path);
        if (!best || mtimeMs > best.mtimeMs) best = { path, mtimeMs };
      }
    }
  };
  await walk(pluginsDir, 0);
  return (best as { path: string } | null)?.path ?? null;
}

/** kit-quota from PATH first, else the newest copy installed as a Claude Code plugin. */
export async function resolveKitQuota(
  pathEnv = kitQuotaPath(process.env.PATH),
  pluginsDir?: string,
): Promise<string | null> {
  return (await findOnPath(pathEnv)) ?? (await findInPlugins(pluginsDir));
}

export interface UsageOptions {
  resolve?: () => Promise<string | null>;
  pathEnv?: string;
  timeoutMs?: number;
}

/** One `kit-quota --json` run. Never rejects: anything that goes wrong becomes null (the pill shows "–"). */
export async function getUsage(options: UsageOptions = {}): Promise<UsageSnapshot | null> {
  const path = kitQuotaPath(options.pathEnv ?? process.env.PATH);
  let bin: string | null;
  try {
    bin = await (options.resolve ?? (() => resolveKitQuota(path)))();
  } catch {
    return null;
  }
  if (!bin) return null;
  const binPath = bin;
  const limit = 1024 * 1024;
  return new Promise((resolve) => {
    let settled = false;
    let child: ChildProcess | undefined;
    const finish = (value: UsageSnapshot | null) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve(value);
    };
    const killGroup = () => {
      if (!child?.pid) return;
      try {
        process.kill(-child.pid, "SIGKILL");
      } catch {
        // already gone
      }
    };
    // Own timer plus a process-group kill: a hung grandchild (e.g. the jules CLI) would
    // otherwise hold stdout open long after kit-quota itself was killed.
    const timer = setTimeout(() => {
      killGroup();
      finish(null);
    }, options.timeoutMs ?? TIMEOUT_MS);
    try {
      child = spawn(binPath, ["--json"], {
        detached: true,
        stdio: ["ignore", "pipe", "ignore"],
        env: { ...process.env, PATH: path },
      });
    } catch {
      finish(null);
      return;
    }
    let stdout = "";
    child.stdout?.setEncoding("utf8");
    child.stdout?.on("data", (chunk: string) => {
      stdout += chunk;
      if (stdout.length > limit) {
        killGroup();
        finish(null);
      }
    });
    child.on("error", () => finish(null));
    child.on("close", (code) => finish(code === 0 ? parseKitQuota(stdout) : null));
  });
}
