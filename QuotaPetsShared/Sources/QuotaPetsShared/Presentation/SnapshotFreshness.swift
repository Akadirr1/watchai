import Foundation

/// How much to trust what is on screen (§10).
///
/// The brief is explicit: never show old values as if they are live. Every surface that
/// renders a number also renders one of these.
public enum SnapshotFreshness: Sendable, Hashable {
    case live(age: TimeInterval)
    case stale(age: TimeInterval)

    /// Past this age a snapshot is labelled stale rather than live. Chosen as 2× the
    /// foreground refresh interval (§9), so a single missed refresh does not
    /// immediately cry wolf.
    public static let staleThreshold: TimeInterval = 120

    public var age: TimeInterval {
        switch self {
        case .live(let a), .stale(let a): a
        }
    }

    public var isStale: Bool {
        if case .stale = self { return true }
        return false
    }

    public static func evaluate(generatedAt: Date, now: Date) -> SnapshotFreshness {
        // Clamp at zero: a snapshot stamped slightly in the future (clock skew between
        // the helper Mac and the phone) must not render as a negative age.
        let age = max(0, now.timeIntervalSince(generatedAt))
        return age > staleThreshold ? .stale(age: age) : .live(age: age)
    }

    /// `UPDATED 42s AGO` / `STALE · 8m`
    public var label: String {
        let a = Int(age.rounded(.down))
        switch self {
        case .live:
            return a < 60 ? "UPDATED \(a)s AGO" : "UPDATED \(CountdownFormatter.string(seconds: age)) AGO"
        case .stale:
            return "STALE · \(CountdownFormatter.string(seconds: age))"
        }
    }
}
