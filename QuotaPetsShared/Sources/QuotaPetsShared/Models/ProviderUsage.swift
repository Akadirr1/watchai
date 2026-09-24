import Foundation

/// Normalised, provider-neutral usage for one provider.
///
/// Nothing Anthropic- or OpenAI-shaped survives past this type — raw provider JSON never
/// reaches SwiftUI (§2 of the brief).
public struct ProviderUsage: Codable, Sendable, Hashable {
    public let provider: AIProvider
    public let fiveHour: UsageWindow?
    public let weekly: UsageWindow?
    /// Provider plan tier when reported ("pro", "max", "plus"…). Codex reports it as
    /// `plan_type`; Claude carries it on the credential record rather than the usage
    /// payload, so it may be nil for Claude.
    public let planName: String?
    public let fetchedAt: Date

    public init(
        provider: AIProvider,
        fiveHour: UsageWindow? = nil,
        weekly: UsageWindow? = nil,
        planName: String? = nil,
        fetchedAt: Date
    ) {
        self.provider = provider
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.planName = planName
        self.fetchedAt = fetchedAt
    }

    public func window(_ kind: UsageWindowKind) -> UsageWindow? {
        switch kind {
        case .fiveHour: fiveHour
        case .weekly: weekly
        }
    }

    /// True when the provider returned neither window. Distinguishes "connected but the
    /// payload carried nothing we understand" from "not connected", which the Watch
    /// surfaces differently (§25).
    public var isEmpty: Bool { fiveHour == nil && weekly == nil }
}

/// Both providers at one instant. This is the ONLY thing that crosses WatchConnectivity —
/// never a credential (§6).
public struct UsageSnapshot: Codable, Sendable, Hashable {
    public let claude: ProviderUsage?
    public let codex: ProviderUsage?
    public let generatedAt: Date

    public init(claude: ProviderUsage? = nil, codex: ProviderUsage? = nil, generatedAt: Date) {
        self.claude = claude
        self.codex = codex
        self.generatedAt = generatedAt
    }

    public func usage(for provider: AIProvider) -> ProviderUsage? {
        switch provider {
        case .claude: claude
        case .codex: codex
        }
    }

    /// Providers whose usage rose since `previous`: the only sign of work in progress the
    /// server exposes. Snapshots more than a few 60-second polls apart say nothing about now.
    public func busyProviders(since previous: UsageSnapshot?) -> Set<AIProvider> {
        guard let previous, generatedAt.timeIntervalSince(previous.generatedAt) < 180 else { return [] }
        return Set(AIProvider.allCases.filter { provider in
            guard let before = previous.usage(for: provider), let after = usage(for: provider) else { return false }
            return [UsageWindowKind.fiveHour, .weekly].contains {
                (after.window($0)?.usedPercent ?? 0) > (before.window($0)?.usedPercent ?? 0)
            }
        })
    }

    /// What the complications print: each provider's two windows as whole percentages
    /// left. Two snapshots with the same digest draw identical complications, so the
    /// second is not worth one of the widget's ~75 daily reloads. Anything a complication
    /// starts to show must be added here, or it will go stale on the face.
    public var complicationDigest: [Int?] {
        AIProvider.allCases.flatMap { provider in
            [UsageWindowKind.fiveHour, .weekly].map { kind in
                usage(for: provider)?.window(kind).map { Int($0.remainingPercent.rounded()) }
            }
        }
    }

    /// Replaces one provider's slot, preserving the other. Used when the two providers
    /// are fetched on a stagger (§9) and only one has new data.
    public func replacing(_ usage: ProviderUsage, generatedAt: Date) -> UsageSnapshot {
        switch usage.provider {
        case .claude: UsageSnapshot(claude: usage, codex: codex, generatedAt: generatedAt)
        case .codex: UsageSnapshot(claude: claude, codex: usage, generatedAt: generatedAt)
        }
    }
}
