import Foundation

/// Wraps a provider with the §26 request policy: **one** bounded retry for genuinely
/// transient failures, and no retry at all for anything else.
///
/// Auth failures, schema changes and 429s are not retried — retrying them burns battery
/// and quota to fail identically, and a 429 retry actively makes things worse.
public struct RetryingUsageProvider: UsageProvider {
    public var provider: AIProvider { wrapped.provider }
    private let wrapped: any UsageProvider
    private let backoff: Duration
    private let sleep: @Sendable (Duration) async throws -> Void

    public init(
        wrapping wrapped: any UsageProvider,
        backoff: Duration = .seconds(2),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.wrapped = wrapped
        self.backoff = backoff
        self.sleep = sleep
    }

    public func fetchUsage() async throws -> ProviderUsage {
        do {
            return try await wrapped.fetchUsage()
        } catch let error as ProviderError where error.isTransient {
            try await sleep(backoff)
            return try await wrapped.fetchUsage()
        }
    }
}

/// Guarantees that a provider never has two usage requests in flight at once (§26).
///
/// Concurrent callers — a foreground timer, a manual "refresh now" tap and a background
/// task can easily coincide — join the request already running instead of starting a
/// second one. That is the same single-flight discipline the brief asks for around token
/// refresh, applied where this architecture actually needs it.
public actor SingleFlightUsageProvider: UsageProvider {
    public nonisolated let provider: AIProvider
    private let wrapped: any UsageProvider
    private var inFlight: Task<ProviderUsage, any Error>?

    public init(wrapping wrapped: any UsageProvider) {
        self.wrapped = wrapped
        self.provider = wrapped.provider
    }

    public func fetchUsage() async throws -> ProviderUsage {
        if let existing = inFlight {
            return try await existing.value
        }
        let task = Task { [wrapped] in try await wrapped.fetchUsage() }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }
}

/// Staggers the two providers so they never fire in the same instant, forever (§9).
///
/// The offset is derived from the provider rather than randomised, so it is stable
/// across launches and reproducible in tests — `Math.random()`-style jitter would make
/// the schedule untestable for no real benefit at two providers.
public enum RefreshSchedule {
    public static let foregroundInterval: TimeInterval = 60

    public static func stagger(for provider: AIProvider) -> TimeInterval {
        switch provider {
        case .claude: 0
        case .codex: foregroundInterval / 2
        }
    }

    public static func nextFire(for provider: AIProvider, after date: Date) -> Date {
        date.addingTimeInterval(foregroundInterval)
    }

    public static func firstFire(for provider: AIProvider, from start: Date) -> Date {
        start.addingTimeInterval(stagger(for: provider))
    }
}
