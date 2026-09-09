import Testing
import Foundation
@testable import QuotaPetsShared

// Fixtures are hand-written from the schema documented in docs/provider-research.md §2.
// No real credential or captured live response appears anywhere in this suite (§29).

private let epoch = Date(timeIntervalSince1970: 1_757_000_000)  // 2025-09-04T15:33:20Z

@Suite("Claude usage mapping")
struct ClaudeMappingTests {

    @Test("five_hour and seven_day map to fiveHour and weekly")
    func mapsBothWindows() throws {
        let json = """
        {"five_hour":{"utilization":64,"resets_at":1757010000},
         "seven_day":{"utilization":31,"resets_at":1757300000}}
        """.data(using: .utf8)!
        let usage = try ClaudeUsageMapper.decode(json, fetchedAt: epoch)

        #expect(usage.provider == .claude)
        #expect(usage.fiveHour?.usedPercent == 64)
        #expect(usage.weekly?.usedPercent == 31)
        // remaining is always derived, never stored (§32)
        #expect(usage.fiveHour?.remainingPercent == 36)
        #expect(usage.weekly?.remainingPercent == 69)
    }

    // The regression that motivated this whole file: the brief assumed `used_percent`,
    // which Claude never sends. Decoding only that name yields no data at all.
    @Test("utilization takes precedence over used_percentage")
    func utilizationWins() throws {
        let json = #"{"five_hour":{"utilization":80,"used_percentage":20}}"#.data(using: .utf8)!
        let usage = try ClaudeUsageMapper.decode(json, fetchedAt: epoch)
        #expect(usage.fiveHour?.usedPercent == 80)
    }

    @Test("used_percentage is used when utilization is absent")
    func usedPercentageFallback() throws {
        let json = #"{"five_hour":{"used_percentage":42}}"#.data(using: .utf8)!
        let usage = try ClaudeUsageMapper.decode(json, fetchedAt: epoch)
        #expect(usage.fiveHour?.usedPercent == 42)
    }

    @Test("a payload using the brief's assumed used_percent yields no window")
    func briefsAssumedFieldIsNotAccepted() {
        let json = #"{"five_hour":{"used_percent":42}}"#.data(using: .utf8)!
        // Documents the trap rather than hiding it: this field name is not real.
        #expect(throws: ProviderError.self) {
            _ = try ClaudeUsageMapper.decode(json, fetchedAt: epoch)
        }
    }

    @Test("a missing window stays nil without failing the other")
    func missingWindow() throws {
        let json = #"{"five_hour":{"utilization":10}}"#.data(using: .utf8)!
        let usage = try ClaudeUsageMapper.decode(json, fetchedAt: epoch)
        #expect(usage.fiveHour != nil)
        #expect(usage.weekly == nil)
    }

    @Test("zero and one-hundred percent are represented exactly")
    func boundaryUsage() throws {
        let json = #"{"five_hour":{"utilization":0},"seven_day":{"utilization":100}}"#.data(using: .utf8)!
        let usage = try ClaudeUsageMapper.decode(json, fetchedAt: epoch)
        #expect(usage.fiveHour?.usedPercent == 0)
        #expect(usage.fiveHour?.remainingPercent == 100)
        #expect(usage.weekly?.usedPercent == 100)
        #expect(usage.weekly?.remainingPercent == 0)
    }

    @Test("out-of-range percentages are clamped, not propagated")
    func clampsOutOfRange() throws {
        let json = #"{"five_hour":{"utilization":142.7},"seven_day":{"utilization":-8}}"#.data(using: .utf8)!
        let usage = try ClaudeUsageMapper.decode(json, fetchedAt: epoch)
        #expect(usage.fiveHour?.usedPercent == 100)
        #expect(usage.weekly?.usedPercent == 0)
    }

    @Test("malformed JSON becomes providerResponseChanged, never a crash")
    func malformedJSON() {
        #expect(throws: ProviderError.self) {
            _ = try ClaudeUsageMapper.decode(Data("{not json".utf8), fetchedAt: epoch)
        }
    }

    @Test("an HTML error page becomes providerResponseChanged")
    func htmlErrorPage() {
        #expect(throws: ProviderError.self) {
            _ = try ClaudeUsageMapper.decode(Data("<html><body>502</body></html>".utf8), fetchedAt: epoch)
        }
    }

    @Test("a well-formed payload with no recognised window is a schema change")
    func emptyPayloadIsSchemaChange() {
        #expect(throws: ProviderError.self) {
            _ = try ClaudeUsageMapper.decode(Data(#"{"something_new":{}}"#.utf8), fetchedAt: epoch)
        }
    }
}

@Suite("Claude reset timestamp decoding")
struct ClaudeResetTimestampTests {

    @Test("seconds are scaled to a sensible date")
    func secondsEpoch() {
        let d = ClaudeResetTimestamp.date(fromNumeric: 1_757_000_000)
        #expect(d == Date(timeIntervalSince1970: 1_757_000_000))
    }

    @Test("milliseconds are detected and not re-scaled")
    func millisecondEpoch() {
        let d = ClaudeResetTimestamp.date(fromNumeric: 1_757_000_000_000)
        #expect(d == Date(timeIntervalSince1970: 1_757_000_000))
    }

    // Orca uses a strict `>` comparison, so exactly 1e10 falls to the seconds branch.
    // Pinning it keeps a future refactor from silently flipping the boundary.
    @Test("exactly 1e10 is treated as seconds, matching Orca")
    func boundaryIsSeconds() {
        let d = ClaudeResetTimestamp.date(fromNumeric: 10_000_000_000)
        #expect(d == Date(timeIntervalSince1970: 10_000_000_000))
    }

    @Test("just above the boundary is treated as milliseconds")
    func justAboveBoundaryIsMilliseconds() {
        let d = ClaudeResetTimestamp.date(fromNumeric: 10_000_000_001)
        #expect(d == Date(timeIntervalSince1970: 10_000_000.001))
    }

    @Test("ISO-8601 strings parse, with and without fractional seconds")
    func isoStrings() {
        #expect(ClaudeResetTimestamp.date(from: .string("2026-09-08T20:00:00Z")) != nil)
        #expect(ClaudeResetTimestamp.date(from: .string("2026-09-08T20:00:00.512Z")) != nil)
    }

    @Test("numeric strings are treated as epochs")
    func numericString() {
        #expect(ClaudeResetTimestamp.date(from: .string("1757000000"))
                == Date(timeIntervalSince1970: 1_757_000_000))
    }

    @Test("junk, empty and non-finite values yield nil rather than a bogus date")
    func rejectsJunk() {
        #expect(ClaudeResetTimestamp.date(from: .string("tomorrow")) == nil)
        #expect(ClaudeResetTimestamp.date(from: .string("   ")) == nil)
        #expect(ClaudeResetTimestamp.date(from: .absent) == nil)
        #expect(ClaudeResetTimestamp.date(from: nil) == nil)
        #expect(ClaudeResetTimestamp.date(fromNumeric: .nan) == nil)
        #expect(ClaudeResetTimestamp.date(fromNumeric: .infinity) == nil)
    }

    @Test("a window decodes its reset date end-to-end")
    func endToEnd() throws {
        let json = #"{"five_hour":{"utilization":50,"resets_at":"2026-09-08T20:00:00Z"}}"#.data(using: .utf8)!
        let usage = try ClaudeUsageMapper.decode(json, fetchedAt: epoch)
        #expect(usage.fiveHour?.resetAt != nil)
    }
}
