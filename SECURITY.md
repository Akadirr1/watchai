# Security

QuotaPets brokers OAuth tokens for two AI providers, so it is worth being explicit about
what it holds, where, and why.

## Reporting a vulnerability

Open a [GitHub security advisory](https://github.com/Akadirr1/watchai/security/advisories/new)
rather than a public issue. Please include a reproduction and what you believe the impact
is. This is a personal project, so expect a best-effort response rather than an SLA.

## What the server holds

| Secret | Where | Notes |
|---|---|---|
| Claude OAuth credential | `$CLAUDE_CONFIG_DIR/.credentials.json`, mode `0600` | Written by the real `claude` CLI, not by QuotaPets |
| Codex OAuth credential | `$CODEX_HOME/auth.json`, mode `0600` | Written by the real `codex` CLI |
| `AUTH_TOKEN` | Environment only | Never written to disk by QuotaPets |
| Device tokens | `$DATA_DIR/devices.json`, mode `0600` | One per paired watch, revocable individually |

The container keeps its **own** OAuth grant, separate from any CLI credential elsewhere on
the host. That separation is deliberate: refreshing a token rotates the refresh token, and
rotating one that another process owns can strand its copy — under OAuth 2.1 reuse
detection it can invalidate the whole grant family.

## Two token tiers

- **`AUTH_TOKEN`** is the admin credential. It opens `/setup`, device management and
  pairing. Treat it like a password.
- **Device tokens** are issued to paired watches. They open `/api/usage` and
  `/api/heartbeat` only — never `/setup`, never pairing, never device management. Losing a
  watch means revoking one device, not rotating `AUTH_TOKEN`.

## What never leaves the server

No response body contains a token, a token prefix, or a fingerprint of one. A test asserts
that no 8-character slice of the configured token appears in any response.

Provider responses are never logged — they carry plan type and account shape. On a schema
change only the *names* of the top-level keys are logged, never the values.

By default the vendor CLI's own output during sign-in is **not** logged either, because
device-flow progress text can contain the verification URL and user code. Set
`DEBUG_LOGIN=1` to see it while debugging; do not leave it on.

## What QuotaPets does not do

It runs no prompts. Two tests enforce this mechanically rather than by promise: the set of
hostnames reachable from `src/` must equal a documented inventory, and no source file may
mention an inference endpoint.

It also implements no OAuth flow of its own — sign-in drives the vendors' real CLIs.

## Known trade-offs

- **`/api/pair/start` is unauthenticated.** It has to be: the watch has no credential yet.
  It is rate limited, and the code it returns is worthless without an authenticated user
  claiming it.
- **`src/credentials/refresh.ts` carries Claude's public OAuth `client_id`** as a fallback.
  Public clients hold no secret, so this leaks nothing — but it does mean the consent
  screen reads "Claude Code". That is inherent to driving the vendor's own client and is
  documented in `docs/provider-research.md` §4.3.
- **The Claude programmatic-login API is marked `@internal`** in the vendor SDK. It works
  and is what first-party clients use, but carries no stability guarantee.
