import SwiftUI
import QuotaPetsShared

@main
struct QuotaPetsPhoneApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = PhoneModel()

    var body: some Scene {
        WindowGroup {
            PhoneRootView()
                .environmentObject(model)
                .onOpenURL { url in model.handlePairing(url) }
        }
    }
}

/// Background-task registration must happen here: Apple requires all registration to
/// complete before `didFinishLaunching` returns, and registering twice terminates the app.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ app: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        BackgroundRefresh.register { task in
            BackgroundRefresh.handle(task) {
                await PhoneModel.shared.refreshAll()
            }
        }
        BackgroundRefresh.schedule()
        return true
    }
}

@MainActor
final class PhoneModel: ObservableObject {
    static let shared = PhoneModel()

    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var errors: [AIProvider: ProviderError] = [:]
    @Published private(set) var pairingState: PairingState = .idle
    @Published private(set) var lastRefreshAt: Date?
    @Published var now = Date()

    let sync = PhoneSyncService()
    private var foregroundTimer: Timer?
    private var redemption = PairingRedemption()

    init() {
        sync.snapshotProvider = { [weak self] in
            // The watch asked. Serve cache immediately and let the pull trigger a
            // refresh, rather than making the watch wait on the network.
            await MainActor.run { self?.snapshot }
        }
    }

    func handlePairing(_ url: URL) {
        guard let payload = PairingPayload.parse(url) else {
            pairingState = .failed
            return
        }
        switch redemption.redeem(payload, at: Date()) {
        case .accepted: pairingState = .paired
        case .expired: pairingState = .expired
        case .alreadyUsed, .malformed: pairingState = .failed
        }
    }

    /// Foreground cadence (§9). Stopped on background — nothing pretends to survive.
    func startForegroundRefresh() {
        foregroundTimer?.invalidate()
        Task { await refreshAll() }
        let t = Timer(timeInterval: RefreshSchedule.foregroundInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.now = Date()
                await self?.refreshAll()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        foregroundTimer = t
    }

    func stopForegroundRefresh() {
        foregroundTimer?.invalidate()
        foregroundTimer = nil
    }

    /// Refreshes both providers and pushes the result to the watch.
    ///
    /// Under the helper-relay design this talks to the Mac helper, not to Anthropic or
    /// OpenAI — the phone holds no provider credential (research §6). Until the helper
    /// is reachable, mock providers stand in so the UI is exercisable end to end.
    func refreshAll() async {
        let providers: [any UsageProvider] = [
            MockUsageProvider.claudeDefault(),
            MockUsageProvider.codexDefault(),
        ]
        var next = snapshot ?? UsageSnapshot(generatedAt: Date())
        for provider in providers {
            do {
                let usage = try await provider.fetchUsage()
                next = next.replacing(usage, generatedAt: Date())
                errors[provider.provider] = nil
            } catch let error as ProviderError {
                errors[provider.provider] = error
            } catch {
                errors[provider.provider] = .unknown(detail: "\(error)")
            }
        }
        snapshot = next
        lastRefreshAt = Date()
        sync.push(next)
    }
}
