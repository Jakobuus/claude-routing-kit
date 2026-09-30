import assert from "node:assert/strict";
import { chmod, mkdir, mkdtemp, readFile, rm, utimes, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, describe, it } from "node:test";
import { findInPlugins, findOnPath, getUsage, kitQuotaPath, resolveKitQuota } from "./usage";

let root = "";
before(async () => {
  root = await mkdtemp(join(tmpdir(), "pill-test-"));
});
after(() => rm(root, { recursive: true, force: true }));

async function script(path: string, body: string, mtimeSec?: number): Promise<string> {
  await mkdir(join(path, ".."), { recursive: true });
  await writeFile(path, `#!/bin/sh\n${body}\n`);
  await chmod(path, 0o755);
  if (mtimeSec !== undefined) await utimes(path, mtimeSec, mtimeSec);
  return path;
}

describe("kitQuotaPath", () => {
  it("appends the Homebrew and /usr/local bins once", () => {
    assert.equal(kitQuotaPath("/usr/bin:/bin"), "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin");
    assert.equal(kitQuotaPath("/opt/homebrew/bin:/usr/bin"), "/opt/homebrew/bin:/usr/bin:/usr/local/bin");
    assert.equal(kitQuotaPath(undefined), "/opt/homebrew/bin:/usr/local/bin");
  });
});

describe("resolveKitQuota", () => {
  it("finds an executable kit-quota on PATH", async () => {
    const bin = join(root, "pathbin");
    const found = await script(join(bin, "kit-quota"), "exit 0");
    await writeFile(join(root, "kit-quota"), "not executable");
    assert.equal(await findOnPath(`${root}:${bin}`), found);
    assert.equal(await findOnPath(join(root, "missing")), null);
  });

  it("picks the newest routing-kit/bin/kit-quota under the plugins folder", async () => {
    const plugins = join(root, "plugins");
    await script(join(plugins, "cache", "m", "routing-kit", "1.0.0", "bin", "kit-quota"), "exit 0", 1_700_000_000);
    const newest = await script(join(plugins, "marketplaces", "routing-kit", "plugins", "routing-kit", "bin", "kit-quota"), "exit 0", 1_800_000_000);
    await script(join(plugins, "cache", "other", "bin", "kit-quota"), "exit 0", 1_900_000_000);
    assert.equal(await findInPlugins(plugins), newest);
    assert.equal(await findInPlugins(join(root, "no-plugins")), null);
  });

  it("uses CLAUDE_CONFIG_DIR for the default plugins folder", async () => {
    const configDir = join(root, "alternate-claude");
    const found = await script(join(configDir, "plugins", "cache", "routing-kit", "bin", "kit-quota"), "exit 0");
    const previous = process.env.CLAUDE_CONFIG_DIR;
    process.env.CLAUDE_CONFIG_DIR = configDir;
    try {
      assert.equal(await resolveKitQuota(join(root, "missing")), found);
    } finally {
      if (previous === undefined) delete process.env.CLAUDE_CONFIG_DIR;
      else process.env.CLAUDE_CONFIG_DIR = previous;
    }
  });

  it("prefers PATH over the plugins folder", async () => {
    const onPath = join(root, "pathbin", "kit-quota");
    assert.equal(await resolveKitQuota(join(root, "pathbin"), join(root, "plugins")), onPath);
    assert.match((await resolveKitQuota(join(root, "missing"), join(root, "plugins"))) ?? "", /marketplaces/);
    assert.equal(await resolveKitQuota(join(root, "missing"), join(root, "missing")), null);
  });
});

describe("getUsage", () => {
  const json = '{"claude":{"five_hour":{"percent":42,"resets_epoch":null,"pace":null},"week":{"percent":27,"resets_epoch":null,"pace":null},"stale":true},"codex":null,"jules":null,"kimi":null,"glm":null}';

  it("runs kit-quota --json once and parses it", async () => {
    const log = join(root, "calls.log");
    const bin = await script(join(root, "run", "kit-quota"), `echo "$@|$PATH" >> '${log}'\necho '${json}'`);
    const snapshot = await getUsage({ resolve: async () => bin, pathEnv: "/usr/bin:/bin" });
    assert.equal(snapshot?.claude?.stale, true);
    assert.equal(snapshot?.claude?.fiveHour.percent, 42);
    assert.equal(snapshot?.codex, null);
    assert.equal(await readFile(log, "utf8"), "--json|/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin\n");
  });

  it("returns null when kit-quota is missing, fails, prints junk or hangs", async () => {
    assert.equal(await getUsage({ resolve: async () => null }), null);
    const failing = await script(join(root, "fail", "kit-quota"), "exit 2");
    assert.equal(await getUsage({ resolve: async () => failing }), null);
    const junk = await script(join(root, "junk", "kit-quota"), "echo hello");
    assert.equal(await getUsage({ resolve: async () => junk }), null);
    const slow = await script(join(root, "slow", "kit-quota"), "sleep 5");
    const started = Date.now();
    assert.equal(await getUsage({ resolve: async () => slow, timeoutMs: 300 }), null);
    assert.ok(Date.now() - started < 3000, "timeout must stop a hung kit-quota");
  });
});
