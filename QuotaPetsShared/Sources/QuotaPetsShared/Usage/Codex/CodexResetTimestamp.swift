import Foundation

/// Decodes Codex's `reset_at`.
///
/// Ported concept: Orca `codex-rate-limit-window-mapper.ts:14-16`, whose comment is
/// explicit — *"Codex returns resetsAt as Unix seconds, not milliseconds."*
///
/// Unlike `ClaudeResetTimestamp` there is **no magnitude heuristic**: the unit is known.
/// Applying Claude's heuristic here would silently mis-scale any value above 1e10, and
/// applying this rule to Claude would put millisecond timestamps in the year 56 000.
/// The duplication between the two types is intentional (research §3.5).
public enum CodexResetTimestamp {
    public static func date(fromUnixSeconds value: Double?) -> Date? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return Date(timeIntervalSince1970: value)
    }
}
