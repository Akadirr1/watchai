import Fastify, { type FastifyInstance, type FastifyRequest } from "fastify";
import cookie from "@fastify/cookie";
import { PROVIDERS, type AIProvider } from "../models/provider.js";
import { remainingPercent } from "../models/usageWindow.js";
import { usageFor, type ProviderUsage } from "../models/snapshot.js";
import { evaluateFreshness } from "../presentation/freshness.js";
import { countdownUntil } from "../presentation/countdown.js";
import { resolveMascotPressure } from "../presentation/mascotState.js";
import type { Poller } from "../poll/poller.js";
import type { SnapshotStore } from "../poll/snapshotStore.js";
import type { LoginManager } from "../login/manager.js";
import { createAuthGuard, COOKIE_NAME } from "./auth.js";
import type { PairingStore } from "../pair/index.js";
import { PAIR_RESULT_PAGE } from "./pairPage.js";
import { publicOrigin, pairingURL, renderPairingQR } from "../pair/qr.js";
import { SETUP_PAGE } from "./setupPage.js";
import { LOGIN_PAGE } from "./loginPage.js";
import { missingCLIHint } from "../login/availability.js";

const STARTED_AT = Date.now();

function isProvider(value: string): value is AIProvider {
  return (PROVIDERS as readonly string[]).includes(value);
}

function serialiseWindow(window: ProviderUsage["fiveHour"], now: number) {
  if (!window) return null;
  return {
    usedPercent: Math.round(window.usedPercent * 10) / 10,
    remainingPercent: Math.round(remainingPercent(window) * 10) / 10,
    resetAt: window.resetAt === null ? null : new Date(window.resetAt).toISOString(),
    resetIn: countdownUntil(window.resetAt, now),
    durationSec: window.durationSec,
  };
}

/**
 * Where to send someone once they have signed in.
 *
 * Same-site paths only. `//evil.com` and `/\evil.com` are both absolute to a browser, so
 * an open redirect is exactly one missing check away. It matters here because the QR
 * flow's natural landing page is `/pair?c=CODE`, which a signed-out phone has to be
 * returned to.
 */
export function safeNext(raw: unknown, fallback = "/setup"): string {
  if (typeof raw !== "string" || raw.length > 512) return fallback;
  if (!/^\/[^/\\]/.test(raw)) return fallback;
  if (/[\u0000-\u001f\u007f]/.test(raw)) return fallback;
  return raw;
}

/**
 * `secure` was hard-coded true, which meant a browser silently dropped the cookie over
 * plain HTTP and signing in locally was impossible. `trustProxy` is on, so behind a TLS
 * terminator this still reads https.
 */
function sessionCookie(request: FastifyRequest) {
  return {
    path: "/",
    httpOnly: true,
    sameSite: "lax" as const,
    secure: request.protocol === "https",
    maxAge: 31_536_000,
  };
}

export interface ServerDeps {
  store: SnapshotStore;
  poller: Poller;
  logins: LoginManager;
  pairing: PairingStore;
  authToken: string;
}

