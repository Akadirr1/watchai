import Foundation

/// Provider error states (§25).
///
/// `providerResponseChanged` is the important one: both usage endpoints are private and
/// unversioned (research §3.1), so a schema change is an expected operating condition,
/// not a crash. It is raised whenever a payload parses as JSON but does not carry the
/// fields we require.
public enum ProviderError: Error, Sendable, Hashable {
    case notAuthenticated
    case tokenExpired
    case networkUnavailable
    /// Retry hint from the server (`Retry-After`) when it supplied one.
    case rateLimited(retryAfter: TimeInterval?)
    case providerResponseChanged(detail: String)
    case serverError(status: Int)
    case unknown(detail: String)

    /// Compact state for the Watch. The brief (§25) forbids dumping raw HTTP onto the
    /// wrist; the phone's debug view gets the full case instead.
    public var watchLabel: String {
        switch self {
        case .notAuthenticated, .tokenExpired: "AUTH"
        case .networkUnavailable: "OFFLINE"
        case .rateLimited: "STALE"
        case .providerResponseChanged: "PROVIDER ERROR"
        case .serverError, .unknown: "PROVIDER ERROR"
        }
    }

    /// Whether a bounded retry is worth attempting (§26). Auth and schema failures are
    /// not retryable — retrying them just burns quota and battery to fail identically.
    public var isTransient: Bool {
        switch self {
        case .networkUnavailable, .serverError: true
        case .rateLimited: false
        case .notAuthenticated, .tokenExpired, .providerResponseChanged, .unknown: false
        }
    }
}

/// Maps an HTTP status to the error model. Mirrors Orca's classification
/// (research §2/§3) without importing its Electron-specific machinery.
public enum HTTPStatusClassifier {
    public static func error(for status: Int, retryAfter: TimeInterval? = nil) -> ProviderError? {
        switch status {
        case 200...299: nil
        case 401: .notAuthenticated
        case 403: .tokenExpired
        case 429: .rateLimited(retryAfter: retryAfter)
        case 500...599: .serverError(status: status)
        default: .unknown(detail: "HTTP \(status)")
        }
    }
}
