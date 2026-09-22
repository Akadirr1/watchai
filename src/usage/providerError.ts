/**
 * Provider error taxonomy.
 *
 * `providerResponseChanged` is the important one: both usage endpoints are private and
 * unversioned, so a schema change is an expected operating condition, not a crash. It is
 * raised whenever a payload parses as JSON but does not carry the fields we require.
 */
export type ProviderErrorKind =
  | "notAuthenticated"
  | "tokenExpired"
  | "networkUnavailable"
  | "rateLimited"
  | "providerResponseChanged"
  | "serverError"
  | "unknown";

export class ProviderError extends Error {
  readonly kind: ProviderErrorKind;
  readonly status: number | null;
  /** Seconds, from the server's Retry-After, when it sent one. */
  readonly retryAfterSec: number | null;

  constructor(
    kind: ProviderErrorKind,
    message: string,
    opts: { status?: number | null; retryAfterSec?: number | null } = {},
  ) {
    super(message);
    this.name = "ProviderError";
    this.kind = kind;
    this.status = opts.status ?? null;
    this.retryAfterSec = opts.retryAfterSec ?? null;
  }

  /**
   * Whether a bounded retry is worth attempting. Auth and schema failures are not
   * retryable — retrying them burns battery and quota to fail identically. `rateLimited`
   * is deliberately NOT transient: retrying a 429 actively makes things worse.
   */
  get isTransient(): boolean {
    return this.kind === "networkUnavailable" || this.kind === "serverError";
  }
}

export function isProviderError(e: unknown): e is ProviderError {
  return e instanceof ProviderError;
}

/** Maps an HTTP status to the error model, or null when the response is a success. */
export function classifyStatus(
  status: number,
  retryAfterSec: number | null = null,
): ProviderError | null {
  if (status >= 200 && status <= 299) return null;
  if (status === 401) return new ProviderError("notAuthenticated", "Not authenticated", { status });
  if (status === 403) return new ProviderError("tokenExpired", "Token rejected", { status });
  if (status === 429)
    return new ProviderError("rateLimited", "Rate limited", { status, retryAfterSec });
  if (status >= 500 && status <= 599)
    return new ProviderError("serverError", `Server error ${status}`, { status });
  return new ProviderError("unknown", `HTTP ${status}`, { status });
}

/**
 * RFC 9110 allows Retry-After to be either delay-seconds or an HTTP-date. Ignoring the
 * date form silently loses the hint on servers that use it.
 */
export function parseRetryAfter(header: string | null | undefined, now: number): number | null {
  if (!header) return null;
  const trimmed = header.trim();
  if (trimmed === "") return null;

  const asNumber = Number(trimmed);
  if (Number.isFinite(asNumber) && asNumber >= 0) return asNumber;

  const asDate = Date.parse(trimmed);
  if (Number.isNaN(asDate)) return null;
  return Math.max(0, (asDate - now) / 1000);
}
