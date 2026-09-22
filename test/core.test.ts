import { describe, expect, it } from "vitest";
import { clampPercent, makeWindow, remainingPercent, isResetPending } from "../src/models/usageWindow.js";
import { mascotStateFor, resolveMascotPressure } from "../src/presentation/mascotState.js";
import { formatCountdown, countdownUntil } from "../src/presentation/countdown.js";
import { evaluateFreshness } from "../src/presentation/freshness.js";
import {
  EMPTY_THRESHOLD_STATE, evaluateThresholds, isMajorEvent,
} from "../src/presentation/thresholds.js";
import { classifyStatus, parseRetryAfter, ProviderError } from "../src/usage/providerError.js";
import { replaceUsage, type ProviderUsage } from "../src/models/snapshot.js";

const NOW = 1_757_000_000_000;

function usage(five: number | null, weekly: number | null): ProviderUsage {
  return {
    provider: "claude",
    fiveHour: five === null ? null : makeWindow(100 - five, null, null),
    weekly: weekly === null ? null : makeWindow(100 - weekly, null, null),
    planName: null,
    fetchedAt: NOW,
  };
}

describe("percentages", () => {
  it.each([[0, 100], [36, 64], [64, 36], [100, 0]])(
    "remaining is the complement of used (%i)", (used, expected) => {
      expect(remainingPercent(makeWindow(used, null, null))).toBe(expected);
    });

  it("clamps into 0...100", () => {
    expect(clampPercent(-40)).toBe(0);
    expect(clampPercent(55.5)).toBe(55.5);
    expect(clampPercent(1000)).toBe(100);
  });

  // A naive min/max propagates NaN to the API, which then renders "nan%".
  it("collapses non-finite input to zero", () => {
    expect(clampPercent(Number.NaN)).toBe(0);
    expect(clampPercent(Number.POSITIVE_INFINITY)).toBe(0);
    expect(remainingPercent(makeWindow(Number.NaN, null, null))).toBe(100);
  });

  it("detects reset-pending only once the instant has passed", () => {
    expect(isResetPending(makeWindow(90, NOW - 1, null), NOW)).toBe(true);
    expect(isResetPending(makeWindow(90, NOW + 60_000, null), NOW)).toBe(false);
    expect(isResetPending(makeWindow(90, null, null), NOW)).toBe(false);
  });
});

describe("mascot state", () => {
  it.each([
    [100, "hyper"], [75, "hyper"], [74.9, "happy"], [50, "happy"],
    [49.9, "normal"], [30, "normal"], [29.9, "tired"], [15, "tired"],
    [14.9, "exhausted"], [1, "exhausted"], [0, "empty"],
  ])("maps %f%% remaining to %s", (remaining, expected) => {
    expect(mascotStateFor(remaining as number)).toBe(expected);
  });

  // The brief leaves 0 < r < 1 unspecified; documenting our resolution as a decision.
  it("reads a sliver of quota as exhausted, not empty", () => {
    expect(mascotStateFor(0.4)).toBe("exhausted");
  });

  it("takes pressure from the tighter window", () => {
    const p = resolveMascotPressure(usage(80, 8));
    expect(p?.state).toBe("exhausted");
    expect(p?.remainingPercent).toBe(8);
    expect(p?.constrainingWindow).toBe("weekly");
  });

  it("can be constrained by the five-hour window", () => {
    const p = resolveMascotPressure(usage(12, 78));
    expect(p?.constrainingWindow).toBe("fiveHour");
  });

  // A missing window must not read as 0% and panic the mascot.
  it("uses a single present window alone", () => {
    const p = resolveMascotPressure(usage(90, null));
    expect(p?.state).toBe("hyper");
    expect(p?.constrainingWindow).toBe("fiveHour");
  });

  it("yields no pressure without data", () => {
    expect(resolveMascotPressure(usage(null, null))).toBeNull();
    expect(resolveMascotPressure(null)).toBeNull();
  });
});

describe("countdown", () => {
  it.each([
    [2520, "42m"], [7980, "2h 13m"], [280_800, "3d 6h"],
    [3600, "1h"], [86_400, "1d"], [30, "0m"],
  ])("formats %i seconds as %s", (seconds, expected) => {
    expect(formatCountdown(seconds as number)).toBe(expected);
  });

  it("renders a past reset as 0m, never negative", () => {
    expect(countdownUntil(NOW - 500_000, NOW)).toBe("0m");
  });

  it("renders null when there is no reset time", () => {
    expect(countdownUntil(null, NOW)).toBeNull();
  });
});

