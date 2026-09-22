import { describe, expect, it } from "vitest";
import { decodeCodexUsage, parseCodexWindow } from "../src/usage/codexMapper.js";
import { codexResetAt } from "../src/usage/codexResetTimestamp.js";
import { ProviderError } from "../src/usage/providerError.js";

const AT = 1_757_000_000_000;
const FIVE_HOUR = `{"used_percent":12,"limit_window_seconds":18000,"reset_at":1757010000}`;
const WEEKLY = `{"used_percent":47,"limit_window_seconds":604800,"reset_at":1757300000}`;

function payload(primary: string | null, secondary: string | null, plan: string | null = "plus") {
  const windows = [
    primary ? `"primary_window":${primary}` : null,
    secondary ? `"secondary_window":${secondary}` : null,
  ].filter(Boolean).join(",");
  const parts = [plan ? `"plan_type":"${plan}"` : null, `"rate_limit":{${windows}}`]
    .filter(Boolean).join(",");
  return `{${parts}}`;
}

describe("Codex window classification", () => {
  it("classifies the conventional order", () => {
    const usage = decodeCodexUsage(payload(FIVE_HOUR, WEEKLY), AT);
    expect(usage.fiveHour?.usedPercent).toBe(12);
    expect(usage.weekly?.usedPercent).toBe(47);
  });

  // The case the brief warns about: trusting position swaps these two.
  it("classifies by duration even when primary is the weekly window", () => {
    const usage = decodeCodexUsage(payload(WEEKLY, FIVE_HOUR), AT);
    expect(usage.fiveHour?.usedPercent).toBe(12);
    expect(usage.weekly?.usedPercent).toBe(47);
  });

  it("honours the one-minute drift tolerance", () => {
    const usage = decodeCodexUsage(payload(
      `{"used_percent":5,"limit_window_seconds":17940}`,   // 299 min
      `{"used_percent":6,"limit_window_seconds":604860}`), // 10081 min
      AT);
    expect(usage.fiveHour?.usedPercent).toBe(5);
    expect(usage.weekly?.usedPercent).toBe(6);
  });

  it("does not absorb a duration well outside tolerance into a canonical bucket", () => {
    const usage = decodeCodexUsage(payload(
      `{"used_percent":9,"limit_window_seconds":3600}`, WEEKLY), AT); // 60 min
    expect(usage.fiveHour?.usedPercent).toBe(9);   // positional fallback
    expect(usage.weekly?.usedPercent).toBe(47);    // classified by duration
  });

  it("falls back to the positional mapping when durations are missing", () => {
    const usage = decodeCodexUsage(payload(
      `{"used_percent":21}`, `{"used_percent":33}`), AT);
    expect(usage.fiveHour?.usedPercent).toBe(21);
    expect(usage.weekly?.usedPercent).toBe(33);
  });

  // The highest-value test: encodes the narrow-fallback rule.
  it("never reuses a classified weekly window as the five-hour window", () => {
    const usage = decodeCodexUsage(payload(WEEKLY, null), AT);
    expect(usage.weekly?.usedPercent).toBe(47);
    expect(usage.fiveHour).toBeNull();
  });

  it("handles a single window", () => {
    const usage = decodeCodexUsage(payload(FIVE_HOUR, null), AT);
    expect(usage.fiveHour?.usedPercent).toBe(12);
    expect(usage.weekly).toBeNull();
  });

  it("discards a window without a usable percentage before the fallback runs", () => {
    const usage = decodeCodexUsage(payload(
      `{"limit_window_seconds":18000}`, WEEKLY), AT);
    expect(usage.fiveHour).toBeNull();
    expect(usage.weekly?.usedPercent).toBe(47);
  });

  it("treats a zero or negative duration as absent", () => {
    expect(parseCodexWindow({ used_percent: 1, limit_window_seconds: 0 })?.durationMinutes).toBeNull();
    expect(parseCodexWindow({ used_percent: 1, limit_window_seconds: -60 })?.durationMinutes).toBeNull();
  });
});

describe("Codex payload handling", () => {
  it("surfaces plan_type as planName", () => {
    expect(decodeCodexUsage(payload(FIVE_HOUR, WEEKLY, "pro"), AT).planName).toBe("pro");
  });

  // Orca's cheap guard against being handed a login redirect or error page.
  it("rejects a payload missing plan_type as a schema change", () => {
    expect(() => decodeCodexUsage(payload(FIVE_HOUR, WEEKLY, null), AT)).toThrow(ProviderError);
  });

  it("turns malformed JSON into providerResponseChanged", () => {
    expect(() => decodeCodexUsage("}{", AT)).toThrow(ProviderError);
  });

  it("reads reset_at as Unix seconds", () => {
    const usage = decodeCodexUsage(payload(FIVE_HOUR, null), AT);
    expect(usage.fiveHour?.resetAt).toBe(1_757_010_000_000);
  });

  // Guards the divergence: a value above Claude's 1e10 boundary must NOT be
  // reinterpreted as milliseconds here.
  it("does not reinterpret a large reset_at with Claude's heuristic", () => {
    expect(codexResetAt(20_000_000_000)).toBe(20_000_000_000_000);
  });

  it("returns null for non-positive and non-finite reset_at", () => {
    for (const bad of [0, -1, Number.NaN, null, undefined, "1757010000"]) {
      expect(codexResetAt(bad)).toBeNull();
    }
  });

  it("clamps out-of-range used_percent", () => {
    const usage = decodeCodexUsage(payload(
      `{"used_percent":300,"limit_window_seconds":18000}`, null), AT);
    expect(usage.fiveHour?.usedPercent).toBe(100);
  });
});
