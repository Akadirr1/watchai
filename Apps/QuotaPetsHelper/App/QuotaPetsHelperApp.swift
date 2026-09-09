import SwiftUI
import QuotaPetsShared

/// Menu-bar helper. The only component that ever holds a provider credential.
///
/// It reads what the user's own `claude` and `codex` CLIs already wrote, fetches usage
/// with the shared adapters, and serves normalised snapshots to the phone over the LAN.
/// It performs no login and knows no OAuth — see docs/provider-research.md §4.3.
@main
struct QuotaPetsHelperApp: App {
    @StateObject private var model = HelperModel()

    var body: some Scene {
        MenuBarExtra("QuotaPets", systemImage: model.menuBarSymbol) {
            HelperMenu().environmentObject(model)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class HelperModel: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var errors: [AIProvider: ProviderError] = [:]
    @Published private(set) var lastRefreshAt: Date?

    private let providers = HelperProviders.makeAll()
    private var timer: Timer?

    init() { start() }

    /// The helper is the one place a real 60-second cadence is achievable: it is a
    /// desktop process, not subject to iOS or watchOS background budgets (§12).
    private func start() {
        Task { await refresh() }
        let t = Timer(timeInterval: RefreshSchedule.foregroundInterval, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refresh() async {
        var next = snapshot ?? UsageSnapshot(generatedAt: Date())
        for provider in providers {
            // Staggered so the two providers never fire in the same instant (§9).
            try? await Task.sleep(for: .seconds(RefreshSchedule.stagger(for: provider.provider)))
            do {
                next = next.replacing(try await provider.fetchUsage(), generatedAt: Date())
                errors[provider.provider] = nil
            } catch let error as ProviderError {
                errors[provider.provider] = error
            } catch {
                errors[provider.provider] = .unknown(detail: "\(error)")
            }
        }
        snapshot = next
        lastRefreshAt = Date()
    }

    var menuBarSymbol: String {
        guard let snapshot else { return "pawprint" }
        let states = AIProvider.allCases.compactMap { MascotStateResolver.resolve(snapshot.usage(for: $0))?.state }
        guard let worst = states.max(by: { $0.severity < $1.severity }) else { return "pawprint" }
        return worst.severity >= MascotEnergyState.tired.severity ? "pawprint.circle.fill" : "pawprint"
    }
}

struct HelperMenu: View {
    @EnvironmentObject private var model: HelperModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(AIProvider.allCases, id: \.self) { provider in
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.displayName).font(.headline)
                    if let error = model.errors[provider] {
                        Text(error.watchLabel).foregroundStyle(.orange).font(.caption)
                    } else if let usage = model.snapshot?.usage(for: provider) {
                        ForEach([UsageWindowKind.fiveHour, .weekly], id: \.self) { kind in
                            if let w = usage.window(kind) {
                                Text("\(kind.shortLabel)  \(Int(w.remainingPercent.rounded()))% left")
                                    .font(.caption).monospacedDigit()
                            }
                        }
                    } else {
                        Text("Sign in with the CLI: `claude login` / `codex login`")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            Button("Refresh now") { Task { await model.refresh() } }
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .padding(12)
        .frame(width: 240)
    }
}
