import Foundation

public enum CodexUsageMapper {
    public static func map(_ payload: CodexUsagePayload, fetchedAt: Date) -> ProviderUsage {
        let classified = CodexWindowClassifier.classify(
            primary: payload.rateLimit?.primaryWindow,
            secondary: payload.rateLimit?.secondaryWindow
        )
        return ProviderUsage(
            provider: .codex,
            fiveHour: window(classified.fiveHour, fallback: .fiveHour),
            weekly: window(classified.weekly, fallback: .weekly),
            planName: payload.planType,
            fetchedAt: fetchedAt
        )
    }

    public static func decode(_ data: Data, fetchedAt: Date) throws -> ProviderUsage {
        let payload: CodexUsagePayload
        do {
            payload = try JSONDecoder().decode(CodexUsagePayload.self, from: data)
        } catch {
            throw ProviderError.providerResponseChanged(detail: "Codex usage payload did not decode")
        }
        // Orca's cheap sanity check (`codex-backend-usage-client.ts:74-76`): a missing
        // `plan_type` means we were handed something that is not the usage payload —
        // typically an HTML error page or a login redirect (research §3.4).
        guard payload.planType != nil else {
            throw ProviderError.providerResponseChanged(detail: "Codex usage payload missing plan_type")
        }
        return map(payload, fetchedAt: fetchedAt)
    }

    static func window(_ raw: CodexWindowPayload?, fallback: UsageWindowKind) -> UsageWindow? {
        guard let raw, let used = raw.usedPercent, used.isFinite else { return nil }
        // Prefer the server's own duration; fall back to the canonical length only when
        // it did not give us a usable one.
        let minutes = raw.durationMinutes ?? fallback.canonicalMinutes
        return UsageWindow(
            usedPercent: used,
            resetAt: CodexResetTimestamp.date(fromUnixSeconds: raw.resetAt),
            duration: TimeInterval(minutes * 60)
        )
    }
}
