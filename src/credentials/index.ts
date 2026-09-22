import { readFile, stat } from "node:fs/promises";
import { join } from "node:path";
import type { AIProvider } from "../models/provider.js";

export interface Credential {
  readonly accessToken: string;
  readonly accountId: string | null;
  /** Advisory only — never used for control flow. See `expiresAt` note below. */
  readonly expiresAt: number | null;
  readonly mtimeMs: number;
}

export interface CredentialRead {
  readonly credential: Credential | null;
  readonly present: boolean;
  readonly parseError: boolean;
  readonly path: string;
}

/**
 * Reads a credential file written by the vendor CLI.
 *
 * Deliberate choices, both learned from reading the CLIs' own source:
 *
 * - **Re-read every time; never cache the token.** The CLI refreshes lazily and rewrites
 *   the file; re-reading means we pick that up on the next tick with no extra machinery.
 * - **Torn reads are real.** Both CLIs truncate-and-rewrite in place with no temp+rename,
 *   so a read landing mid-write returns valid-UTF-8 broken JSON. We retry twice before
 *   reporting a parse error, and a transient parse failure must never flip the UI to
 *   "not authenticated".
 */
async function readJsonWithRetry(path: string): Promise<{ data: unknown; mtimeMs: number } | "missing" | "corrupt"> {
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      const [raw, info] = await Promise.all([readFile(path, "utf8"), stat(path)]);
      try {
        return { data: JSON.parse(raw), mtimeMs: info.mtimeMs };
      } catch {
        if (attempt === 2) return "corrupt";
        await new Promise((r) => setTimeout(r, 50));
      }
    } catch {
      return "missing";
    }
  }
  return "corrupt";
}

function obj(value: unknown): Record<string, unknown> | null {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

function str(value: unknown): string | null {
  return typeof value === "string" && value !== "" ? value : null;
}

/**
 * Decodes a JWT's `exp` claim without verifying the signature — we are reading metadata,
 * not validating a token. Codex stores no expiry field, so this is the only source.
 */
export function jwtExpiryMs(token: string | null): number | null {
  if (!token) return null;
  const parts = token.split(".");
  if (parts.length !== 3) return null;
  try {
    const payload = JSON.parse(Buffer.from(parts[1]!, "base64url").toString("utf8")) as unknown;
    const exp = obj(payload)?.["exp"];
    return typeof exp === "number" && Number.isFinite(exp) ? exp * 1000 : null;
  } catch {
    return null;
  }
}

/** `$CLAUDE_CONFIG_DIR/.credentials.json` → `{ claudeAiOauth: { accessToken, expiresAt, ... } }` */
export async function readClaudeCredential(configDir: string): Promise<CredentialRead> {
  const path = join(configDir, ".credentials.json");
  const result = await readJsonWithRetry(path);
  if (result === "missing") return { credential: null, present: false, parseError: false, path };
  if (result === "corrupt") return { credential: null, present: true, parseError: true, path };

  const oauth = obj(obj(result.data)?.["claudeAiOauth"]);
  const accessToken = str(oauth?.["accessToken"]);
  if (!accessToken) return { credential: null, present: true, parseError: false, path };

  const expiresAt = oauth?.["expiresAt"];
  return {
    credential: {
      accessToken,
      accountId: null,
      // Claude stores expiresAt as absolute epoch MILLISECONDS.
      expiresAt: typeof expiresAt === "number" && Number.isFinite(expiresAt) ? expiresAt : null,
      mtimeMs: result.mtimeMs,
    },
    present: true,
    parseError: false,
    path,
  };
}

/** `$CODEX_HOME/auth.json` → `{ tokens: { access_token, account_id } }`, no expiry field. */
export async function readCodexCredential(codexHome: string): Promise<CredentialRead> {
  const path = join(codexHome, "auth.json");
  const result = await readJsonWithRetry(path);
  if (result === "missing") return { credential: null, present: false, parseError: false, path };
  if (result === "corrupt") return { credential: null, present: true, parseError: true, path };

  const tokens = obj(obj(result.data)?.["tokens"]);
  const accessToken = str(tokens?.["access_token"]);
  if (!accessToken) return { credential: null, present: true, parseError: false, path };

  return {
    credential: {
      accessToken,
      accountId: str(tokens?.["account_id"]),
      // Codex stores no expiry; it is only derivable from the access token's JWT.
      expiresAt: jwtExpiryMs(accessToken),
      mtimeMs: result.mtimeMs,
    },
    present: true,
    parseError: false,
    path,
  };
}

export function readCredential(
  provider: AIProvider,
  dirs: { claude: string; codex: string },
): Promise<CredentialRead> {
  return provider === "claude"
    ? readClaudeCredential(dirs.claude)
    : readCodexCredential(dirs.codex);
}
