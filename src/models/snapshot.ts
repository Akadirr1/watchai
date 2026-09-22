import type { AIProvider } from "./provider.js";
import type { UsageWindow } from "./usageWindow.js";

/** Per-provider state the API surfaces. Mirrors the Swift `ProviderError` taxonomy. */
export type ProviderState =
  | "ok"
  | "stale"
  | "auth"
  | "offline"
  | "rate_limited"
  | "provider_error"
  | "never_fetched";

/**
 * Normalised, provider-neutral usage. Nothing Anthropic- or OpenAI-shaped survives past
 * this type — raw provider JSON never reaches the API surface.
 */
export interface ProviderUsage {
  readonly provider: AIProvider;
  readonly fiveHour: UsageWindow | null;
  readonly weekly: UsageWindow | null;
  readonly planName: string | null;
  /** Epoch milliseconds. */
  readonly fetchedAt: number;
}

export interface UsageSnapshot {
  readonly claude: ProviderUsage | null;
  readonly codex: ProviderUsage | null;
  /** Epoch milliseconds. */
  readonly generatedAt: number;
}

export const EMPTY_SNAPSHOT: UsageSnapshot = {
  claude: null,
  codex: null,
  generatedAt: 0,
};

/**
 * True when the provider returned neither window. Distinguishes "connected but the
 * payload carried nothing we understand" from "not connected".
 */
export function isEmptyUsage(usage: ProviderUsage): boolean {
  return usage.fiveHour === null && usage.weekly === null;
}

export function usageFor(
  snapshot: UsageSnapshot,
  provider: AIProvider,
): ProviderUsage | null {
  return provider === "claude" ? snapshot.claude : snapshot.codex;
}

/**
 * Replaces one provider's slot, preserving the other. Used because the two providers are
 * fetched on a stagger, so only one has new data at a time.
 */
export function replaceUsage(
  snapshot: UsageSnapshot,
  usage: ProviderUsage,
  generatedAt: number,
): UsageSnapshot {
  return usage.provider === "claude"
    ? { claude: usage, codex: snapshot.codex, generatedAt }
    : { claude: snapshot.claude, codex: usage, generatedAt };
}
