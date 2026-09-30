import type { PluginServerContext } from "@getpaseo/plugin/server";
import { getUsage } from "./server/usage";
import { usageRpc } from "./shared/usage";

export default function contribute(server: PluginServerContext) {
  server.handle(usageRpc, () => getUsage());
  return () => {};
}
