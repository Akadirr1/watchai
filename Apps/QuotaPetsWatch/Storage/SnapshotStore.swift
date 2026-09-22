import Foundation
import QuotaPetsShared

/// Last-known usage, persisted so the watch has something to show the instant it opens
/// (§24). Deliberately small: one snapshot plus its threshold state.
///
/// Uses a file in Application Support rather than UserDefaults. The payload is a
/// structured value, not a preference, and a file gives an atomic write.
@MainActor
public final class SnapshotStore: ObservableObject {
    @Published public private(set) var snapshot: UsageSnapshot?
    @Published public private(set) var thresholds: [String: ThresholdState] = [:]
    /// Providers busy right now. Not persisted: it only means something between two polls.
    @Published public private(set) var working: Set<AIProvider> = []

    private let url: URL

    /// The watch app and the widget extension are separate processes, so the snapshot
    /// lives in the shared App Group container rather than either one's own sandbox.
    /// App Groups are available on a free Personal Team — Apple's watchOS capability
    /// reference states the watch target's capabilities "don't depend on your program
    /// membership".
    public init(filename: String = "snapshot.json") {
        let directory = SharedContainer.directory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.url = directory.appendingPathComponent(filename)
        load()
    }

    private struct Persisted: Codable {
        var snapshot: UsageSnapshot?
        var thresholds: [String: ThresholdState]
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        snapshot = decoded.snapshot
        thresholds = decoded.thresholds
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(Persisted(snapshot: snapshot, thresholds: thresholds)) else { return }
        // Atomic so a crash mid-write cannot leave a truncated file that fails to decode
        // on next launch — which would silently look like "never synced".
        try? data.write(to: url, options: .atomic)
    }

    /// Applies a newly received snapshot, returning any events worth a haptic (§21).
    ///
    /// Out-of-order delivery is real: `transferUserInfo` is FIFO but background transfers
    /// can arrive after a newer `updateApplicationContext`. An older snapshot is dropped.
    public func apply(_ incoming: UsageSnapshot) -> [QuotaEvent] {
        if let current = snapshot, incoming.generatedAt <= current.generatedAt {
            return []
        }
        var events: [QuotaEvent] = []
        for provider in AIProvider.allCases {
            guard let usage = incoming.usage(for: provider) else { continue }
            for kind in [UsageWindowKind.fiveHour, .weekly] {
                guard let window = usage.window(kind) else { continue }
                let key = "\(provider.rawValue).\(kind.rawValue)"
                let result = ThresholdTracker.evaluate(
                    previous: thresholds[key] ?? ThresholdState(),
                    remainingPercent: window.remainingPercent,
                    window: kind)
                thresholds[key] = result.state
                events.append(contentsOf: result.events)
            }
        }
        working = incoming.busyProviders(since: snapshot)
        snapshot = incoming
        persist()
        return events
    }
}
