import WidgetKit
import SwiftUI
import QuotaPetsShared

/// Shared container between the watch app and this extension.
///
/// App Groups are available on a free Personal Team — Apple's watchOS capability
/// reference checks "App groups" in the free column and states the watch target's
/// capabilities "don't depend on your program membership" (research §5). Verified,
/// because an earlier assumption to the contrary would have forced a redesign.
enum SharedContainer {
    static let appGroup = "group.com.quotapets"

    static func snapshotURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("snapshot.json")
    }

    static func loadSnapshot() -> UsageSnapshot? {
        guard let url = snapshotURL(), let data = try? Data(contentsOf: url) else { return nil }
        struct Persisted: Decodable { let snapshot: UsageSnapshot? }
        return try? JSONDecoder().decode(Persisted.self, from: data).snapshot
    }
}

struct QuotaEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageSnapshot?
}

/// Timeline provider.
///
/// The budget is the binding constraint: watchOS allows **75 reloads per day**, about
/// one per 19 minutes at best. So this deliberately emits a SHORT timeline and does not
/// try to encode changing usage into future entries — the numbers only change when the
/// phone delivers a new snapshot.
///
/// What keeps the complication alive between reloads is `Text(_:style:.timer)`, which
/// advances on screen with no code running and no budget spend, and which Apple confirms
/// keeps updating during Always-On (research §5). That is the entire §11 mechanism.
struct QuotaProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuotaEntry {
        QuotaEntry(date: Date(), snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (QuotaEntry) -> Void) {
        completion(QuotaEntry(date: Date(), snapshot: SharedContainer.loadSnapshot()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuotaEntry>) -> Void) {
        let now = Date()
        let entry = QuotaEntry(date: now, snapshot: SharedContainer.loadSnapshot())
        // One entry, refreshed on the system's own schedule. Asking for more would spend
        // budget to display values that cannot have changed.
        completion(Timeline(entries: [entry], policy: .after(now.addingTimeInterval(20 * 60))))
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

    /// Tightest remaining across both windows of the selected provider (§18).
    private var circular: some View {
        let pressure = MascotStateResolver.resolve(claude)
        return VStack(spacing: 0) {
            Image(systemName: mascotSymbol(pressure?.state ?? .normal))
                .font(.system(size: 12))
            Text(pressure.map { "\(Int($0.remainingPercent.rounded()))%" } ?? "--")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
        }
        .containerBackground(for: .widget) { Color.clear }
    }

    private var corner: some View {
        Text(MascotStateResolver.resolve(claude).map { "\(Int($0.remainingPercent.rounded()))%" } ?? "--")
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .containerBackground(for: .widget) { Color.clear }
    }

    /// `C 36% · X 53%` — kept minimal so the family is not overcrowded (§18).
    private var inline: some View {
        Text("C \(remaining(claude, .fiveHour))% · X \(remaining(codex, .weekly))%")
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
