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

export function createAuthGuard(expectedToken: string) {
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

  return {
    matches,
    /** Returns true when the request may proceed; otherwise it has already been answered. */
    async guard(request: FastifyRequest, reply: FastifyReply): Promise<boolean> {
      const ip = request.ip;
      if (limiter.blocked(ip)) {
        await reply.code(429).send({ error: "too_many_attempts" });
        return false;
      }
      if (matches(presentedToken(request))) return true;

      limiter.record(ip);
      // Never distinguish "absent" from "wrong" — that is a probing oracle.
      await reply
        .code(401)
        .header("WWW-Authenticate", "Bearer")
        .send({ error: "unauthorized" });
      return false;
    },
  };
}
