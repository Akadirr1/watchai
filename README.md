# QuotaPets

Your Claude and Codex subscription quota, on your wrist, as a mascot that visibly runs out
of energy as you run out of quota.

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
                                        │  HTTPS + token
                                        ▼
                              Apple Watch (independent watchOS app)
```

No iPhone app. No Mac. watchOS apps have been able to run independently and reach the
network on their own since watchOS 6.

---

## Why it is built this way

The project kept snagging on one question: **who holds the credential?**

Native iOS login turned out to be blocked — neither vendor offers public client
registration, so any native flow would have to send the vendor's own CLI `client_id`, and
the consent screen would read "Claude Code" while a third-party app took the token. That
finding is recorded in [`docs/provider-research.md`](docs/provider-research.md) and still
stands.

So QuotaPets **implements no OAuth at all**. Sign-in starts the real vendor CLI inside the
container, relays the URL it prints, and hands back whatever you paste. The consent screen
is honest, because it really is Claude Code / Codex asking.

The container keeps its **own** credential in its own config directory. That is what makes
it safe to refresh tokens here: refresh-token rotation can't strand anyone else's copy. An
earlier design that mounted the host's `~/.claude` would have broken whatever else on that
machine was using it.

---

## Running it

### Coolify

1. New Resource → Application → your repository → **Dockerfile** build pack.
2. Environment variable: `AUTH_TOKEN` = output of `openssl rand -hex 32`. Turn *off*
   "Build Variable" so it isn't baked into an image layer.
3. Domains → your subdomain, Force HTTPS on.
4. Deploy, then open `https://<your-domain>/setup?t=<AUTH_TOKEN>` and connect each account.

**Optional but recommended:** Persistent Storage → Add, destination `/data`. Without it a
redeploy starts a fresh container and you sign in again. Nothing else needs a volume.

### Locally

```bash
npm install
AUTH_TOKEN=$(openssl rand -hex 32) DATA_DIR=./tmp npm run dev
```

### Configuration

| Variable | Default | |
|---|---|---|
| `AUTH_TOKEN` | — | **Required**, min 32 chars. The process refuses to start without it. |
| `PORT` | `3000` | |
| `DATA_DIR` | `/data` | Snapshot cache |
| `CLAUDE_CONFIG_DIR` | `/data/claude` | Where the Claude CLI keeps its credential |
| `CODEX_HOME` | `/data/codex` | Where the Codex CLI keeps its credential |
| `POLL_INTERVAL_SEC` | `60` | |
| `CODEX_STAGGER_SEC` | `30` | So the two providers never fire in the same instant |

---

## API

| Route | Auth | |
|---|---|---|
| `GET /healthz` | no | Liveness. Zero I/O, leaks nothing. |
| `GET /api/usage` | yes | The snapshot the watch fetches |
| `GET /api/heartbeat` | yes | Freshness, per-provider state, last error |
| `POST /api/refresh` | yes | Nudges the poll loop; joins an in-flight request |
| `GET /setup` | yes | Sign-in page — the only HTML served |

Auth is one shared token: `Authorization: Bearer <token>` or `X-Auth-Token`. `/setup` also
accepts `?t=<token>` once, swaps it for a cookie and strips it from the URL.

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
cp Secrets.xcconfig.example Secrets.xcconfig   # fill in your URL and AUTH_TOKEN
brew install xcodegen && xcodegen generate && open QuotaPets.xcodeproj
```

`Secrets.xcconfig` is gitignored.

**Mascots are drawn in code**, not shipped as images — Claude is a radiating spark whose
arms are the gauge, Codex a terminal window whose cursor is the pulse. In both cases the
form *is* the expression mechanism, so nothing is bolted on to show mood. As quota drains,
Claude's crown wilts (the top arms collapse while the lower ones hold it up) and Codex's
cursor slows from 0.45s to 3s while its glow fades to nothing.

Pressure comes from the *tighter* window — `min(fiveHour, weekly)` — and the UI marks which
one, so a tired pet is explainable.

Two Apple constraints shaped this and are worth knowing before changing it:

- **Complications get 75 timeline reloads a day**, about one per 19 minutes. The timeline
  carries a single entry; the countdown stays alive through `Text(style:.timer)`, which
  advances with no code running and no budget spent. There is no alternative mechanism.
- **A WidgetKit complication is a one-way door.** Once shipped, the system permanently
  stops calling ClockKit timeline APIs.

⚠️ A free Apple ID expires provisioning every 7 days, so the watch app dies weekly until
rebuilt. For something you actually want on your wrist the $99/yr program is effectively
required. App Groups — used to share the snapshot with the widget — *do* work on a free
Personal Team.

---

## Testing

```bash
npm test                              # server: 94 tests
cd QuotaPetsShared && swift test      # watch core: 26 tests, runs on Linux too
```

The Swift package is Foundation-only on purpose: it builds and tests without a Mac, so the
mascot and presentation logic stays verifiable. SwiftUI, WidgetKit and the Xcode project
still require macOS and have **not** been compiled — expect to fix compile errors on the
first build.

---

## Known limitations

- The Claude programmatic login uses SDK control-protocol subtypes marked `@internal` in
  the vendor SDK. They work and are what first-party clients use, but carry no stability
  guarantee. If a release breaks them, the fallback is a one-off
  `docker exec <container> claude auth login` — the credential lands in the same place.
- Image is ~700 MB because both vendor CLIs ship large native binaries. They are only
  needed for sign-in; this was a deliberate trade for a one-step setup.
- Alpine is the base because Codex publishes **only** musl Linux artifacts.

---

## Attribution

Usage-fetching concepts are ported from [Orca](https://github.com/stablyai/orca) (MIT).
Every ported rule is listed with its originating file and line in
[`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md).
