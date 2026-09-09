import Foundation
import WatchConnectivity
import QuotaPetsShared

/// Phone side of the link.
///
/// The phone never tries to *wake* the watch — Apple documents that `sendMessage` from
/// iOS does not wake the WatchKit extension (research §5). So the phone answers pulls
/// and stages data via `updateApplicationContext`, which is latest-value-wins and
/// therefore exactly right for "here is the newest snapshot".
@MainActor
final class PhoneSyncService: NSObject, ObservableObject {
    @Published private(set) var lastPushAt: Date?
    @Published private(set) var lastPushError: String?

    /// Supplies the newest snapshot when the watch asks for one.
    var snapshotProvider: (() async -> UsageSnapshot?)?

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Stages the latest snapshot for the watch. Cheap and safe to call on every
    /// successful refresh: application context replaces rather than queues, so it cannot
    /// build a backlog.
    func push(_ snapshot: UsageSnapshot) {
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        do {
            try session.updateApplicationContext(["snapshot": data])
            lastPushAt = Date()
            lastPushError = nil
        } catch {
            lastPushError = error.localizedDescription
        }
    }
}

extension PhoneSyncService: WCSessionDelegate {
    nonisolated func session(_ s: WCSession, activationDidCompleteWith st: WCSessionActivationState, error: (any Error)?) {}
    nonisolated func sessionDidBecomeInactive(_ s: WCSession) {}
    nonisolated func sessionDidDeactivate(_ s: WCSession) { s.activate() }

    /// The watch pulling. This direction *does* wake the phone, which is why the design
    /// puts the initiative on the watch.
    nonisolated func session(_ s: WCSession, didReceiveMessage m: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        Task { @MainActor in
            guard let snapshot = await snapshotProvider?(),
                  let data = try? JSONEncoder().encode(snapshot) else {
                replyHandler([:])
                return
            }
            replyHandler(["snapshot": data])
        }
    }
}
