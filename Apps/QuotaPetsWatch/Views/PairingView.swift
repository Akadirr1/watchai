import SwiftUI
import UIKit

/// The screen the watch shows until it has a device token.
///
/// The interaction is deliberately one-sided: the watch displays, the phone acts. Nothing
/// here asks the user to type, because typing a 64-character token on a 41mm screen is
/// not a thing a person should be asked to do.
///
/// The 8-character code is printed under the QR as a fallback, for the case where the
/// camera cannot get a clean read — the user can open `/pair?c=` on the phone and type it.
/// Its alphabet already excludes `0/O` and `1/I/l` for exactly that reading-aloud case.
struct PairingView: View {
    @StateObject private var model: PairingModel

    init(baseURL: URL?, onPaired: @escaping @MainActor (String) -> Void) {
        _model = StateObject(wrappedValue: PairingModel(baseURL: baseURL, onPaired: onPaired))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                switch model.phase {
                case .unconfigured:
                    message("NO SERVER URL",
                            detail: "Set QUOTAPETS_API_URL in Secrets.xcconfig and rebuild.",
                            retry: false)

                case .starting:
                    ProgressView()
                        .padding(.vertical, 28)
                    Text("Asking the server…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                case .waiting(let session, let qr):
                    qrPanel(qr)
                    Text(session.code)
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .kerning(1.5)
                    Text("Scan with your iPhone camera")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Text(model.remainingLabel)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)

                case .expired:
                    message("CODE EXPIRED", detail: "Tap to get a new one.", retry: true)

                case .failed(let reason):
                    message(reason, detail: "Tap to try again.", retry: true)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
        }
        .navigationTitle("Pair")
        .task { model.begin() }
        .onDisappear { model.cancel() }
    }

    /// `.interpolation(.none)` is not cosmetic: smoothing a QR blurs module edges and is a
    /// common reason a small on-screen code will not scan.
    @ViewBuilder
    private func qrPanel(_ data: Data?) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(.white)
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .padding(2)
            } else {
                ProgressView().tint(.black)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func message(_ title: String, detail: String, retry: Bool) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if retry {
                Button("Retry") { model.begin(force: true) }
                    .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 12)
    }
}

@MainActor
final class PairingModel: ObservableObject {
    enum Phase {
        case unconfigured
        case starting
        case waiting(PairingClient.Session, qr: Data?)
        case expired
        case failed(String)
    }

    @Published private(set) var phase: Phase = .starting
    @Published private(set) var remainingLabel = ""

    private let client: PairingClient?
    private let onPaired: @MainActor (String) -> Void
    private var work: Task<Void, Never>?

    init(baseURL: URL?, onPaired: @escaping @MainActor (String) -> Void) {
        self.client = baseURL.map { PairingClient(baseURL: $0) }
        self.onPaired = onPaired
        if client == nil { phase = .unconfigured }
    }

    /// Idempotent unless `force`: re-entering the view while a code is still live keeps
    /// that code rather than burning a fresh one on every appearance.
    func begin(force: Bool = false) {
        guard client != nil else { return }
        if !force, case .waiting = phase { return }
        cancel()
        work = Task { await run() }
    }

    func cancel() {
        work?.cancel()
        work = nil
    }

    private func run() async {
        guard let client else { return }
        phase = .starting

        let session: PairingClient.Session
        do {
            session = try await client.start()
        } catch {
            phase = .failed(Self.label(for: error))
            return
        }
        guard !Task.isCancelled else { return }
        phase = .waiting(session, qr: nil)
        tick(until: session.expiresAt)

        // Fetched separately so the code is readable immediately — a slow image must not
        // hold up the fallback path.
        if let data = try? await client.qrImageData(session.qrURL), !Task.isCancelled {
            phase = .waiting(session, qr: data)
        }

        while !Task.isCancelled {
            if Date() >= session.expiresAt {
                phase = .expired
                return
            }
            // 2s is a deliberate compromise: the code lives 2 minutes, so this is at most
            // ~60 requests, and it still feels immediate once the phone claims the code.
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            tick(until: session.expiresAt)

            do {
                if let token = try await client.poll(code: session.code, secret: session.secret) {
                    DeviceTokenStore.save(token)
                    onPaired(token)
                    return
                }
            } catch {
                // A dropped request mid-poll is not fatal — the code is still live, so
                // keep trying until it actually expires.
                continue
            }
        }
    }

    private func tick(until deadline: Date) {
        let seconds = max(0, Int(deadline.timeIntervalSinceNow.rounded()))
        remainingLabel = String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private static func label(for error: Error) -> String {
        switch error as? PairingClient.Failure {
        case .offline: "CAN'T REACH SERVER"
        case .server(let status) where status == 429: "TOO MANY TRIES"
        case .server: "SERVER ERROR"
        case .malformed, .none: "SERVER ERROR"
        }
    }
}
