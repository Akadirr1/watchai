import type { UsageWindowKind } from "../models/provider.js";
import { clampPercent } from "../models/usageWindow.js";

export type QuotaEvent =
  | { readonly type: "crossedBelow"; readonly threshold: number; readonly window: UsageWindowKind }
  | { readonly type: "recharged"; readonly window: UsageWindowKind };

export interface ThresholdState {
  /** Lowest threshold already announced for this window, if any. */
  readonly lastAnnouncedThreshold: number | null;
  /** Last remaining percentage seen, used for reset detection. */
  readonly lastRemainingPercent: number | null;
}

export const EMPTY_THRESHOLD_STATE: ThresholdState = {
  lastAnnouncedThreshold: null,
  lastRemainingPercent: null,
};

/** Descending, so the *lowest* crossed threshold is reported rather than every one. */
export const THRESHOLDS = [50, 25, 10, 5] as const;

/**
 * A jump upward of at least this many points counts as a reset. Guards against a provider
 * reporting small non-monotonic jitter as a full recharge.
 */
export const RECHARGE_DELTA = 5;

export function isMajorEvent(event: QuotaEvent): boolean {
  return event.type === "recharged"
    ? event.window === "weekly"
    : event.threshold <= 5;
}

/**
 * Detects threshold crossings and recharges without spamming.
 *
 * Pure and deterministic: takes prior state plus a new reading and returns new state
 * alongside any events.
 */
export function evaluateThresholds(
  previous: ThresholdState,
  remaining: number,
  window: UsageWindowKind,
): { state: ThresholdState; events: QuotaEvent[] } {
  const value = clampPercent(remaining);
  const events: QuotaEvent[] = [];
  let lastAnnounced = previous.lastAnnouncedThreshold;

  // Recharge: a meaningful jump upward means the window rolled over.
  if (
    previous.lastRemainingPercent !== null &&
    value > previous.lastRemainingPercent + RECHARGE_DELTA
  ) {
    events.push({ type: "recharged", window });
    // Clear the announcement memory so the next depletion cycle can fire again.
    lastAnnounced = null;
  }

  // Crossing: report only the lowest newly-crossed threshold, so falling from 60% to 4%
  // in one step yields one event (5) rather than four.
  const crossed = THRESHOLDS.filter((t) => value < t);
  if (crossed.length > 0) {
    const lowest = Math.min(...crossed);
    if (lastAnnounced === null || lowest < lastAnnounced) {
      events.push({ type: "crossedBelow", threshold: lowest, window });
      lastAnnounced = lowest;
    }
  } else {
    // Back above every threshold — rearm.
    lastAnnounced = null;
  }

  return {
    state: { lastAnnouncedThreshold: lastAnnounced, lastRemainingPercent: value },
    events,
  };
}
