import Foundation

/// Classifies Codex's `primary_window` / `secondary_window` into 5-hour and weekly
/// buckets **by duration, not by position**.
///
/// Ported from Orca `src/main/rate-limits/codex-rate-limit-window-classification.ts`.
/// The brief (§3) is emphatic that position must not be trusted, and it is right: the
/// backend does not guarantee that `primary_window` is the 5-hour one.
public enum CodexWindowClassifier {
    public static let sessionMinutes = 300
    public static let weeklyMinutes = 10_080
    /// Orca's justification: *"tolerate the one-minute drift seen in older Codex bucket
    /// lengths without absorbing other durations."*
    public static let toleranceMinutes = 1

    public struct Classified: Sendable, Hashable {
        public let fiveHour: CodexWindowPayload?
        public let weekly: CodexWindowPayload?
    }

    static func kind(of window: CodexWindowPayload) -> UsageWindowKind? {
        guard let d = window.durationMinutes else { return nil }
        if abs(d - sessionMinutes) <= toleranceMinutes { return .fiveHour }
        if abs(d - weeklyMinutes) <= toleranceMinutes { return .weekly }
        return nil
    }

    public static func classify(primary: CodexWindowPayload?, secondary: CodexWindowPayload?) -> Classified {
        // Unmappable windows (no finite percentage) are discarded up front, so they can
        // never be selected by the positional fallback either.
        let p = (primary?.isMappable ?? false) ? primary : nil
        let s = (secondary?.isMappable ?? false) ? secondary : nil

        var fiveHour: CodexWindowPayload?
        var weekly: CodexWindowPayload?

        // Pass 1 — duration wins, first match per kind.
        for window in [p, s].compactMap({ $0 }) {
            switch kind(of: window) {
            case .fiveHour where fiveHour == nil: fiveHour = window
            case .weekly where weekly == nil: weekly = window
            default: break
            }
        }

        // Pass 2 — legacy positional fallback, and note how narrow it deliberately is:
        // it applies ONLY to a window whose duration was unrecognised. A window that
        // positively classified as weekly is never also taken as the 5-hour window.
        // A naive "classify, else fall back to position" would mis-assign a payload
        // whose primary_window is the 7-day one (research §3.3).
        if fiveHour == nil, let p, kind(of: p) == nil { fiveHour = p }
        if weekly == nil, let s, kind(of: s) == nil { weekly = s }

        return Classified(fiveHour: fiveHour, weekly: weekly)
    }
}
