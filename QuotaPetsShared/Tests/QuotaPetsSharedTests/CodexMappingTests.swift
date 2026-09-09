import Testing
import Foundation
@testable import QuotaPetsShared

private let epoch = Date(timeIntervalSince1970: 1_757_000_000)

private func codexJSON(primary: String?, secondary: String?, plan: String? = "plus") -> Data {
    var parts: [String] = []
    if let plan { parts.append("\"plan_type\":\"\(plan)\"") }
    var windows: [String] = []
    if let primary { windows.append("\"primary_window\":\(primary)") }
    if let secondary { windows.append("\"secondary_window\":\(secondary)") }
    parts.append("\"rate_limit\":{\(windows.joined(separator: ","))}")
    return Data("{\(parts.joined(separator: ","))}".utf8)
}

private let fiveHourWindow = #"{"used_percent":12,"limit_window_seconds":18000,"reset_at":1757010000}"#
private let weeklyWindow   = #"{"used_percent":47,"limit_window_seconds":604800,"reset_at":1757300000}"#

@Suite("Codex window classification")
struct CodexClassificationTests {

    @Test("primary=5h, secondary=week classifies correctly")
    func conventionalOrder() throws {
        let usage = try CodexUsageMapper.decode(
            codexJSON(primary: fiveHourWindow, secondary: weeklyWindow), fetchedAt: epoch)
        #expect(usage.fiveHour?.usedPercent == 12)
        #expect(usage.weekly?.usedPercent == 47)
    }

    // The case the brief specifically warns about (§3): trusting position would swap
    // these two and show the weekly figure as the 5-hour one.
    @Test("primary=week, secondary=5h still classifies by duration, not position")
    func reversedOrder() throws {
        let usage = try CodexUsageMapper.decode(
            codexJSON(primary: weeklyWindow, secondary: fiveHourWindow), fetchedAt: epoch)
        #expect(usage.fiveHour?.usedPercent == 12)
        #expect(usage.weekly?.usedPercent == 47)
    }

    @Test("the one-minute drift tolerance is honoured")
    func toleranceBand() throws {
        // 299 minutes and 10081 minutes: inside Orca's +/-1 minute tolerance.
        let drifted5h = #"{"used_percent":5,"limit_window_seconds":17940}"#
        let driftedWk = #"{"used_percent":6,"limit_window_seconds":604860}"#
        let usage = try CodexUsageMapper.decode(
            codexJSON(primary: drifted5h, secondary: driftedWk), fetchedAt: epoch)
        #expect(usage.fiveHour?.usedPercent == 5)
        #expect(usage.weekly?.usedPercent == 6)
    }

    @Test("a duration well outside tolerance is not absorbed into a canonical bucket")
    func outsideToleranceUsesPositionalFallback() throws {
        // 60 minutes classifies as neither, so the positional fallback applies.
        let hourly = #"{"used_percent":9,"limit_window_seconds":3600}"#
        let usage = try CodexUsageMapper.decode(
            codexJSON(primary: hourly, secondary: weeklyWindow), fetchedAt: epoch)
        #expect(usage.fiveHour?.usedPercent == 9)   // fell back to primary
        #expect(usage.weekly?.usedPercent == 47)    // classified by duration
    }

    @Test("missing duration falls back to the legacy positional mapping")
    func missingDuration() throws {
        let noDurationA = #"{"used_percent":21}"#
        let noDurationB = #"{"used_percent":33}"#
        let usage = try CodexUsageMapper.decode(
            codexJSON(primary: noDurationA, secondary: noDurationB), fetchedAt: epoch)
        #expect(usage.fiveHour?.usedPercent == 21)
        #expect(usage.weekly?.usedPercent == 33)
    }

    // The narrow-fallback rule, stated directly. A positively-classified weekly window
    // must never also be taken as the 5-hour window.
    @Test("a classified weekly window is never reused as the five-hour window")
    func classifiedWeeklyIsNotReusedAsFiveHour() throws {
        let usage = try CodexUsageMapper.decode(
            codexJSON(primary: weeklyWindow, secondary: nil), fetchedAt: epoch)
        #expect(usage.weekly?.usedPercent == 47)
        #expect(usage.fiveHour == nil)
    }

