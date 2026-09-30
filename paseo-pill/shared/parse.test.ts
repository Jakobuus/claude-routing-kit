import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  formatClock,
  formatJulesFrees,
  formatJulesLabel,
  formatPace,
  formatPillLabel,
  formatProviderLabel,
  formatResets,
  formatTokens,
  formatWeekdayClock,
  julesSeverity,
  parseKitQuota,
  providerSeverity,
  severityOf,
  worstSeverity,
} from "./parse";
import type { UsageSnapshot } from "./usage";

// Runs with TZ=UTC (see the npm test script) so local-time output is deterministic.
const now = Date.parse("2025-09-23T12:00:00Z");
const sec = (iso: string): number => Date.parse(iso) / 1000;

const unknownBucket = { percent: null, resets_epoch: null, pace: null };

/** A full `kit-quota --json` object with every lane on, as the script prints it. */
function kitQuota(overrides: Record<string, unknown> = {}): string {
  return JSON.stringify({
    claude: {
      five_hour: { percent: 42, resets_epoch: sec("2025-09-23T19:54:00Z"), pace: 60 },
      week: { percent: 27, resets_epoch: sec("2025-09-26T17:30:00Z"), pace: 31 },
      stale: false,
    },
    codex: {
      five_hour: { percent: 12, resets_epoch: 1758649200, pace: 20 },
      week: { percent: 34, resets_epoch: 1759167600, pace: null },
    },
    jules: {
      used: 3, limit: 15, running: 0, concurrent_limit: 3, percent: 20,
      frees_at_epoch: sec("2025-09-24T14:32:00Z"),
    },
    kimi: { tokens: 12345, spend_usd: 0.42 },
    glm: { tokens: 0, spend_usd: 0 },
    ...overrides,
  });
}

function parsed(overrides: Record<string, unknown> = {}): UsageSnapshot {
  const snapshot = parseKitQuota(kitQuota(overrides), now);
  assert.ok(snapshot, "kit-quota sample must parse");
  return snapshot;
}

