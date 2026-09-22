import { CANONICAL_MINUTES, type UsageWindowKind } from "../models/provider.js";
import { makeWindow, type UsageWindow } from "../models/usageWindow.js";
import type { ProviderUsage } from "../models/snapshot.js";
import { ProviderError } from "./providerError.js";
import { codexResetAt } from "./codexResetTimestamp.js";
import { classifyCodexWindows, type CodexWindowPayload } from "./codexWindowClassifier.js";

function obj(value: unknown): Record<string, unknown> | null {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

function finiteNumber(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

/** Ported from Orca `codex-backend-usage-client.ts:39-45`: ceil(seconds / 60), positive only. */
export function parseCodexWindow(raw: unknown): CodexWindowPayload | null {
  const window = obj(raw);
  if (!window) return null;
  const seconds = finiteNumber(window["limit_window_seconds"]);
  return {
    usedPercent: finiteNumber(window["used_percent"]),
    durationMinutes: seconds !== null && seconds > 0 ? Math.ceil(seconds / 60) : null,
    resetAtRaw: window["reset_at"],
  };
}

function toWindow(raw: CodexWindowPayload | null, fallback: UsageWindowKind): UsageWindow | null {
  if (!raw || raw.usedPercent === null) return null;
  // Prefer the server's own duration; fall back to the canonical length only when it did
  // not give us a usable one.
  const minutes = raw.durationMinutes ?? CANONICAL_MINUTES[fallback];
  return makeWindow(raw.usedPercent, codexResetAt(raw.resetAtRaw), minutes * 60);
}

export function mapCodexUsage(payload: unknown, fetchedAt: number): ProviderUsage {
  const root = obj(payload) ?? {};
  const rateLimit = obj(root["rate_limit"]) ?? {};
  const classified = classifyCodexWindows(
    parseCodexWindow(rateLimit["primary_window"]),
    parseCodexWindow(rateLimit["secondary_window"]),
  );
  const planType = root["plan_type"];
  return {
    provider: "codex",
    fiveHour: toWindow(classified.fiveHour, "fiveHour"),
    weekly: toWindow(classified.weekly, "weekly"),
    planName: typeof planType === "string" ? planType : null,
    fetchedAt,
  };
}

export function decodeCodexUsage(body: string, fetchedAt: number): ProviderUsage {
  let parsed: unknown;
  try {
    parsed = JSON.parse(body);
  } catch {
    throw new ProviderError("providerResponseChanged", "Codex usage payload did not decode");
  }
  // Orca's cheap sanity check (`codex-backend-usage-client.ts:74-76`): a missing
  // `plan_type` means we were handed something that is not the usage payload —
  // typically an HTML error page or a login redirect.
  const root = obj(parsed) ?? {};
  if (typeof root["plan_type"] !== "string") {
    throw new ProviderError("providerResponseChanged", "Codex usage payload missing plan_type");
  }
  return mapCodexUsage(parsed, fetchedAt);
}