    @Test("only one window present is handled")
    func singleWindow() throws {
        let usage = try CodexUsageMapper.decode(
            codexJSON(primary: fiveHourWindow, secondary: nil), fetchedAt: epoch)
        #expect(usage.fiveHour?.usedPercent == 12)
        #expect(usage.weekly == nil)
    }

    @Test("a window without a usable percentage is discarded entirely")
    func unmappableWindowDiscarded() throws {
        let noPercent = #"{"limit_window_seconds":18000}"#
        let usage = try CodexUsageMapper.decode(
            codexJSON(primary: noPercent, secondary: weeklyWindow), fetchedAt: epoch)
        #expect(usage.fiveHour == nil)
        #expect(usage.weekly?.usedPercent == 47)
    }

    @Test("a zero or negative duration is treated as absent")
    func nonPositiveDuration() {
        #expect(CodexWindowPayload(usedPercent: 1, limitWindowSeconds: 0, resetAt: nil).durationMinutes == nil)
        #expect(CodexWindowPayload(usedPercent: 1, limitWindowSeconds: -60, resetAt: nil).durationMinutes == nil)
    }
}

@Suite("Codex payload handling")
struct CodexPayloadTests {

    @Test("plan_type is surfaced as planName")
    func planType() throws {
        let usage = try CodexUsageMapper.decode(
            codexJSON(primary: fiveHourWindow, secondary: weeklyWindow, plan: "pro"), fetchedAt: epoch)
        #expect(usage.planName == "pro")
    }

    // Orca's cheap guard against being handed a login redirect or error page.
    @Test("a payload missing plan_type is rejected as a schema change")
    func missingPlanTypeRejected() {
        #expect(throws: ProviderError.self) {
            _ = try CodexUsageMapper.decode(
                codexJSON(primary: fiveHourWindow, secondary: weeklyWindow, plan: nil), fetchedAt: epoch)
        }
    }

    @Test("malformed JSON becomes providerResponseChanged")
    func malformed() {
        #expect(throws: ProviderError.self) {
            _ = try CodexUsageMapper.decode(Data("}{".utf8), fetchedAt: epoch)
        }
    }

    @Test("reset_at is read as Unix seconds, never milliseconds")
    func resetAtIsSeconds() throws {
        let usage = try CodexUsageMapper.decode(
            codexJSON(primary: fiveHourWindow, secondary: nil), fetchedAt: epoch)
        #expect(usage.fiveHour?.resetAt == Date(timeIntervalSince1970: 1_757_010_000))
    }

    // Guards the §3.5 divergence: a value above Claude's 1e10 boundary must NOT be
    // reinterpreted as milliseconds here.
    @Test("a large reset_at is not reinterpreted by Claude's heuristic")
    func largeResetAtStaysSeconds() {
        let d = CodexResetTimestamp.date(fromUnixSeconds: 20_000_000_000)
        #expect(d == Date(timeIntervalSince1970: 20_000_000_000))
    }

    @Test("non-positive and non-finite reset_at yield nil")
    func rejectsBadResetAt() {
        #expect(CodexResetTimestamp.date(fromUnixSeconds: 0) == nil)
        #expect(CodexResetTimestamp.date(fromUnixSeconds: -1) == nil)
        #expect(CodexResetTimestamp.date(fromUnixSeconds: .nan) == nil)
        #expect(CodexResetTimestamp.date(fromUnixSeconds: nil) == nil)
    }

    @Test("out-of-range used_percent is clamped")
    func clamps() throws {
        let over = #"{"used_percent":300,"limit_window_seconds":18000}"#
        let usage = try CodexUsageMapper.decode(codexJSON(primary: over, secondary: nil), fetchedAt: epoch)
        #expect(usage.fiveHour?.usedPercent == 100)
    }
}
