import Testing
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics   // CGPoint arithmetic in the mascot tests, as in ClaudeMascotRig
#endif
@testable import QuotaPetsShared

private let now = Date(timeIntervalSince1970: 1_757_000_000)

@Suite("Percentage handling")
struct PercentageTests {

    @Test("remaining is the complement of used", arguments: [
        (0.0, 100.0), (36.0, 64.0), (64.0, 36.0), (100.0, 0.0),
    ])
    func remainingIsComplement(used: Double, expectedRemaining: Double) {
        #expect(UsageWindow(usedPercent: used).remainingPercent == expectedRemaining)
    }

    @Test("clamping bounds every input into 0...100")
    func clamps() {
        #expect(UsageWindow.clamp(-40) == 0)
        #expect(UsageWindow.clamp(0) == 0)
        #expect(UsageWindow.clamp(55.5) == 55.5)
        #expect(UsageWindow.clamp(100) == 100)
        #expect(UsageWindow.clamp(1000) == 100)
    }

    // A naive min/max propagates NaN straight to the UI, which then renders "nan%".
    @Test("non-finite input collapses to zero rather than propagating")
    func nonFiniteCollapses() {
        #expect(UsageWindow.clamp(.nan) == 0)
        #expect(UsageWindow.clamp(.infinity) == 0)
        #expect(UsageWindow.clamp(-.infinity) == 0)
        #expect(UsageWindow(usedPercent: .nan).remainingPercent == 100)
    }

    @Test("reset-pending is detected only once the instant has passed")
    func resetPending() {
        let past = UsageWindow(usedPercent: 90, resetAt: now.addingTimeInterval(-1))
        let future = UsageWindow(usedPercent: 90, resetAt: now.addingTimeInterval(60))
        #expect(past.isResetPending(now: now))
        #expect(!future.isResetPending(now: now))
        #expect(!UsageWindow(usedPercent: 90).isResetPending(now: now))
    }
}

@Suite("Mascot state")
struct MascotTests {

    @Test("each band maps to the state the brief specifies", arguments: [
        (100.0, MascotEnergyState.hyper), (75.0, .hyper),
        (74.9, .happy), (50.0, .happy),
        (49.9, .normal), (30.0, .normal),
        (29.9, .tired), (15.0, .tired),
        (14.9, .exhausted), (1.0, .exhausted),
        (0.0, .empty),
    ])
    func bands(remaining: Double, expected: MascotEnergyState) {
        #expect(MascotStateResolver.state(forRemainingPercent: remaining) == expected)
    }

    // The brief lists `1..<15: exhausted` and `0: empty`, leaving this gap unspecified.
    // Documenting our resolution so it is a decision, not an accident.
    @Test("a sliver of quota reads as exhausted, not empty")
    func subOnePercentIsExhausted() {
        #expect(MascotStateResolver.state(forRemainingPercent: 0.4) == .exhausted)
    }

    @Test("pressure comes from the tighter window")
    func tightestWins() {
        let usage = ProviderUsage(
            provider: .claude,
            fiveHour: UsageWindow(usedPercent: 20),   // 80 remaining
            weekly: UsageWindow(usedPercent: 92),     // 8 remaining
            fetchedAt: now)
        let pressure = MascotStateResolver.resolve(usage)
        #expect(pressure?.state == .exhausted)
        #expect(pressure?.remainingPercent == 8)
        // §17: the UI must be able to say WHICH limit caused it.
        #expect(pressure?.constrainingWindow == .weekly)
    }

    @Test("the five-hour window can be the constraining one")
    func fiveHourConstrains() {
        let usage = ProviderUsage(
            provider: .claude,
            fiveHour: UsageWindow(usedPercent: 88),   // 12 remaining
            weekly: UsageWindow(usedPercent: 22),     // 78 remaining
            fetchedAt: now)
        let pressure = MascotStateResolver.resolve(usage)
        #expect(pressure?.state == .exhausted)
        #expect(pressure?.constrainingWindow == .fiveHour)
    }

    // A missing window must not read as "0% remaining" and panic the mascot.
    @Test("a single present window is used alone")
    func singleWindow() {
        let usage = ProviderUsage(provider: .codex, fiveHour: UsageWindow(usedPercent: 10), fetchedAt: now)
        let pressure = MascotStateResolver.resolve(usage)
        #expect(pressure?.state == .hyper)
        #expect(pressure?.constrainingWindow == .fiveHour)
    }

