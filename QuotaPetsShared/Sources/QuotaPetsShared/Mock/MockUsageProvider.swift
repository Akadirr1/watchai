import Foundation

/// DEBUG-only mock provider (§30).
///
/// Lives in the shared package rather than behind `#if DEBUG` so that it can be unit
/// tested, but every *call site* that constructs one is expected to be DEBUG-gated. The
/// production path must use the real adapters (§30).
public struct MockUsageProvider: UsageProvider {
    public let provider: AIProvider
    /// Values are expressed as **remaining** percentages, because that is how the brief
    /// states the defaults and how the debug sliders are labelled. They are converted to
    /// canonical `usedPercent` on the way out (§32).
    public var fiveHourRemaining: Double?
    public var weeklyRemaining: Double?
    public var planName: String?
    public var resetIn: TimeInterval?
    /// When set, `fetchUsage()` throws this instead — for exercising the §25 error states.
    public var failure: ProviderError?
    private let now: @Sendable () -> Date

    public init(
        provider: AIProvider,
        fiveHourRemaining: Double? = nil,
        weeklyRemaining: Double? = nil,
        planName: String? = nil,
        resetIn: TimeInterval? = 3600,
        failure: ProviderError? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.provider = provider
        self.fiveHourRemaining = fiveHourRemaining
        self.weeklyRemaining = weeklyRemaining
        self.planName = planName
        self.resetIn = resetIn
        self.failure = failure
        self.now = now
    }

    /// The defaults the brief specifies (§30).
    public static func claudeDefault(now: @escaping @Sendable () -> Date = { Date() }) -> MockUsageProvider {
        MockUsageProvider(provider: .claude, fiveHourRemaining: 92, weeklyRemaining: 60,
                          planName: "max", resetIn: 2 * 3600 + 14 * 60, now: now)
    }

    public static func codexDefault(now: @escaping @Sendable () -> Date = { Date() }) -> MockUsageProvider {
        MockUsageProvider(provider: .codex, fiveHourRemaining: 8, weeklyRemaining: 72,
                          planName: "plus", resetIn: 41 * 60, now: now)
    }

    public func fetchUsage() async throws -> ProviderUsage {
        if let failure { throw failure }
        let timestamp = now()
        let reset = resetIn.map { timestamp.addingTimeInterval($0) }
        return ProviderUsage(
            provider: provider,
            fiveHour: fiveHourRemaining.map {
                UsageWindow(usedPercent: 100 - $0, resetAt: reset,
                            duration: TimeInterval(UsageWindowKind.fiveHour.canonicalMinutes * 60))
            },
            weekly: weeklyRemaining.map {
                UsageWindow(usedPercent: 100 - $0, resetAt: reset.map { $0.addingTimeInterval(86_400) },
                            duration: TimeInterval(UsageWindowKind.weekly.canonicalMinutes * 60))
            },
            planName: planName,
            fetchedAt: timestamp
        )
    }
}

/// The DEBUG mascot gallery (§31): fixed remaining values that walk every energy state,
/// so the art can be tuned without spending real quota.
public enum MascotGallery {
    public struct Sample: Sendable, Hashable {
        public let label: String
        public let remainingPercent: Double
        public let state: MascotEnergyState
        /// True for the post-reset celebration, which is a transition rather than a
        /// resting state and therefore has no `MascotEnergyState` of its own (§16).
        public let isRecharged: Bool
    }

    public static let samples: [Sample] = {
        let levels: [Double] = [100, 70, 45, 25, 10, 0]
        var out = levels.map {
            Sample(label: "\(Int($0))%", remainingPercent: $0,
                   state: MascotStateResolver.state(forRemainingPercent: $0), isRecharged: false)
        }
        out.append(Sample(label: "RECHARGED", remainingPercent: 100, state: .hyper, isRecharged: true))
        return out
    }()
}
