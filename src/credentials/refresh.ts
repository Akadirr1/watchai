import { readFile, writeFile, rename, chmod } from "node:fs/promises";
import { join } from "node:path";
import type { AIProvider } from "../models/provider.js";

/**
 * Token refresh.
 *
 * Why this exists at all: both CLIs refresh **lazily**, only when a command runs. Once
 * login is done nothing invokes them again, so without this the access token would simply
 * expire and the page would sit on `auth` forever.
 *
 * Why it is safe here, when the same code would have been dangerous in the earlier
 * design: QuotaPets owns its **own grant**, obtained through the vendor's own CLI into its
 * own config directory. Refresh-token rotation therefore cannot strand anyone else's
 * copy. In the abandoned "mount the host's ~/.claude" design this would have invalidated
 * the host CLI's refresh token and broken the user's other tooling.
 *
 * This is NOT an invented login flow. The grant is created by the real CLI; this only
 * exchanges a refresh token we already hold, using the client id the CLI itself recorded.
 */

const CLAUDE_TOKEN_URL = "https://platform.claude.com/v1/oauth/token";
const CODEX_TOKEN_URL = "https://auth.openai.com/oauth/token";
const REFRESH_TIMEOUT_MS = 30_000;

/** Refresh when the token expires within this window. Matches the CLIs' own 5-minute skew. */
export const REFRESH_SKEW_MS = 5 * 60_000;

export interface RefreshOutcome {
  readonly refreshed: boolean;
  readonly reason: string;
}

function obj(v: unknown): Record<string, unknown> | null {
  return typeof v === "object" && v !== null && !Array.isArray(v)
    ? (v as Record<string, unknown>)
    : null;
}

async function postJson(url: string, body: unknown): Promise<Record<string, unknown>> {
  const response = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(REFRESH_TIMEOUT_MS),
  });
  if (!response.ok) throw new Error(`token refresh failed: HTTP ${response.status}`);
  const parsed = obj(await response.json());
  if (!parsed) throw new Error("token refresh returned a non-object body");
  return parsed;
}

/** Writes atomically (.tmp + rename) and restores 0600 — better than the CLIs' in-place write. */
async function writeSecret(path: string, value: unknown): Promise<void> {
  const tmp = `${path}.tmp`;
  await writeFile(tmp, JSON.stringify(value, null, 2), { encoding: "utf8", mode: 0o600 });
  await rename(tmp, path);
  await chmod(path, 0o600);
}

async function readJson(path: string): Promise<Record<string, unknown> | null> {
  try {
    return obj(JSON.parse(await readFile(path, "utf8")));
  } catch {
    return null;
  }
}

async function refreshClaude(configDir: string): Promise<RefreshOutcome> {
  const path = join(configDir, ".credentials.json");
  const store = await readJson(path);
  const oauth = obj(store?.["claudeAiOauth"]);
  const refreshToken = oauth?.["refreshToken"];
  if (typeof refreshToken !== "string" || refreshToken === "") {
    return { refreshed: false, reason: "no refresh token" };
  }

  const scopes = oauth?.["scopes"];
  const clientId = oauth?.["clientId"];
  const body: Record<string, unknown> = {
    grant_type: "refresh_token",
    refresh_token: refreshToken,
    // Prefer the client id the CLI recorded; fall back to the one it uses by default.
    client_id: typeof clientId === "string" ? clientId : "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
  };
  if (Array.isArray(scopes) && scopes.every((s) => typeof s === "string")) {
    body["scope"] = (scopes as string[]).join(" ");
  }

  const result = await postJson(CLAUDE_TOKEN_URL, body);
  const accessToken = result["access_token"];
  const expiresIn = result["expires_in"];
  if (typeof accessToken !== "string") throw new Error("refresh response had no access_token");

  // The response's refresh_token defaults to the one we sent when absent — rotation is
  // possible but not guaranteed, exactly as the CLI handles it.
  const nextRefresh =
    typeof result["refresh_token"] === "string" ? result["refresh_token"] : refreshToken;

  await writeSecret(path, {
    ...store,
    claudeAiOauth: {
      ...oauth,
      accessToken,
      refreshToken: nextRefresh,
      expiresAt:
        typeof expiresIn === "number" && Number.isFinite(expiresIn)
          ? Date.now() + expiresIn * 1000
          : null,
    },
  });
  return { refreshed: true, reason: "ok" };
}

async function refreshCodex(codexHome: string): Promise<RefreshOutcome> {
  const path = join(codexHome, "auth.json");
  const store = await readJson(path);
  const tokens = obj(store?.["tokens"]);
  const refreshToken = tokens?.["refresh_token"];
  if (typeof refreshToken !== "string" || refreshToken === "") {
    return { refreshed: false, reason: "no refresh token" };
  }

  const result = await postJson(CODEX_TOKEN_URL, {
    client_id: "app_EMoamEEZ73f0CkXaXp7hrann",
    grant_type: "refresh_token",
    refresh_token: refreshToken,
  });

  const accessToken = result["access_token"];
  if (typeof accessToken !== "string") throw new Error("refresh response had no access_token");

  await writeSecret(path, {
    ...store,
    tokens: {
      ...tokens,
      access_token: accessToken,
      ...(typeof result["id_token"] === "string" ? { id_token: result["id_token"] } : {}),
      ...(typeof result["refresh_token"] === "string"
        ? { refresh_token: result["refresh_token"] }
        : {}),
    },
    last_refresh: new Date().toISOString(),
  });
  return { refreshed: true, reason: "ok" };
}

export function refreshCredential(
  provider: AIProvider,
  dirs: { claude: string; codex: string },
): Promise<RefreshOutcome> {
  return provider === "claude" ? refreshClaude(dirs.claude) : refreshCodex(dirs.codex);
}
