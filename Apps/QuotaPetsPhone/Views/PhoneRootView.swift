import SwiftUI
import QuotaPetsShared

struct PhoneRootView: View {
    @EnvironmentObject private var model: PhoneModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var showDebug = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(AIProvider.allCases, id: \.self) { provider in
                    Section(provider.displayName) {
                        ProviderRow(usage: model.snapshot?.usage(for: provider),
                                    error: model.errors[provider])
                    }
                }

                Section {
                    Button("Refresh now") { Task { await model.refreshAll() } }
                    NavigationLink("Diagnostics") { DiagnosticsView() }
                }

                if let snapshot = model.snapshot {
                    Section {
                        Text(SnapshotFreshness.evaluate(generatedAt: snapshot.generatedAt, now: model.now).label)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("QuotaPets")
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            phase == .active ? model.startForegroundRefresh() : model.stopForegroundRefresh()
        }
    }
}

struct ProviderRow: View {
    let usage: ProviderUsage?
    let error: ProviderError?

    var body: some View {
        if let error {
            Label(error.watchLabel, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        } else if let usage {
            // Phone mirrors the brief's §22 layout, which states USED. The watch states
            // REMAINING (§32). Both are labelled, so neither can be misread.
            ForEach([UsageWindowKind.fiveHour, .weekly], id: \.self) { kind in
                if let window = usage.window(kind) {
                    HStack {
                        Text(kind.shortLabel).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(window.usedPercent.rounded()))% used")
                        if let reset = window.resetAt, reset > Date() {
                            Text(reset, style: .timer)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            }
            if let plan = usage.planName {
                Text(plan.uppercased()).font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Text("Not connected").foregroundStyle(.secondary)
        }
    }
}

/// §22's advanced section. Note what is deliberately absent: the access token. Nothing
/// here can print a credential, because under this architecture the phone never has one.
struct DiagnosticsView: View {
    @EnvironmentObject private var model: PhoneModel

    var body: some View {
        List {
            LabeledContent("Last refresh", value: model.lastRefreshAt?.formatted() ?? "never")
            LabeledContent("Last watch sync", value: model.sync.lastPushAt?.formatted() ?? "never")
            LabeledContent("Watch sync error", value: model.sync.lastPushError ?? "none")
            LabeledContent("Pairing", value: model.pairingState.rawValue)
            Section("Providers") {
                ForEach(AIProvider.allCases, id: \.self) { provider in
                    LabeledContent(provider.displayName,
                                   value: model.errors[provider].map { "\($0)" } ?? "ok")
                }
            }
        }
        .navigationTitle("Diagnostics")
    }
}
