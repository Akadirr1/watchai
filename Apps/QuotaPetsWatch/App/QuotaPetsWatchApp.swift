import Combine
import SwiftUI
import WatchKit
import WidgetKit
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
    /// The 30 s poll. Runs while the app is on screen, dimmed under Always-On, or kept
    /// running off screen by `keepAlive`, and stops once none of those holds.
    private var ticker: Timer?
    /// Up to an hour of background runtime after every visit (see `KeepAlive`).
    private let keepAlive = KeepAlive()
    private var inBackground = false
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
        keepAlive.onEnd = { [weak self] in
            if self?.inBackground == true { self?.stopTicking() }
        }
    }

    /// Active polls and renews the hour. Always-On (inactive) changes nothing: the app is
    /// still frontmost, so it keeps polling. Background polls only while the keep-alive
    /// session lasts.
    func sceneChanged(to phase: ScenePhase) {
        inBackground = phase == .background
        switch phase {
        case .active: becameActive()
        case .background: leftScreen()
        default: break
        }
    }

    private func becameActive() {
        guard client != nil else { return }
        // Free while the app is in front (WidgetKit does not count those reloads), so
        // every visit puts the face back in step, whatever the widget last recorded.
        WidgetCenter.shared.reloadAllTimelines()
        // Cached data is already on screen; ask for fresh in the background.
        refresh()
        startTicking()
        keepAlive.start()
    }

    private func leftScreen() {
        // Off screen, the app is still the complication's only source of new numbers.
        if client != nil { BackgroundRefresh.schedule() }
        if !keepAlive.isRunning { stopTicking() }
    }

    private func stopTicking() {
        ticker?.invalidate()
        ticker = nil
    }

    /// The `.appRefresh` wake: one fetch — which reloads the complication if it is
    /// behind — then book the next.
    func backgroundRefresh() async {
        guard client != nil else { return }
        // Shown on the settings page: the only way to see whether watchOS is granting
        // wakes at all, which decides how fresh the complications can be.
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: BackgroundRefresh.lastWakeKey)
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
        stopTicking()
        keepAlive.stop()
        isPaired = false
    }

    /// One timer drives both the clock label and the fetch, so there is no second polling
    /// loop to duplicate.
    private func startTicking() {
        ticker?.invalidate()
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.now = Date()
                self?.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    func refresh() {
        Task { await fetch(announcing: !inBackground) }
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

/// Up to an hour of background runtime after every visit, so the 30 s poll keeps going
/// with the wrist down instead of waiting on the four background wakes an hour watchOS
/// hands out. watchOS grants that as an extended runtime session of the "physical
/// therapy" type (`WKBackgroundModes` in project.yml). This is a personal build: Apple
/// asks that the session type match the app's purpose, so as it stands this would not
/// pass App Review.
@MainActor
final class KeepAlive: NSObject, WKExtendedRuntimeSessionDelegate {
    private var session: WKExtendedRuntimeSession?
    var onEnd: (() -> Void)?

    var isRunning: Bool { session?.state == .running }

    /// Only while the app is active, the one state watchOS starts a session from.
    /// Renews a spent session and leaves a live one alone.
    func start() {
        if let session, session.state != .invalid { return }
        let next = WKExtendedRuntimeSession()
        next.delegate = self
        next.start()
        session = next
    }

    func stop() {
        session?.invalidate()
        session = nil
    }

    nonisolated func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {}

    // Nothing to wind down: the next poll simply does not happen.
    nonisolated func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {}

    nonisolated func extendedRuntimeSession(_ extendedRuntimeSession: WKExtendedRuntimeSession,
                                            didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
                                            error: (any Error)?) {
        // Only the session this object is holding: a late callback from an old one must
        // not clear the fresh session that replaced it.
        let ended = ObjectIdentifier(extendedRuntimeSession)
        Task { @MainActor [weak self] in
            guard let self, let session, ObjectIdentifier(session) == ended else { return }
            self.session = nil
            onEnd?()
        }
    }
}

/// Keeps the complication current while the app is closed.
///
/// The app only fetched while on screen, so between visits the complication had nothing
/// new to show. A watch app whose complication is on the active face gets up to four
/// background refreshes an hour; each wake fetches, persists (which reloads the widget
/// if it is behind) and books the next. A wake that lands while the app is
/// frontmost is dropped by the system, and leaving the app books a fresh one, so the
/// chain survives that too. Nothing third-party wakes more often: 30 s in the background
/// is not on offer, only on screen.
enum BackgroundRefresh {
    static let identifier = "com.quotapets.watch.refresh"
    static let lastWakeKey = "lastBackgroundRefresh"

    /// Four wakes an hour, the most watchOS grants. Reloading the widget only while it
    /// is behind keeps that inside the ~75 reloads a day it allows.
    static let interval: TimeInterval = 15 * 60

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
    @AppStorage("bandana") private var bandana = true
    @AppStorage(BackgroundRefresh.lastWakeKey) private var lastBackgroundWake: Double = 0

    /// Animation stops when the scene is inactive OR the display is dimmed for
    /// Always-On (§16, §20).
    private var isAnimating: Bool { scenePhase == .active && !isLuminanceReduced }

    var body: some View {
        TabView {
            FaceView(usage: model.store.snapshot?.claude,
                     generatedAt: model.store.snapshot?.generatedAt,
                     working: model.store.working.contains(.claude),
                     isAnimating: isAnimating)
            ForEach(AIProvider.allCases, id: \.self) { provider in
                ProviderPageView(
                    provider: provider,
                    usage: model.store.snapshot?.usage(for: provider),
                    freshness: model.store.snapshot.map {
                        SnapshotFreshness.evaluate(generatedAt: $0.generatedAt, now: model.now)
                    },
                    error: model.lastError?.watchLabel,
                    working: model.store.working.contains(provider),
                    isAnimating: isAnimating,
                    now: model.now
                )
            }
            VStack(spacing: 10) {
                Toggle("Bandana", isOn: $bandana)
                Text(lastBackgroundWake > 0
                     ? "Background refresh \(Date(timeIntervalSince1970: lastBackgroundWake).formatted(date: .omitted, time: .shortened))"
                     : "No background refresh yet")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
        }
        .tabViewStyle(.verticalPage)
        .onChange(of: scenePhase, initial: true) { _, phase in
            model.sceneChanged(to: phase)
        }
    }
}
