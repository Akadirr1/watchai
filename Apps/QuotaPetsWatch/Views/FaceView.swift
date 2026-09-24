import AVKit
import SwiftUI
import WatchKit
import QuotaPetsShared

/// The live pet, as a watch face.
///
/// watchOS has no API for third-party faces, up to and including watchOS 27. Every
/// "custom face" app is one of two things: an image or Live Photo on Apple's Photos face,
/// or an app that draws a clock and stays in front — Clockology is the latter, and so is
/// this. It is the app's first page, so opening the app lands here. With Settings ›
/// General › Return to Clock › QuotaPets › Custom › After 1 hour, a wrist raise brings it
/// back instead of the Apple face, and Always-On keeps it on screen, dimmed and still.
struct FaceView: View {
    let usage: ProviderUsage?
    let generatedAt: Date?
    /// Usage rose since the last poll, which puts Claude to work.
    let working: Bool
    let isAnimating: Bool

    @State private var hopping = false

    private var pressure: MascotPressure? { MascotStateResolver.mascotPressure(usage) }
    private var state: MascotEnergyState { pressure?.state ?? .normal }

    var body: some View {
        // Once a minute is all Always-On redraws anyway, and the staleness check rides
        // the same tick — `model.now` stops with the ticker the moment the wrist drops.
        TimelineView(.everyMinute) { context in
            let stale = generatedAt.map {
                SnapshotFreshness.evaluate(generatedAt: $0, now: context.date).isStale
            } ?? true
            VStack(spacing: 2) {
                Text(context.date, format: .dateTime.weekday(.abbreviated).day())
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Text(context.date, format: .dateTime.hour(.defaultDigits(amPM: .omitted)).minute())
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()

                Button { pet() } label: {
                    // Busy only on fresh data, as on the Claude page: stale can't say.
                    MascotView(provider: .claude, state: state, working: working && !stale,
                               isAnimating: isAnimating)
                        // Whatever the text leaves: the rig keeps headroom for its jumps.
                        .frame(minHeight: 74, maxHeight: .infinity)
                        // A full pet leaps, a spent one barely stirs: the tap reads the
                        // same weekly energy as the mood.
                        .offset(y: hopping ? -CGFloat(18 - 3 * state.severity) : 0)
                        .animation(.spring(response: 0.22, dampingFraction: 0.45), value: hopping)
                }
                .buttonStyle(.plain)
                // Double Tap (Series 9, Ultra 2 and later) pets it hands-free.
                .handGestureShortcut(.primaryAction)

                summary(now: context.date)
            }
        }
        // Every watch app carries the system time in its corner, which gives a face two
        // clocks. watchOS drops it while a VideoPlayer is on screen, so an invisible one
        // does the job — a known workaround for full-screen clocks. Undocumented: if an
        // update stops honouring it, the small system time simply comes back.
        .background {
            VideoPlayer(player: nil)
                .focusable(false) // keeps the Digital Crown on page scrolling, not volume
                .disabled(true)
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
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
