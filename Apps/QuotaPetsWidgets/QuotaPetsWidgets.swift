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

// The four slot complications are written out one by one, each with literal strings, in
// the same shape as the QuotaPets widget that has always registered on the watch. A
// shared helper returning `some WidgetConfiguration` with interpolated names was the one
// new construct in the descriptor path when the app vanished from the face's picker.

struct ClaudeFiveHourWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.quotapets.claude-5h", provider: QuotaProvider()) { entry in
            WindowComplicationView(provider: .claude, window: .fiveHour, entry: entry)
        }
        .configurationDisplayName("Claude 5H")
        .description("Claude 5-hour quota left.")
        .supportedFamilies([.accessoryCorner, .accessoryCircular])
    }
}

struct ClaudeWeeklyWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.quotapets.claude-week", provider: QuotaProvider()) { entry in
            WindowComplicationView(provider: .claude, window: .weekly, entry: entry)
        }
        .configurationDisplayName("Claude WEEK")
        .description("Claude weekly quota left.")
        .supportedFamilies([.accessoryCorner, .accessoryCircular])
    }
}

struct CodexFiveHourWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.quotapets.codex-5h", provider: QuotaProvider()) { entry in
            WindowComplicationView(provider: .codex, window: .fiveHour, entry: entry)
        }
        .configurationDisplayName("Codex 5H")
        .description("Codex 5-hour quota left.")
        .supportedFamilies([.accessoryCorner, .accessoryCircular])
    }
}

struct CodexWeeklyWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.quotapets.codex-week", provider: QuotaProvider()) { entry in
            WindowComplicationView(provider: .codex, window: .weekly, entry: entry)
        }
        .configurationDisplayName("Codex WEEK")
        .description("Codex weekly quota left.")
        .supportedFamilies([.accessoryCorner, .accessoryCircular])
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

@main
struct QuotaPetsWidgetBundle: WidgetBundle {
    var body: some Widget {
        ClaudeFiveHourWidget()
        ClaudeWeeklyWidget()
        CodexFiveHourWidget()
        CodexWeeklyWidget()
        QuotaPetsWidgets()
    }
}