    @Test("Claude's mascot reads the weekly window even when the five-hour one is tighter")
    func claudeMascotFollowsWeekly() {
        let tight5h = { (provider: AIProvider) in
            ProviderUsage(provider: provider,
                          fiveHour: UsageWindow(usedPercent: 95),   // 5 remaining
                          weekly: UsageWindow(usedPercent: 40),     // 60 remaining
                          fetchedAt: now)
        }
        let claude = MascotStateResolver.mascotPressure(tight5h(.claude))
        #expect(claude?.state == .happy)
        #expect(claude?.constrainingWindow == .weekly)
        // Codex keeps the tighter window.
        #expect(MascotStateResolver.mascotPressure(tight5h(.codex))?.constrainingWindow == .fiveHour)
        // No weekly window: Claude falls back to the one it has.
        let noWeekly = ProviderUsage(provider: .claude, fiveHour: UsageWindow(usedPercent: 95), fetchedAt: now)
        #expect(MascotStateResolver.mascotPressure(noWeekly)?.constrainingWindow == .fiveHour)
    }

    @Test("no windows and no usage both yield no pressure")
    func noData() {
        #expect(MascotStateResolver.resolve(ProviderUsage(provider: .codex, fetchedAt: now)) == nil)
        #expect(MascotStateResolver.resolve(nil) == nil)
    }

    @Test("only the empty state opts out of idle animation")
    func animationGating() {
        #expect(MascotEnergyState.empty.wantsIdleAnimation == false)
        #expect(MascotEnergyState.exhausted.wantsIdleAnimation)
    }
}

@Suite("Claude mascot")
struct ClaudeMascotTests {

    @Test("each mood plays its own clips", arguments: [
        (MascotEnergyState.hyper, false, [ClaudeClip.look, .jump, .idle]),
        (.tired, true, [.walk, .tighten, .gym]),
        (.exhausted, false, [.flagWave, .celebrate]),
        (.empty, true, [.sweat]),
    ])
    func rotations(state: MascotEnergyState, working: Bool, expected: [ClaudeClip]) {
        #expect(ClaudeClip.rotation(for: state, working: working) == expected)
    }

    // Clips play back to back, so each must hand over on the stance the next starts from.
    // Confetti may still be falling past the rig's shapes; the JS clears it on the next clip.
    // Sweat loops for as long as the quota stays gone, so it never hands over.
    @Test("every clip ends on the rest pose",
          arguments: [ClaudeClip.look, .jump, .idle, .walk, .tighten, .gym, .flagWave, .celebrate])
    func endsAtRest(clip: ClaudeClip) {
        let rest = ClaudeMascotRig.shapes([.idle], at: 0, bandana: true)
        let end = ClaudeMascotRig.shapes([clip], at: ClaudeMascotRig.duration(clip, bandana: true) - 0.001, bandana: true)
        #expect(end.count >= rest.count)
        for (a, b) in zip(end, rest) {
            #expect(a.rgb == b.rgb)
            #expect(zip(a.points, b.points).allSatisfy { abs($0.x - $1.x) < 0.01 && abs($0.y - $1.y) < 0.01 })
        }
    }

    @Test("the bandana is drawn only when switched on")
    func bandana() {
        let band: UInt32 = 0xB4453A
        #expect(ClaudeMascotRig.shapes([.idle], at: 0, bandana: true).contains { $0.rgb == band })
        #expect(!ClaudeMascotRig.shapes([.idle], at: 0, bandana: false).contains { $0.rgb == band })
    }
}

@Suite("Countdown formatting")
struct CountdownTests {

    // Values are literal rather than arithmetic: expressions inside a parameterised
    // `arguments:` array push the type-checker past its time budget.
    static let cases: [(TimeInterval, String)] = [
        (2520, "42m"),      // 42m
        (7980, "2h 13m"),
        (280_800, "3d 6h"),
        (3600, "1h"),
        (86_400, "1d"),
        (30, "0m"),         // rounds down to the minute
    ]

    @Test("durations render with at most two units", arguments: cases)
    func formats(seconds: TimeInterval, expected: String) {
        #expect(CountdownFormatter.string(seconds: seconds) == expected)
    }

    @Test("a past reset renders as 0m rather than a negative value")
    func pastDate() {
        #expect(CountdownFormatter.string(until: now.addingTimeInterval(-500), now: now) == "0m")
    }

