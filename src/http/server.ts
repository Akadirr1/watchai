import Fastify, { type FastifyInstance } from "fastify";
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
import { SETUP_PAGE } from "./setupPage.js";

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

export interface ServerDeps {
  store: SnapshotStore;
  poller: Poller;
  logins: LoginManager;
  authToken: string;
}

export function buildServer(deps: ServerDeps): FastifyInstance {
  const app = Fastify({ logger: false, trustProxy: true });
  const auth = createAuthGuard(deps.authToken);
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
        .setCookie(COOKIE_NAME, supplied, {
          path: "/", httpOnly: true, sameSite: "lax", secure: true, maxAge: 31_536_000,
        })
        .redirect("/setup", 302);
    }
    if (!(await auth.guard(request, reply))) return reply;
    return reply.type("text/html; charset=utf-8").send(SETUP_PAGE);
  });

  app.get("/", async (_request, reply) => reply.redirect("/setup", 302));

  app.get("/api/usage", async (request, reply) => {
    if (!(await auth.guard(request, reply))) return reply;
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
    if (!(await auth.guard(request, reply))) return reply;
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

    // `ok` tracks the process, not the providers — nobody should wire an alert to it that
    // fires every time a vendor sneezes.
    return reply.send({
      ok: true,
      now: new Date(now).toISOString(),
      uptimeSec: Math.round((now - STARTED_AT) / 1000),
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
    if (!(await auth.guard(request, reply))) return reply;
    await Promise.all(PROVIDERS.map((p) => deps.poller.tick(p)));
    return reply.send({ ok: true });
  });

  app.post<{ Params: { provider: string } }>("/api/login/:provider/start", async (request, reply) => {
    if (!(await auth.guard(request, reply))) return reply;
    const provider = request.params.provider;
    if (!isProvider(provider)) return reply.code(404).send({ error: "unknown_provider" });
    try {
      return reply.send(await deps.logins.start(provider));
    } catch (error) {
      return reply.code(500).send({ error: "login_start_failed", detail: (error as Error).message });
    }
  });

  app.post<{ Params: { provider: string }; Body: { code?: string } }>(
    "/api/login/:provider/complete",
    async (request, reply) => {
      if (!(await auth.guard(request, reply))) return reply;
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
    if (!(await auth.guard(request, reply))) return reply;
    const provider = request.params.provider;
    if (!isProvider(provider)) return reply.code(404).send({ error: "unknown_provider" });
    return reply.send(deps.logins.session(provider));
  });

  return app;
}
