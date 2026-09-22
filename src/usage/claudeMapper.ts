import { CANONICAL_MINUTES } from "../models/provider.js";
import { makeWindow, type UsageWindow } from "../models/usageWindow.js";
import { isEmptyUsage, type ProviderUsage } from "../models/snapshot.js";
import { ProviderError } from "./providerError.js";
import { claudeResetAt } from "./claudeResetTimestamp.js";

function obj(value: unknown): Record<string, unknown> | null {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

function finiteNumber(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

/**
 * `utilization` wins, `used_percentage` is the fallback.
 *
 * Ported from Orca `claude-usage-window.ts:61-66`. **This precedence is load-bearing:**
 * the original brief assumed the field was called `used_percent`, which Claude never
 * sends — decoding only that name yields no Claude data at all.
 */
export function resolveClaudeUsedPercent(raw: Record<string, unknown>): number | null {
  const utilization = finiteNumber(raw["utilization"]);
  if (utilization !== null) return utilization;
  return finiteNumber(raw["used_percentage"]);
}

function mapWindow(raw: unknown, kind: keyof typeof CANONICAL_MINUTES): UsageWindow | null {
  const window = obj(raw);
  if (!window) return null;
  const used = resolveClaudeUsedPercent(window);
  if (used === null) return null;
  // Claude never reports a duration, so the canonical length is always used.
  return makeWindow(used, claudeResetAt(window["resets_at"]), CANONICAL_MINUTES[kind] * 60);
}

/** `five_hour` → fiveHour, `seven_day` → weekly. */
export function mapClaudeUsage(
  payload: unknown,
  fetchedAt: number,
  planName: string | null = null,
): ProviderUsage {
  const root = obj(payload) ?? {};
  return {
    provider: "claude",
    fiveHour: mapWindow(root["five_hour"], "fiveHour"),
    weekly: mapWindow(root["seven_day"], "weekly"),
    planName,
    fetchedAt,
  };
}

/**
 * Decodes a response body, converting any failure into `providerResponseChanged` rather
 * than letting an opaque parse error escape.
 */
export function decodeClaudeUsage(
  body: string,
  fetchedAt: number,
  planName: string | null = null,
): ProviderUsage {
  let parsed: unknown;
  try {
    parsed = JSON.parse(body);
  } catch {
    throw new ProviderError(
      "providerResponseChanged",
      "Claude usage payload did not decode",
    );
  }
  const usage = mapClaudeUsage(parsed, fetchedAt, planName);
  // A payload that decodes but yields no window at all means the schema moved under us.
  if (isEmptyUsage(usage)) {
    throw new ProviderError(
      "providerResponseChanged",
      "Claude usage payload contained no recognised window",
    );
  }
  return usage;
}
