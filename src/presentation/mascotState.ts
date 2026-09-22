import type { UsageWindowKind } from "../models/provider.js";
import { clampPercent, remainingPercent } from "../models/usageWindow.js";
import type { ProviderUsage } from "../models/snapshot.js";

export type MascotEnergyState =
  | "hyper" | "happy" | "normal" | "tired" | "exhausted" | "empty";

export interface MascotPressure {
  readonly state: MascotEnergyState;
  readonly remainingPercent: number;
  readonly constrainingWindow: UsageWindowKind;
}

/**
 * Energy bands, evaluated on clamped remaining percent.
 *
 * The brief lists `1..<15: exhausted` and `0: empty`, leaving 0 < r < 1 unspecified. We
 * resolve that gap toward `exhausted`: a pet with 0.4% left is not out of quota, and only
 * a true zero should read as collapsed.
 */
export function mascotStateFor(remaining: number): MascotEnergyState {
  const r = clampPercent(remaining);
  if (r <= 0) return "empty";
  if (r < 15) return "exhausted";
  if (r < 30) return "tired";
  if (r < 50) return "normal";
  if (r < 75) return "happy";
  return "hyper";
}

/**
 * Pressure comes from the *tightest* window: `min(fiveHourRemaining, weeklyRemaining)`.
 *
 * When only one window is present it is used alone — a missing weekly window must not be
 * read as 0% remaining and panic the mascot.
 */
export function resolveMascotPressure(usage: ProviderUsage | null): MascotPressure | null {
  if (!usage) return null;

  const candidates: Array<[UsageWindowKind, number]> = [];
  if (usage.fiveHour) candidates.push(["fiveHour", remainingPercent(usage.fiveHour)]);
  if (usage.weekly) candidates.push(["weekly", remainingPercent(usage.weekly)]);
  if (candidates.length === 0) return null;

  let tightest = candidates[0]!;
  for (const candidate of candidates) if (candidate[1] < tightest[1]) tightest = candidate;

  return {
    state: mascotStateFor(tightest[1]),
    remainingPercent: tightest[1],
    constrainingWindow: tightest[0],
  };
}
