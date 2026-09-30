import type { JulesUsage, ProviderUsage, TokenUsage, UsageSnapshot, UsageWindow } from "./usage";

/** Parser and formatters for `kit-quota --json`. The clock can be supplied for deterministic parsing. */

const MAX_RESET_DISTANCE_MS = 8 * 24 * 60 * 60 * 1000;
const UNKNOWN_MARK = "–";

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function percentOrNull(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) && value >= 0 && value <= 100 ? value : null;
}

function nonNegativeOrNull(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : null;
}

function countOrNull(value: unknown, min = 0): number | null {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= min ? value : null;
}

/** Epoch seconds → epoch milliseconds, or null when missing or implausibly far from now. */
function epochMsOrNull(value: unknown, now: number): number | null {
  if (typeof value !== "number" || !Number.isFinite(value) || value <= 0) return null;
  const ms = value * 1000;
  return Math.abs(ms - now) <= MAX_RESET_DISTANCE_MS ? ms : null;
}

function parseWindow(value: unknown, now: number): UsageWindow {
  const bucket = isRecord(value) ? value : {};
  return {
    percent: percentOrNull(bucket.percent),
    resetsAt: epochMsOrNull(bucket.resets_epoch, now),
    pace: nonNegativeOrNull(bucket.pace),
  };
}

/** A lane that is present is on; a malformed one is on with every value unknown. */
function parseProvider(value: unknown, now: number): ProviderUsage | null {
  if (value === null || value === undefined) return null;
  const lane = isRecord(value) ? value : {};
  return {
    fiveHour: parseWindow(lane.five_hour, now),
    week: parseWindow(lane.week, now),
    stale: lane.stale === true,
  };
}

function parseJules(value: unknown, now: number): JulesUsage | null {
  if (value === null || value === undefined) return null;
  const lane = isRecord(value) ? value : {};
  return {
    used: countOrNull(lane.used),
    limit: countOrNull(lane.limit, 1),
    running: countOrNull(lane.running),
    concurrentLimit: countOrNull(lane.concurrent_limit, 1),
    percent: nonNegativeOrNull(lane.percent),
    freesAt: epochMsOrNull(lane.frees_at_epoch, now),
  };
}

function parseTokens(value: unknown): TokenUsage | null {
  if (value === null || value === undefined) return null;
  const lane = isRecord(value) ? value : {};
  return {
    tokens: countOrNull(lane.tokens),
    spendUsd: nonNegativeOrNull(lane.spend_usd),
  };
}

/**
 * Parse `kit-quota --json`. Returns null when the text is not a kit-quota object at all.
 * Keys: claude/codex/jules/kimi/glm; null means the lane is off in the friend's profile.
 */
export function parseKitQuota(text: string, now = Date.now()): UsageSnapshot | null {
  let data: unknown;
  try {
    data = JSON.parse(text);
  } catch {
    return null;
  }
  if (!isRecord(data)) return null;
  return {
    claude: parseProvider(data.claude, now),
    codex: parseProvider(data.codex, now),
    jules: parseJules(data.jules, now),
    kimi: parseTokens(data.kimi),
    glm: parseTokens(data.glm),
  };
}

export type Severity = "normal" | "warning" | "critical";

export function severityOf(percent: number): Severity {
  if (percent >= 90) return "critical";
  if (percent >= 70) return "warning";
  return "normal";
}

const RANK: Record<Severity, number> = { normal: 0, warning: 1, critical: 2 };

function worse(a: Severity | null, b: Severity | null): Severity | null {
  if (a === null) return b;
  if (b === null) return a;
  return RANK[b] > RANK[a] ? b : a;
}

/** Highest severity across the known windows of a provider (null when nothing is known). */
export function providerSeverity(usage: ProviderUsage | null): Severity | null {
  if (!usage) return null;
  let worst: Severity | null = null;
  for (const w of [usage.fiveHour, usage.week]) {
    if (w.percent !== null) worst = worse(worst, severityOf(w.percent));
  }
  return worst;
}

/** Severity from the daily percent; at least a warning when every concurrent slot is busy. */
export function julesSeverity(usage: JulesUsage | null | undefined): Severity | null {
  if (!usage || usage.percent === null) return null;
  const byPercent = severityOf(usage.percent);
  const full = usage.running !== null && usage.concurrentLimit !== null && usage.running >= usage.concurrentLimit;
  return full && byPercent === "normal" ? "warning" : byPercent;
}