    @Test("no reset date renders as nil")
    func noDate() {
        #expect(CountdownFormatter.string(until: nil, now: now) == nil)
    }
}

@Suite("Snapshot freshness")
struct FreshnessTests {

    @Test("a recent snapshot is live and labelled in seconds")
    func live() {
        let f = SnapshotFreshness.evaluate(generatedAt: now.addingTimeInterval(-42), now: now)
        #expect(!f.isStale)
        #expect(f.label == "UPDATED 42s AGO")
    }

    @Test("an old snapshot is stale and says so")
    func stale() {
        let f = SnapshotFreshness.evaluate(generatedAt: now.addingTimeInterval(-8 * 60), now: now)
        #expect(f.isStale)
        #expect(f.label == "STALE · 8m")
    }

    @Test("the boundary is exclusive")
    func boundary() {
        #expect(!SnapshotFreshness.evaluate(generatedAt: now.addingTimeInterval(-120), now: now).isStale)
        #expect(SnapshotFreshness.evaluate(generatedAt: now.addingTimeInterval(-121), now: now).isStale)
    }

    // Clock skew between the helper Mac and the phone must not produce a negative age.
    @Test("a future timestamp clamps to zero age")
    func futureTimestamp() {
        let f = SnapshotFreshness.evaluate(generatedAt: now.addingTimeInterval(300), now: now)
        #expect(f.age == 0)
        #expect(!f.isStale)
    }
}

@Suite("Threshold crossings")
struct ThresholdTests {

    @Test("crossing below a threshold fires once, not on every refresh")
    func firesOnce() {
        var state = ThresholdState()
        var r = ThresholdTracker.evaluate(previous: state, remainingPercent: 48, window: .fiveHour)
        #expect(r.events == [.crossedBelow(threshold: 50, window: .fiveHour)])
        state = r.state

        r = ThresholdTracker.evaluate(previous: state, remainingPercent: 47, window: .fiveHour)
        #expect(r.events.isEmpty)
    }

    // Falling 60 -> 4 in one step should be one event, not four.
    @Test("a large drop reports only the lowest threshold crossed")
    func reportsLowestOnly() {
        let r = ThresholdTracker.evaluate(previous: ThresholdState(), remainingPercent: 4, window: .weekly)
        #expect(r.events == [.crossedBelow(threshold: 5, window: .weekly)])
    }

    @Test("descending through bands fires each new one")
    func descending() {
        var state = ThresholdState()
        for (remaining, expected) in [(48.0, 50.0), (24.0, 25.0), (9.0, 10.0), (4.0, 5.0)] {
            let r = ThresholdTracker.evaluate(previous: state, remainingPercent: remaining, window: .fiveHour)
            #expect(r.events == [.crossedBelow(threshold: expected, window: .fiveHour)])
            state = r.state
        }
    }

    @Test("a reset is detected and rearms the thresholds")
    func rechargeRearms() {
        var state = ThresholdState()
        state = ThresholdTracker.evaluate(previous: state, remainingPercent: 4, window: .fiveHour).state

        let recharged = ThresholdTracker.evaluate(previous: state, remainingPercent: 100, window: .fiveHour)
        #expect(recharged.events.contains(.recharged(window: .fiveHour)))
        #expect(recharged.state.lastAnnouncedThreshold == nil)

        // Having rearmed, the next depletion fires again.
        let again = ThresholdTracker.evaluate(previous: recharged.state, remainingPercent: 48, window: .fiveHour)
        #expect(again.events == [.crossedBelow(threshold: 50, window: .fiveHour)])
    }

    @Test("small upward jitter is not mistaken for a reset")
    func jitterIsNotRecharge() {
        let state = ThresholdState(lastAnnouncedThreshold: 25, lastRemainingPercent: 20)
        let r = ThresholdTracker.evaluate(previous: state, remainingPercent: 22, window: .weekly)
        #expect(!r.events.contains(.recharged(window: .weekly)))
    }

    @Test("a weekly recharge is major, a five-hour one is not")
    func severity() {
        #expect(QuotaEvent.recharged(window: .weekly).isMajor)
        #expect(!QuotaEvent.recharged(window: .fiveHour).isMajor)
        #expect(QuotaEvent.crossedBelow(threshold: 5, window: .weekly).isMajor)
    }
}

@Suite("Snapshot composition")
struct SnapshotTests {

