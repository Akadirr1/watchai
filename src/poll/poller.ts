import { PROVIDERS, type AIProvider } from "../models/provider.js";
import { replaceUsage, type ProviderState, type ProviderUsage } from "../models/snapshot.js";
import { ProviderError, classifyStatus, isProviderError, parseRetryAfter } from "../usage/providerError.js";
import { decodeClaudeUsage } from "../usage/claudeMapper.js";
import { decodeCodexUsage } from "../usage/codexMapper.js";
import { claudeHeaders, codexHeaders, CLAUDE_USAGE, CODEX_USAGE, REQUEST_TIMEOUT_MS } from "../providers/endpoints.js";
import { readCredential, type Credential } from "../credentials/index.js";
import { refreshCredential, REFRESH_SKEW_MS } from "../credentials/refresh.js";
import type { SnapshotStore } from "./snapshotStore.js";

export interface ProviderStatus {
  state: ProviderState;
  lastSuccessAt: number | null;
  lastAttemptAt: number | null;
  consecutiveFailures: number;
  lastError: { kind: string; status: number | null; at: number; hint: string } | null;
  credential: {
    present: boolean;
    parseError: boolean;
    mtimeMs: number | null;
    /** Advisory only — never used for control flow. */
    expiresAt: number | null;
  };
}

function freshStatus(): ProviderStatus {
  return {
    state: "never_fetched",
    lastSuccessAt: null,
    lastAttemptAt: null,
    consecutiveFailures: 0,
    lastError: null,
    credential: { present: false, parseError: false, mtimeMs: null, expiresAt: null },
  };
}

const STATE_FOR_ERROR: Record<string, ProviderState> = {
  notAuthenticated: "auth",
  tokenExpired: "auth",
  networkUnavailable: "offline",
  rateLimited: "rate_limited",
  providerResponseChanged: "provider_error",
  serverError: "offline",
  unknown: "provider_error",
};

async function fetchUsage(provider: AIProvider, credential: Credential): Promise<ProviderUsage> {
  const url = provider === "claude" ? CLAUDE_USAGE.url : CODEX_USAGE.url;
  const headers =
    provider === "claude"
      ? claudeHeaders(credential.accessToken)
      : codexHeaders(credential.accessToken, credential.accountId);

  let response: Response;
  try {
    response = await fetch(url, { headers, signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS) });
  } catch {
    throw new ProviderError("networkUnavailable", "request failed or timed out");
  }

  const retryAfter = parseRetryAfter(response.headers.get("retry-after"), Date.now());
  const failure = classifyStatus(response.status, retryAfter);
  if (failure) {
    void response.body?.cancel();
    throw failure;
  }

  const body = await response.text();
  const at = Date.now();
  return provider === "claude" ? decodeClaudeUsage(body, at) : decodeCodexUsage(body, at);
}

/**
 * Drives both providers.
 *
 * Two independent self-rearming timeout chains rather than `setInterval`: an interval
 * drifts and, worse, stacks callbacks when a tick runs long.
 */
export class Poller {
  private readonly statuses = new Map<AIProvider, ProviderStatus>();
  private readonly inFlight = new Map<AIProvider, Promise<void>>();
  private readonly skipUntil = new Map<AIProvider, number>();
  private readonly timers = new Map<AIProvider, NodeJS.Timeout>();
  private stopped = false;

  constructor(
    private readonly store: SnapshotStore,
    private readonly dirs: { claude: string; codex: string },
    private readonly intervalMs: number,
    private readonly staggerMs: number,
  ) {
    for (const provider of PROVIDERS) this.statuses.set(provider, freshStatus());
  }

  status(provider: AIProvider): ProviderStatus {
    return this.statuses.get(provider) ?? freshStatus();
  }

  start(): void {
    for (const provider of PROVIDERS) {
      const delay = provider === "codex" ? this.staggerMs : 0;
      this.timers.set(provider, setTimeout(() => void this.loop(provider), delay));
    }
  }

  stop(): void {
    this.stopped = true;
    for (const timer of this.timers.values()) clearTimeout(timer);
    this.timers.clear();
  }

  private async loop(provider: AIProvider): Promise<void> {
    const began = Date.now();
    try {
      await this.tick(provider);
    } finally {
      if (!this.stopped) {
        const elapsed = Date.now() - began;
        const wait = Math.max(5_000, this.intervalMs - elapsed);
        this.timers.set(provider, setTimeout(() => void this.loop(provider), wait));
      }
    }
  }

  /** Concurrent callers join the in-flight request rather than starting a second one. */
  tick(provider: AIProvider): Promise<void> {
    const existing = this.inFlight.get(provider);
    if (existing) return existing;
    const run = this.runTick(provider).finally(() => this.inFlight.delete(provider));
    this.inFlight.set(provider, run);
    return run;
  }