describe("parseKitQuota", () => {
  it("reads every lane of the kit-quota --json object", () => {
    assert.deepEqual(parseKitQuota(kitQuota(), now), {
      claude: {
        fiveHour: { percent: 42, resetsAt: Date.parse("2025-09-23T19:54:00Z"), pace: 60 },
        week: { percent: 27, resetsAt: Date.parse("2025-09-26T17:30:00Z"), pace: 31 },
        stale: false,
      },
      codex: {
        fiveHour: { percent: 12, resetsAt: 1758649200_000, pace: 20 },
        week: { percent: 34, resetsAt: 1759167600_000, pace: null },
        stale: false,
      },
      jules: {
        used: 3, limit: 15, running: 0, concurrentLimit: 3, percent: 20,
        freesAt: Date.parse("2025-09-24T14:32:00Z"),
      },
      kimi: { tokens: 12345, spendUsd: 0.42 },
      glm: { tokens: 0, spendUsd: 0 },
    });
  });

  it("parses the exact line kit-quota prints for a fresh install", () => {
    const text = '{"claude":{"five_hour":{"percent":null,"resets_epoch":null,"pace":null},"week":{"percent":null,"resets_epoch":null,"pace":null},"stale":false},"codex":null,"jules":null,"kimi":null,"glm":null}\n';
    const blank = { percent: null, resetsAt: null, pace: null };
    assert.deepEqual(parseKitQuota(text, now), {
      claude: { fiveHour: blank, week: blank, stale: false },
      codex: null,
      jules: null,
      kimi: null,
      glm: null,
    });
  });

  it("keeps Claude's stale flag", () => {
    const claude = { five_hour: unknownBucket, week: { percent: 5, resets_epoch: null, pace: null }, stale: true };
    assert.equal(parsed({ claude }).claude?.stale, true);
  });

  it("treats a null or missing lane as switched off", () => {
    const snapshot = parseKitQuota(JSON.stringify({ claude: null, codex: null }), now);
    assert.deepEqual(snapshot, { claude: null, codex: null, jules: null, kimi: null, glm: null });
  });

  it("treats a lane that is on but unreadable as unknown, not off", () => {
    const snapshot = parsed({
      codex: { five_hour: unknownBucket, week: unknownBucket },
      jules: { used: null, limit: null, running: null, concurrent_limit: null, percent: null, frees_at_epoch: null },
    });
    assert.deepEqual(snapshot.codex, {
      fiveHour: { percent: null, resetsAt: null, pace: null },
      week: { percent: null, resetsAt: null, pace: null },
      stale: false,
    });
    assert.notEqual(snapshot.jules, null);
    assert.equal(snapshot.jules?.used, null);
    // A lane object of the wrong shape is still "on": its values are unknown.
    assert.deepEqual(parsed({ codex: "garbage" }).codex?.fiveHour, { percent: null, resetsAt: null, pace: null });
  });

  it("returns null for output that is not a kit-quota object", () => {
    for (const text of ["", "not json", "[]", "null", "42", "kit-quota: macOS only"]) {
      assert.equal(parseKitQuota(text, now), null, JSON.stringify(text));
    }
  });

  it("makes invalid percentages unknown without hiding the other window", () => {
    for (const percent of [-1, 101, "12", Number.NaN]) {
      const claude = {
        five_hour: { percent, resets_epoch: sec("2025-09-23T19:54:00Z"), pace: 60 },
        week: { percent: 27, resets_epoch: null, pace: null },
        stale: false,
      };
      const snapshot = parsed({ claude });
      assert.equal(snapshot.claude?.fiveHour.percent, null, String(percent));
      assert.equal(snapshot.claude?.week.percent, 27);
      assert.match(formatPillLabel(snapshot), /^C–\/27%/);
    }
  });

  it("makes invalid reset times and paces unknown and never formats NaN", () => {
    for (const bad of [0, 999999999999999, "garbage", -5]) {
      const codex = {
        five_hour: { percent: 12, resets_epoch: bad, pace: -5 },
        week: { percent: 34, resets_epoch: 1759167600, pace: 40 },
      };
      const usage = parsed({ codex }).codex;
      assert.deepEqual(usage?.fiveHour, { percent: 12, resetsAt: null, pace: null });
      assert.equal(formatResets(usage ?? null), "5h resets –, week resets Mon 17:40");
      assert.doesNotMatch(formatResets(usage ?? null), /NaN/);
      assert.doesNotMatch(formatPace(usage ?? null), /NaN/);
    }
  });

  it("rejects negative or non-integer Jules counts as unknown", () => {
    for (const jules of [
      { used: -1, limit: 15, running: 0, concurrent_limit: 3, percent: 0, frees_at_epoch: null },
      { used: 3, limit: 0, running: 0, concurrent_limit: 3, percent: 20, frees_at_epoch: null },
      { used: 3.5, limit: 15, running: 0, concurrent_limit: 3, percent: 20, frees_at_epoch: null },
      { used: "3", limit: 15, running: 0, concurrent_limit: 3, percent: 20, frees_at_epoch: null },
    ]) {
      const usage = parsed({ jules }).jules;
      assert.notEqual(usage, null);
      assert.equal(formatJulesLabel(usage), "Jules –", JSON.stringify(jules));
    }
  });

  it("allows Jules above its daily limit", () => {
    const jules = { used: 18, limit: 15, running: 1, concurrent_limit: 3, percent: 120, frees_at_epoch: null };
    assert.equal(parsed({ jules }).jules?.percent, 120);
  });

  it("makes a non-object Kimi or GLM value unknown, not off", () => {
    const snapshot = parsed({ kimi: "lots", glm: -4 });
    assert.deepEqual(snapshot.kimi, { tokens: null, spendUsd: null });
    assert.deepEqual(snapshot.glm, { tokens: null, spendUsd: null });
  });

  it("makes a non-count token or a negative spend unknown without hiding the other field", () => {
    const snapshot = parsed({
      kimi: { tokens: "lots", spend_usd: 0.42 },
      glm: { tokens: 100, spend_usd: -4 },
    });
    assert.deepEqual(snapshot.kimi, { tokens: null, spendUsd: 0.42 });
    assert.deepEqual(snapshot.glm, { tokens: 100, spendUsd: null });
  });
});

describe("severity", () => {
  it("uses the 70 and 90 thresholds", () => {
    assert.equal(severityOf(69), "normal");
    assert.equal(severityOf(70), "warning");
    assert.equal(severityOf(89), "warning");
    assert.equal(severityOf(90), "critical");
  });

  it("ignores unknown windows", () => {
    assert.equal(providerSeverity(parseKitQuota(kitQuota({ claude: { five_hour: unknownBucket, week: unknownBucket, stale: false } }), now)?.claude ?? null), null);
  });

  it("takes the worst across lanes", () => {
    const codex = { five_hour: { percent: 91, resets_epoch: null, pace: null }, week: unknownBucket };
    assert.equal(worstSeverity(parsed({ codex })), "critical");
    assert.equal(worstSeverity(null), null);
    assert.equal(worstSeverity(parsed({ claude: null, codex: null, jules: null })), null);
  });

  it("rates Jules by percent, and warns when every concurrent slot is busy", () => {
    const jules = (percent: number, running: number) =>
      parsed({ jules: { used: 1, limit: 15, running, concurrent_limit: 3, percent, frees_at_epoch: null } }).jules;
    assert.equal(julesSeverity(null), null);
    assert.equal(julesSeverity(jules(20, 0)), "normal");
    assert.equal(julesSeverity(jules(73, 0)), "warning");
    assert.equal(julesSeverity(jules(93, 0)), "critical");
    assert.equal(julesSeverity(jules(20, 3)), "warning");
  });
});

