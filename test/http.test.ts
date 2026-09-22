import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { FastifyInstance } from "fastify";
import { buildServer } from "../src/http/server.js";
import { SnapshotStore } from "../src/poll/snapshotStore.js";
import { Poller } from "../src/poll/poller.js";
import { LoginManager } from "../src/login/manager.js";

const TOKEN = "t".repeat(48);
let app: FastifyInstance;

beforeAll(async () => {
  const dir = await mkdtemp(join(tmpdir(), "qp-"));
  const dirs = { claude: join(dir, "claude"), codex: join(dir, "codex") };
  const store = new SnapshotStore(dir);
  const poller = new Poller(store, dirs, 60_000, 30_000); // never started
  app = buildServer({ store, poller, logins: new LoginManager(dirs), authToken: TOKEN });
  await app.ready();
});

afterAll(async () => { await app.close(); });

const authed = { authorization: `Bearer ${TOKEN}` };

describe("auth", () => {
  it("leaves /healthz open and cheap", async () => {
    const r = await app.inject({ method: "GET", url: "/healthz" });
    expect(r.statusCode).toBe(200);
    expect(r.body).toBe("ok");
  });

  it("rejects api routes without a token", async () => {
    for (const url of ["/api/usage", "/api/heartbeat"]) {
      expect((await app.inject({ method: "GET", url })).statusCode).toBe(401);
    }
  });

  it("rejects a wrong token without throwing on length mismatch", async () => {
    for (const bad of ["x", "short", "y".repeat(48), "z".repeat(200)]) {
      const r = await app.inject({ method: "GET", url: "/api/usage", headers: { authorization: `Bearer ${bad}` } });
      expect(r.statusCode).toBe(401);
    }
  });

  it("accepts Bearer and X-Auth-Token alike", async () => {
    expect((await app.inject({ method: "GET", url: "/api/usage", headers: authed })).statusCode).toBe(200);
    expect((await app.inject({ method: "GET", url: "/api/usage", headers: { "x-auth-token": TOKEN } })).statusCode).toBe(200);
  });

  it("does not distinguish absent from wrong", async () => {
    const absent = await app.inject({ method: "GET", url: "/api/usage" });
    const wrong = await app.inject({ method: "GET", url: "/api/usage", headers: { authorization: "Bearer nope" } });
    expect(absent.statusCode).toBe(wrong.statusCode);
    expect(absent.body).toBe(wrong.body);
  });
});

describe("payloads", () => {
  it("serves heartbeat while both providers are unauthenticated", async () => {
    const r = await app.inject({ method: "GET", url: "/api/heartbeat", headers: authed });
    expect(r.statusCode).toBe(200);
    const body = r.json();
    expect(body.ok).toBe(true);           // process health, not provider health
    expect(body.providers.claude.state).toBe("never_fetched");
    expect(body.providers.codex.state).toBe("never_fetched");
  });

  it("never leaks any part of the auth token", async () => {
    for (const url of ["/api/usage", "/api/heartbeat", "/api/login/claude/status"]) {
      const body = (await app.inject({ method: "GET", url, headers: authed })).body;
      for (let i = 0; i + 8 <= TOKEN.length; i++) {
        expect(body).not.toContain(TOKEN.slice(i, i + 8));
      }
    }
  });

  it("rejects an unknown provider", async () => {
    const r = await app.inject({ method: "GET", url: "/api/login/gemini/status", headers: authed });
    expect(r.statusCode).toBe(404);
  });

  it("requires a non-empty code to complete a login", async () => {
    const r = await app.inject({
      method: "POST", url: "/api/login/claude/complete", headers: authed, payload: { code: "  " },
    });
    expect(r.statusCode).toBe(400);
  });

  it("sets no-store and noindex on every response", async () => {
    const r = await app.inject({ method: "GET", url: "/api/usage", headers: authed });
    expect(r.headers["cache-control"]).toBe("no-store");
    expect(r.headers["x-robots-tag"]).toContain("noindex");
  });
});

describe("empty snapshot", () => {
  it("reports no age rather than a 56-year-old reading", async () => {
    const heartbeat = (await app.inject({ method: "GET", url: "/api/heartbeat", headers: authed })).json();
    expect(heartbeat.snapshot.generatedAt).toBeNull();
    expect(heartbeat.snapshot.ageSec).toBeNull();
    expect(heartbeat.snapshot.freshness).toBeNull();

    const usage = (await app.inject({ method: "GET", url: "/api/usage", headers: authed })).json();
    expect(usage.generatedAt).toBeNull();
    expect(usage.freshness).toBeNull();
  });
});