  private async runTick(provider: AIProvider): Promise<void> {
    const status = this.statuses.get(provider)!;
    const skip = this.skipUntil.get(provider);
    if (skip && Date.now() < skip) return;

    status.lastAttemptAt = Date.now();

    // Refresh proactively when the token is near expiry. Safe because this is our own
    // grant — see credentials/refresh.ts. Failures here are non-fatal: the request still
    // fires and the server decides.
    await this.maybeRefresh(provider, status);

    const read = await readCredential(provider, this.dirs);
    status.credential = {
      present: read.present,
      parseError: read.parseError,
      mtimeMs: read.credential?.mtimeMs ?? null,
      expiresAt: read.credential?.expiresAt ?? null,
    };

    if (read.parseError) {
      // A torn read must never flip the UI to "not authenticated" — hold previous state.
      return;
    }
    if (!read.credential) {
      this.fail(status, new ProviderError("notAuthenticated", "no credential"), provider);
      return;
    }

    const usedToken = read.credential.accessToken;
    try {
      await this.attempt(provider, read.credential, status);
      return;
    } catch (error) {
      if (!isProviderError(error)) {
        this.fail(status, new ProviderError("unknown", String(error)), provider);
        return;
      }

      // On a rejected token, re-read once. A refresh may have landed between our read and
      // the request; if the token on disk has changed, the old one was simply stale and
      // the new one deserves an immediate attempt within this same tick.
      if (error.kind === "notAuthenticated" || error.kind === "tokenExpired") {
        const reread = await readCredential(provider, this.dirs);
        if (reread.credential && reread.credential.accessToken !== usedToken) {
          try {
            await this.attempt(provider, reread.credential, status);
            return;
          } catch (retryError) {
            this.fail(
              status,
              isProviderError(retryError)
                ? retryError
                : new ProviderError("unknown", String(retryError)),
              provider,
            );
            return;
          }
        }
      }

      if (error.kind === "rateLimited") {
        // Never retried. Honour the server's hint, or back off five minutes.
        const backoffSec = error.retryAfterSec ?? 300;
        this.skipUntil.set(provider, Date.now() + backoffSec * 1000);
      }
      this.fail(status, error, provider);
    }
  }

  /** One bounded retry, transient failures only. Never for auth, schema, or 429. */
  private async attempt(
    provider: AIProvider,
    credential: Credential,
    status: ProviderStatus,
  ): Promise<void> {
    let usage: ProviderUsage;
    try {
      usage = await fetchUsage(provider, credential);
    } catch (error) {
      if (isProviderError(error) && error.isTransient) {
        await new Promise((r) => setTimeout(r, 2_000));
        usage = await fetchUsage(provider, credential);
      } else {
        throw error;
      }
    }

    const now = Date.now();
    await this.store.set(replaceUsage(this.store.current(), usage, now));
    status.state = "ok";
    status.lastSuccessAt = now;
    status.consecutiveFailures = 0;
    status.lastError = null;
    this.skipUntil.delete(provider);
    console.log(`[${provider}] ok`);
  }

  private async maybeRefresh(provider: AIProvider, status: ProviderStatus): Promise<void> {
    const expiresAt = status.credential.expiresAt;
    if (expiresAt === null) return;
    if (Date.now() + REFRESH_SKEW_MS < expiresAt) return;
    try {
      const outcome = await refreshCredential(provider, this.dirs);
      if (outcome.refreshed) console.log(`[${provider}] token refreshed`);
    } catch (error) {
      console.error(`[${provider}] refresh failed: ${(error as Error).message}`);
    }
  }

  private fail(status: ProviderStatus, error: ProviderError, provider: AIProvider): void {
    status.state = STATE_FOR_ERROR[error.kind] ?? "provider_error";
    status.consecutiveFailures += 1;
    status.lastError = {
      kind: error.kind,
      status: error.status,
      at: Date.now(),
      hint: hintFor(error, status),
    };
    // Status and code only. Never the body (it carries plan_type and account shape),
    // never headers, never any part of a token.
    console.warn(`[${provider}] ${error.kind}${error.status ? ` (${error.status})` : ""}`);
  }
}

function hintFor(error: ProviderError, status: ProviderStatus): string {
  if (error.kind === "notAuthenticated" || error.kind === "tokenExpired") {
    if (!status.credential.present) return "not connected — sign in from /setup";
    const expiresAt = status.credential.expiresAt;
    if (expiresAt !== null && expiresAt < Date.now()) {
      return "token expired and could not be refreshed — reconnect from /setup";
    }
    return "token rejected — it may have been revoked; reconnect from /setup";
  }
  if (error.kind === "rateLimited") return "rate limited by the provider — backing off";
  if (error.kind === "providerResponseChanged") {
    return "the provider's response shape changed — the adapter needs updating";
  }
  return error.message;
}
