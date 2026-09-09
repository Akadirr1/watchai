import Foundation
import WatchConnectivity
import QuotaPetsShared

/// Receives snapshots from the phone and asks for fresh ones.
///
/// The direction matters. Apple documents that `sendMessage` from iOS does **not** wake
/// the watch app, while the reverse *does* wake the phone. So the watch pulls; the phone
/// never pushes on demand. Everything phone-initiated arrives opportunistically through
/// `updateApplicationContext` instead (research §5).
@MainActor
public final class WatchSyncService: NSObject, ObservableObject {
    @Published public private(set) var isReachable = false
    @Published public private(set) var lastSyncAt: Date?

    private let store: SnapshotStore
    private let onEvents: ([QuotaEvent]) -> Void
    private var session: WCSession { .default }
    /// Guards against the foreground timer and an onAppear both asking at once.
    private var requestInFlight = false

    public init(store: SnapshotStore, onEvents: @escaping ([QuotaEvent]) -> Void) {
        self.store = store
        self.onEvents = onEvents
        super.init()
        guard WCSession.isSupported() else { return }
        session.delegate = self
        session.activate()
    }

    /// Asks the phone for a fresh snapshot. Safe to call repeatedly — it coalesces, and
    /// no-ops when the phone is unreachable rather than erroring into the UI (§9).
    public func requestRefresh() {
        guard session.activationState == .activated, session.isReachable, !requestInFlight else { return }
        requestInFlight = true
        session.sendMessage(["request": "snapshot"], replyHandler: { [weak self] reply in
            Task { @MainActor in
                self?.requestInFlight = false
                self?.ingest(reply)
            }
        }, errorHandler: { [weak self] _ in
            // A failed pull is not an error state: the cached snapshot stays on screen
            // with its own freshness label, which is exactly what §10 asks for.
            Task { @MainActor in self?.requestInFlight = false }
        })
    }

    private func ingest(_ payload: [String: Any]) {
        guard let data = payload["snapshot"] as? Data,
              let snapshot = try? JSONDecoder().decode(UsageSnapshot.self, from: data) else { return }
        let events = store.apply(snapshot)
        lastSyncAt = Date()
        if !events.isEmpty { onEvents(events) }
    }
}

extension WatchSyncService: WCSessionDelegate {
    nonisolated public func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: (any Error)?) {
        Task { @MainActor in self.isReachable = session.isReachable }
    }

    nonisolated public func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.isReachable = session.isReachable
            // Becoming reachable is the cheapest possible moment to catch up.
            if session.isReachable { self.requestRefresh() }
        }
    }

    nonisolated public func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        Task { @MainActor in self.ingest(context) }
    }

    nonisolated public func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        Task { @MainActor in self.ingest(userInfo) }
    }
}
