import WidgetKit
import SwiftUI
import QuotaPetsShared

/// Reads what the watch app wrote. Never fetches: the app is the only thing that talks to
/// the server, and it reloads these timelines every time it writes a new snapshot.
func loadSharedSnapshot() -> UsageSnapshot? {
    guard let data = try? Data(contentsOf: SharedContainer.snapshotURL()) else { return nil }
    struct Persisted: Decodable { let snapshot: UsageSnapshot? }
    return try? JSONDecoder().decode(Persisted.self, from: data).snapshot
}

struct QuotaEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageSnapshot?
}

/// Timeline provider.
///
/// The budget is the binding constraint: watchOS allows **75 reloads per day**, about
/// one per 19 minutes at best. The numbers only change when the app writes a new
/// snapshot, and the app reloads this timeline when it does (`SnapshotStore.persist`).
/// So the timeline never schedules a reload of its own: a timed policy would spend that
/// same budget re-reading a file nothing has rewritten.
///
/// What keeps the complication alive between reloads is `Text(timerInterval:)`, which
/// advances on screen with no code running and no budget spend, and which Apple confirms
/// keeps updating during Always-On (research §5). That is the entire §11 mechanism.
struct QuotaProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuotaEntry {
        QuotaEntry(date: Date(), snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (QuotaEntry) -> Void) {
        completion(QuotaEntry(date: Date(), snapshot: loadSharedSnapshot()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuotaEntry>) -> Void) {
        let entry = QuotaEntry(date: Date(), snapshot: loadSharedSnapshot())
        completion(Timeline(entries: [entry], policy: .never))
    }
}

/// Static frame selection — complications never animate (§19). Battery-friendly and
/// correct under Always-On.
private func mascotSymbol(_ state: MascotEnergyState) -> String {
    switch state {
    case .hyper, .happy: "bolt.fill"
    case .normal: "circle.fill"
    case .tired: "moon.fill"
    case .exhausted: "moon.zzz.fill"
    case .empty: "zzz"
    }
}

private func remaining(_ usage: ProviderUsage?, _ kind: UsageWindowKind) -> String {
    usage?.window(kind).map { "\(Int($0.remainingPercent.rounded()))" } ?? "--"
}

/// What the mascot reacts to, as a percentage: Claude's weekly window, Codex's tighter one.
private func percentLeft(_ pressure: MascotPressure?) -> String {
    pressure.map { "\(Int($0.remainingPercent.rounded()))%" } ?? "--"
}

/// Both providers at once: the rectangular and inline slots.
struct QuotaComplicationView: View {
    @Environment(\.widgetFamily) private var family
    let entry: QuotaEntry

    var body: some View {
        switch family {
        case .accessoryRectangular: rectangular
        default: inline
        }
    }

    /// `CLAUDE  36 / 69` — first is 5H remaining, second WEEK (§18).
    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(AIProvider.allCases, id: \.self) { provider in
                let usage = entry.snapshot?.usage(for: provider)
                HStack(spacing: 4) {
                    Image(systemName: mascotSymbol(MascotStateResolver.mascotPressure(usage)?.state ?? .normal))
                        .font(.system(size: 9))
                    Text(provider.displayName.uppercased())
                        .font(.system(size: 10, weight: .medium))
                    Spacer(minLength: 2)
                    Text("\(remaining(usage, .fiveHour)) / \(remaining(usage, .weekly))")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                }
            }
        }
        .containerBackground(for: .widget) { Color.clear }
    }

    /// `C 36% · X 53%` — each provider's number as its pet reads it (§18).
    private var inline: some View {
        let c = percentLeft(MascotStateResolver.mascotPressure(entry.snapshot?.claude))
        let x = percentLeft(MascotStateResolver.mascotPressure(entry.snapshot?.codex))
        return Text("C \(c) · X \(x)")
            .containerBackground(for: .widget) { Color.clear }
    }
}

/// One window of one provider, for a corner or circular slot. Each of the four is its own
/// entry in the face's complication picker, so every slot says one fixed thing instead of
/// following whichever window happens to be tighter.
struct WindowComplicationView: View {
    @Environment(\.widgetFamily) private var family
    let provider: AIProvider
    let window: UsageWindowKind
    let entry: QuotaEntry

    private var value: String {
        entry.snapshot?.usage(for: provider)?.window(window)
            .map { "\(Int($0.remainingPercent.rounded()))%" } ?? "--"
    }

    var body: some View {
        switch family {
        case .accessoryCorner:
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                // Curves along the bezel.
                .widgetLabel { Text("\(provider.displayName.uppercased()) \(window.shortLabel)") }
                .containerBackground(for: .widget) { Color.clear }
        default:
            VStack(spacing: 0) {
                Text(provider.displayName.uppercased())
                    .font(.system(size: 8, weight: .medium))
                Text(value)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                Text(window.shortLabel)
                    .font(.system(size: 8, weight: .medium))
            }
            .containerBackground(for: .widget) { Color.clear }
        }
    }
}

/// The pixel Claude from `ClaudeMascotRig`, cropped to the character. The app's
/// `ClaudeMascotView` fills the same polygons; this copy exists because the widget target
/// shares only the package with the app, never the app's own files.
private struct ClaudeRigCanvas: View {
    let shapes: [RigShape]

