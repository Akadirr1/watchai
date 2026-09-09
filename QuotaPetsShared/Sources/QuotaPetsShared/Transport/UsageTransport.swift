import Foundation

/// One HTTP round trip, reduced to what the usage adapters actually need.
///
/// The core deliberately does not depend on `URLSession`. That keeps `QuotaPetsShared`
/// buildable everywhere (URLSession lives in `FoundationNetworking` on Linux), and more
/// importantly it makes every adapter testable against fixtures with no network — which
/// is how the provider-schema tests in this package run.
public protocol UsageTransport: Sendable {
    func send(_ request: UsageRequest) async throws -> UsageResponse
}

public struct UsageRequest: Sendable, Hashable {
    public let url: URL
    public let headers: [String: String]
    public let timeout: TimeInterval

    public init(url: URL, headers: [String: String], timeout: TimeInterval = 10) {
        self.url = url
        self.headers = headers
        self.timeout = timeout
    }
}

public struct UsageResponse: Sendable, Hashable {
    public let status: Int
    public let body: Data
    /// Parsed `Retry-After`, when the server sent one (§26: obey retry hints).
    public let retryAfter: TimeInterval?

    public init(status: Int, body: Data, retryAfter: TimeInterval? = nil) {
        self.status = status
        self.body = body
        self.retryAfter = retryAfter
    }
}

/// Parses `Retry-After`, which RFC 9110 allows to be either delay-seconds or an
/// HTTP-date. Ignoring the date form silently loses the hint on servers that use it.
public enum RetryAfterParser {
    public static func seconds(from header: String?, now: Date) -> TimeInterval? {
        guard let header = header?.trimmingCharacters(in: .whitespaces), !header.isEmpty else { return nil }
        if let s = TimeInterval(header), s.isFinite, s >= 0 { return s }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: header) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }
}
