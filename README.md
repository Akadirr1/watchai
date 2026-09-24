# QuotaPets

Your Claude and Codex subscription quota, on your wrist, as a mascot that visibly runs out
of energy as you run out of quota.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Two pieces: a small **server** that reads your quota and publishes it as JSON, and a
**standalone Apple Watch app** that draws the pets.

```
Browser ──"Connect Claude"──▶  Server (Docker / Coolify)
                                 ├─ drives the real claude / codex CLI over stdio-JSON
                                 ├─ relays the sign-in URL to your browser
                                 └─ the CLI writes its own credential into /data
                                        │
                                   polls 2 usage endpoints every 60s
                                        │
                                   JSON API  ── no HTML, no SVG
                                        │  HTTPS + device token
                                        ▼
                              Apple Watch (independent watchOS app)
```

No iPhone app. No Mac at runtime. watchOS apps have been able to run independently and
reach the network on their own since watchOS 6.

---

## Why it is built this way

The project kept snagging on one question: **who holds the credential?**

Native iOS login turned out to be blocked — neither vendor offers public client
registration, so any native flow would have to send the vendor's own CLI `client_id`, and
the consent screen would read "Claude Code" while a third-party app took the token. That
finding is recorded in [`docs/provider-research.md`](docs/provider-research.md) with
file-and-line citations, and it still stands.

So QuotaPets **implements no OAuth at all**. Sign-in starts the real vendor CLI inside the
container, relays the URL it prints, and hands back whatever you paste. The consent screen
is honest, because it really is Claude Code / Codex asking.

The container keeps its **own** credential in its own config directory. That is what makes
it safe to refresh tokens here: refresh-token rotation cannot strand anyone else's copy. An
earlier design that mounted the host's `~/.claude` would have broken whatever else on that
machine was using it.

> **One disclosure, since this repository is public.**
> `src/credentials/refresh.ts` carries Claude's OAuth `client_id` as a fallback. It is not
> a secret — it is a public client with no secret, published in the vendor's own CLI — but
> in an open repository you should know it is there, and know what it implies: a token
> refreshed by QuotaPets is refreshed *as Claude Code*, because that is the grant the CLI
> created.

---

## Running the server

### Coolify

1. New Resource → Application → your repository → **Build Pack: `Dockerfile`**, Dockerfile
   Location `/Dockerfile`.

   > ⚠️ **This one matters.** Coolify defaults to Nixpacks, which will happily build and
   > start the server — but Nixpacks knows nothing about the two vendor CLIs this image
   > installs, so sign-in has nothing to run. Symptoms: `[claude] cli: claude NOT FOUND on
   > PATH` in the logs, an orange banner on `/setup`, and a `503 cli_not_found` if you
   > press Connect. The tell in the logs is an `npm run start` banner — this Dockerfile's
   > `CMD` never goes through npm.

2. Environment variable: `AUTH_TOKEN` = output of `openssl rand -hex 32`. Turn *off*
   "Build Variable" so it isn't baked into an image layer.
3. Domains → your subdomain, Force HTTPS on. Set `PUBLIC_URL` to that same URL.
4. Deploy, open `https://<your-domain>/setup`, sign in with your `AUTH_TOKEN`, and connect
   each account.

**Optional but recommended:** Persistent Storage → Add, destination `/data`. Without it a
redeploy starts a fresh container and you sign in again. Nothing else needs a volume.

### Signing in

`/setup` asks for your `AUTH_TOKEN` and keeps it in an `HttpOnly` cookie on that device.
`https://<your-domain>/setup?t=<AUTH_TOKEN>` still works for scripting — the token is
swapped for the same cookie and stripped from the URL by a redirect.

Failed attempts are rate limited per IP, and the server never distinguishes "no token"
from "wrong token": both answer 401, because the difference is a probing oracle.

### Locally

```bash
npm ci
AUTH_TOKEN=$(openssl rand -hex 32) DATA_DIR=./tmp npm run dev
```

### Configuration

Every variable, with its default. See [`.env.example`](.env.example) for the annotated
version. The server does **not** read `.env` itself — your platform injects these.

| Variable | Default | |
|---|---|---|
| `AUTH_TOKEN` | — | **Required**, min 32 chars. The process refuses to start without it. |
| `PORT` | `3000` | |
| `HOST` | `0.0.0.0` | |
| `PUBLIC_URL` | derived from the request | The origin embedded in the pairing QR. Set it when you are behind a proxy you would rather not trust for that. |
| `DATA_DIR` | `/data` | Snapshot cache and the paired-device list |
| `CLAUDE_CONFIG_DIR` | `/data/claude` | Where the Claude CLI keeps its credential |
| `CODEX_HOME` | `/data/codex` | Where the Codex CLI keeps its credential |
| `POLL_INTERVAL_SEC` | `60` | |
| `CODEX_STAGGER_SEC` | `30` | So the two providers never fire in the same instant |
| `DEBUG_LOGIN` | `0` | `1` logs the vendor CLI's own output. Off by default because that output contains device verification URLs and user codes. |

