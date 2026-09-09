import SwiftUI
import WatchKit
import QuotaPetsShared

@main
struct QuotaPetsWatchApp: App {
    @StateObject private var model = WatchModel()

    var body: some Scene {
        WindowGroup {
            WatchRootView().environmentObject(model)
        }
    }
}

@MainActor
final class WatchModel: ObservableObject {
    @Published private(set) var store = SnapshotStore()
    @Published var now = Date()
    private(set) var sync: WatchSyncService!
    /// Foreground-only ticker. Stopped the moment the scene leaves `.active`, so nothing
    /// pretends to survive suspension (§10, §20).
    private var ticker: Timer?

    init() {
        let store = self.store
        sync = WatchSyncService(store: store) { events in
            WatchModel.playHaptics(for: events)
        }
    }

    func becameActive() {
        // Show cached data instantly, then ask for fresh (§9).
        sync.requestRefresh()
        startTicking()
    }

    func becameInactive() {
        ticker?.invalidate()
        ticker = nil
    }

    /// One timer drives both the clock label and the refresh request, so there is no
    /// second polling loop to duplicate (§9).
    private func startTicking() {
        ticker?.invalidate()
        let t = Timer(timeInterval: RefreshSchedule.foregroundInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.now = Date()
                self?.sync.requestRefresh()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    /// Subtle while active, stronger for a weekly recharge (§21).
    private static func playHaptics(for events: [QuotaEvent]) {
        guard let strongest = events.max(by: { !$0.isMajor && $1.isMajor }) else { return }
        WKInterfaceDevice.current().play(strongest.isMajor ? .success : .click)
    }
}

struct WatchRootView: View {
    @EnvironmentObject private var model: WatchModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        TabView {
            ForEach(AIProvider.allCases, id: \.self) { provider in
                ProviderPageView(
                    provider: provider,
                    usage: model.store.snapshot?.usage(for: provider),
                    freshness: model.store.snapshot.map {
                        SnapshotFreshness.evaluate(generatedAt: $0.generatedAt, now: model.now)
                    },
                    error: nil,
                    // Animation stops when the scene is inactive OR the display is
                    // dimmed for Always-On (§16, §20).
                    isAnimating: scenePhase == .active && !isLuminanceReduced,
                    now: model.now
                )
            }
        }
        .tabViewStyle(.verticalPage)
        .onChange(of: scenePhase, initial: true) { _, phase in
            phase == .active ? model.becameActive() : model.becameInactive()
        }
    }
}