describe("formatting", () => {
  function assertPillLabel(snapshot: UsageSnapshot | null, expected: string): void {
    const label = formatPillLabel(snapshot);
    assert.equal(label, expected);
    assert.ok(label.length <= 24, `pill label is ${label.length} characters: ${label}`);
  }

  it("shows Claude and Codex 5-hour and weekly values", () => {
    assertPillLabel(parsed(), "C42/27% X12/34%");
  });

  it("fits 100% in every window, even when Claude is stale", () => {
    const full = { percent: 100, resets_epoch: null, pace: null };
    assertPillLabel(
      parsed({ claude: { five_hour: full, week: full, stale: true }, codex: { five_hour: full, week: full } }),
      "C100/100% old X100/100%",
    );
  });

  it("marks a stale Claude reading as old", () => {
    const claude = {
      five_hour: { percent: 42, resets_epoch: null, pace: null },
      week: { percent: 27, resets_epoch: null, pace: null },
      stale: true,
    };
    const snapshot = parsed({ claude });
    assertPillLabel(snapshot, "C42/27% old X12/34%");
    assert.equal(formatProviderLabel("Claude", snapshot.claude), "Claude 5h 42% · wk 27% · old reading");
  });

  it("hides a lane that is off", () => {
    assertPillLabel(parsed({ codex: null }), "C42/27%");
    assertPillLabel(parsed({ claude: null }), "X12/34%");
    assertPillLabel(parsed({ claude: null, codex: null }), "–");
  });

  it("shows – for unknown values", () => {
    assertPillLabel(parsed({ codex: { five_hour: unknownBucket, week: unknownBucket } }), "C42/27% X–/–%");
    assertPillLabel(parsed({ codex: { five_hour: unknownBucket, week: { percent: 34, resets_epoch: null, pace: null } } }), "C42/27% X–/34%");
    assert.equal(formatProviderLabel("Codex", parsed({ codex: { five_hour: unknownBucket, week: unknownBucket } }).codex), "Codex 5h – · wk –");
  });

  it("shows only Claude as unknown when kit-quota could not run", () => {
    assertPillLabel(null, "C–/–%");
  });

  it("formats pace per window", () => {
    const snapshot = parsed();
    assert.equal(formatPace(snapshot.claude), "pace 5h 60% · wk 31%");
    assert.equal(formatPace(snapshot.codex), "pace 5h 20% · wk –");
    assert.equal(formatPace(null), "–");
  });

  it("formats the Jules lines", () => {
    const usage = parsed().jules;
    assert.equal(formatJulesLabel(usage), "Jules 24h 20% · 0/3 running");
    assert.equal(formatJulesFrees(usage), "oldest frees 14:32");
    assert.equal(formatJulesFrees(parsed({ jules: { used: 0, limit: 15, running: 0, concurrent_limit: 3, percent: 0, frees_at_epoch: null } }).jules), "–");
    assert.equal(formatJulesLabel(null), "Jules –");
    assert.equal(formatJulesFrees(null), "–");
  });

  it("formats Kimi and GLM spend and token counts, with – for unknown parts", () => {
    assert.equal(formatTokens("Kimi", { tokens: 12345, spendUsd: 0.42 }), "Kimi $0.42 this month · 12,345 tokens");
    assert.equal(formatTokens("GLM", { tokens: 0, spendUsd: 0 }), "GLM $0.00 this month · 0 tokens");
    assert.equal(formatTokens("GLM", { tokens: 1234567, spendUsd: 12.3 }), "GLM $12.30 this month · 1,234,567 tokens");
    assert.equal(formatTokens("Kimi", { tokens: 33, spendUsd: 0.000098 }), "Kimi <$0.01 this month · 33 tokens");
    assert.equal(formatTokens("Kimi", { tokens: null, spendUsd: null }), "Kimi $– this month · – tokens");
  });

  it("leaves the pill label to Claude and Codex", () => {
    assertPillLabel(parsed({ jules: null, kimi: null, glm: null }), "C42/27% X12/34%");
  });

  it("formats reset times in local time", () => {
    assert.equal(formatClock(Date.parse("2025-09-23T19:54:00Z")), "19:54");
    assert.equal(formatWeekdayClock(Date.parse("2025-09-26T17:30:00Z")), "Fri 17:30");
    assert.equal(formatResets(parsed().claude), "5h resets 19:54, week resets Fri 17:30");
    assert.equal(formatResets(parsed({ codex: { five_hour: unknownBucket, week: unknownBucket } }).codex), "5h resets –, week resets –");
    assert.equal(formatResets(null), "–");
  });
});
