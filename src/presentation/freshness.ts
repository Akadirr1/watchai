/**
 * How much to trust what is on screen. Every surface showing a number also shows one of
 * these — the brief is explicit that old values must never be presented as live.
 */
export type Freshness = "live" | "stale";

/** Past this age a snapshot is stale. 2x the 60s poll interval, so one missed tick doesn't cry wolf. */
export const STALE_THRESHOLD_SEC = 120;

export interface FreshnessResult {
  readonly freshness: Freshness;
  readonly ageSec: number;
}

export function evaluateFreshness(generatedAt: number, now: number): FreshnessResult {
  // Clamp at zero: a snapshot stamped slightly in the future (clock skew between the
  // server and a client) must not render as a negative age.
  const ageSec = Math.max(0, (now - generatedAt) / 1000);
  // Boundary is exclusive: exactly 120s is still live.
  return { freshness: ageSec > STALE_THRESHOLD_SEC ? "stale" : "live", ageSec };
}
