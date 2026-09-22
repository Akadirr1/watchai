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
    @Published private(set) var lastError: APIClient.Failure?
    @Published var now = Date()

    private let client: APIClient?
    /// Foreground-only ticker. Stopped the moment the scene leaves `.active`, so nothing
    /// pretends to survive suspension.
    private var ticker: Timer?
    /// Guards against the timer and an onAppear both fetching at once.
    private var inFlight = false

    init(client: APIClient? = APIClient()) {
        self.client = client
    }

    var isConfigured: Bool { client != nil }

    func becameActive() {
        // Cached data is already on screen; ask for fresh in the background.
        refresh()
        startTicking()
    }

    func becameInactive() {
        ticker?.invalidate()
        ticker = nil
    }

    /// One timer drives both the clock label and the fetch, so there is no second polling
    /// loop to duplicate.
    private func startTicking() {
        ticker?.invalidate()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.now = Date()
                self?.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    func refresh() {
        guard let client, !inFlight else { return }
        inFlight = true
        Task { @MainActor in
            defer { inFlight = false }
            do {
                let snapshot = try await client.fetchSnapshot()
                let events = store.apply(snapshot)
                lastError = nil
                if !events.isEmpty { WatchModel.playHaptics(for: events) }
            } catch let failure as APIClient.Failure {
                // A failed fetch is not an error state on screen: the cached snapshot
                // stays with its own freshness label. Only the reason is recorded.
                lastError = failure
            } catch {
                lastError = .offline
            }
        }
    }

    /// Subtle while active, stronger for a weekly recharge.
    private static func playHaptics(for events: [QuotaEvent]) {
        guard let strongest = events.max(by: { !$0.isMajor && $1.isMajor }) else { return }
        WKInterfaceDevice.current().play(strongest.isMajor ? .success : .click)
    }
}

extension APIClient.Failure {
    /// Compact labels for a 41mm screen — never a raw HTTP error.
    var watchLabel: String {
        switch self {
        case .unauthorized: "AUTH"
        case .offline: "OFFLINE"
        case .malformed: "SERVER ERROR"
        case .server: "SERVER ERROR"
        }
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
                    error: model.lastError?.watchLabel,
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
