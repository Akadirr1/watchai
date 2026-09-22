/**
 * Every provider-specific constant lives here and nowhere else.
 *
 * Two reasons this file is isolated:
 *
 * 1. `anthropic-beta` and both User-Agents are dated, version-bearing values that WILL
 *    rot. When a provider changes, this is the only edit.
 * 2. It is the mechanical basis of the "QuotaPets never runs prompts" guarantee. A test
 *    asserts that the set of hostnames reachable from src/ is exactly the list below and
 *    that no source file mentions an inference endpoint.
 *
 * Complete inventory of external hosts QuotaPets can reach:
 *   api.anthropic.com    — Claude usage
 *   chatgpt.com          — Codex usage
 *   platform.claude.com  — Claude login/refresh (performed by the CLI, not by us)
 *   auth.openai.com      — Codex login/refresh (performed by the CLI, not by us)
 */

export const REQUEST_TIMEOUT_MS = 10_000;

export const CLAUDE_USAGE = {
  url: "https://api.anthropic.com/api/oauth/usage",
  betaHeader: "oauth-2025-04-20",
  userAgent: "claude-code/2.1.0",
} as const;

export const CODEX_USAGE = {
  url: "https://chatgpt.com/backend-api/wham/usage",
  userAgent: "codex-cli",
  betaHeader: "codex-1",
  originator: "Codex Desktop",
} as const;

export function claudeHeaders(accessToken: string): Record<string, string> {
  return {
    Authorization: `Bearer ${accessToken}`,
    "anthropic-beta": CLAUDE_USAGE.betaHeader,
    "User-Agent": CLAUDE_USAGE.userAgent,
  };
}

export function codexHeaders(
  accessToken: string,
  accountId: string | null,
): Record<string, string> {
  const headers: Record<string, string> = {
    Authorization: `Bearer ${accessToken}`,
    "User-Agent": CODEX_USAGE.userAgent,
    "OpenAI-Beta": CODEX_USAGE.betaHeader,
    originator: CODEX_USAGE.originator,
  };
  // Orca sends this only when the auth file carried one — never an empty header.
  if (accountId && accountId !== "") headers["ChatGPT-Account-Id"] = accountId;
  return headers;
}