    var body: some View {
        // Worked out before the Canvas, so the renderer captures plain values.
        let visible = shapes.filter { $0.opacity > 0 }
        let xs = visible.flatMap { $0.points.map(\.x) }
        let ys = visible.flatMap { $0.points.map(\.y) }
        Canvas { context, size in
            guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max(),
                  maxX > minX, maxY > minY else { return }
            let scale = min(size.width / (maxX - minX), size.height / (maxY - minY))
            context.translateBy(x: (size.width - (maxX - minX) * scale) / 2 - minX * scale,
                                y: (size.height - (maxY - minY) * scale) / 2 - minY * scale)
            context.scaleBy(x: scale, y: scale)
            for shape in visible {
                var path = Path()
                path.addLines(shape.points)
                path.closeSubpath()
                let color = Color(red: Double(shape.rgb >> 16 & 0xFF) / 255,
                                  green: Double(shape.rgb >> 8 & 0xFF) / 255,
                                  blue: Double(shape.rgb & 0xFF) / 255)
                context.fill(path, with: .color(color.opacity(shape.opacity)))
            }
        }
    }
}

/// Claude, drawn, on the watch face — the biggest surface watchOS gives a third-party
/// app: a rectangular slot on Modular, Modular Duo, Modular Ultra, Infograph Modular or
/// the Smart Stack.
///
/// A complication cannot animate, so the pixel Claude holds the first frame of its mood —
/// what the app shows while dimmed — and the countdown is what moves.
/// `Text(timerInterval:)` rather than `.timer`: it stops at zero instead of counting back
/// up past a reset the snapshot has not caught up with.
struct ClaudePetView: View {
    let entry: QuotaEntry

    var body: some View {
        let usage = entry.snapshot?.claude
        let pressure = MascotStateResolver.mascotPressure(usage)
        HStack(spacing: 6) {
            // The bandana switch lives in the app's own defaults, out of the widget's reach;
            // on is its default.
            ClaudeRigCanvas(shapes: ClaudeMascotRig.shapes(
                ClaudeClip.rotation(for: pressure?.state ?? .normal, working: false), at: 0, bandana: true))
                .aspectRatio(1.5, contentMode: .fit)
                .widgetAccentable()

            VStack(alignment: .leading, spacing: 0) {
                Text("CLAUDE")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(percentLeft(pressure))
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                    if let kind = pressure?.constrainingWindow {
                        Text(kind.shortLabel)
                            .font(.system(size: 10, weight: .medium))
                    }
                }
                if let kind = pressure?.constrainingWindow,
                   let reset = usage?.window(kind)?.resetAt, reset > entry.date {
                    // A weekly reset days away reads better as a day than as 100+ hours.
                    Group {
                        if reset.timeIntervalSince(entry.date) < 86_400 {
                            Text(timerInterval: entry.date...reset, countsDown: true)
                        } else {
                            Text(reset, format: .dateTime.weekday(.abbreviated).hour().minute())
                        }
                    }
                    .font(.system(size: 11, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .containerBackground(for: .widget) { Color.clear }
    }
}

@main
struct QuotaPetsWidgetBundle: WidgetBundle {
    var body: some Widget {
        ClaudeFiveHourWidget()
        ClaudeWeeklyWidget()
        CodexFiveHourWidget()
        CodexWeeklyWidget()
        QuotaPetsWidgets()
        ClaudePetWidget()
    }
}

@MainActor
private func windowWidget(_ provider: AIProvider, _ window: UsageWindowKind) -> some WidgetConfiguration {
    let name = "\(provider.displayName) \(window.shortLabel)"
    let span = window == .fiveHour ? "5-hour" : "weekly"
    return StaticConfiguration(kind: "com.quotapets.\(provider.rawValue).\(window.rawValue)",
                               provider: QuotaProvider()) { entry in
        WindowComplicationView(provider: provider, window: window, entry: entry)
    }
    .configurationDisplayName(name)
    .description("\(provider.displayName) \(span) quota left.")
    .supportedFamilies([.accessoryCorner, .accessoryCircular])
}

struct ClaudeFiveHourWidget: Widget {
    var body: some WidgetConfiguration { windowWidget(.claude, .fiveHour) }
}

struct ClaudeWeeklyWidget: Widget {
    var body: some WidgetConfiguration { windowWidget(.claude, .weekly) }
}

struct CodexFiveHourWidget: Widget {
    var body: some WidgetConfiguration { windowWidget(.codex, .fiveHour) }
}

struct CodexWeeklyWidget: Widget {
    var body: some WidgetConfiguration { windowWidget(.codex, .weekly) }
}

struct ClaudePetWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.quotapets.pet", provider: QuotaProvider()) { entry in
            ClaudePetView(entry: entry)
        }
        .configurationDisplayName("Claude Pet")
        .description("Claude at its weekly energy, with the reset countdown.")
        .supportedFamilies([.accessoryRectangular])
    }
}

struct QuotaPetsWidgets: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.quotapets.complication", provider: QuotaProvider()) { entry in
            QuotaComplicationView(entry: entry)
        }
        .configurationDisplayName("QuotaPets")
        .description("Claude and Codex quota remaining.")
        .supportedFamilies([.accessoryRectangular, .accessoryInline])
    }
}