---

## Pairing the watch

The watch does not ship with a credential. On first launch it shows a QR; you scan it with
your iPhone's **Camera app** while signed in to the server, and a device token lands in the
watch's Keychain.

```
watch                        server                      phone
  │ POST /api/pair/start        │
  │───────────────────────────▶ │ mints {code, secret}, TTL 2 min
  │ ◀──── {code, secret} ────── │
  │ shows a QR containing       │
  │ https://<server>/pair?c=CODE│
  │                             │ ◀── GET /pair?c=CODE   (your admin cookie)
  │                             │     claims it, issues a device token
  │ POST /api/pair/poll         │
  │   {code, secret}            │
  │───────────────────────────▶ │
  │ ◀──── {deviceToken} ─────── │ single use, then discarded
```

Three properties carry the security, and they are why an 8-character code is enough:

1. **The code is inert.** Claiming it requires the admin credential. Guessing a code gets
   you nothing unless you are already the admin.
2. **The `secret` never enters the QR.** It stays in the watch's memory and is what
   authorises the poll, so a code read over your shoulder still cannot fetch a token.
3. **A device token is not `AUTH_TOKEN`.** It opens `/api/usage` and `/api/heartbeat` and
   nothing else. Lose a watch and you revoke one device from `/setup`; you do not rotate
   anything.

The QR encodes a *URL* rather than raw pairing data for a practical reason: iOS Safari has
no `BarcodeDetector`, so a scanner inside the web page would have been broken on the one
device that has to scan it. The phone's own camera reads the link, Safari opens it, and the
cookie you already have finishes the job. If the camera will not cooperate, the 8-character
code is printed under the QR and `/setup` takes it typed.

Unknown, expired, unclaimed and wrong-secret codes all answer with the same `404`, so the
poll endpoint cannot be used as an oracle.

---

## API

| Route | Auth | |
|---|---|---|
| `GET /healthz` | none | Liveness. Zero I/O, leaks nothing. |
| `GET /api/usage` | admin **or** device | The snapshot the watch fetches |
| `GET /api/heartbeat` | admin **or** device | Freshness, per-provider state, last error, and whether each vendor CLI is installed |
| `POST /api/session` | the token itself | What the sign-in form posts to; returns the session cookie |
| `POST /api/refresh` | admin | Nudges the poll loop; joins an in-flight request |
| `GET /setup` | admin | Sign-in and device management. A browser gets a sign-in form on 401; everything else gets JSON |
| `POST /api/login/:provider/start` · `/complete` · `GET /status` | admin | Drives the vendor CLI |
| `GET /api/devices` · `DELETE /api/devices/:id` | admin | List and revoke paired watches |
| `GET /pair?c=CODE` | admin | What the phone's camera opens; claims a code |
| `POST /api/pair/start` | none | Rate-limited. Mints an inert code. |
| `GET /api/pair/qr?c=CODE` | none | The QR image for a code |
| `POST /api/pair/poll` | the code's `secret` | Where the watch collects its device token |

Tokens travel as `Authorization: Bearer <token>` or `X-Auth-Token`. `/setup` also accepts
`?t=<token>` once, swaps it for a cookie and strips it from the URL. Failed attempts are
rate limited per IP — the subdomain is public and will be scanned.

**`/healthz` deliberately says nothing about provider health.** If it did, an Anthropic
outage would mark the container unhealthy and Coolify would restart it in a loop while the
app was working perfectly.

---

## The four traps

Both usage endpoints are private and unversioned. These are the non-obvious rules, each
pinned by a test:

| | |
|---|---|
| **Claude sends `utilization`**, falling back to `used_percentage` | It never sends `used_percent`. Decoding only that name yields *no Claude data at all* |
| **Claude reset timestamps** are seconds *or* milliseconds, split at `> 1e10` | Strictly greater-than, so exactly `1e10` means seconds |
| **Codex `reset_at`** is unconditionally Unix seconds | Applying Claude's rule mis-scales anything above `1e10`. Two separate decoders on purpose |
| **Codex classifies windows by duration, not position** | `primary_window` is *not* guaranteed to be the 5-hour one. The positional fallback applies only to an unrecognised duration |

Plus: non-finite input clamps to 0 (a naive `min/max` would render `nan%`), a missing
window is not 0% remaining, and a missing `plan_type` means the schema moved.

### "Never runs prompts" — enforced, not promised

Two tests make it mechanical rather than a claim in a README: the set of hostnames
reachable from `src/` must equal the documented inventory, and no source file may mention
an inference endpoint. A third asserts no 8-character slice of the auth token appears in
any response body.

Every external host QuotaPets can reach: `api.anthropic.com`, `chatgpt.com` (usage) and
`platform.claude.com`, `auth.openai.com` (token refresh of our own grant).

