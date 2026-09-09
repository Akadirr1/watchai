import Foundation

/// Decodes Claude's `resets_at`, which is polymorphic: an ISO-8601 string, a numeric
/// string, or a number — and when numeric, it may be in **seconds or milliseconds**.
///
/// Ported concept: Orca `src/main/rate-limits/claude-usage-window.ts:11-30`.
/// Orca's reasoning, preserved because it is the whole justification for the constant:
/// 1e10 sits between any plausible seconds epoch (< year 2286) and any millisecond
/// epoch (> year 2001), so magnitude alone distinguishes the units.
///
/// Deliberately Claude-specific. Codex uses a *different* rule (`CodexResetTimestamp`)
/// and the two must never be merged — see docs/provider-research.md §3.5.
public enum ClaudeResetTimestamp {
    /// The boundary. Note the comparison is strictly greater-than, so exactly 1e10 is
    /// treated as **seconds**, matching Orca.
    static let millisecondBoundary: Double = 10_000_000_000

    public static func date(from value: ClaudeFlexibleTimestamp?) -> Date? {
        switch value {
        case nil, .some(.absent):
            return nil
        case .some(.number(let n)):
            return date(fromNumeric: n)
        case .some(.string(let s)):
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            // A numeric string is treated as an epoch, exactly as Orca does, before
            // falling back to date parsing.
            if let n = Double(trimmed), n.isFinite {
                return date(fromNumeric: n)
            }
            return ISO8601.date(from: trimmed)
        }
    }

    static func date(fromNumeric value: Double) -> Date? {
        guard value.isFinite else { return nil }
        let milliseconds = value > millisecondBoundary ? value : value * 1000
        guard milliseconds.isFinite else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }
}

/// A value that may arrive as a JSON string or a JSON number, and must never throw when
/// it arrives as neither. `.absent` covers null and unexpected types.
public enum ClaudeFlexibleTimestamp: Decodable, Sendable, Hashable {
    case number(Double)
    case string(String)
    case absent

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .absent
        } else if let d = try? container.decode(Double.self) {
            self = .number(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else {
            self = .absent
        }
    }
}