    @Test("replacing one provider preserves the other")
    func replacePreserves() {
        let claude = ProviderUsage(provider: .claude, fiveHour: UsageWindow(usedPercent: 10), fetchedAt: now)
        let codex = ProviderUsage(provider: .codex, fiveHour: UsageWindow(usedPercent: 90), fetchedAt: now)
        let snapshot = UsageSnapshot(claude: claude, codex: codex, generatedAt: now)

        let updated = snapshot.replacing(
            ProviderUsage(provider: .claude, fiveHour: UsageWindow(usedPercent: 55), fetchedAt: now),
            generatedAt: now.addingTimeInterval(60))

        #expect(updated.claude?.fiveHour?.usedPercent == 55)
        #expect(updated.codex?.fiveHour?.usedPercent == 90)
    }

    @Test("a snapshot round-trips through JSON for WatchConnectivity transport")
    func codableRoundTrip() throws {
        let snapshot = UsageSnapshot(
            claude: ProviderUsage(provider: .claude,
                                  fiveHour: UsageWindow(usedPercent: 64, resetAt: now, duration: 18000),
                                  weekly: UsageWindow(usedPercent: 31),
                                  planName: "max", fetchedAt: now),
            codex: nil, generatedAt: now)
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: data)
        #expect(decoded == snapshot)
    }

    @Test("a provider is busy only while its usage climbs between neighbouring polls")
    func busy() {
        func snap(_ used: Double, at seconds: Double) -> UsageSnapshot {
            UsageSnapshot(claude: ProviderUsage(provider: .claude, fiveHour: UsageWindow(usedPercent: used), fetchedAt: now),
                          generatedAt: now.addingTimeInterval(seconds))
        }
        #expect(snap(41, at: 60).busyProviders(since: snap(40, at: 0)) == [.claude])
        #expect(snap(40, at: 60).busyProviders(since: snap(40, at: 0)).isEmpty)
        // An hour-old snapshot says nothing about right now.
        #expect(snap(41, at: 3600).busyProviders(since: snap(40, at: 0)).isEmpty)
        #expect(snap(41, at: 60).busyProviders(since: nil).isEmpty)
    }
}

// MARK: - Timestamp decoding

/// The bug that made a healthy server look broken.
///
/// The watch showed "SERVER ERROR" on every request while `/api/pair/start` was answering
/// 200 with a valid body. The cause was entirely client-side: the stock `.iso8601` date
/// strategy cannot read the timestamps the server emits, so decoding threw and the error
/// was flattened into a generic label.
@Suite("Timestamp decoding")
struct ISO8601DecodingTests {
    private struct Wrapper: Decodable { let at: Date }

    /// Exactly what the Node server sends: `toISOString()` always includes milliseconds.
    private static let withMilliseconds = #"{"at":"2026-09-22T20:13:00.250Z"}"#
    private static let withoutMilliseconds = #"{"at":"2026-09-22T20:13:00Z"}"#

    private func decode(_ json: String, with decoder: JSONDecoder) throws -> Date {
        try decoder.decode(Wrapper.self, from: Data(json.utf8)).at
    }

    /// Pins the trap itself. `.iso8601` uses `ISO8601DateFormatter` with only
    /// `.withInternetDateTime`, which has no fractional-seconds support — so this is not a
    /// server bug to go chasing.
    @Test("the stock .iso8601 strategy rejects the server's own output")
    func stockStrategyRejectsFractionalSeconds() {
        let stock = JSONDecoder()
        stock.dateDecodingStrategy = .iso8601
        #expect(throws: (any Error).self) {
            try decode(Self.withMilliseconds, with: stock)
        }
    }

    @Test("ours reads milliseconds")
    func readsFractionalSeconds() throws {
        let date = try decode(Self.withMilliseconds, with: .quotaPets())
        #expect(date.timeIntervalSince1970 == 1_790_107_980.25)
    }

    // A different serialiser on the other end must not break the app either.
    @Test("ours still reads plain seconds")
    func readsWholeSeconds() throws {
        let date = try decode(Self.withoutMilliseconds, with: .quotaPets())
        #expect(date.timeIntervalSince1970 == 1_790_107_980)
    }

    @Test("ours rejects what is genuinely not a timestamp")
    func rejectsGarbage() {
        #expect(throws: (any Error).self) {
            try decode(#"{"at":"tomorrow-ish"}"#, with: .quotaPets())
        }
    }
}
