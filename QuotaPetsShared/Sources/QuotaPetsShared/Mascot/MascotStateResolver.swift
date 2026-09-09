import Foundation

/// Resolves mascot energy from usage. Kept out of Views deliberately (§15) so the
/// Watch app, the complication and the debug gallery cannot disagree about what 27%
/// looks like.
public enum MascotStateResolver {
    /// Band thresholds from §15, expressed as lower bounds on *remaining* percent.
    ///
    /// The brief lists `1..<15: exhausted` and `0: empty`, leaving 0 < r < 1
    /// unspecified. We resolve that gap toward `.exhausted`: a pet with 0.4% left is
    /// not out of quota, and only a true zero should read as collapsed.
    public static func state(forRemainingPercent remaining: Double) -> MascotEnergyState {
        let r = UsageWindow.clamp(remaining)
        if r <= 0 { return .empty }
        if r < 15 { return .exhausted }
        if r < 30 { return .tired }
        if r < 50 { return .normal }
        if r < 75 { return .happy }
        return .hyper
    }

    /// Pressure comes from the *tightest* window (§15):
    /// `pressure = min(fiveHourRemaining, weeklyRemaining)`.
    ///
    /// When only one window is present it is used alone — a missing weekly window must
    /// not be read as 0% remaining and panic the mascot.
    public static func resolve(_ usage: ProviderUsage?) -> MascotPressure? {
        guard let usage else { return nil }

        let candidates: [(UsageWindowKind, Double)] = [
            usage.fiveHour.map { (UsageWindowKind.fiveHour, $0.remainingPercent) },
            usage.weekly.map { (UsageWindowKind.weekly, $0.remainingPercent) },
        ].compactMap { $0 }

        guard let tightest = candidates.min(by: { $0.1 < $1.1 }) else { return nil }

        return MascotPressure(
            state: state(forRemainingPercent: tightest.1),
            remainingPercent: tightest.1,
            constrainingWindow: tightest.0
        )
    }
}
