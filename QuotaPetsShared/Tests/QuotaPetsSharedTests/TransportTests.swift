import Testing
import Foundation
@testable import QuotaPetsShared

private let now = Date(timeIntervalSince1970: 1_757_000_000)

/// Records what it was asked to send and replays a scripted answer. No network.
private actor StubTransport: UsageTransport {
    private var responses: [Result<UsageResponse, any Error>]
    private(set) var requests: [UsageRequest] = []
    private(set) var callCount = 0

    init(_ responses: [Result<UsageResponse, any Error>]) { self.responses = responses }

    init(status: Int, body: String) {
        self.responses = [.success(UsageResponse(status: status, body: Data(body.utf8)))]
    }

    func send(_ request: UsageRequest) async throws -> UsageResponse {
        requests.append(request)
        callCount += 1
        // The last scripted response repeats, so retry tests need not pad the script.
        let result = responses.count > 1 ? responses.removeFirst() : responses[0]
        return try result.get()
    }

    func lastRequest() -> UsageRequest? { requests.last }
}

private struct StubCredentials: CredentialSupplier {
    var token = "test-token-not-a-real-credential"
    var account: String?
    func accessToken() async throws -> String { token }
    func accountID() async throws -> String? { account }
}

private struct FailingProvider: UsageProvider {
    let provider = AIProvider.claude
    let error: ProviderError
    func fetchUsage() async throws -> ProviderUsage { throw error }
}

private let claudeBody = #"{"five_hour":{"utilization":64},"seven_day":{"utilization":31}}"#
private let codexBody = #"{"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":12,"limit_window_seconds":18000}}}"#

@Suite("Claude adapter")
struct ClaudeAdapterTests {

    @Test("sends exactly the headers Orca sends")
    func headers() async throws {
        let transport = StubTransport(status: 200, body: claudeBody)
        let provider = ClaudeUsageProvider(transport: transport, credentials: StubCredentials(), now: { now })
        _ = try await provider.fetchUsage()

        let request = await transport.lastRequest()
        #expect(request?.url == URL(string: "https://api.anthropic.com/api/oauth/usage"))
        #expect(request?.headers["Authorization"] == "Bearer test-token-not-a-real-credential")
        #expect(request?.headers["anthropic-beta"] == "oauth-2025-04-20")
        #expect(request?.headers["User-Agent"] == "claude-code/2.1.0")
        #expect(request?.timeout == 10)
    }

    @Test("a successful response maps to normalised usage")
    func mapsUsage() async throws {
        let transport = StubTransport(status: 200, body: claudeBody)
        let provider = ClaudeUsageProvider(transport: transport, credentials: StubCredentials(), now: { now })
        let usage = try await provider.fetchUsage()
        #expect(usage.provider == .claude)
        #expect(usage.fiveHour?.remainingPercent == 36)
        #expect(usage.weekly?.remainingPercent == 69)
        #expect(usage.fetchedAt == now)
    }

    @Test("HTTP failures surface as the mapped error, not as decoded garbage")
    func httpErrors() async throws {
        for (status, expected) in [(401, ProviderError.notAuthenticated),
                                   (403, .tokenExpired),
                                   (503, .serverError(status: 503))] {
            let transport = StubTransport(status: status, body: "")
            let provider = ClaudeUsageProvider(transport: transport, credentials: StubCredentials(), now: { now })
            await #expect(throws: expected) { _ = try await provider.fetchUsage() }
        }
    }
}

@Suite("Codex adapter")
struct CodexAdapterTests {

    @Test("sends the codex-cli header set")
    func headers() async throws {
        let transport = StubTransport(status: 200, body: codexBody)
        let provider = CodexUsageProvider(
            transport: transport,
            credentials: StubCredentials(account: "acct-123"), now: { now })
        _ = try await provider.fetchUsage()

        let h = await transport.lastRequest()?.headers
        #expect(h?["User-Agent"] == "codex-cli")
        #expect(h?["OpenAI-Beta"] == "codex-1")
        #expect(h?["originator"] == "Codex Desktop")
        #expect(h?["ChatGPT-Account-Id"] == "acct-123")
    }

    // Orca omits the header entirely rather than sending an empty one.
    @Test("the account header is omitted when there is no account id")
    func omitsAccountHeader() async throws {
        let transport = StubTransport(status: 200, body: codexBody)
        let provider = CodexUsageProvider(transport: transport, credentials: StubCredentials(), now: { now })
        _ = try await provider.fetchUsage()
        let h = await transport.lastRequest()?.headers
        #expect(h?["ChatGPT-Account-Id"] == nil)
    }

    @Test("a 429 carries the server's retry hint through")
    func rateLimited() async {
        let transport = StubTransport([.success(UsageResponse(status: 429, body: Data(), retryAfter: 30))])
        let provider = CodexUsageProvider(transport: transport, credentials: StubCredentials(), now: { now })
        await #expect(throws: ProviderError.rateLimited(retryAfter: 30)) {
            _ = try await provider.fetchUsage()
        }
    }
}

