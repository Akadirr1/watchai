import Foundation

/// The kind of quota window. Both providers expose exactly these two, and the brief
/// (§33) requires both to be visible for both providers.
public enum UsageWindowKind: String, Codable, Sendable, Hashable {
    case fiveHour
    case weekly

    /// Canonical duration in minutes. These are the same constants Orca classifies
    /// Codex windows against (300 / 10080) — see docs/provider-research.md §3.3.
    public var canonicalMinutes: Int {
        switch self {
        case .fiveHour: 300
        case .weekly: 10_080
        }
    }

    public var shortLabel: String {
        switch self {
        case .fiveHour: "5H"
        case .weekly: "WEEK"
        }
    }
}

/// A single quota window.
///
/// `usedPercent` is canonical (§32): provider APIs report *used*, so that is what we
/// store, and `remainingPercent` is always derived. The two are never stored
/// independently, which makes it impossible for them to disagree.
public struct UsageWindow: Codable, Sendable, Hashable {
    /// Percentage of the window consumed. Always clamped to 0...100 at construction.
    public let usedPercent: Double
    /// When the window resets, if the provider told us.
    public let resetAt: Date?
    /// Window length. May differ slightly from `kind.canonicalMinutes` — Codex has been
    /// observed reporting bucket lengths off by a minute (research §3.3).
    public let duration: TimeInterval?

    public init(usedPercent: Double, resetAt: Date? = nil, duration: TimeInterval? = nil) {
        self.usedPercent = UsageWindow.clamp(usedPercent)
        self.resetAt = resetAt
        self.duration = duration
    }

    /// Derived, never stored (§32).
    public var remainingPercent: Double {
        UsageWindow.clamp(100 - usedPercent)
    }

    /// Clamps into 0...100 and maps non-finite input to 0.
    ///
    /// NaN is the case worth calling out: a naive `min(100, max(0, x))` propagates NaN
    /// straight through to the UI, where it renders as "nan%". Malformed provider data
    /// must never do that (§8: never crash, never display nonsense).
    public static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return Swift.min(100, Swift.max(0, value))
    }

    /// True once the reset instant has passed. The brief (§34) is explicit that this
    /// means "reset pending refresh" — we must NOT assume usage dropped to zero until
    /// the provider confirms it.
    public func isResetPending(now: Date) -> Bool {
        guard let resetAt else { return false }
        return resetAt <= now
    }
}