/** Highest severity across every lane in the snapshot. */
export function worstSeverity(snapshot: UsageSnapshot | null): Severity | null {
  if (!snapshot) return null;
  return [providerSeverity(snapshot.claude), providerSeverity(snapshot.codex), julesSeverity(snapshot.jules)]
    .reduce<Severity | null>(worse, null);
}

function pct(value: number | null): string {
  return value === null ? UNKNOWN_MARK : `${Math.round(value)}%`;
}

/** `Claude 5h 42% · wk 27%`, plus `· old reading` when stale. */
export function formatProviderLabel(name: string, usage: ProviderUsage | null): string {
  if (!usage) return `${name} ${UNKNOWN_MARK}`;
  const base = `${name} 5h ${pct(usage.fiveHour.percent)} · wk ${pct(usage.week.percent)}`;
  return usage.stale ? `${base} · old reading` : base;
}

/** `pace 5h 60% · wk 31%`. */
export function formatPace(usage: ProviderUsage | null): string {
  if (!usage) return UNKNOWN_MARK;
  return `pace 5h ${pct(usage.fiveHour.pace)} · wk ${pct(usage.week.pace)}`;
}

/** `Jules 24h 20% · 0/3 running`, or `Jules –` when unknown. */
export function formatJulesLabel(usage: JulesUsage | null | undefined): string {
  if (!usage || usage.used === null || usage.limit === null || usage.percent === null ||
    usage.running === null || usage.concurrentLimit === null) {
    return `Jules ${UNKNOWN_MARK}`;
  }
  return `Jules 24h ${Math.round(usage.percent)}% · ${usage.running}/${usage.concurrentLimit} running`;
}

/** `oldest frees 14:32` in local time, or `–` when unknown. */
export function formatJulesFrees(usage: JulesUsage | null | undefined): string {
  if (!usage || usage.freesAt === null) return UNKNOWN_MARK;
  return `oldest frees ${formatClock(usage.freesAt)}`;
}

function thousands(value: number): string {
  return String(value).replace(/\B(?=(\d{3})+(?!\d))/g, ",");
}

/** `$0.42`, `<$0.01` for a known spend under a cent, `$0.00` for exactly zero, `$–` when unknown. */
function money(value: number | null): string {
  if (value === null) return `$${UNKNOWN_MARK}`;
  if (value === 0) return "$0.00";
  if (value < 0.01) return "<$0.01";
  return `$${value.toFixed(2)}`;
}

/** `Kimi $0.42 this month · 12,345 tokens`, with `–` for any part that is unknown. */
export function formatTokens(name: string, usage: TokenUsage): string {
  const tokens = usage.tokens === null ? UNKNOWN_MARK : thousands(usage.tokens);
  return `${name} ${money(usage.spendUsd)} this month · ${tokens} tokens`;
}

/** `C42/27% X12/34%`: Claude and Codex, each 5h/week; `old` after a stale Claude; lanes that are off are left out. */
export function formatPillLabel(snapshot: UsageSnapshot | null): string {
  const compact = (value: number | null): string => value === null ? UNKNOWN_MARK : String(Math.round(value));
  const pair = (usage: ProviderUsage): string => `${compact(usage.fiveHour.percent)}/${compact(usage.week.percent)}%`;
  if (!snapshot) return `C${UNKNOWN_MARK}/${UNKNOWN_MARK}%`;
  const parts: string[] = [];
  if (snapshot.claude) parts.push(`C${pair(snapshot.claude)}${snapshot.claude.stale ? " old" : ""}`);
  if (snapshot.codex) parts.push(`X${pair(snapshot.codex)}`);
  return parts.length ? parts.join(" ") : UNKNOWN_MARK;
}

const WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"] as const;

function hhmm(date: Date): string {
  return `${String(date.getHours()).padStart(2, "0")}:${String(date.getMinutes()).padStart(2, "0")}`;
}

/** Local `19:54`, or `–` when unknown. */
export function formatClock(epochMs: number | null): string {
  if (epochMs === null) return UNKNOWN_MARK;
  return hhmm(new Date(epochMs));
}

/** Local `Fri 17:30`, or `–` when unknown. */
export function formatWeekdayClock(epochMs: number | null): string {
  if (epochMs === null) return UNKNOWN_MARK;
  const date = new Date(epochMs);
  return `${WEEKDAYS[date.getDay()]} ${hhmm(date)}`;
}

/** `5h resets 19:54, week resets Fri 17:30`, or `–` when the provider is unknown. */
export function formatResets(usage: ProviderUsage | null): string {
  if (!usage) return UNKNOWN_MARK;
  return `5h resets ${formatClock(usage.fiveHour.resetsAt)}, week resets ${formatWeekdayClock(usage.week.resetsAt)}`;
}
