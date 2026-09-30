import type { PluginButton, PluginButtonRegistration, PluginClientContext } from "@getpaseo/plugin/client";
import { UsageDetails, UsageIcon } from "./client/pill";
import { getUsageSnapshot, setUsage } from "./client/store";
import { formatJulesFrees, formatJulesLabel, formatPillLabel, formatResets, formatTokens } from "./shared/parse";
import type { UsageSnapshot } from "./shared/usage";
import { usageRpc } from "./shared/usage";

const REFRESH_MS = 60_000;

/** Tooltip on hover: reset times in local time, for the lanes that are on. */
function tooltip(snapshot: UsageSnapshot | null): string {
  if (!snapshot) return "Usage unknown: kit-quota could not run";
  const parts: string[] = [];
  if (snapshot.claude) parts.push(`Claude ${formatResets(snapshot.claude)}${snapshot.claude.stale ? " (old reading)" : ""}`);
  if (snapshot.codex) parts.push(`Codex ${formatResets(snapshot.codex)}`);
  if (snapshot.jules) parts.push(`${formatJulesLabel(snapshot.jules)}, ${formatJulesFrees(snapshot.jules)}`);
  if (snapshot.kimi !== null) parts.push(formatTokens("Kimi", snapshot.kimi));
  if (snapshot.glm !== null) parts.push(formatTokens("GLM", snapshot.glm));
  return parts.join("  |  ");
}

function presentation(snapshot: UsageSnapshot | null): Pick<PluginButton, "label" | "title"> {
  return { label: formatPillLabel(snapshot), title: tooltip(snapshot) };
}

export default function contribute(client: PluginClientContext) {
  const pills = new Map<string, PluginButtonRegistration>();
  const lifetime = new AbortController();
  let stopped = false;

  const register = (agent: { id: string; workspaceId?: string | null }) => {
    if (stopped || !agent.workspaceId) return;
    pills.get(agent.id)?.remove();
    const registration = client.addComposerPill({
      id: "routing-kit-usage",
      workspaceId: agent.workspaceId,
      agentId: agent.id,
      button: {
        ...presentation(getUsageSnapshot()),
        icon: UsageIcon,
        behavior: { kind: "popover", Content: UsageDetails },
      },
    });
    pills.set(agent.id, registration);
  };

  const unregister = (agentId: string) => {
    pills.get(agentId)?.remove();
    pills.delete(agentId);
  };

  const refresh = async () => {
    let snapshot: UsageSnapshot | null;
    try {
      snapshot = await client.rpc(usageRpc, {});
    } catch {
      snapshot = null; // shows "–"; never throw into the host
    }
    if (stopped) return;
    setUsage(snapshot);
    const patch = presentation(snapshot);
    for (const pill of pills.values()) pill.update(patch);
  };

  void client.paseo.agents
    .list({ subscribe: {}, signal: lifetime.signal })
    .then(({ subscription }) => {
      subscription.subscribe({
        snapshot: ({ entries }) => {
          for (const pill of pills.values()) pill.remove();
          pills.clear();
          for (const { agent } of entries) register(agent);
        },
        update: (message) => {
          if (message.type !== "agent_update") return;
          const update = message.payload;
          if (update.kind === "remove") unregister(update.agentId);
          else register(update.agent);
        },
      });
      return undefined;
    })
    .catch((error: unknown) => {
      if (!stopped) console.error("Usage pill: agent observation failed", error);
    });

  void refresh();
  const timer = setInterval(() => void refresh(), REFRESH_MS);

  return () => {
    stopped = true;
    clearInterval(timer);
    lifetime.abort();
    for (const pill of pills.values()) pill.remove();
    pills.clear();
  };
}