export function buildServer(deps: ServerDeps): FastifyInstance {
  const app = Fastify({ logger: false, trustProxy: true });
  const auth = createAuthGuard(deps.authToken, {
    verifyDeviceToken: (token) => deps.pairing.verifyDeviceToken(token, Date.now()),
  });
  void app.register(cookie);

  app.addHook("onSend", async (_request, reply, payload) => {
    void reply.header("Cache-Control", "no-store");
    void reply.header("Referrer-Policy", "no-referrer");
    void reply.header("X-Robots-Tag", "noindex, nofollow");
    void reply.header("X-Content-Type-Options", "nosniff");
    return payload;
  });

  /**
   * Liveness only — deliberately says nothing about provider health.
   *
   * If this reflected provider state, an Anthropic outage or an expired token would make
   * Docker mark the container unhealthy and Coolify restart it, repeatedly, while the app
   * is working perfectly.
   */
  app.get("/healthz", async (_request, reply) => {
    return reply.type("text/plain").send("ok");
  });

  app.get("/robots.txt", async (_request, reply) =>
    reply.type("text/plain").send("User-agent: *\nDisallow: /\n"),
  );

  app.get("/setup", async (request, reply) => {
    // A token in the query is accepted once, swapped for a cookie, and stripped from the
    // URL so it does not linger in history or a Referer.
    const supplied = (request.query as Record<string, string> | undefined)?.["t"];
    if (supplied && auth.matches(supplied)) {
      return reply
        .setCookie(COOKIE_NAME, supplied, sessionCookie(request))
        .redirect("/setup", 302);
    }
    // A browser gets the sign-in form rather than a JSON body it cannot act on.
    const ok = await auth.guardAdminPage(request, reply, (reason) => LOGIN_PAGE("/setup", reason));
    if (!ok) return reply;
    return reply.type("text/html; charset=utf-8").send(SETUP_PAGE);
  });

  /**
   * What the sign-in form posts to. The token is swapped for the same cookie `?t=` sets,
   * so there is one session mechanism, not two — and it never lands in the URL bar, in
   * history, or in a Referer.
   */
  app.post<{ Body: { token?: unknown } }>("/api/session", async (request, reply) => {
    const token = (request.body ?? {}).token;
    if (!(await auth.signIn(request, reply, token))) return reply;
    return reply.setCookie(COOKIE_NAME, token as string, sessionCookie(request)).send({ ok: true });
  });

  app.get("/", async (_request, reply) => reply.redirect("/setup", 302));

  app.get("/api/usage", async (request, reply) => {
    if (!(await auth.guardRead(request, reply))) return reply;
    const now = Date.now();
    const snapshot = deps.store.current();
    const hasSnapshot = snapshot.generatedAt > 0;
    const body: Record<string, unknown> = {
      generatedAt: hasSnapshot ? new Date(snapshot.generatedAt).toISOString() : null,
      // With no snapshot at all there is no age to report — an epoch-zero timestamp
      // would otherwise surface as a 56-year-old reading.
      freshness: hasSnapshot ? evaluateFreshness(snapshot.generatedAt, now).freshness : null,
    };
    for (const provider of PROVIDERS) {
      const usage = usageFor(snapshot, provider);
      const pressure = resolveMascotPressure(usage);
      body[provider] = usage
        ? {
            fiveHour: serialiseWindow(usage.fiveHour, now),
            weekly: serialiseWindow(usage.weekly, now),
            planName: usage.planName,
            fetchedAt: new Date(usage.fetchedAt).toISOString(),
            state: deps.poller.status(provider).state,
            mascot: pressure
              ? {
                  state: pressure.state,
                  remainingPercent: Math.round(pressure.remainingPercent * 10) / 10,
                  constrainingWindow: pressure.constrainingWindow,
                }
              : null,
          }
        : { state: deps.poller.status(provider).state };
    }
    return reply.send(body);
  });

  app.get("/api/heartbeat", async (request, reply) => {
    if (!(await auth.guardRead(request, reply))) return reply;
    const now = Date.now();
    const snapshot = deps.store.current();
    const hasSnapshot = snapshot.generatedAt > 0;
    const fresh = evaluateFreshness(snapshot.generatedAt, now);

    const providers: Record<string, unknown> = {};
    for (const provider of PROVIDERS) {
      const status = deps.poller.status(provider);
      providers[provider] = {
        state: status.state,
        lastSuccessAt: status.lastSuccessAt ? new Date(status.lastSuccessAt).toISOString() : null,
        lastAttemptAt: status.lastAttemptAt ? new Date(status.lastAttemptAt).toISOString() : null,
        ageSec: status.lastSuccessAt ? Math.round((now - status.lastSuccessAt) / 1000) : null,
        consecutiveFailures: status.consecutiveFailures,
        lastError: status.lastError
          ? { ...status.lastError, at: new Date(status.lastError.at).toISOString() }
          : null,
        credential: {
          present: status.credential.present,
          parseError: status.credential.parseError,
          // Advisory only. Never used for control flow — a skewed clock must not be able
          // to declare a working token expired.
          advisory: true,
          expiresAt: status.credential.expiresAt
            ? new Date(status.credential.expiresAt).toISOString()
            : null,
        },
      };
    }

    // Reported separately from provider state because "no token yet" and "the binary is
    // not installed" are different problems that otherwise look identical from here.
    // Asked of the login manager rather than resolved again here, so this can never
    // disagree with what /api/login/:provider/start will do. Availability only — never
    // the resolved path, which is container-internal.
    const tools: Record<string, unknown> = {};
    for (const provider of PROVIDERS) {
      tools[provider] = { available: deps.logins.cliAvailable(provider) };
    }

    // `ok` tracks the process, not the providers — nobody should wire an alert to it that
    // fires every time a vendor sneezes.
    return reply.send({
      ok: true,
      now: new Date(now).toISOString(),
      uptimeSec: Math.round((now - STARTED_AT) / 1000),
      tools,
      snapshot: {
        generatedAt: hasSnapshot ? new Date(snapshot.generatedAt).toISOString() : null,
        ageSec: hasSnapshot ? Math.round(fresh.ageSec) : null,
        freshness: hasSnapshot ? fresh.freshness : null,
        restoredFromDisk: deps.store.wasRestored(),
      },
      providers,
    });
  });

  app.post("/api/refresh", async (request, reply) => {
    if (!(await auth.guardAdmin(request, reply))) return reply;
    await Promise.all(PROVIDERS.map((p) => deps.poller.tick(p)));
    return reply.send({ ok: true });
  });

  app.post<{ Params: { provider: string } }>("/api/login/:provider/start", async (request, reply) => {
    if (!(await auth.guardAdmin(request, reply))) return reply;
    const provider = request.params.provider;
    if (!isProvider(provider)) return reply.code(404).send({ error: "unknown_provider" });
    // Answered before anything is spawned. Without this the only signal was a crashed
    // process, which read as an outage rather than a missing dependency.
    if (!deps.logins.cliAvailable(provider)) {
      return reply.code(503).send({ error: "cli_not_found", hint: missingCLIHint(provider) });
    }
    try {
      return reply.send(await deps.logins.start(provider));
    } catch (error) {
      return reply.code(500).send({ error: "login_start_failed", detail: (error as Error).message });
    }
  });

  app.post<{ Params: { provider: string }; Body: { code?: string } }>(
    "/api/login/:provider/complete",
    async (request, reply) => {
      if (!(await auth.guardAdmin(request, reply))) return reply;
      const provider = request.params.provider;
      if (!isProvider(provider)) return reply.code(404).send({ error: "unknown_provider" });
      const code = request.body?.code;
      if (typeof code !== "string" || code.trim() === "") {
        return reply.code(400).send({ error: "missing_code" });
      }
      return reply.send(deps.logins.complete(provider, code));
    },
  );

  app.get<{ Params: { provider: string } }>("/api/login/:provider/status", async (request, reply) => {
    if (!(await auth.guardAdmin(request, reply))) return reply;
    const provider = request.params.provider;
    if (!isProvider(provider)) return reply.code(404).send({ error: "unknown_provider" });
    return reply.send(deps.logins.session(provider));
  });

  // --- Pairing -------------------------------------------------------------
  // The watch has no credential yet, so this one endpoint cannot be authenticated.
  // It is rate limited, and the code it hands back is inert until an authenticated
  // user claims it.
  const startLimiter = new Map<string, { count: number; windowStart: number }>();

  // The QR image itself. Unauthenticated for the same reason as /start — the watch has
  // no credential yet — and harmless, because the code it encodes is inert until an
  // authenticated user claims it.
  app.get<{ Querystring: { c?: string } }>("/api/pair/qr", async (request, reply) => {
    const code = request.query.c;
    if (!code || !/^[A-Z2-9]{8}$/.test(code)) {
      return reply.code(400).send({ error: "bad_code" });
    }
    const png = await renderPairingQR(pairingURL(publicOrigin(request), code));
    return reply.type("image/png").send(png);
  });

  app.post("/api/pair/start", async (request, reply) => {
    const now = Date.now();
    const entry = startLimiter.get(request.ip);
    if (!entry || now - entry.windowStart > 60_000) {
      startLimiter.set(request.ip, { count: 1, windowStart: now });
    } else if (entry.count >= 10) {
      return reply.code(429).send({ error: "too_many_attempts" });
    } else {
      entry.count += 1;
    }
    const session = deps.pairing.start(now);
    const origin = publicOrigin(request);
    return reply.send({
      code: session.code,
      secret: session.secret,
      expiresAt: new Date(session.expiresAt).toISOString(),
      // Handed back so the watch does not have to reconstruct either of these.
      pairingUrl: pairingURL(origin, session.code),
      qrUrl: `${origin}/api/pair/qr?c=${session.code}`,
    });
  });

  // What the phone's camera opens. Authenticated by the admin cookie, which the user
  // already has from /setup.
  app.get<{ Querystring: { c?: string } }>("/pair", async (request, reply) => {
    // A phone that scans the watch's QR without a session used to land on a JSON 401 —
    // a dead end in the middle of the one flow this page exists for. It now gets the
    // sign-in form and is returned here, code and all.
    const ok = await auth.guardAdminPage(request, reply, (reason) =>
      LOGIN_PAGE(safeNext(request.url), reason),
    );
    if (!ok) return reply;
    const code = request.query.c;
    if (!code) return reply.type("text/html; charset=utf-8").send(PAIR_RESULT_PAGE(false, "No code in the link."));
    const result = deps.pairing.claim(code, Date.now());
    return reply
      .type("text/html; charset=utf-8")
      .send(PAIR_RESULT_PAGE(result.ok, result.ok ? "Your watch will pick this up in a moment." : result.reason));
  });

  // The watch polls here. Unknown, expired, unclaimed and wrong-secret all answer with
  // the same 404 so this cannot be used as an oracle.
  app.post<{ Body: { code?: string; secret?: string } }>("/api/pair/poll", async (request, reply) => {
    const { code, secret } = request.body ?? {};
    if (typeof code !== "string" || typeof secret !== "string") {
      return reply.code(400).send({ error: "missing_fields" });
    }
    const token = deps.pairing.poll(code, secret, Date.now());
    if (!token) return reply.code(404).send({ error: "not_ready" });
    return reply.send({ deviceToken: token });
  });

  app.get("/api/devices", async (request, reply) => {
    if (!(await auth.guardAdmin(request, reply))) return reply;
    return reply.send({ devices: deps.pairing.list() });
  });

  app.delete<{ Params: { id: string } }>("/api/devices/:id", async (request, reply) => {
    if (!(await auth.guardAdmin(request, reply))) return reply;
    const removed = await deps.pairing.revoke(request.params.id);
    return removed ? reply.send({ ok: true }) : reply.code(404).send({ error: "unknown_device" });
  });

  return app;
}
