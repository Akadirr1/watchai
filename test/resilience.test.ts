import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { execPath } from "node:process";
import type { FastifyInstance } from "fastify";
import { buildServer, safeNext } from "../src/http/server.js";
import { SnapshotStore } from "../src/poll/snapshotStore.js";
import { Poller } from "../src/poll/poller.js";
import { LoginManager } from "../src/login/manager.js";
import { PairingStore } from "../src/pair/index.js";
import { resolveExecutable } from "../src/login/availability.js";
import type { AIProvider } from "../src/models/provider.js";

const TOKEN = "r".repeat(48);

async function buildWith(resolve: (provider: AIProvider) => string | null): Promise<FastifyInstance> {
  const dir = await mkdtemp(join(tmpdir(), "qp-res-"));
  const dirs = { claude: join(dir, "claude"), codex: join(dir, "codex") };
  const store = new SnapshotStore(dir);
  const app = buildServer({
    store,
    poller: new Poller(store, dirs, 60_000, 30_000),
    logins: new LoginManager(dirs, resolve),
    pairing: new PairingStore(dir),
    authToken: TOKEN,
  });
  await app.ready();
  return app;
}

// ---------------------------------------------------------------------------
// The regression these exist for: `spawn claude ENOENT` emits an 'error' event, and an
// 'error' event with no listener is THROWN. A container built without the vendor CLIs
// took the whole API down every time anyone pressed Connect.
// ---------------------------------------------------------------------------
describe("a missing vendor CLI", () => {
  const dirs = { claude: "/tmp/qp-missing/claude", codex: "/tmp/qp-missing/codex" };

  it("fails the login instead of the process, when nothing is on PATH", async () => {
    const logins = new LoginManager(dirs, () => null);
    const session = await logins.start("claude");
    expect(session.phase).toBe("failed");
    expect(session.error).toContain("not on PATH");
  });

  // The path above never spawns. This one does, and is the case that used to crash:
  // resolution succeeds but the file is gone by the time execve runs.
  it("survives a spawn that fails outright", async () => {
    const logins = new LoginManager(dirs, () => "/nonexistent/bin/codex");
    await logins.start("codex");
    await new Promise((resolve) => setTimeout(resolve, 300));

    const session = logins.session("codex");
    expect(session.phase).toBe("failed");
    expect(session.error).toBeTruthy();
  });

  it("says so rather than trying, over HTTP", async () => {
    const app = await buildWith(() => null);
    const r = await app.inject({
      method: "POST", url: "/api/login/claude/start",
      headers: { authorization: `Bearer ${TOKEN}` },
    });
    expect(r.statusCode).toBe(503);
    expect(r.json().error).toBe("cli_not_found");
    await app.close();
  });

  it("is reported by the heartbeat, without leaking where it looked", async () => {
    const app = await buildWith(() => null);
    const body = (await app.inject({
      method: "GET", url: "/api/heartbeat", headers: { authorization: `Bearer ${TOKEN}` },
    })).json();
    expect(body.tools.claude.available).toBe(false);
    expect(body.tools.codex.available).toBe(false);
    expect(JSON.stringify(body.tools)).not.toContain("/");
    await app.close();
  });
});

describe("resolveExecutable", () => {
  it("finds a binary that is really on PATH", () => {
    // node is running this test, so its directory is a PATH entry we can count on.
    expect(resolveExecutable("node", join(execPath, ".."))).toBe(execPath);
  });

  it("returns null rather than guessing", () => {
    expect(resolveExecutable("definitely-not-a-real-binary-xyz")).toBeNull();
    expect(resolveExecutable("node", "")).toBeNull();
  });
});

// ---------------------------------------------------------------------------
// The second failure: opening the site in a browser answered `{"error":"unauthorized"}`
// with no way forward. The only route in was knowing to append ?t=<AUTH_TOKEN> by hand.
// ---------------------------------------------------------------------------
describe("signing in from a browser", () => {
  let app: FastifyInstance;
  beforeAll(async () => { app = await buildWith(() => "/usr/bin/true"); });
  afterAll(async () => { await app.close(); });

  const html = { accept: "text/html,application/xhtml+xml" };

  it("serves a form, not a JSON body", async () => {
    const r = await app.inject({ method: "GET", url: "/setup", headers: html });
    expect(r.statusCode).toBe(401);
    expect(r.headers["content-type"]).toContain("text/html");
    expect(r.body).toContain("<form");
    expect(r.body).not.toContain('{"error"');
  });

  // Unchanged for everything that is not a browser — the watch and every test that
  // injects without an Accept header still get the same JSON 401.
  it("keeps the JSON 401 for non-browsers", async () => {
    const r = await app.inject({ method: "GET", url: "/setup" });
    expect(r.statusCode).toBe(401);
    expect(r.json()).toEqual({ error: "unauthorized" });
  });

  it("exchanges the token for the same cookie ?t= sets", async () => {
    const r = await app.inject({ method: "POST", url: "/api/session", payload: { token: TOKEN } });
    expect(r.statusCode).toBe(200);
    const cookie = r.cookies.find((c) => c.name === "qp_auth");
    expect(cookie?.value).toBe(TOKEN);
    expect(cookie?.httpOnly).toBe(true);

    const after = await app.inject({
      method: "GET", url: "/setup", headers: { cookie: `qp_auth=${TOKEN}` },
    });
    expect(after.statusCode).toBe(200);
    expect(after.body).toContain("Paired watches");
  });

  it("refuses a wrong token", async () => {
    const r = await app.inject({ method: "POST", url: "/api/session", payload: { token: "nope" } });
    expect(r.statusCode).toBe(401);
    expect(r.cookies.find((c) => c.name === "qp_auth")).toBeUndefined();
  });

  // A form is not a bypass: it goes through the same per-IP failure limiter.
  it("counts form attempts against the rate limit", async () => {
    const isolated = await buildWith(() => null);
    const codes: number[] = [];
    for (let i = 0; i < 12; i++) {
      codes.push(
        (await isolated.inject({ method: "POST", url: "/api/session", payload: { token: "bad" } }))
          .statusCode,
      );
    }
    expect(codes.slice(0, 10)).toEqual(Array(10).fill(401));
    expect(codes.slice(10)).toEqual([429, 429]);
    await isolated.close();
  });

  // The QR flow's landing page. A signed-out phone used to hit a JSON dead end here.
  it("returns a signed-out phone to the pairing link it scanned", async () => {
    const r = await app.inject({ method: "GET", url: "/pair?c=ABCD2345", headers: html });
    expect(r.statusCode).toBe(401);
    expect(r.body).toContain("<form");
    expect(r.body).toContain('data-next="/pair?c=ABCD2345"');
  });
});

describe("safeNext", () => {
  it("keeps a same-site path", () => {
    expect(safeNext("/pair?c=ABCD2345")).toBe("/pair?c=ABCD2345");
  });

  it("refuses anything a browser would treat as absolute", () => {
    // `//host` and `/\host` are both absolute URLs to a browser — an open redirect is one
    // missing check away.
    for (const hostile of ["//evil.com", "/\\evil.com", "https://evil.com", "evil.com", "", "/"]) {
      expect(safeNext(hostile)).toBe("/setup");
    }
  });

  it("refuses non-strings and control characters", () => {
    expect(safeNext(undefined)).toBe("/setup");
    expect(safeNext({ toString: () => "/ok" })).toBe("/setup");
    expect(safeNext("/ok\nSet-Cookie: x=1")).toBe("/setup");
  });
});
