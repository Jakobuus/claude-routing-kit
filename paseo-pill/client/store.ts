import { useSyncExternalStore } from "react";
import type { UsageSnapshot } from "../shared/usage";

/** Latest usage snapshot, shared by the pill label, its icon and its popover. */
let current: UsageSnapshot | null = null;
const listeners = new Set<() => void>();

export function setUsage(next: UsageSnapshot | null): void {
  current = next;
  for (const listener of listeners) listener();
}

export function getUsageSnapshot(): UsageSnapshot | null {
  return current;
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

export function useUsage(): UsageSnapshot | null {
  return useSyncExternalStore(subscribe, getUsageSnapshot, getUsageSnapshot);
}
