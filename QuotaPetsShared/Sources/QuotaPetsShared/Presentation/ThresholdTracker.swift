import Foundation

/// Meaningful events worth a haptic (§21).
public enum QuotaEvent: Sendable, Hashable {
    /// Remaining quota fell below a threshold for the first time.
    case crossedBelow(threshold: Double, window: UsageWindowKind)
    /// A window reset — the 5-hour one is a small celebration, weekly a larger one.
    case recharged(window: UsageWindowKind)

    public var isMajor: Bool {
        switch self {
        case .recharged(let w): w == .weekly
        case .crossedBelow(let t, _): t <= 5
        }
    }
}

/// Persisted per-window state, so a crossing fires once rather than on every refresh.
public struct ThresholdState: Codable, Sendable, Hashable {
    /// Lowest threshold already announced for this window, if any.
    public var lastAnnouncedThreshold: Double?
    /// Last remaining percentage seen, used for reset detection.
    public var lastRemainingPercent: Double?

    public init(lastAnnouncedThreshold: Double? = nil, lastRemainingPercent: Double? = nil) {
        self.lastAnnouncedThreshold = lastAnnouncedThreshold
        self.lastRemainingPercent = lastRemainingPercent
    }
}

/// Detects threshold crossings and recharges without spamming (§21).
///
/// Pure and deterministic: it takes prior state plus a new reading and returns the new
/// state alongside any events. Nothing here schedules a notification — the caller
/// decides whether the app is foregrounded enough to make a haptic appropriate.
public enum ThresholdTracker {
    /// Descending so the *lowest* crossed threshold is reported, not every one.
    public static let thresholds: [Double] = [50, 25, 10, 5]

    /// A jump upward of at least this many points counts as a reset. Guards against a
    /// provider reporting small non-monotonic jitter as a full recharge.
    public static let rechargeDelta: Double = 5

    public static func evaluate(
        previous: ThresholdState,
        remainingPercent: Double,
        window: UsageWindowKind
    ) -> (state: ThresholdState, events: [QuotaEvent]) {
        let remaining = UsageWindow.clamp(remainingPercent)
        var state = previous
        var events: [QuotaEvent] = []

        // Recharge: a meaningful jump upward means the window rolled over.
        if let last = previous.lastRemainingPercent, remaining > last + rechargeDelta {
            events.append(.recharged(window: window))
            // Clear the announcement memory so the next depletion cycle can fire again.
            state.lastAnnouncedThreshold = nil
        }

        // Crossing: report only the lowest newly-crossed threshold, so falling from
        // 60% to 4% in one step yields one event (5) rather than four.
        let crossed = thresholds.filter { remaining < $0 }
        if let lowest = crossed.min() {
            let alreadyAnnounced = state.lastAnnouncedThreshold
            if alreadyAnnounced == nil || lowest < alreadyAnnounced! {
                events.append(.crossedBelow(threshold: lowest, window: window))
                state.lastAnnouncedThreshold = lowest
            }
        } else {
            // Back above every threshold — rearm.
            state.lastAnnouncedThreshold = nil
        }

        state.lastRemainingPercent = remaining
        return (state, events)
    }
}
