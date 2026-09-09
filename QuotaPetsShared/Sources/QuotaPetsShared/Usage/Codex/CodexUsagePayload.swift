import Foundation

/// Wire shape of `GET https://chatgpt.com/backend-api/wham/usage`.
/// Private, unversioned endpoint — every field optional, nothing may throw.
public struct CodexUsagePayload: Decodable, Sendable {
    public let planType: String?
    public let rateLimit: CodexRateLimit?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        planType = try? c.decodeIfPresent(String.self, forKey: .planType)
        rateLimit = try? c.decodeIfPresent(CodexRateLimit.self, forKey: .rateLimit)
    }
}

public struct CodexRateLimit: Decodable, Sendable {
    public let primaryWindow: CodexWindowPayload?
    public let secondaryWindow: CodexWindowPayload?

    enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        primaryWindow = try? c.decodeIfPresent(CodexWindowPayload.self, forKey: .primaryWindow)
        secondaryWindow = try? c.decodeIfPresent(CodexWindowPayload.self, forKey: .secondaryWindow)
    }
}

public struct CodexWindowPayload: Decodable, Sendable, Hashable {
    public let usedPercent: Double?
    public let limitWindowSeconds: Double?
    public let resetAt: Double?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case limitWindowSeconds = "limit_window_seconds"
        case resetAt = "reset_at"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        usedPercent = try? c.decodeIfPresent(Double.self, forKey: .usedPercent)
        limitWindowSeconds = try? c.decodeIfPresent(Double.self, forKey: .limitWindowSeconds)
        resetAt = try? c.decodeIfPresent(Double.self, forKey: .resetAt)
    }

    public init(usedPercent: Double?, limitWindowSeconds: Double?, resetAt: Double?) {
        self.usedPercent = usedPercent
        self.limitWindowSeconds = limitWindowSeconds
        self.resetAt = resetAt
    }

    /// Window length in whole minutes, rounded up, or nil when unusable.
    /// Ported from Orca `codex-backend-usage-client.ts:39-45`.
    public var durationMinutes: Int? {
        guard let s = limitWindowSeconds, s.isFinite, s > 0 else { return nil }
        return Int((s / 60).rounded(.up))
    }

    /// Only windows with a finite percentage are classifiable
    /// (Orca `codex-rate-limit-window-classification.ts:21-25`).
    public var isMappable: Bool {
        guard let p = usedPercent else { return false }
        return p.isFinite
    }
}
