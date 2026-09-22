import Foundation
import QuotaPetsShared

/// Talks to the QuotaPets server directly.
///
/// This replaces the old phone-relay design entirely. A watchOS app has been able to run
/// independently and reach the network on its own since watchOS 6, so there is no iPhone
/// app, no WatchConnectivity, and no pairing step — the watch simply fetches the API.
///
/// That also sidesteps the constraint that shaped the old design: Apple documents that
/// `sendMessage` from iOS does *not* wake the watch extension, so a phone could never
/// have pushed an update on demand anyway.
public struct APIClient: Sendable {
    public enum Failure: Error, Sendable {
        case unauthorized
        case server(status: Int)
        case malformed
        case offline
    }

    private let baseURL: URL
    private let token: String
    private let session: URLSession

    /// Reads `QUOTAPETS_API_URL` and `QUOTAPETS_API_TOKEN` from the build's Info.plist,
    /// supplied by a gitignored `Secrets.xcconfig`. Nothing credential-shaped is committed.
    public init?(bundle: Bundle = .main) {
        guard
            let urlString = bundle.object(forInfoDictionaryKey: "QUOTAPETS_API_URL") as? String,
            let url = URL(string: urlString),
            let token = bundle.object(forInfoDictionaryKey: "QUOTAPETS_API_TOKEN") as? String,
            !token.isEmpty
        else { return nil }
        self.init(baseURL: url, token: token)
    }

    public init(baseURL: URL, token: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    public func fetchSnapshot() async throws -> UsageSnapshot {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/usage"))
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure.offline
        }

        guard let http = response as? HTTPURLResponse else { throw Failure.malformed }
        if http.statusCode == 401 { throw Failure.unauthorized }
        guard (200...299).contains(http.statusCode) else {
            throw Failure.server(status: http.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(APIUsageResponse.self, from: data).toSnapshot()
        } catch {
            throw Failure.malformed
        }
    }
}

// MARK: - Wire shape

/// The server's `/api/usage` body. Kept separate from `UsageSnapshot` so a server-side
/// field rename cannot silently reshape the app's domain model.
struct APIUsageResponse: Decodable {
    struct Window: Decodable {
        let usedPercent: Double
        let resetAt: Date?
        let durationSec: Double?
    }

    struct Provider: Decodable {
        let fiveHour: Window?
        let weekly: Window?
        let planName: String?
        let fetchedAt: Date?
    }

    let generatedAt: Date?
    let claude: Provider?
    let codex: Provider?

    func toSnapshot() -> UsageSnapshot {
        let stamp = generatedAt ?? Date()
        return UsageSnapshot(
            claude: claude.map { $0.toUsage(provider: .claude, fallback: stamp) },
            codex: codex.map { $0.toUsage(provider: .codex, fallback: stamp) },
            generatedAt: stamp
        )
    }
}

private extension APIUsageResponse.Provider {
    func toUsage(provider: AIProvider, fallback: Date) -> ProviderUsage {
        ProviderUsage(
            provider: provider,
            fiveHour: fiveHour?.toWindow(),
            weekly: weekly?.toWindow(),
            planName: planName,
            fetchedAt: fetchedAt ?? fallback
        )
    }
}

private extension APIUsageResponse.Window {
    func toWindow() -> UsageWindow {
        UsageWindow(usedPercent: usedPercent, resetAt: resetAt, duration: durationSec)
    }
}
