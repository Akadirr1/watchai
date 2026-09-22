import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { randomUUID } from "node:crypto";
import { join } from "node:path";
import type { FastifyInstance } from "fastify";
import { buildServer } from "../src/http/server.js";
import { SnapshotStore } from "../src/poll/snapshotStore.js";
import { Poller } from "../src/poll/poller.js";
import { LoginManager } from "../src/login/manager.js";
import { PairingStore, PAIRING_TTL_MS } from "../src/pair/index.js";
import { pairingURL, renderPairingQR, publicOrigin } from "../src/pair/qr.js";
import { readFile } from "node:fs/promises";

const NOW = 1_757_000_000_000;

describe("PairingStore", () => {
  let store: PairingStore;
  // A fresh directory per test. These cases are about the in-memory state machine, but
  // claiming a code writes devices.json, and sharing one path across tests makes those
  // writes collide.
  beforeEach(() => { store = new PairingStore(join(tmpdir(), `qp-unit-${randomUUID()}`)); });

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

describe("the pairing QR", () => {
  // The QR carries a URL rather than raw pairing data so the iPhone's own Camera app can
  // open it — iOS Safari has no BarcodeDetector, so an in-page scanner was never an option.
  it("encodes a link the phone's camera can follow", () => {
    expect(pairingURL("https://pets.example.com", "ABCD2345"))
      .toBe("https://pets.example.com/pair?c=ABCD2345");
  });

  it("renders a real PNG", async () => {
    const png = await renderPairingQR("https://pets.example.com/pair?c=ABCD2345");
    // PNG magic. Cheap, but it catches the failure that actually happened here once:
    // an encoder that produced something QR-shaped and unreadable.
    expect(png.subarray(0, 8)).toEqual(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]));
    expect(png.byteLength).toBeGreaterThan(200);
  });
});

describe("the QR endpoint", () => {
  const ADMIN = "b".repeat(48);
  let app: FastifyInstance;

  beforeAll(async () => {
    const dir = await mkdtemp(join(tmpdir(), "qp-qr-"));
    const dirs = { claude: join(dir, "claude"), codex: join(dir, "codex") };
    const store = new SnapshotStore(dir);
    app = buildServer({
      store, poller: new Poller(store, dirs, 60_000, 30_000),
      logins: new LoginManager(dirs), pairing: new PairingStore(dir), authToken: ADMIN,
    });
    await app.ready();
  });
  afterAll(async () => { await app.close(); });

  it("hands the watch both the link and the image to fetch", async () => {
    const body = (await app.inject({ method: "POST", url: "/api/pair/start" })).json();
    expect(body.pairingUrl).toContain(`/pair?c=${body.code}`);
    expect(body.qrUrl).toContain(`/api/pair/qr?c=${body.code}`);
  });

  // Unauthenticated for the same reason /start is: the watch has no credential yet. It is
  // harmless because the code it draws is inert until an authenticated user claims it.
  it("serves a PNG for a well-formed code without a credential", async () => {
    const code = (await app.inject({ method: "POST", url: "/api/pair/start" })).json().code;
    const r = await app.inject({ method: "GET", url: `/api/pair/qr?c=${code}` });
    expect(r.statusCode).toBe(200);
    expect(r.headers["content-type"]).toBe("image/png");
    expect(r.rawPayload.subarray(1, 4).toString()).toBe("PNG");
  });

  it("refuses to render anything that is not a pairing code", async () => {
    for (const c of ["", "short", "lowercase", "ABCD23450", "ABCD 345", "../../etc"]) {
      const r = await app.inject({ method: "GET", url: `/api/pair/qr?c=${encodeURIComponent(c)}` });
      expect(r.statusCode).toBe(400);
    }
  });
});

describe("the device file", () => {
  // Claims fire persistence without awaiting it. Before these writes were serialised,
  // two in the same tick raced on devices.json.tmp: one rename failed with ENOENT and the
  // survivor could be the one carrying the shorter list.
  it("survives claims landing in the same tick", async () => {
    const dir = await mkdtemp(join(tmpdir(), "qp-persist-"));
    const store = new PairingStore(dir);

    const codes = [store.start(NOW), store.start(NOW), store.start(NOW), store.start(NOW)];
    for (const { code } of codes) store.claim(code, NOW);

    // Let the serialised queue drain. One more write is enough to sit behind all of them.
    await store.revoke("no-such-device");
    await new Promise((resolve) => setTimeout(resolve, 50));

    const onDisk = JSON.parse(await readFile(join(dir, "devices.json"), "utf8"));
    expect(onDisk).toHaveLength(codes.length);
  });
});

describe("the origin embedded in the QR", () => {
  const request = { protocol: "https", hostname: "derived.example.com" } as never;
  const original = process.env["PUBLIC_URL"];
  afterAll(() => {
    if (original === undefined) delete process.env["PUBLIC_URL"];
    else process.env["PUBLIC_URL"] = original;
  });

  it("falls back to the request when PUBLIC_URL is unset", () => {
    delete process.env["PUBLIC_URL"];
    expect(publicOrigin(request)).toBe("https://derived.example.com");
  });

  it("uses PUBLIC_URL when it carries a scheme", () => {
    process.env["PUBLIC_URL"] = "https://pets.example.com";
    expect(publicOrigin(request)).toBe("https://pets.example.com");
  });

  // Found in production: PUBLIC_URL was set to a bare host, so the QR encoded
  // "pets.example.com/pair?c=..." — a string no camera can open.
  it("assumes https for a bare host rather than emitting an unusable origin", () => {
    process.env["PUBLIC_URL"] = "pets.example.com";
    expect(publicOrigin(request)).toBe("https://pets.example.com");
  });

  it("tolerates trailing slashes and surrounding whitespace", () => {
    process.env["PUBLIC_URL"] = "  https://pets.example.com//  ";
    expect(publicOrigin(request)).toBe("https://pets.example.com");
  });

  it("leaves plain http alone — a local deployment is not https", () => {
    process.env["PUBLIC_URL"] = "http://192.168.1.10:3000";
    expect(publicOrigin(request)).toBe("http://192.168.1.10:3000");
  });
});
