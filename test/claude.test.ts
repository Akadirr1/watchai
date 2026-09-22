import { describe, expect, it } from "vitest";
import { decodeClaudeUsage, mapClaudeUsage } from "../src/usage/claudeMapper.js";
import { claudeResetAt, claudeResetFromNumber } from "../src/usage/claudeResetTimestamp.js";
import { ProviderError } from "../src/usage/providerError.js";
import { remainingPercent } from "../src/models/usageWindow.js";

// Fixtures are hand-written from the schema in docs/provider-research.md.
// No real credential or captured live response appears anywhere in this suite.
const AT = 1_757_000_000_000;

describe("Claude usage mapping", () => {
  it("maps five_hour and seven_day to fiveHour and weekly", () => {
    const usage = decodeClaudeUsage(
      `{"five_hour":{"utilization":64},"seven_day":{"utilization":31}}`, AT);
    expect(usage.provider).toBe("claude");
    expect(usage.fiveHour?.usedPercent).toBe(64);
    expect(usage.weekly?.usedPercent).toBe(31);
    // remaining is always derived, never stored
    expect(remainingPercent(usage.fiveHour!)).toBe(36);
    expect(remainingPercent(usage.weekly!)).toBe(69);
  });

  // The regression that motivated this file.
  it("prefers utilization over used_percentage", () => {
    const usage = decodeClaudeUsage(`{"five_hour":{"utilization":80,"used_percentage":20}}`, AT);
    expect(usage.fiveHour?.usedPercent).toBe(80);
  });

  it("falls back to used_percentage when utilization is absent", () => {
    const usage = decodeClaudeUsage(`{"five_hour":{"used_percentage":42}}`, AT);
    expect(usage.fiveHour?.usedPercent).toBe(42);
  });

  // Documents the trap rather than hiding it: this field name is not real for Claude.
  it("yields no window for the brief's assumed used_percent field", () => {
    expect(() => decodeClaudeUsage(`{"five_hour":{"used_percent":42}}`, AT))
      .toThrow(ProviderError);
  });

  it("keeps one window when the other is missing", () => {
    const usage = decodeClaudeUsage(`{"five_hour":{"utilization":10}}`, AT);
    expect(usage.fiveHour).not.toBeNull();
    expect(usage.weekly).toBeNull();
  });

  it("represents 0 and 100 exactly", () => {
    const usage = decodeClaudeUsage(
      `{"five_hour":{"utilization":0},"seven_day":{"utilization":100}}`, AT);
    expect(remainingPercent(usage.fiveHour!)).toBe(100);
    expect(remainingPercent(usage.weekly!)).toBe(0);
  });

  it("clamps out-of-range percentages", () => {
    const usage = decodeClaudeUsage(
      `{"five_hour":{"utilization":142.7},"seven_day":{"utilization":-8}}`, AT);
    expect(usage.fiveHour?.usedPercent).toBe(100);
    expect(usage.weekly?.usedPercent).toBe(0);
  });

  it("turns malformed JSON into providerResponseChanged", () => {
    expect(() => decodeClaudeUsage("{not json", AT)).toThrow(ProviderError);
  });

  it("turns an HTML error page into providerResponseChanged", () => {
    expect(() => decodeClaudeUsage("<html><body>502</body></html>", AT)).toThrow(ProviderError);
  });

  it("treats a decodable payload with no recognised window as a schema change", () => {
    expect(() => decodeClaudeUsage(`{"something_new":{}}`, AT)).toThrow(ProviderError);
  });

  it("never throws from the pure mapper, even on junk", () => {
    expect(mapClaudeUsage(null, AT).fiveHour).toBeNull();
    expect(mapClaudeUsage(42, AT).weekly).toBeNull();
    expect(mapClaudeUsage([1, 2], AT).fiveHour).toBeNull();
  });
});

describe("Claude reset timestamp", () => {
  it("scales seconds", () => {
    expect(claudeResetFromNumber(1_757_000_000)).toBe(1_757_000_000_000);
  });

  it("detects milliseconds and does not rescale", () => {
    expect(claudeResetFromNumber(1_757_000_000_000)).toBe(1_757_000_000_000);
  });

  // Orca uses a strict `>`, so exactly 1e10 falls to the seconds branch. Pinning it keeps
  // a future refactor from silently flipping the boundary.
  it("treats exactly 1e10 as seconds", () => {
    expect(claudeResetFromNumber(10_000_000_000)).toBe(10_000_000_000_000);
  });

  it("treats just above the boundary as milliseconds", () => {
    expect(claudeResetFromNumber(10_000_000_001)).toBe(10_000_000_001);
  });

  it("parses ISO-8601 with and without fractional seconds", () => {
    expect(claudeResetAt("2026-09-08T20:00:00Z")).not.toBeNull();
    expect(claudeResetAt("2026-09-08T20:00:00.512Z")).not.toBeNull();
  });

  it("treats numeric strings as epochs", () => {
    expect(claudeResetAt("1757000000")).toBe(1_757_000_000_000);
  });

  it("returns null for junk rather than a bogus date", () => {
    for (const junk of ["tomorrow", "   ", "", null, undefined, {}, []]) {
      expect(claudeResetAt(junk)).toBeNull();
    }
    expect(claudeResetFromNumber(Number.NaN)).toBeNull();
    expect(claudeResetFromNumber(Number.POSITIVE_INFINITY)).toBeNull();
  });

  it("decodes a reset date end to end", () => {
    const usage = decodeClaudeUsage(
      `{"five_hour":{"utilization":50,"resets_at":"2026-09-08T20:00:00Z"}}`, AT);
    expect(usage.fiveHour?.resetAt).not.toBeNull();
  });
});
