import Foundation

/// Supplies the bearer credential for a provider at request time.
///
/// Under the helper-relay architecture (research §6) this is implemented on macOS by
/// reading what the vendor CLIs already wrote. It is a protocol so the core never sees a
/// credential type, and so tests can supply a constant.
public protocol CredentialSupplier: Sendable {
    func accessToken() async throws -> String
    /// Codex only; Claude implementations return nil.
    func accountID() async throws -> String?
}

public extension CredentialSupplier {
    func accountID() async throws -> String? { nil }
}

/// Claude usage adapter. Anthropic-shaped JSON stops here (§2).
public struct ClaudeUsageProvider: UsageProvider {
    public let provider = AIProvider.claude
    private let transport: any UsageTransport
    private let credentials: any CredentialSupplier
    private let now: @Sendable () -> Date

    public init(
        transport: any UsageTransport,
        credentials: any CredentialSupplier,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.credentials = credentials
        self.now = now
    }

    public func fetchUsage() async throws -> ProviderUsage {
        let token = try await credentials.accessToken()
        let response = try await transport.send(UsageRequest(
            url: ClaudeEndpoint.usageURL,
            headers: ClaudeEndpoint.headers(accessToken: token),
            timeout: ClaudeEndpoint.timeout
        ))
        if let error = HTTPStatusClassifier.error(for: response.status, retryAfter: response.retryAfter) {
            throw error
        }
        return try ClaudeUsageMapper.decode(response.body, fetchedAt: now())
    }
}

/// Codex usage adapter. The endpoint is private and unversioned, so every assumption
/// about it is confined to this type and `CodexEndpoint` (§3).
public struct CodexUsageProvider: UsageProvider {
    public let provider = AIProvider.codex
    private let transport: any UsageTransport
    private let credentials: any CredentialSupplier
    private let now: @Sendable () -> Date

    public init(
        transport: any UsageTransport,
        credentials: any CredentialSupplier,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.credentials = credentials
        self.now = now
    }

    public func fetchUsage() async throws -> ProviderUsage {
        let token = try await credentials.accessToken()
        let account = try await credentials.accountID()
        let response = try await transport.send(UsageRequest(
            url: CodexEndpoint.usageURL,
            headers: CodexEndpoint.headers(accessToken: token, accountID: account),
            timeout: CodexEndpoint.timeout
        ))
        if let error = HTTPStatusClassifier.error(for: response.status, retryAfter: response.retryAfter) {
            throw error
        }
        return try CodexUsageMapper.decode(response.body, fetchedAt: now())
    }
}
