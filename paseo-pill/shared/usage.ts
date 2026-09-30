import { defineRpc } from "@getpaseo/plugin";
import { z } from "zod";

/** Every value is null when unknown; the pill shows "–" for it. */
const windowSchema = z.object({
  /** Used percent, 0–100. */
  percent: z.number().nullable(),
  /** Reset time as epoch milliseconds. */
  resetsAt: z.number().nullable(),
  /** kit-quota's pace: used percent against elapsed share of the window (100 = on track to run out). */
  pace: z.number().nullable(),
});

const providerSchema = z.object({
  fiveHour: windowSchema,
  week: windowSchema,
  /** Claude only: the reading is old (no recent statusline update). */
  stale: z.boolean(),
});

/** Jules counts tasks started in a rolling 24-hour window, not fixed resets. */
const julesSchema = z.object({
  /** Tasks started in the last 24 hours (may exceed the limit). */
  used: z.number().nullable(),
  /** Daily task limit, at least 1. */
  limit: z.number().nullable(),
  /** Tasks running now. */
  running: z.number().nullable(),
  concurrentLimit: z.number().nullable(),
  /** used / limit × 100 (may exceed 100). */
  percent: z.number().nullable(),
  /** When the oldest counted task leaves the window, epoch milliseconds. */
  freesAt: z.number().nullable(),
});

/** Tokens and spend for a lane this month. A null field is unknown; the whole lane is null when it's off. */
const tokensSchema = z.object({
  tokens: z.number().nullable(),
  spendUsd: z.number().nullable(),
});

/** One `kit-quota --json` reading. A null lane is switched off in the profile: its line is hidden. */
export const usageSnapshotSchema = z.object({
  claude: providerSchema.nullable(),
  codex: providerSchema.nullable(),
  jules: julesSchema.nullable(),
  kimi: tokensSchema.nullable(),
  glm: tokensSchema.nullable(),
});

export type UsageWindow = z.infer<typeof windowSchema>;
export type ProviderUsage = z.infer<typeof providerSchema>;
export type JulesUsage = z.infer<typeof julesSchema>;
export type TokenUsage = z.infer<typeof tokensSchema>;
export type UsageSnapshot = z.infer<typeof usageSnapshotSchema>;

export const usageRpc = defineRpc({
  name: "usage.get",
  input: z.object({}),
  /** null when kit-quota could not be found or run. */
  output: usageSnapshotSchema.nullable(),
});
