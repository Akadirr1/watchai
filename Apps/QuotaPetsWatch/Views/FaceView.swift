import SwiftUI
import WatchKit
import QuotaPetsShared

/// The live pet, dressed as a watch face.
///
/// As close as watchOS lets a third-party app get: apps cannot ship watch faces, and a
/// complication is a static snapshot that cannot animate, so a pet that breathes, blinks
/// and wilts can only live in the app. This is its first page, so opening the app lands
/// here. With Settings › General › Return to Clock › QuotaPets › Custom › After 1 hour, a
/// wrist raise brings it back instead of the clock, and Always-On keeps it on screen,
/// dimmed and still.
struct FaceView: View {
    let usage: ProviderUsage?
    let generatedAt: Date?
    let isAnimating: Bool

    @State private var hopping = false

    private var pressure: MascotPressure? { MascotStateResolver.resolve(usage) }
    private var state: MascotEnergyState { pressure?.state ?? .normal }

    var body: some View {
        // Once a minute is all Always-On redraws anyway, and the staleness check rides
        // the same tick — `model.now` stops with the ticker the moment the wrist drops.
        TimelineView(.everyMinute) { context in
            VStack(spacing: 2) {
                Text(context.date, format: .dateTime.hour(.defaultDigits(amPM: .omitted)).minute())
                    .font(.system(size: 36, weight: .semibold, design: .rounded))
                    .monospacedDigit()

                Button { pet() } label: {
                    MascotView(provider: .claude, state: state, isAnimating: isAnimating)
                        .frame(height: 92)
                        // A full pet leaps, a spent one barely stirs: the reaction reads
                        // the same energy the arms do.
                        .offset(y: hopping ? -CGFloat(18 - 3 * state.severity) : 0)
                        .animation(.spring(response: 0.22, dampingFraction: 0.45), value: hopping)
                }
                .buttonStyle(.plain)
                // Double Tap (Series 9, Ultra 2 and later) pets it hands-free.
                .handGestureShortcut(.primaryAction)

                summary(now: context.date)
            }
        }
    }

    private func pet() {
        WKInterfaceDevice.current().play(.click)
        hopping = true
        Task {
            try? await Task.sleep(for: .milliseconds(180))
            hopping = false
        }
    }

    /// Both windows, the one the pet is reacting to emphasised (§17).
    @ViewBuilder
    private func summary(now: Date) -> some View {
        if let usage {
            HStack(spacing: 10) {
                ForEach([UsageWindowKind.fiveHour, .weekly], id: \.self) { kind in
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(usage.window(kind).map { "\(Int($0.remainingPercent.rounded()))%" } ?? "--")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                        Text(kind.shortLabel)
                            .font(.system(size: 9))
                    }
                    .foregroundStyle(pressure?.constrainingWindow == kind ? .primary : .secondary)
                }
            }
        } else {
            Text("NOT CONNECTED")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        // Only once stale: a face stays up for an hour, and an old number must not pass
        // as a live one (§10) — exactly what the complication used to do.
        if let generatedAt {
            let freshness = SnapshotFreshness.evaluate(generatedAt: generatedAt, now: now)
            if freshness.isStale {
                Text(freshness.label)
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
            }
        }
    }
}
