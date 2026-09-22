import { randomBytes, timingSafeEqual, createHash } from "node:crypto";
import { readFile, writeFile, rename, mkdir, chmod } from "node:fs/promises";
import { join, dirname } from "node:path";

/**
 * Watch pairing.
 *
 * The problem: the watch needs a credential, but typing a 64-character token on a 41mm
 * screen is not a thing, and baking it into the build means a rebuild every time it
 * changes.
 *
 * The flow, and why it is shaped this way:
 *
 *   watch                        server                      phone
 *     │ POST /api/pair/start        │
 *     │───────────────────────────▶ │ mints {code, secret}, TTL 2 min
 *     │ ◀──── {code, secret} ────── │
 *     │ shows a QR containing       │
 *     │ https://<server>/pair?c=CODE│
 *     │                             │ ◀── GET /pair?c=CODE  (admin cookie)
 *     │                             │     claims it, issues a device token
 *     │ POST /api/pair/poll         │
 *     │   {code, secret}            │
 *     │───────────────────────────▶ │
 *     │ ◀──── {deviceToken} ─────── │ single use, then discarded
 *
 * The QR carries a URL rather than raw data so the iPhone's own Camera app can scan it —
 * iOS Safari has no `BarcodeDetector`, so an in-page scanner would have been either
 * broken or an extra dependency.
 *
 * Three properties do the security work:
 *
 * 1. **The code is worthless alone.** Claiming it requires the admin credential. Someone
 *    who guesses a code but is not already the admin gets nothing, which is why 8
 *    characters is enough.
 * 2. **The secret never appears in the QR.** It stays in the watch's memory and is what
 *    authorises the poll, so a code seen over someone's shoulder still cannot fetch a
 *    token.
 * 3. **Device tokens are not the admin token.** A lost watch means revoking one device,
 *    not rotating `AUTH_TOKEN`.
 */

/** No 0/O or 1/I/l — these get read aloud and typed by hand. */
const CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";
const CODE_LENGTH = 8;
export const PAIRING_TTL_MS = 2 * 60_000;

export interface PairingSession {
  readonly code: string;
  readonly secretHash: Buffer;
  readonly expiresAt: number;
  claimed: boolean;
  deviceToken: string | null;
}

export interface Device {
  readonly id: string;
  readonly tokenHash: string;
  readonly createdAt: number;
  lastSeenAt: number | null;
}

function randomCode(): string {
  const bytes = randomBytes(CODE_LENGTH);
  let out = "";
  for (let i = 0; i < CODE_LENGTH; i++) {
    out += CODE_ALPHABET[bytes[i]! % CODE_ALPHABET.length];
  }
  return out;
}

function sha256(value: string): Buffer {
  return createHash("sha256").update(value, "utf8").digest();
}

/** Length-safe constant-time compare. `timingSafeEqual` throws on differing lengths. */
function secretMatches(given: string, expected: Buffer): boolean {
  return timingSafeEqual(sha256(given), expected);
}

export class PairingStore {
  private readonly sessions = new Map<string, PairingSession>();
  private devices: Device[] = [];
  private readonly path: string;
  private persistQueue: Promise<void> = Promise.resolve();

  constructor(dataDir: string) {
    this.path = join(dataDir, "devices.json");
  }

  async load(): Promise<void> {
    try {
      const parsed = JSON.parse(await readFile(this.path, "utf8")) as unknown;
      if (Array.isArray(parsed)) this.devices = parsed as Device[];
    } catch {
      // Absent or corrupt: start with no paired devices. Never fatal.
    }
  }

  /**
   * Serialised. Two claims landing in the same tick would otherwise both write
   * `devices.json.tmp` and both rename it: the second rename fails with ENOENT, and the
   * one that lands last can be carrying the older device list. Chaining makes the last
   * write the one with the most state, which is the only ordering that is correct here.
   */
  private persist(): Promise<void> {
    this.persistQueue = this.persistQueue.then(() => this.writeDevices());
    return this.persistQueue;
  }

  private async writeDevices(): Promise<void> {
    try {
      await mkdir(dirname(this.path), { recursive: true });
      const tmp = `${this.path}.tmp`;
      await writeFile(tmp, JSON.stringify(this.devices, null, 2), { encoding: "utf8", mode: 0o600 });
      await rename(tmp, this.path); // atomic
      await chmod(this.path, 0o600);
    } catch (error) {
      console.error("device store persist failed:", (error as Error).message);
    }
  }

  private sweep(now: number): void {
    for (const [code, session] of this.sessions) {
      if (session.expiresAt <= now) this.sessions.delete(code);
    }
  }

  /** Called by the watch. Returns the code to display and the secret to keep. */
  start(now: number): { code: string; secret: string; expiresAt: number } {
    this.sweep(now);
    let code = randomCode();
    while (this.sessions.has(code)) code = randomCode();

    const secret = randomBytes(32).toString("base64url");
    const expiresAt = now + PAIRING_TTL_MS;
    this.sessions.set(code, {
      code,
      secretHash: sha256(secret),
      expiresAt,
      claimed: false,
      deviceToken: null,
    });
    return { code, secret, expiresAt };
  }

  /** Called by the authenticated phone. Mints the device token. */
  claim(code: string, now: number): { ok: true; deviceId: string } | { ok: false; reason: string } {
    this.sweep(now);
    const session = this.sessions.get(code.trim().toUpperCase());
    if (!session) return { ok: false, reason: "unknown or expired code" };
    if (session.claimed) return { ok: false, reason: "this code was already used" };

    const token = randomBytes(32).toString("base64url");
    const device: Device = {
      id: randomBytes(8).toString("hex"),
      tokenHash: sha256(token).toString("hex"),
      createdAt: now,
      lastSeenAt: null,
    };
    this.devices.push(device);
    void this.persist();

    session.claimed = true;
    session.deviceToken = token;
    return { ok: true, deviceId: device.id };
  }

  /**
   * Called by the watch, repeatedly, until it gets a token.
   *
   * Returns null for unknown, expired, unclaimed AND wrong-secret alike — the caller
   * answers all four with the same 404 so this cannot be used as an oracle.
   */
  poll(code: string, secret: string, now: number): string | null {
    this.sweep(now);
    const session = this.sessions.get(code.trim().toUpperCase());
    if (!session || !session.claimed || session.deviceToken === null) return null;
    if (!secretMatches(secret, session.secretHash)) return null;

    const token = session.deviceToken;
    this.sessions.delete(session.code); // single use
    return token;
  }

  /** True when the token belongs to a paired device. Updates its last-seen stamp. */
  verifyDeviceToken(token: string, now: number): boolean {
    const hash = sha256(token).toString("hex");
    const device = this.devices.find((d) => d.tokenHash === hash);
    if (!device) return false;
    device.lastSeenAt = now;
    return true;
  }

  list(): Array<Omit<Device, "tokenHash">> {
    return this.devices.map(({ id, createdAt, lastSeenAt }) => ({ id, createdAt, lastSeenAt }));
  }

  async revoke(id: string): Promise<boolean> {
    const before = this.devices.length;
    this.devices = this.devices.filter((d) => d.id !== id);
    if (this.devices.length === before) return false;
    await this.persist();
    return true;
  }
}