@Suite("Request policy")
struct RequestPolicyTests {

    @Test("a transient failure is retried exactly once")
    func retriesOnce() async throws {
        let transport = StubTransport([
            .success(UsageResponse(status: 503, body: Data())),
            .success(UsageResponse(status: 200, body: Data(claudeBody.utf8))),
        ])
        let base = ClaudeUsageProvider(transport: transport, credentials: StubCredentials(), now: { now })
        let provider = RetryingUsageProvider(wrapping: base, sleep: { _ in })

        let usage = try await provider.fetchUsage()
        #expect(usage.fiveHour?.remainingPercent == 36)
        #expect(await transport.callCount == 2)
    }

    @Test("a second transient failure is not retried again")
    func boundedRetry() async {
        let transport = StubTransport(status: 503, body: "")
        let base = ClaudeUsageProvider(transport: transport, credentials: StubCredentials(), now: { now })
        let provider = RetryingUsageProvider(wrapping: base, sleep: { _ in })

        await #expect(throws: ProviderError.self) { _ = try await provider.fetchUsage() }
        #expect(await transport.callCount == 2)   // original + one retry, never three
    }

    @Test("auth, schema and rate-limit failures are never retried", arguments: [
        ProviderError.notAuthenticated,
        .tokenExpired,
        .rateLimited(retryAfter: nil),
        .providerResponseChanged(detail: "x"),
    ])
    func doesNotRetryPermanentFailures(error: ProviderError) async {
        let provider = RetryingUsageProvider(wrapping: FailingProvider(error: error), sleep: { _ in })
        await #expect(throws: error) { _ = try await provider.fetchUsage() }
    }

    // A foreground timer, a manual refresh and a background task can easily coincide.
    @Test("concurrent callers join one in-flight request instead of starting several")
    func singleFlight() async throws {
        let transport = StubTransport(status: 200, body: claudeBody)
        let base = ClaudeUsageProvider(transport: transport, credentials: StubCredentials(), now: { now })
        let provider = SingleFlightUsageProvider(wrapping: base)

        try await withThrowingTaskGroup(of: ProviderUsage.self) { group in
            for _ in 0..<8 { group.addTask { try await provider.fetchUsage() } }
            for try await usage in group { #expect(usage.fiveHour?.remainingPercent == 36) }
        }
        #expect(await transport.callCount == 1)
    }

    @Test("providers are staggered so they never fire in the same instant")
    func stagger() {
        #expect(RefreshSchedule.stagger(for: .claude) == 0)
        #expect(RefreshSchedule.stagger(for: .codex) == 30)
        #expect(RefreshSchedule.firstFire(for: .codex, from: now) == now.addingTimeInterval(30))
    }

    @Test("Retry-After is parsed from both delay-seconds and HTTP-date forms")
    func retryAfterParsing() {
        #expect(RetryAfterParser.seconds(from: "30", now: now) == 30)
        #expect(RetryAfterParser.seconds(from: nil, now: now) == nil)
        #expect(RetryAfterParser.seconds(from: "  ", now: now) == nil)
        #expect(RetryAfterParser.seconds(from: "not-a-date", now: now) == nil)
        let future = RetryAfterParser.seconds(from: "Wed, 09 Sep 2026 00:00:00 GMT", now: now)
        #expect(future != nil && future! > 0)
    }
}

@Suite("Mock providers")
struct MockProviderTests {

    @Test("the brief's default mock values round-trip as remaining percentages")
    func defaults() async throws {
        let claude = try await MockUsageProvider.claudeDefault(now: { now }).fetchUsage()
        #expect(claude.fiveHour?.remainingPercent == 92)
        #expect(claude.weekly?.remainingPercent == 60)

        let codex = try await MockUsageProvider.codexDefault(now: { now }).fetchUsage()
        #expect(codex.fiveHour?.remainingPercent == 8)
        #expect(codex.weekly?.remainingPercent == 72)
    }

    @Test("a mock's tightest window drives the mascot as a real one would")
    func drivesMascot() async throws {
        let codex = try await MockUsageProvider.codexDefault(now: { now }).fetchUsage()
        let pressure = MascotStateResolver.resolve(codex)
        #expect(pressure?.state == .exhausted)
        #expect(pressure?.constrainingWindow == .fiveHour)
    }

    @Test("a mock can simulate every error state")
    func simulatesFailure() async {
        let provider = MockUsageProvider(provider: .claude, failure: .networkUnavailable)
        await #expect(throws: ProviderError.networkUnavailable) { _ = try await provider.fetchUsage() }
    }

    @Test("the mascot gallery covers every energy state plus the recharge transition")
    func gallery() {
        let states = Set(MascotGallery.samples.filter { !$0.isRecharged }.map(\.state))
        #expect(states == Set(MascotEnergyState.allCases))
        #expect(MascotGallery.samples.contains { $0.isRecharged })
    }
}
