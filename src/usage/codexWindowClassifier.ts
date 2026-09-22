import type { UsageWindowKind } from "../models/provider.js";

export interface CodexWindowPayload {
  readonly usedPercent: number | null;
  readonly durationMinutes: number | null;
  readonly resetAtRaw: unknown;
}

export const SESSION_MINUTES = 300;
export const WEEKLY_MINUTES = 10_080;
/** Orca: "tolerate the one-minute drift seen in older Codex bucket lengths." */
export const TOLERANCE_MINUTES = 1;

function isMappable(w: CodexWindowPayload | null): w is CodexWindowPayload {
  return w !== null && w.usedPercent !== null && Number.isFinite(w.usedPercent);
}

export function classifyDuration(w: CodexWindowPayload): UsageWindowKind | null {
  const d = w.durationMinutes;
  if (d === null || !Number.isFinite(d)) return null;
  if (Math.abs(d - SESSION_MINUTES) <= TOLERANCE_MINUTES) return "fiveHour";
  if (Math.abs(d - WEEKLY_MINUTES) <= TOLERANCE_MINUTES) return "weekly";
  return null;
}

/**
 * Classifies Codex's primary/secondary windows **by duration, not by position**.
 *
 * Ported from Orca `codex-rate-limit-window-classification.ts:43-74`. The backend does not
 * guarantee that `primary_window` is the 5-hour one, so trusting position swaps the two
 * figures on a payload where it isn't.
 */
export function classifyCodexWindows(
  primaryRaw: CodexWindowPayload | null,
  secondaryRaw: CodexWindowPayload | null,
): { fiveHour: CodexWindowPayload | null; weekly: CodexWindowPayload | null } {
  // Unmappable windows are discarded up front, so they can never be selected by the
  // positional fallback either.
  const primary = isMappable(primaryRaw) ? primaryRaw : null;
  const secondary = isMappable(secondaryRaw) ? secondaryRaw : null;

  let fiveHour: CodexWindowPayload | null = null;
  let weekly: CodexWindowPayload | null = null;

  // Pass 1 — duration wins, first match per kind.
  for (const window of [primary, secondary]) {
    if (!window) continue;
    const kind = classifyDuration(window);
    if (kind === "fiveHour" && fiveHour === null) fiveHour = window;
    else if (kind === "weekly" && weekly === null) weekly = window;
  }

  // Pass 2 — legacy positional fallback, and note how narrow it deliberately is: it
  // applies ONLY to a window whose duration was unrecognised. A window that positively
  // classified as weekly is never also taken as the 5-hour window.
  if (fiveHour === null && primary && classifyDuration(primary) === null) fiveHour = primary;
  if (weekly === null && secondary && classifyDuration(secondary) === null) weekly = secondary;

  return { fiveHour, weekly };
}
