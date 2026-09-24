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

/// The tighter window's remaining — the same number the pet's mood is drawn from.
private func tightest(_ pressure: MascotPressure?) -> String {
    pressure.map { "\(Int($0.remainingPercent.rounded()))%" } ?? "--"
}

struct QuotaComplicationView: View {
    @Environment(\.widgetFamily) private var family
    let entry: QuotaEntry

    private var claude: ProviderUsage? { entry.snapshot?.claude }
    private var codex: ProviderUsage? { entry.snapshot?.codex }

    var body: some View {
        switch family {
        case .accessoryRectangular: rectangular
        case .accessoryCircular: circular
        case .accessoryCorner: corner
        default: inline
        }
    }

    /// `CLAUDE  36 / 69` — first is 5H remaining, second WEEK (§18).
    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(AIProvider.allCases, id: \.self) { provider in
                let usage = entry.snapshot?.usage(for: provider)
                HStack(spacing: 4) {
                    Image(systemName: mascotSymbol(MascotStateResolver.resolve(usage)?.state ?? .normal))
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

    /// Tightest remaining across both windows of the selected provider (§18), and which
    /// window that is. Unlabelled, a weekly number moves so slowly it reads as frozen.
    private var circular: some View {
        let pressure = MascotStateResolver.resolve(claude)
        return VStack(spacing: 0) {
            Image(systemName: mascotSymbol(pressure?.state ?? .normal))
                .font(.system(size: 10))
            Text(tightest(pressure))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
            if let kind = pressure?.constrainingWindow {
                Text(kind.shortLabel)
                    .font(.system(size: 8, weight: .medium))
            }
        }
        .containerBackground(for: .widget) { Color.clear }
    }

    private var corner: some View {
        let pressure = MascotStateResolver.resolve(claude)
        return Text(tightest(pressure))
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            // Curves along the bezel: which provider, and which window the number is.
            .widgetLabel {
                Text(pressure?.constrainingWindow.map { "CLAUDE \($0.shortLabel)" } ?? "CLAUDE")
            }
            .containerBackground(for: .widget) { Color.clear }
    }

    /// `C 36% · X 53%` — each provider's tighter window, as on its pet (§18). It used to
    /// be Claude's 5-hour beside Codex's weekly, two numbers that meant different things.
    private var inline: some View {
        let c = tightest(MascotStateResolver.resolve(claude))
        let x = tightest(MascotStateResolver.resolve(codex))
        return Text("C \(c) · X \(x)")
            .containerBackground(for: .widget) { Color.clear }
    }
}

@main
struct QuotaPetsWidgets: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.quotapets.complication", provider: QuotaProvider()) { entry in
            QuotaComplicationView(entry: entry)
        }
        .configurationDisplayName("QuotaPets")
        .description("Claude and Codex quota remaining.")
        .supportedFamilies([.accessoryRectangular, .accessoryCircular, .accessoryCorner, .accessoryInline])
    }
}
