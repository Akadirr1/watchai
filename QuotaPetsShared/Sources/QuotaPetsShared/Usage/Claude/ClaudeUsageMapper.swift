import Foundation

/// Turns a raw Claude payload into the provider-neutral model.
/// `five_hour → fiveHour`, `seven_day → weekly` (research §2.2).
public enum ClaudeUsageMapper {
    public static func map(_ payload: ClaudeUsagePayload, fetchedAt: Date, planName: String? = nil) -> ProviderUsage {
        ProviderUsage(
            provider: .claude,
            fiveHour: window(payload.fiveHour, kind: .fiveHour),
            weekly: window(payload.sevenDay, kind: .weekly),
            planName: planName,
            fetchedAt: fetchedAt
        )
    }

    /// Decodes bytes, converting any decoding failure into `providerResponseChanged`
    /// rather than letting it escape as an opaque `DecodingError` (§25).
    public static func decode(_ data: Data, fetchedAt: Date, planName: String? = nil) throws -> ProviderUsage {
        let payload: ClaudeUsagePayload
        do {
            payload = try JSONDecoder().decode(ClaudeUsagePayload.self, from: data)
        } catch {
            throw ProviderError.providerResponseChanged(detail: "Claude usage payload did not decode")
        }
        let usage = map(payload, fetchedAt: fetchedAt, planName: planName)
        // A payload that decodes but yields no window at all means the schema moved
        // under us — the same class of signal as Codex's `plan_type` guard (§3.4).
        guard !usage.isEmpty else {
            throw ProviderError.providerResponseChanged(detail: "Claude usage payload contained no recognised window")
        }
        return usage
    }

    static func window(_ raw: ClaudeUsageWindowPayload?, kind: UsageWindowKind) -> UsageWindow? {
        guard let raw, let used = raw.resolvedUsedPercent else { return nil }
        return UsageWindow(
            usedPercent: used,
            resetAt: ClaudeResetTimestamp.date(from: raw.resetsAt),
            duration: TimeInterval(kind.canonicalMinutes * 60)
        )
    }
}
