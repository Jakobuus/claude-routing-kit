import type {
  PluginButtonContentProps,
  PluginButtonIconProps,
} from "@getpaseo/plugin/client";
import type { PluginTheme } from "@getpaseo/plugin";
import { Text, View } from "react-native";
import {
  formatJulesFrees,
  formatJulesLabel,
  formatPace,
  formatProviderLabel,
  formatResets,
  formatTokens,
  julesSeverity,
  providerSeverity,
  worstSeverity,
  type Severity,
} from "../shared/parse";
import type { JulesUsage, ProviderUsage, TokenUsage } from "../shared/usage";
import { useUsage } from "./store";

function severityColor(severity: Severity | null, theme: PluginTheme, normal: string): string {
  if (severity === "critical") return theme.colors.statusDanger;
  if (severity === "warning") return theme.colors.statusWarning;
  if (severity === "normal") return normal;
  return theme.colors.foregroundMuted;
}

/** Dot in the pill's icon slot, coloured by the highest usage across all providers. */
export function UsageIcon({ theme, size, color }: PluginButtonIconProps) {
  const snapshot = useUsage();
  const severity = worstSeverity(snapshot);
  const dot = Math.max(6, Math.round(size * 0.55));
  // A stale Claude reading also dims the dot (the label says "old").
  const claudeStale = snapshot?.claude?.stale === true;
  return (
    <View style={{ width: size, height: size, alignItems: "center", justifyContent: "center" }}>
      <View
        style={{
          width: dot,
          height: dot,
          borderRadius: dot / 2,
          backgroundColor: severityColor(severity, theme, color),
          opacity: claudeStale ? 0.5 : 1,
        }}
      />
    </View>
  );
}

function ProviderRows({
  name,
  usage,
  theme,
}: {
  name: string;
  usage: ProviderUsage | null;
  theme: PluginTheme;
}) {
  const color = severityColor(providerSeverity(usage), theme, theme.colors.foreground);
  const dim = usage?.stale === true ? 0.5 : 1;
  return (
    <View style={{ gap: 2, opacity: dim }}>
      <Text style={{ color, fontWeight: "600" }}>{formatProviderLabel(name, usage)}</Text>
      <Text style={{ color: theme.colors.foregroundMuted }}>{formatPace(usage)}</Text>
      <Text style={{ color: theme.colors.foregroundMuted }}>{formatResets(usage)}</Text>
    </View>
  );
}

function TokenRow({ name, tokens, theme }: { name: string; tokens: TokenUsage; theme: PluginTheme }) {
  return <Text style={{ color: theme.colors.foreground, fontWeight: "600" }}>{formatTokens(name, tokens)}</Text>;
}

function JulesRows({ usage, theme }: { usage: JulesUsage | null; theme: PluginTheme }) {
  const color = severityColor(julesSeverity(usage), theme, theme.colors.foreground);
  return (
    <View style={{ gap: 2 }}>
      <Text style={{ color, fontWeight: "600" }}>{formatJulesLabel(usage)}</Text>
      <Text style={{ color: theme.colors.foregroundMuted }}>{formatJulesFrees(usage)}</Text>
    </View>
  );
}

/** Popover opened on press: one block per lane that is on, with local reset times. */
export function UsageDetails({ theme }: PluginButtonContentProps) {
  const snapshot = useUsage();
  if (!snapshot) {
    return (
      <View style={{ gap: 10 }}>
        <ProviderRows name="Claude" usage={null} theme={theme} />
        <Text style={{ color: theme.colors.foregroundMuted }}>kit-quota could not run</Text>
      </View>
    );
  }
  return (
    <View style={{ gap: 10 }}>
      {snapshot.claude && <ProviderRows name="Claude" usage={snapshot.claude} theme={theme} />}
      {snapshot.codex && <ProviderRows name="Codex" usage={snapshot.codex} theme={theme} />}
      {snapshot.jules && <JulesRows usage={snapshot.jules} theme={theme} />}
      {snapshot.kimi !== null && <TokenRow name="Kimi" tokens={snapshot.kimi} theme={theme} />}
      {snapshot.glm !== null && <TokenRow name="GLM" tokens={snapshot.glm} theme={theme} />}
    </View>
  );
}
