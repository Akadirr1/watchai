import SwiftUI
import QuotaPetsShared

/// One provider page: mascot dominant, usage subordinate (§13).
///
/// Deliberately no large progress bars. Two small percentages and a countdown carry the
/// information; the mascot carries the feeling.
struct ProviderPageView: View {
    let provider: AIProvider
    let usage: ProviderUsage?
    let freshness: SnapshotFreshness?
    let error: ProviderError?
    let isAnimating: Bool
    let now: Date

    private var pressure: MascotPressure? { MascotStateResolver.resolve(usage) }

    var body: some View {
        VStack(spacing: 4) {
            Text(provider.displayName)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)

            MascotView(provider: provider,
                       state: pressure?.state ?? .normal,
                       isAnimating: isAnimating)
                .frame(height: 74)

            if let error {
                Text(error.watchLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.orange)
            } else if let usage {
                windows(usage)
                countdown(usage)
            } else {
                Text("NOT CONNECTED")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if let freshness {
                Text(freshness.label)
                    .font(.system(size: 9))
                    .foregroundStyle(freshness.isStale ? .orange : .secondary)
            }
        }
        .padding(.horizontal, 6)
    }

    /// Both windows are always shown (§33), and the constraining one is emphasised so
    /// the user can see *why* the mascot looks the way it does (§17).
    @ViewBuilder
    private func windows(_ usage: ProviderUsage) -> some View {
        HStack(spacing: 12) {
            ForEach([UsageWindowKind.fiveHour, .weekly], id: \.self) { kind in
                let window = usage.window(kind)
                VStack(spacing: 0) {
                    Text(window.map { "\(Int($0.remainingPercent.rounded()))%" } ?? "--")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(pressure?.constrainingWindow == kind ? .primary : .secondary)
                    Text(kind.shortLabel)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
        }
        // Labelled as LEFT because remaining is what the user cares about (§32).
        .accessibilityLabel(accessibilitySummary(usage))
    }

    /// The countdown uses `Text(_:style:.timer)` rather than a formatted string: it
    /// advances on screen with no code running and, in the complication, no timeline
    /// budget spend (research §5).
    @ViewBuilder
    private func countdown(_ usage: ProviderUsage) -> some View {
        if let kind = pressure?.constrainingWindow,
           let reset = usage.window(kind)?.resetAt {
            if reset > now {
                HStack(spacing: 3) {
                    Text("reset")
                    Text(reset, style: .timer)
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            } else {
                // §34: never assume the window zeroed just because the clock passed.
                Text("resetting…")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func accessibilitySummary(_ usage: ProviderUsage) -> String {
        let parts = [UsageWindowKind.fiveHour, .weekly].compactMap { kind -> String? in
            guard let w = usage.window(kind) else { return nil }
            return "\(kind == .fiveHour ? "5 hour" : "weekly") \(Int(w.remainingPercent.rounded())) percent left"
        }
        return parts.joined(separator: ", ")
    }
}
