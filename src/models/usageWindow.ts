import type { UsageWindowKind } from "./provider.js";

/**
 * A single quota window.
 *
 * `usedPercent` is canonical: provider APIs report *used*, so that is what we store and
 * `remainingPercent` is always derived. The two are never stored independently, which
 * makes it impossible for them to disagree.
 */
export interface UsageWindow {
  readonly usedPercent: number;
  /** Epoch milliseconds, or null when the provider didn't tell us. */
  readonly resetAt: number | null;
  /** Window length in seconds, or null. */
  readonly durationSec: number | null;
}

/**
 * Clamps into 0...100, mapping non-finite input to 0.
 *
 * The NaN case is the one worth calling out: a naive `Math.min(100, Math.max(0, x))`
 * propagates NaN straight through to the API, where it serialises as `null` and renders
 * as "nan%". Malformed provider data must never do that.
 */
export function clampPercent(value: number): number {
  if (!Number.isFinite(value)) return 0;
  return Math.min(100, Math.max(0, value));
}

export function makeWindow(
  usedPercent: number,
  resetAt: number | null,
  durationSec: number | null,
): UsageWindow {
  return { usedPercent: clampPercent(usedPercent), resetAt, durationSec };
}

export function remainingPercent(window: UsageWindow): number {
  return clampPercent(100 - window.usedPercent);
}

/**
 * True once the reset instant has passed. This means "reset pending refresh" — we must
 * NOT assume usage dropped to zero until the provider confirms it.
 */
export function isResetPending(window: UsageWindow, now: number): boolean {
  return window.resetAt !== null && window.resetAt <= now;
}

export function windowOf(
  usage: { fiveHour: UsageWindow | null; weekly: UsageWindow | null } | null,
  kind: UsageWindowKind,
): UsageWindow | null {
  if (!usage) return null;
  return kind === "fiveHour" ? usage.fiveHour : usage.weekly;
}
