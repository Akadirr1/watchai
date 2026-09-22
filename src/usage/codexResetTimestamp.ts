/**
 * Decodes Codex's `reset_at`.
 *
 * Ported from Orca `codex-rate-limit-window-mapper.ts:14-16`, whose comment is explicit:
 * *"Codex returns resetsAt as Unix seconds, not milliseconds."*
 *
 * Unlike the Claude decoder there is **no magnitude heuristic**: the unit is known.
 * Applying Claude's rule here would silently mis-scale any value above 1e10, and applying
 * this rule to Claude would put millisecond timestamps in the year 56 000. The duplication
 * between the two is intentional.
 */
export function codexResetAt(value: unknown): number | null {
  if (typeof value !== "number") return null;
  if (!Number.isFinite(value) || value <= 0) return null;
  return value * 1000;
}
