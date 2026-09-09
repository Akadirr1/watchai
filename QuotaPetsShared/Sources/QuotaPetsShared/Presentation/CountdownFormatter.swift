import Foundation

/// Formats "time until reset" (§34): `RESET 42m`, `RESET 2h 13m`, `RESET 3d 6h`.
///
/// Pure arithmetic on purpose. On the Watch this is used for the in-app label, while the
/// complication uses `Text(date, style: .timer)` so the countdown advances with no code
/// running and no timeline-reload budget spent (research §5).
public enum CountdownFormatter {
    /// Renders the gap between `now` and `date`. Returns nil when there is no date.
    /// A past date renders as "0m" rather than a negative value — the window is then
    /// "reset pending refresh" (§34) and the caller shows that state instead.
    public static func string(until date: Date?, now: Date) -> String? {
        guard let date else { return nil }
        let seconds = max(0, date.timeIntervalSince(now))
        return string(seconds: seconds)
    }

    public static func string(seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0m" }
        let total = Int(seconds.rounded(.down))
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60

        // Two units at most: enough precision to act on, short enough for a 41mm watch.
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        return "\(minutes)m"
    }
}
