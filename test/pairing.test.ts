import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { FastifyInstance } from "fastify";
import { buildServer } from "../src/http/server.js";
import { SnapshotStore } from "../src/poll/snapshotStore.js";
import { Poller } from "../src/poll/poller.js";
import { LoginManager } from "../src/login/manager.js";
import { PairingStore, PAIRING_TTL_MS } from "../src/pair/index.js";

const NOW = 1_757_000_000_000;

describe("PairingStore", () => {
  let store: PairingStore;
  beforeEach(() => { store = new PairingStore("/nonexistent"); });

  it("mints an unambiguous code and a separate secret", () => {
    const { code, secret } = store.start(NOW);
    expect(code).toHaveLength(8);
    // No characters that get misread when typed by hand.
    expect(code).not.toMatch(/[0O1Il]/);
    expect(secret.length).toBeGreaterThanOrEqual(40);
    expect(secret).not.toContain(code);
  });

  it("issues a device token only after an authenticated claim", () => {
    const { code, secret } = store.start(NOW);
    // Before the claim there is nothing to collect.
    expect(store.poll(code, secret, NOW)).toBeNull();
    expect(store.claim(code, NOW).ok).toBe(true);
    expect(store.poll(code, secret, NOW)).toBeTruthy();
  });

  it("is single use", () => {
    const { code, secret } = store.start(NOW);
    store.claim(code, NOW);
    expect(store.poll(code, secret, NOW)).toBeTruthy();
    expect(store.poll(code, secret, NOW)).toBeNull();
  });

  it("cannot be claimed twice", () => {
    const { code } = store.start(NOW);
    expect(store.claim(code, NOW).ok).toBe(true);
    expect(store.claim(code, NOW).ok).toBe(false);
  });

  it("expires", () => {
    const { code, secret } = store.start(NOW);
    store.claim(code, NOW);
    expect(store.poll(code, secret, NOW + PAIRING_TTL_MS + 1)).toBeNull();
  });

  it("refuses to be claimed once expired", () => {
    const { code } = store.start(NOW);
    expect(store.claim(code, NOW + PAIRING_TTL_MS + 1).ok).toBe(false);
  });

  // The secret is what protects the poll — a code seen over someone's shoulder is inert.
  it("rejects a wrong secret", () => {
    const { code } = store.start(NOW);
    store.claim(code, NOW);
    expect(store.poll(code, "wrong-secret", NOW)).toBeNull();
  });

  // Unknown, expired, unclaimed and wrong-secret must be indistinguishable.
  it("answers every failure mode identically", () => {
    const { code, secret } = store.start(NOW);
    expect(store.poll("ZZZZZZZZ", secret, NOW)).toBeNull();   // unknown
    expect(store.poll(code, secret, NOW)).toBeNull();          // unclaimed
    expect(store.poll(code, "nope", NOW)).toBeNull();          // wrong secret
  });

  it("accepts the code case-insensitively and trimmed", () => {
    const { code, secret } = store.start(NOW);
    expect(store.claim(` ${code.toLowerCase()} `, NOW).ok).toBe(true);
    expect(store.poll(code, secret, NOW)).toBeTruthy();
  });

  it("verifies and revokes device tokens", async () => {
    const { code, secret } = store.start(NOW);
    const claim = store.claim(code, NOW);
    const token = store.poll(code, secret, NOW)!;

    expect(store.verifyDeviceToken(token, NOW)).toBe(true);
    expect(store.verifyDeviceToken("not-a-token", NOW)).toBe(false);
    expect(store.list()).toHaveLength(1);

    expect(claim.ok && (await store.revoke(claim.deviceId))).toBe(true);
    expect(store.verifyDeviceToken(token, NOW)).toBe(false);
    expect(store.list()).toHaveLength(0);
  });

  it("never exposes a token hash through the device list", () => {
    const { code, secret } = store.start(NOW);
    store.claim(code, NOW);
    const token = store.poll(code, secret, NOW)!;
    const serialised = JSON.stringify(store.list());
    expect(serialised).not.toContain(token);
    expect(serialised).not.toContain("tokenHash");
  });
});

