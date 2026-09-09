import Foundation

/// Wire shape of `GET https://api.anthropic.com/api/oauth/usage`.
///
/// Every field is optional. A missing or unexpected field must degrade to "no window",
/// never to a thrown error — the endpoint is private and unversioned (research §2.1).
public struct ClaudeUsagePayload: Decodable, Sendable {
    public let fiveHour: ClaudeUsageWindowPayload?
    public let sevenDay: ClaudeUsageWindowPayload?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `decodeIfPresent` with `try?` so that a malformed *window* loses only that
        // window, not the whole payload.
        fiveHour = try? c.decodeIfPresent(ClaudeUsageWindowPayload.self, forKey: .fiveHour)
        sevenDay = try? c.decodeIfPresent(ClaudeUsageWindowPayload.self, forKey: .sevenDay)
    }
}

public struct ClaudeUsageWindowPayload: Decodable, Sendable {
    /// Preferred percentage field.
    public let utilization: Double?
    /// Fallback percentage field.
    public let usedPercentage: Double?
    public let resetsAt: ClaudeFlexibleTimestamp?

    enum CodingKeys: String, CodingKey {
        case utilization
        case usedPercentage = "used_percentage"
        case resetsAt = "resets_at"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        utilization = try? c.decodeIfPresent(Double.self, forKey: .utilization)
        usedPercentage = try? c.decodeIfPresent(Double.self, forKey: .usedPercentage)
        resetsAt = try? c.decodeIfPresent(ClaudeFlexibleTimestamp.self, forKey: .resetsAt)
    }

    /// `utilization` wins, `used_percentage` is the fallback.
    ///
    /// Ported from Orca `claude-usage-window.ts:61-66`. **This precedence is
    /// load-bearing**: the brief assumed the field was called `used_percent`, which
    /// Claude never sends — decoding only that name yields no Claude data at all
    /// (research §2.2).
    public var resolvedUsedPercent: Double? {
        if let utilization, utilization.isFinite { return utilization }
        if let usedPercentage, usedPercentage.isFinite { return usedPercentage }
        return nil
    }
}
