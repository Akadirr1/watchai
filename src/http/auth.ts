import { createHash, timingSafeEqual } from "node:crypto";
import type { FastifyReply, FastifyRequest } from "fastify";

export const COOKIE_NAME = "qp_auth";

/**
 * Constant-time comparison, hashing both sides first.
 *
 * Hashing is the load-bearing detail: `timingSafeEqual` THROWS on differing buffer
 * lengths, so comparing raw strings both crashes on short input and leaks length.
 * Equal-length digests remove both problems.
 */
export function makeTokenMatcher(expected: string): (given: string | undefined) => boolean {
  const digest = createHash("sha256").update(expected, "utf8").digest();
  return (given) => {
    if (!given) return false;
    return timingSafeEqual(createHash("sha256").update(given, "utf8").digest(), digest);
  };
}

/** In-memory failure counter. The subdomain is public and will be scanned. */
class FailureLimiter {
  private readonly hits = new Map<string, { count: number; windowStart: number }>();
  private static readonly WINDOW_MS = 60_000;
  private static readonly MAX = 10;

  blocked(ip: string): boolean {
    const entry = this.hits.get(ip);
    if (!entry) return false;
    if (Date.now() - entry.windowStart > FailureLimiter.WINDOW_MS) {
      this.hits.delete(ip);
      return false;
    }
    return entry.count >= FailureLimiter.MAX;
  }

  record(ip: string): void {
    const entry = this.hits.get(ip);
    if (!entry || Date.now() - entry.windowStart > FailureLimiter.WINDOW_MS) {
      this.hits.set(ip, { count: 1, windowStart: Date.now() });
      return;
    }
    entry.count += 1;
  }
}

export interface AuthGuardOptions {
  /** Returns true when the presented token belongs to a paired device. */
  readonly verifyDeviceToken?: (token: string) => boolean;
}

export function createAuthGuard(expectedToken: string, options: AuthGuardOptions = {}) {
  const matches = makeTokenMatcher(expectedToken);
  const limiter = new FailureLimiter();

  function presentedToken(request: FastifyRequest): string | undefined {
    const header = request.headers.authorization;
    if (typeof header === "string" && header.startsWith("Bearer ")) return header.slice(7);
    const custom = request.headers["x-auth-token"];
    if (typeof custom === "string") return custom;
    const cookies = (request as FastifyRequest & { cookies?: Record<string, string> }).cookies;
    return cookies?.[COOKIE_NAME];
  }

  async function reject(request: FastifyRequest, reply: FastifyReply): Promise<false> {
    limiter.record(request.ip);
    // Never distinguish "absent" from "wrong" — that is a probing oracle.
    await reply.code(401).header("WWW-Authenticate", "Bearer").send({ error: "unauthorized" });
    return false;
  }

  async function overLimit(request: FastifyRequest, reply: FastifyReply): Promise<boolean> {
    if (!limiter.blocked(request.ip)) return false;
    await reply.code(429).send({ error: "too_many_attempts" });
    return true;
  }

  return {
    matches,

    /**
     * Admin only. Gates /setup, pairing and device management — anything that could
     * mint or revoke access.
     */
    async guardAdmin(request: FastifyRequest, reply: FastifyReply): Promise<boolean> {
      if (await overLimit(request, reply)) return false;
      if (matches(presentedToken(request))) return true;
      return reject(request, reply);
    },

    /**
     * Admin token OR a paired device token. Gates the read-only usage surface, which is
     * all a watch ever needs — so a lost watch is one revoked device, not a rotated
     * admin credential.
     */
    async guardRead(request: FastifyRequest, reply: FastifyReply): Promise<boolean> {
      if (await overLimit(request, reply)) return false;
      const token = presentedToken(request);
      if (matches(token)) return true;
      if (token && options.verifyDeviceToken?.(token)) return true;
      return reject(request, reply);
    },
  };
}