---

## The watch app

```bash
cp Secrets.xcconfig.example Secrets.xcconfig   # your server URL — and nothing else
brew install xcodegen && xcodegen generate && open QuotaPets.xcodeproj
```

`Secrets.xcconfig` and the generated `.xcodeproj` are both gitignored. The xcconfig holds
`QUOTAPETS_API_URL` only; the token arrives by QR pairing, so no credential is ever
compiled into the bundle and rotating `AUTH_TOKEN` never means rebuilding the app.

**Mascots are drawn in code**, not shipped as images — Claude is a radiating spark whose
arms are the gauge, Codex a terminal window whose cursor is the pulse. In both cases the
form *is* the expression mechanism, so nothing is bolted on to show mood. As quota drains,
Claude's crown wilts (the top arms collapse while the lower ones hold it up) and Codex's
cursor slows from 0.45s to 3s while its glow fades to nothing.

Pressure comes from the *tighter* window — `min(fiveHour, weekly)` — and the UI marks which
one, so a tired pet is explainable.

Two Apple constraints shaped this and are worth knowing before changing it:

- **Complications get 75 timeline reloads a day**, about one per 19 minutes, and only
  redraw when told to. The app reloads them on every new snapshot, and while it is closed
  it wakes itself every 20 minutes (background app refresh) to fetch one — three wakes an
  hour, 72 reloads a day. The timeline carries a single entry; the countdown stays alive
  through `Text(timerInterval:)`, which advances with no code running and no budget spent.
- **A WidgetKit complication is a one-way door.** Once shipped, the system permanently
  stops calling ClockKit timeline APIs.

⚠️ A free Apple ID expires provisioning every 7 days, so the watch app dies weekly until
rebuilt. For something you actually want on your wrist the $99/yr program is effectively
required. App Groups — used to share the snapshot with the widget — *do* work on a free
Personal Team.

---

## Testing

```bash
npm test                              # server: 137 tests
cd QuotaPetsShared && swift test      # watch core: 26 tests, runs on Linux too
```

The Swift package is Foundation-only on purpose: it builds and tests without a Mac, so the
mascot and presentation logic stays verifiable in CI. SwiftUI, WidgetKit and the Xcode
project still require macOS and have **not** been compiled — expect to fix compile errors
on the first build.

---

## If something looks wrong

| Symptom | |
|---|---|
| `{"error":"unauthorized"}` in a browser | You are on an `/api/*` route. Person-facing pages (`/setup`, `/pair`) serve a sign-in form instead. |
| `[claude] cli: claude NOT FOUND on PATH` at startup | The image was not built from this Dockerfile — see the Coolify warning above. |
| `[claude] notAuthenticated` on repeat | Genuinely not signed in. Open `/setup` and connect. If the startup line above also appeared, fix that first: they look the same from the poll loop but are different problems. |
| `503 cli_not_found` from Connect | Same cause. The server stays up and says so rather than crashing. |
| `[claude login] process exited (1)` and no sign-in link | The CLI started and refused its arguments. Set `DEBUG_LOGIN=1` and retry to see the CLI's own message. Both invocations are pinned by `test/login.test.ts` and documented in [`docs/provider-research.md` §6.1](docs/provider-research.md) — these are undocumented interfaces and a vendor update can move them. |
| Signed in but the cookie will not stick | The session cookie is `Secure` over HTTPS. Over plain `http://` it is not set as `Secure`, so local development works — but a proxy that terminates TLS must forward `X-Forwarded-Proto`. |

## Known limitations

- **The watch UI has never been compiled.** Everything under `Apps/` was written without a
  Mac. The server, and the Foundation-only Swift core it shares with the watch, are tested;
  the SwiftUI layer is not.
- The Claude programmatic login uses SDK control-protocol subtypes marked `@internal` in
  the vendor SDK. They work and are what first-party clients use, but carry no stability
  guarantee. If a release breaks them, the fallback is a one-off
  `docker exec <container> claude auth login` — the credential lands in the same place.
- Image is ~700 MB because both vendor CLIs ship large native binaries. They are only
  needed for sign-in; this was a deliberate trade for a one-step setup.
- Alpine is the base because Codex publishes **only** musl Linux artifacts.
- Pairing state lives in memory, so a restart mid-pairing means starting the 2-minute
  window again. Paired devices themselves are on disk and survive.

---

## Contributing and security

- [`CONTRIBUTING.md`](CONTRIBUTING.md) — how to run the two test suites and what the review
  bar is.
- [`SECURITY.md`](SECURITY.md) — the token model, what is stored where, and how to report
  something privately. This project holds two providers' OAuth tokens; please read it
  before filing a public issue about one.

## Attribution

Usage-fetching concepts are ported from [Orca](https://github.com/stablyai/orca) (MIT).
Every ported rule is listed with its originating file and line in
[`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md).

Licensed under the [MIT License](LICENSE).
