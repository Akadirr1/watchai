import Foundation
import QuotaPetsShared

/// The real network transport. Lives in the helper because the helper is the only
/// component that talks to a provider.
struct URLSessionTransport: UsageTransport {
    let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        // No credential should ever land in a URL cache or cookie jar (§28).
        config.urlCache = nil
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        return URLSession(configuration: config)
    }()

    func send(_ request: UsageRequest) async throws -> UsageResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.timeoutInterval = request.timeout
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch let error as URLError where error.code == .timedOut || error.code == .notConnectedToInternet {
            throw ProviderError.networkUnavailable
        } catch {
            throw ProviderError.networkUnavailable
        }

        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.providerResponseChanged(detail: "non-HTTP response")
        }
        return UsageResponse(
            status: http.statusCode,
            body: data,
            retryAfter: RetryAfterParser.seconds(
                from: http.value(forHTTPHeaderField: "Retry-After"), now: Date())
        )
    }
}

/// Assembles the fully-wrapped providers the helper serves from.
enum HelperProviders {
    static func makeAll() -> [any UsageProvider] {
        let transport = URLSessionTransport()
        return [
            wrap(ClaudeUsageProvider(transport: transport, credentials: ClaudeCredentialReader())),
            wrap(CodexUsageProvider(transport: transport, credentials: CodexCredentialReader())),
        ]
    }

    /// Retry innermost, single-flight outermost: coalesced callers should join one
    /// attempt *including* its retry, not race to start separate retry chains.
    private static func wrap(_ provider: any UsageProvider) -> any UsageProvider {
        SingleFlightUsageProvider(wrapping: RetryingUsageProvider(wrapping: provider))
    }
}
