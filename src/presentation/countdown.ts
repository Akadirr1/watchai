/**
 * Formats "time until reset": `42m`, `2h 13m`, `3d 6h`.
 *
 * Two units at most: enough precision to act on, short enough for a 41mm watch face.
 * The watch renders its own live countdown with `Text(style:.timer)`; this exists so the
 * API can carry a human-readable form too.
 */
export function formatCountdown(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds <= 0) return "0m";
  const total = Math.floor(seconds);
  const days = Math.floor(total / 86_400);
  const hours = Math.floor((total % 86_400) / 3_600);
  const minutes = Math.floor((total % 3_600) / 60);

  if (days > 0) return hours > 0 ? `${days}d ${hours}h` : `${days}d`;
  if (hours > 0) return minutes > 0 ? `${hours}h ${minutes}m` : `${hours}h`;
  return `${minutes}m`;
}

/** Renders the gap between now and a reset instant. Null when there is no reset time. */
export function countdownUntil(resetAt: number | null, now: number): string | null {
  if (resetAt === null) return null;
  // A past reset renders as "0m" rather than a negative value — the window is then
  // "reset pending refresh" and the caller shows that state instead.
  return formatCountdown(Math.max(0, (resetAt - now) / 1000));
}