describe("freshness", () => {
  it("calls a recent snapshot live", () => {
    expect(evaluateFreshness(NOW - 42_000, NOW).freshness).toBe("live");
  });

  it("calls an old snapshot stale", () => {
    const r = evaluateFreshness(NOW - 8 * 60_000, NOW);
    expect(r.freshness).toBe("stale");
    expect(Math.round(r.ageSec)).toBe(480);
  });

  it("treats the boundary as exclusive", () => {
    expect(evaluateFreshness(NOW - 120_000, NOW).freshness).toBe("live");
    expect(evaluateFreshness(NOW - 121_000, NOW).freshness).toBe("stale");
  });

  // Clock skew must not produce a negative age.
  it("clamps a future timestamp to zero age", () => {
    expect(evaluateFreshness(NOW + 300_000, NOW).ageSec).toBe(0);
  });
});

describe("threshold crossings", () => {
  it("fires once, not on every refresh", () => {
    let r = evaluateThresholds(EMPTY_THRESHOLD_STATE, 48, "fiveHour");
    expect(r.events).toEqual([{ type: "crossedBelow", threshold: 50, window: "fiveHour" }]);
    r = evaluateThresholds(r.state, 47, "fiveHour");
    expect(r.events).toEqual([]);
  });

  // Falling 60 -> 4 in one step should be one event, not four.
  it("reports only the lowest threshold crossed", () => {
    const r = evaluateThresholds(EMPTY_THRESHOLD_STATE, 4, "weekly");
    expect(r.events).toEqual([{ type: "crossedBelow", threshold: 5, window: "weekly" }]);
  });

  it("fires each new band while descending", () => {
    let state = EMPTY_THRESHOLD_STATE;
    for (const [remaining, threshold] of [[48, 50], [24, 25], [9, 10], [4, 5]] as const) {
      const r = evaluateThresholds(state, remaining, "fiveHour");
      expect(r.events).toEqual([{ type: "crossedBelow", threshold, window: "fiveHour" }]);
      state = r.state;
    }
  });

  it("detects a reset and rearms", () => {
    const depleted = evaluateThresholds(EMPTY_THRESHOLD_STATE, 4, "fiveHour");
    const recharged = evaluateThresholds(depleted.state, 100, "fiveHour");
    expect(recharged.events).toContainEqual({ type: "recharged", window: "fiveHour" });
    expect(recharged.state.lastAnnouncedThreshold).toBeNull();

    const again = evaluateThresholds(recharged.state, 48, "fiveHour");
    expect(again.events).toEqual([{ type: "crossedBelow", threshold: 50, window: "fiveHour" }]);
  });

  it("does not mistake small upward jitter for a reset", () => {
    const r = evaluateThresholds(
      { lastAnnouncedThreshold: 25, lastRemainingPercent: 20 }, 22, "weekly");
    expect(r.events.some((e) => e.type === "recharged")).toBe(false);
  });

  it("marks a weekly recharge major and a five-hour one not", () => {
    expect(isMajorEvent({ type: "recharged", window: "weekly" })).toBe(true);
    expect(isMajorEvent({ type: "recharged", window: "fiveHour" })).toBe(false);
    expect(isMajorEvent({ type: "crossedBelow", threshold: 5, window: "weekly" })).toBe(true);
  });
});

describe("errors and snapshots", () => {
  it("classifies HTTP statuses", () => {
    expect(classifyStatus(200)).toBeNull();
    expect(classifyStatus(401)?.kind).toBe("notAuthenticated");
    expect(classifyStatus(403)?.kind).toBe("tokenExpired");
    expect(classifyStatus(429, 30)?.retryAfterSec).toBe(30);
    expect(classifyStatus(503)?.kind).toBe("serverError");
  });

  it("retries only genuinely transient errors", () => {
    expect(new ProviderError("networkUnavailable", "x").isTransient).toBe(true);
    expect(new ProviderError("serverError", "x").isTransient).toBe(true);
    expect(new ProviderError("notAuthenticated", "x").isTransient).toBe(false);
    expect(new ProviderError("rateLimited", "x").isTransient).toBe(false);
    expect(new ProviderError("providerResponseChanged", "x").isTransient).toBe(false);
  });

  it("parses Retry-After in both delay-seconds and HTTP-date forms", () => {
    expect(parseRetryAfter("30", NOW)).toBe(30);
    expect(parseRetryAfter(null, NOW)).toBeNull();
    expect(parseRetryAfter("   ", NOW)).toBeNull();
    expect(parseRetryAfter("not-a-date", NOW)).toBeNull();
    expect(parseRetryAfter(new Date(NOW + 60_000).toUTCString(), NOW)).toBeCloseTo(60, 0);
  });

  it("replaces one provider while preserving the other", () => {
    const base = { claude: usage(90, 90), codex: null, generatedAt: NOW };
    const next = replaceUsage(base, { ...usage(45, 45), provider: "codex" }, NOW + 1);
    expect(next.claude?.fiveHour?.usedPercent).toBe(10);
    expect(next.codex?.fiveHour?.usedPercent).toBe(55);
  });
});