describe("pairing over HTTP", () => {
  const ADMIN = "a".repeat(48);
  let app: FastifyInstance;
  let pairing: PairingStore;

  beforeAll(async () => {
    const dir = await mkdtemp(join(tmpdir(), "qp-pair-"));
    const dirs = { claude: join(dir, "claude"), codex: join(dir, "codex") };
    const store = new SnapshotStore(dir);
    pairing = new PairingStore(dir);
    app = buildServer({
      store, poller: new Poller(store, dirs, 60_000, 30_000),
      logins: new LoginManager(dirs), pairing, authToken: ADMIN,
    });
    await app.ready();
  });
  afterAll(async () => { await app.close(); });

  const admin = { authorization: `Bearer ${ADMIN}` };

  async function pairAWatch(): Promise<string> {
    const started = (await app.inject({ method: "POST", url: "/api/pair/start" })).json();
    await app.inject({ method: "GET", url: `/pair?c=${started.code}`, headers: admin });
    const polled = (await app.inject({
      method: "POST", url: "/api/pair/poll",
      payload: { code: started.code, secret: started.secret },
    })).json();
    return polled.deviceToken;
  }

  // The watch has no credential yet, so this one endpoint cannot be authenticated.
  it("lets an unauthenticated watch start a pairing", async () => {
    const r = await app.inject({ method: "POST", url: "/api/pair/start" });
    expect(r.statusCode).toBe(200);
    expect(r.json().code).toHaveLength(8);
  });

  it("requires admin auth to claim a code", async () => {
    const started = (await app.inject({ method: "POST", url: "/api/pair/start" })).json();
    expect((await app.inject({ method: "GET", url: `/pair?c=${started.code}` })).statusCode).toBe(401);
  });

  it("answers an unripe poll with 404, not a hint", async () => {
    const started = (await app.inject({ method: "POST", url: "/api/pair/start" })).json();
    const r = await app.inject({
      method: "POST", url: "/api/pair/poll",
      payload: { code: started.code, secret: started.secret },
    });
    expect(r.statusCode).toBe(404);
  });

  it("completes the whole flow", async () => {
    expect(await pairAWatch()).toBeTruthy();
  });

  // The point of the two tiers: a lost watch is one revoked device, not a rotated admin token.
  it("gives a device token the read surface but not the admin surface", async () => {
    const device = { authorization: `Bearer ${await pairAWatch()}` };

    expect((await app.inject({ method: "GET", url: "/api/usage", headers: device })).statusCode).toBe(200);
    expect((await app.inject({ method: "GET", url: "/api/heartbeat", headers: device })).statusCode).toBe(200);

    for (const url of ["/setup", "/api/devices"]) {
      expect((await app.inject({ method: "GET", url, headers: device })).statusCode).toBe(401);
    }
    expect((await app.inject({
      method: "POST", url: "/api/login/claude/start", headers: device,
    })).statusCode).toBe(401);
  });

  it("stops accepting a revoked device token", async () => {
    const token = await pairAWatch();
    const device = { authorization: `Bearer ${token}` };
    expect((await app.inject({ method: "GET", url: "/api/usage", headers: device })).statusCode).toBe(200);

    const listed = (await app.inject({ method: "GET", url: "/api/devices", headers: admin })).json();
    const id = listed.devices.at(-1).id;
    expect((await app.inject({ method: "DELETE", url: `/api/devices/${id}`, headers: admin })).statusCode).toBe(200);

    expect((await app.inject({ method: "GET", url: "/api/usage", headers: device })).statusCode).toBe(401);
  });

  it("never returns a device token from the device list", async () => {
    const token = await pairAWatch();
    const body = (await app.inject({ method: "GET", url: "/api/devices", headers: admin })).body;
    expect(body).not.toContain(token);
  });
});
