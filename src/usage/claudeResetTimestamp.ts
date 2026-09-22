/**
 * Decodes Claude's `resets_at`, which is polymorphic: an ISO-8601 string, a numeric
 * string, or a number — and when numeric, it may be in **seconds or milliseconds**.
 *
 * Ported from Orca `src/main/rate-limits/claude-usage-window.ts:11-30`. Orca's reasoning,
 * preserved because it is the whole justification for the constant: 1e10 sits between any
 * plausible seconds epoch (< year 2286) and any millisecond epoch (> year 2001), so
 * magnitude alone distinguishes the units.
 *
 * Deliberately Claude-specific. Codex uses a *different* rule and the two must never be
 * merged — Orca's own codebase applies opposite meanings to this boundary in
 * `claude-usage-window.ts:16` and `codex-reset-credit-client.ts:46`.
 */

/** Note the comparison is strictly greater-than, so exactly 1e10 is treated as seconds. */
export const MILLISECOND_BOUNDARY = 10_000_000_000;

export function claudeResetFromNumber(value: number): number | null {
  if (!Number.isFinite(value)) return null;
  const ms = value > MILLISECOND_BOUNDARY ? value : value * 1000;
  return Number.isFinite(ms) ? ms : null;
}

/** Returns epoch milliseconds, or null when the value is absent or unusable. */
export function claudeResetAt(value: unknown): number | null {
  if (typeof value === "number") return claudeResetFromNumber(value);
  if (typeof value !== "string") return null;

  const trimmed = value.trim();
  if (trimmed === "") return null;

  // A numeric string is treated as an epoch, exactly as Orca does, BEFORE falling back
  // to date parsing.
  const asNumber = Number(trimmed);
  if (Number.isFinite(asNumber)) return claudeResetFromNumber(asNumber);

  const parsed = Date.parse(trimmed);
  return Number.isNaN(parsed) ? null : parsed;
}
