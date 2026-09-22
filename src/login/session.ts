import type { AIProvider } from "../models/provider.js";

export type LoginPhase = "idle" | "waiting" | "completed" | "failed" | "expired";

export interface LoginSession {
  provider: AIProvider;
  phase: LoginPhase;
  /** The URL the user opens in a browser. Never contains a token. */
  url: string | null;
  /** Codex device flow only: the code the user types on the verification page. */
  userCode: string | null;
  /** True when the provider expects the user to paste a code back (Claude). */
  needsCodePaste: boolean;
  error: string | null;
  startedAt: number;
}

export function idleSession(provider: AIProvider): LoginSession {
  return {
    provider,
    phase: "idle",
    url: null,
    userCode: null,
    needsCodePaste: provider === "claude",
    error: null,
    startedAt: 0,
  };
}

/** Login flows are abandoned after this long rather than holding a child process forever. */
export const LOGIN_TIMEOUT_MS = 15 * 60_000;
