import Combine
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
        // Holds the model itself, read here while `body` runs, rather than reaching back
        // through the @StateObject wrapper from a background wake.
        .backgroundTask(.appRefresh(BackgroundRefresh.identifier)) { [model] in
            await model.backgroundRefresh()
        }
    }
}

@MainActor
final class WatchModel: ObservableObject {
    @Published private(set) var store = SnapshotStore()
    @Published private(set) var lastError: APIClient.Failure?
    @Published var now = Date()
    /// Nil until this watch has been paired. Drives which screen is on.
    @Published private(set) var isPaired: Bool

    private var client: APIClient?
    /// Foreground-only ticker. Stopped the moment the scene leaves `.active`, so nothing
    /// pretends to survive suspension.
    private var ticker: Timer?
    /// Guards against the timer and an onAppear both fetching at once.
    private var inFlight = false
    /// `store` is a nested ObservableObject, so its own changes do not reach this one's
    /// subscribers by themselves. Forwarded explicitly rather than relying on some other
    /// `@Published` happening to fire in the same turn.
    private var storeChanges: AnyCancellable?

    init(token: String? = DeviceTokenStore.read()) {
        self.client = token.flatMap { APIClient(token: $0) }
        self.isPaired = self.client != nil
        // `SnapshotStore` is @MainActor and its `@Published` properties publish
        // synchronously from there, so this closure is always already on the main actor.
        self.storeChanges = store.objectWillChange.sink { [weak self] _ in
            MainActor.assumeIsolated { self?.objectWillChange.send() }
        }
    }

    func becameActive() {
        guard client != nil else { return }
        // Cached data is already on screen; ask for fresh in the background.
        refresh()
        startTicking()
    }

    func becameInactive() {
        ticker?.invalidate()
        ticker = nil
        // Off screen, the app is still the complication's only source of new numbers.
        if client != nil { BackgroundRefresh.schedule() }
    }

    /// The `.appRefresh` wake: one fetch — which persists and so reloads the
    /// complication — then book the next.
    func backgroundRefresh() async {
        guard client != nil else { return }
        await fetch(announcing: false)
        BackgroundRefresh.schedule()
    }

    /// Called by the pairing screen once a device token has reached the Keychain.
    func adopt(token: String) {
        client = APIClient(token: token)
        isPaired = client != nil
        lastError = nil
        becameActive()
    }

    /// A 401 means the token is no longer good — most often because the device was
    /// revoked from `/setup`. Drop it and fall back to pairing rather than retrying a
    /// credential the server has already rejected.
    private func unpair() {
        DeviceTokenStore.clear()
        client = nil
        becameInactive()
        isPaired = false
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
        Task { await fetch(announcing: true) }
    }

    /// The one fetch, for the foreground ticker and the background wake alike. No haptic
    /// from the background: it would land on a wrist that is not looking.
    private func fetch(announcing: Bool) async {
        guard let client, !inFlight else { return }
        inFlight = true
        defer { inFlight = false }
        do {
            let snapshot = try await client.fetchSnapshot()
            let events = store.apply(snapshot)
            lastError = nil
            if announcing, !events.isEmpty { WatchModel.playHaptics(for: events) }
        } catch APIClient.Failure.unauthorized {
            unpair()
        } catch let failure as APIClient.Failure {
            // A failed fetch is not an error state on screen: the cached snapshot
            // stays with its own freshness label. Only the reason is recorded.
            lastError = failure
        } catch {
            lastError = .offline
        }
    }

    /// Subtle while active, stronger for a weekly recharge.
    private static func playHaptics(for events: [QuotaEvent]) {
        guard let strongest = events.max(by: { !$0.isMajor && $1.isMajor }) else { return }
        WKInterfaceDevice.current().play(strongest.isMajor ? .success : .click)
    }
}

/// Keeps the complication current while the app is closed.
///
/// The app only fetched while on screen, so between visits the complication had nothing
/// new to show. A watch app whose complication is on the active face gets up to four
/// background refreshes an hour; each wake fetches, persists (which reloads the widget)
/// and books the next. A wake that lands while the app is frontmost is dropped by the
/// system, and leaving the app books a fresh one, so the chain survives that too.
enum BackgroundRefresh {
    static let identifier = "com.quotapets.watch.refresh"

    /// Three wakes an hour: inside the four the system grants, and 72 widget reloads a
    /// day against a budget of about 75.
    static let interval: TimeInterval = 20 * 60

    /// Only one request can be pending and a new one replaces it, so calling this more
    /// often than needed is harmless.
    @MainActor static func schedule() {
        // The identifier rides as userInfo: that is how WatchKit routes the wake to the
        // matching `.backgroundTask(.appRefresh(identifier))` handler.
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: Date().addingTimeInterval(interval),
            userInfo: identifier as NSString
        ) { _ in }
    }
}

extension APIClient.Failure {
    /// Compact labels for a 41mm screen — never a raw HTTP error.
    var watchLabel: String {
        switch self {
        case .unauthorized: "AUTH"
        case .offline: "OFFLINE"
        // Distinct from .server on purpose: one means the server said no, the other means
        // we could not read what it said. Collapsing them hid a client-side decode bug
        // behind a label that pointed at the server.
        case .malformed: "BAD RESPONSE"
        // The status, not the word "SERVER ERROR": this line is the only thing the watch
        // can tell you, so it should say which failure it was. Kept short because it
        // shares a 41mm screen with the mascot, both windows and a countdown.
        case .server(let status): "HTTP \(status)"
        }
    }
}

struct WatchRootView: View {
    @EnvironmentObject private var model: WatchModel

    var body: some View {
        if model.isPaired {
            UsageTabs()
        } else {
            PairingView(baseURL: ServerConfig.baseURL()) { token in
                model.adopt(token: token)
            }
        }
    }
}

private struct UsageTabs: View {
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
