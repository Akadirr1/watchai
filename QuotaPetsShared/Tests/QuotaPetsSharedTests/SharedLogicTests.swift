import Testing
import Foundation
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

    @Test("error states map to compact Watch labels")
    func watchLabels() {
        #expect(ProviderError.notAuthenticated.watchLabel == "AUTH")
        #expect(ProviderError.networkUnavailable.watchLabel == "OFFLINE")
        #expect(ProviderError.rateLimited(retryAfter: 30).watchLabel == "STALE")
        #expect(ProviderError.providerResponseChanged(detail: "x").watchLabel == "PROVIDER ERROR")
    }

    @Test("only genuinely transient errors are retried")
    func retryPolicy() {
        #expect(ProviderError.networkUnavailable.isTransient)
        #expect(ProviderError.serverError(status: 503).isTransient)
        #expect(!ProviderError.notAuthenticated.isTransient)
        #expect(!ProviderError.providerResponseChanged(detail: "x").isTransient)
        #expect(!ProviderError.rateLimited(retryAfter: nil).isTransient)
    }

    @Test("HTTP statuses classify as the brief requires")
    func statusClassification() {
        #expect(HTTPStatusClassifier.error(for: 200) == nil)
        #expect(HTTPStatusClassifier.error(for: 401) == .notAuthenticated)
        #expect(HTTPStatusClassifier.error(for: 403) == .tokenExpired)
        #expect(HTTPStatusClassifier.error(for: 429, retryAfter: 30) == .rateLimited(retryAfter: 30))
        #expect(HTTPStatusClassifier.error(for: 503) == .serverError(status: 503))
    }
}
