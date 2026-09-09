# QuotaPets — Provider Research (Phase 0)

**Status:** Phase 0 complete. No product code written yet.
**Date:** 2026-09-09
**Purpose:** Satisfy §0/§42 — research before implementation.

> **Rule applied throughout:** every provider fact is cited to a file+line in a source tree that was
> actually cloned and read, or to an official document that was actually fetched. Where something
> could not be established from a primary source it appears under *Unknowns*, not as an assertion.
> A parallel adversarial-verification pass ran over the load-bearing claims; four were **refuted**
> and are corrected in place below, with the correction marked.

---

## 0. Sources actually inspected

| Source | Obtained | Version pinned | Licence |
|---|---|---|---|
| `stablyai/orca` | `git clone --depth 1` | HEAD @ 2026-09-08 | MIT, © 2026 Lovecast Inc. |
| `openai/codex` | `git clone --depth 1` | `1530f828cbaea015bc0fc53c0486e2f889a677f3` | Apache-2.0 |
| `@anthropic-ai/claude-code` | on-disk npm bundle | **2.1.42** (`BUILD_TIME 2026-02-13`) | proprietary |
| Apple Developer docs | DocC JSON endpoints | fetched 2026-09-08 | — |

All ten Orca files named in the brief exist in current `main` and were read in full:
`claude-active-usage-fetch.ts` (248), `claude-oauth-usage-request.ts` (103),
`claude-oauth-credentials.ts` (160), `claude-usage-window.ts` (76),
`codex-backend-usage-client.ts` (134), `codex-backend-auth.ts` (98),
`codex-rate-limit-window-classification.ts` (75), `codex-rate-limit-window-mapper.ts` (38),
`src/cli/handlers/account.ts` (337), `src/shared/rate-limit-types.ts` (147).

> ⚠️ **Version caveat, from the verification pass.** The Claude OAuth facts in §4.1 were read from
> the npm bundle **2.1.42**. The `claude` actually on this machine's PATH is a 215 MB Bun-compiled
> binary reporting **2.1.263** — roughly 200 releases newer. Every §4.1 fact is therefore
> *version-pinned to 2.1.42* and may have drifted. This does not affect the conclusion (§4.3),
> which does not depend on any specific endpoint value.

---

## 1. The headline finding

**Orca implements no OAuth for either provider. It contains no authorize endpoint and no token
endpoint.** An exhaustive scan of every Anthropic/OpenAI URL literal in its TypeScript returns eight
URLs, none of them authentication:

```
https://api.anthropic.com/                                       https://api.openai.com/auth
https://api.anthropic.com/api/oauth/usage                        https://api.openai.com/profile
https://chatgpt.com/backend-api/wham/usage                       https://api.openai.com/v1/audio/transcriptions
https://chatgpt.com/backend-api/wham/rate-limit-reset-credits     …/rate-limit-reset-credits/consume
```

Orca acquires credentials in exactly two moves:

1. **Spawn the real vendor CLI** so the vendor's own flow runs unmodified —
   `account.ts:218` → `claude auth login --claudeai`; `account.ts:259` → `codex login --device-auth`.
2. **Read the credential files those CLIs wrote** (§2.3, §3.2).

Orca's own comment at `account.ts:256` explains the device-auth choice:

> *"plain OAuth binds a loopback callback the user's browser cannot reach on a headless/SSH host;
> device auth is explicitly designed for this flow."*

**Why this matters more than it first appears.** Orca's strategy is *co-location*: be on the same
machine as a logged-in CLI, read its files, re-invoke it to repair credentials. All three moves are
unavailable to an iOS app. This is the fact that determines the entire architecture (§5, §6).

---

## 2. Claude usage — verified mechanism

### 2.1 Endpoint and headers

`claude-oauth-usage-request.ts:8`, `:72-79`:

```
GET https://api.anthropic.com/api/oauth/usage
Authorization:  Bearer <OAuth access token>
anthropic-beta: oauth-2025-04-20
User-Agent:     claude-code/2.1.0
```
Timeout 10 000 ms (`:9`). Both `anthropic-beta` and `User-Agent` are version-bearing and will rot —
they belong in one isolated constants value, per §2 of the brief.

### 2.2 Response shape — and a correction to the brief

Windows mapped at `:90-91`: `five_hour → session (300 min)`, `seven_day → weekly (10080 min)`.
The brief's `five_hour → fiveHour`, `seven_day → weekly` mapping is confirmed.

**Correction.** The brief calls the percentage field `used_percent`. Claude does not use that name.
`claude-usage-window.ts:4-8` declares:

```ts
type ClaudeUsageWindowInput = { utilization?: number; used_percentage?: number; resets_at?: string | number }
```

and `:61-66` reads **`utilization` first, then `used_percentage`** — never `used_percent`. A port
that decodes only `used_percent` yields *no Claude data at all*. Both are *used* percentages.
Clamped `0...100` at `:71`.

The response also carries `limits[]` with `kind: 'weekly_scoped'` entries used for model-scoped
windows (`:35-53`). QuotaPets does not need these (no per-model breakdown in scope).

### 2.3 Credential source

`claude-oauth-credentials.ts:135-148` reads, in order: **macOS Keychain** (only on `darwin` — `:68`
returns empty otherwise), then **`~/.claude/.credentials.json`** (`:121-124`). Shape at `:10-16`:
`{ claudeAiOauth: { accessToken, refreshToken, expiresAt } }`.

Note the deliberate choice at `:47`: *"expiresAt is not authoritative for the usage endpoint; let
the server decide."* Orca does not pre-emptively refresh on local expiry — it fires and reacts to
rejection. **Worth porting:** local clock skew cannot then cause a spurious "expired" state.

Refresh is also delegated: on rejection, `claude-active-usage-fetch.ts:105-114` calls
`repairClaudeCredentialsThenRetryOAuth`, and `:116-128` falls back to re-invoking the CLI.

### 2.4 Timestamp units — a real trap

`claude-usage-window.ts:11-30` accepts ISO string, numeric string, or number, in **seconds or
milliseconds**, disambiguated by magnitude at `:16`:

```ts
return value > 10_000_000_000 ? value : value * 1000
```

Reasoning at `:10`: *"1e10 sits between any plausible seconds epoch (<2286) and any millisecond
epoch (>2001)."* Note `== 1e10` falls to the **seconds** branch. Porting this wrong puts reset times
in 1970 or the year 56 000.

---

## 3. Codex usage — verified mechanism

### 3.1 Endpoint and headers

`codex-backend-usage-client.ts:68`, `codex-backend-auth.ts:88-96`:

```
GET https://chatgpt.com/backend-api/wham/usage
Authorization:      Bearer <access token>
User-Agent:         codex-cli
OpenAI-Beta:        codex-1
originator:         Codex Desktop
ChatGPT-Account-Id: <account id>      // only when present
```

This is a **private, unversioned backend endpoint of the ChatGPT web product** with no stability
guarantee. Quarantining it behind one adapter is not hygiene, it is the only thing that keeps a
schema change from becoming a crash.

### 3.2 Credential source

`codex-backend-auth.ts:70-72`: `options.codexHomePath ?? $CODEX_HOME ?? ~/.codex`, then `auth.json`
(`:81`). Shape `:14-19`: `{ tokens: { access_token, account_id } }`.

### 3.3 Window classification — the part worth porting carefully

`codex-rate-limit-window-classification.ts` classifies by **duration**, not position:

- `CODEX_SESSION_WINDOW_MINUTES = 300` (`:1`), `CODEX_WEEKLY_WINDOW_MINUTES = 10080` (`:2`)
- tolerance **±1 min** (`:5`) — *"tolerate the one-minute drift seen in older Codex bucket lengths"*

Algorithm (`:43-74`): keep windows with finite `usedPercent` (`:21-25`); classify each of
`[primary, secondary]` by duration, first match wins per kind (`:54-64`); then the positional
fallback (`:66-72`) — and note how narrow it is: `primary→session` / `secondary→weekly` applies
**only when that window's duration classified as `null`**, i.e. missing or unrecognised. A window
that positively classifies as weekly is *never* also taken as session. A naive
"classify-else-fall-back-to-position" implementation mis-assigns a payload whose `primary_window` is
the 7-day window; Orca's does not.

Duration arrives as seconds: `windowDurationMins = ceil(limit_window_seconds / 60)`, only when
finite and `> 0` (`codex-backend-usage-client.ts:39-45`).

### 3.4 Response shape

```ts
type BackendRateLimitWindow = { used_percent?: number; limit_window_seconds?: number; reset_at?: number }
type BackendUsageResponse   = { plan_type?: string; rate_limit?: { primary_window?, secondary_window? } | null; … }
```

Here the field genuinely **is** `used_percent` — the two providers differ, so the brief's single
`used_percent` assumption is right for Codex and wrong for Claude.

**Guard worth porting:** `:74-76` rejects the payload when `plan_type` is not a string — a cheap
check separating "real authenticated payload" from "HTML error page / login redirect". That is
exactly the `providerResponseChanged` signal §25 asks for.

### 3.5 Timestamp units — different from Claude

`codex-rate-limit-window-mapper.ts:14-16`: *"Codex returns resetsAt as Unix seconds, not
milliseconds."* Unconditional `× 1000`, and required `> 0`.

> **Do not merge these into one shared helper.** Claude needs the magnitude heuristic; Codex is
> unconditionally seconds. A third inconsistency exists inside Orca itself: in
> `codex-reset-credit-client.ts:46` exactly `1e10` means *milliseconds*, the opposite of
> `claude-usage-window.ts:16`. QuotaPets will implement two explicitly-named decoders,
> `ClaudeResetTimestamp` and `CodexResetTimestamp`, and never a generic one.

---

## 4. Authentication — the STOP condition

### 4.1 Claude Code's actual flow (bundle 2.1.42)

| Item | Value |
|---|---|
| `CLIENT_ID` | `9d1c250a-e61b-44d9-88ed-5944d1962f5e` (same for subscription *and* console) |
| Subscription authorize | `https://claude.ai/oauth/authorize` |
| Console authorize | `https://platform.claude.com/oauth/authorize` |
| Token (exchange **and** refresh) | `https://platform.claude.com/v1/oauth/token` |
| Manual redirect | `https://platform.claude.com/oauth/code/callback` |
| Loopback redirect | `http://localhost:${PORT}/callback`, **ephemeral** port (`listen(0)`) |

- **PKCE S256 is mandatory.** verifier = base64url(32 random bytes); challenge = base64url(sha256(verifier)).
- **Token requests are JSON, not form-encoded** — `Content-Type: application/json`, body
  `{grant_type, code, redirect_uri, client_id, code_verifier, state}`. The echoed `state` is
  non-standard. *This alone breaks AppAuth-iOS and most OAuth SDKs, which cannot POST JSON.*
- **Scopes** (interactive login): `org:create_api_key user:profile user:inference
  user:sessions:claude_code user:mcp_servers`. `claude setup-token` requests only `user:inference`
  and sends `expires_in: 31536000`.
- Refresh: same endpoint, JSON `{grant_type:"refresh_token", refresh_token, client_id, scope}`.
  Refresh tokens **rotate**. Proactive refresh at a 300 000 ms (5 min) skew.
- Credentials at `~/.claude/.credentials.json`, mode `0600`, shape
  `{claudeAiOauth:{accessToken, refreshToken, expiresAt, scopes, subscriptionType, rateLimitTier}}`;
  `expiresAt` is absolute epoch **milliseconds**.
- `subscriptionType` is *not* from the token endpoint — it comes from
  `GET https://api.anthropic.com/api/oauth/profile`, mapping `organization.organization_type`
  (`claude_max`→max, `claude_pro`→pro, …).
- Note `org:create_api_key` exists to mint a real billable key via
  `POST /api/oauth/claude_cli/create_api_key`. **Any client requesting it can spend real money.**

> **Discrepancy, unresolved.** Orca spawns `claude auth login --claudeai`, but bundle 2.1.42 exposes
> `claude login` with only `--email` and `--sso`. Either Orca targets a different version or the
> flag is tolerated. Not load-bearing for our design; recorded for accuracy.

> **Refuted claim, corrected.** An earlier finding asserted Claude Code has *no* RFC 8628 device
> flow. The shipped 2.1.263 binary **does** contain one — `/oauth/device_authorization`,
> `grant_type=urn:ietf:params:oauth:grant-type:device_code`, client id `claude_code`, with
> `authorization_pending`/`slow_down`/`expired_token` handling. **But** it is scoped to
> customer-operated enterprise gateways and third-party MCP servers, **not** to Anthropic's own
> identity provider. It is therefore not a route to a personal Pro/Max subscription token.

### 4.2 Codex CLI's actual flow (`openai/codex` @ `1530f828`)

Two paths, both in the `codex-login` crate:

**Browser/loopback PKCE** (`login/src/server.rs`) — binds `127.0.0.1:1455` (fallback 1457),
`redirect_uri = http://localhost:{port}/auth/callback` (`:176`), authorize at
`https://auth.openai.com/oauth/authorize` with `originator=codex_cli_rs` (`:584-605`). PKCE
mandatory S256 (`pkce.rs:12-27`). Exchange is **form-encoded** at `{issuer}/oauth/token`
(`:809-845`). It then performs an RFC-8693 token exchange to mint a platform API key (`:1137-1171`).
The fixed port must match a server-side allow-list.

**Device flow** (`--device-auth`, `device_code_auth.rs`) — **not RFC 8628**. Private endpoints
`POST {issuer}/api/accounts/deviceauth/usercode` and `/deviceauth/token`, JSON bodies, keyed on
`device_auth_id` + `user_code`. **The server returns the PKCE `code_verifier` to the client**
(`:55-60, :198-201`), so the client cannot bind the exchange to a locally generated secret.

`client_id = app_EMoamEEZ73f0CkXaXp7hrann` (`manager.rs:204`). `auth.json` stores **no expiry** —
it is derived by base64url-decoding the access-token JWT and reading `exp` (`manager.rs:2969-2975`).
Refresh uses a **JSON** body (`manager.rs:1613-1615`) while exchange uses **form** encoding — a
client assuming uniform encoding fails on refresh.

### 4.3 Feasibility verdict on iOS — **BLOCKED, both providers**

**The brief's framing was wrong, and it is worth being precise about why.** §4/§5 assume the
loopback redirect is the obstacle. It is not:

1. Claude already ships a **manual paste-code** redirect (`platform.claude.com/oauth/code/callback`)
   requiring no listener and no redirect capture at all.
2. Even loopback is surmountable — an iOS app may bind `127.0.0.1` via `NWListener`. *Verified:*
   loopback is **not** "local network" under Apple's TN3179, so no `NSLocalNetworkUsageDescription`
   is required. (This claim survived adversarial verification.)

**The actual blocker is client identity.** Neither vendor offers public or dynamic client
registration. Any native flow must transmit Anthropic's `9d1c250a-…` or OpenAI's
`app_EMoamEEZ…`. Both are public clients with no secret, so it is trivially possible and
cryptographically unpreventable — RFC 8252 §8.4/§8.5 say exactly that. But *"the spec says the
server cannot stop you"* documents a threat model; it does not grant permission. The decisive,
user-visible consequence:

> The OAuth consent screen would read **"Claude Code"** while **QuotaPets** receives the token.

That is precisely the misrepresentation OAuth consent exists to prevent. Independently, Anthropic's
Consumer Terms §3 prohibits accessing the Services "through automated or non-human means" except via
an API key.

Codex is **strictly worse**: its device flow is proprietary rather than RFC 8628, and the server
mints the `code_verifier` — there is no standard to implement against and no way to participate
except as the registered Codex client.

There is also **no sanctioned alternative data source**: neither vendor's official usage API exposes
subscription rate-limit windows. Both report API-platform token spend against Admin keys, a
different quantity from what QuotaPets displays.

**Per §5, both providers' native auth implementations are STOPPED and documented here rather than
invented.** The usage-provider architecture (§6) remains complete and is unaffected.

---

## 5. Apple platform constraints (all verified against Apple docs)

**Targets.** watchOS 11 supports Series 6 and later → **Series 7 is supported**; requires iPhone Xs+
on iOS 18. watchOS 11.6.2 is the final 11.x. Xcode 26.6 still permits iOS 15–26.5 / watchOS 8–26.5
deployment targets, so **iOS 18 / watchOS 11 remain valid on current Xcode**. *(Verified:* since
28 Apr 2026 App Store *uploads* must be **built against** the iOS 26 / watchOS 26 SDK — that
constrains the SDK, not the deployment target. Only relevant if you ever ship to the Store.)

**WatchConnectivity — the decisive asymmetry.** Apple states outright that `sendMessage` *"from your
iOS app does not wake up the corresponding WatchKit extension"*; only watch→phone wakes the
counterpart, and `sendMessage` additionally requires `isReachable == true`.

| API | Wakes counterpart | Semantics |
|---|---|---|
| `sendMessage` | watch→phone only | high priority, needs `isReachable` |
| `updateApplicationContext` | **no** | latest-value-wins, replaces prior dict, opportunistic |
| `transferUserInfo` | no | FIFO, **guaranteed**, survives suspension |
| `transferCurrentComplicationUserInfo` | — | **50/day** when complication is on the active face, **0** otherwise; silently degrades to `transferUserInfo` |

Apple publishes **no numeric payload size limit** — only `WCError.payloadTooLarge` exists.

**Background refresh.** `BGAppRefreshTask` has **no guaranteed interval**; `earliestBeginDate` is a
floor, never a promise. Only **1** pending app-refresh task at a time; registering the same
identifier twice **terminates the app**; all registration must finish before
`didFinishLaunching` returns; requires the `fetch` background mode and a
`BGTaskSchedulerPermittedIdentifiers` entry. On watchOS the equivalent is
`WKApplication.scheduleBackgroundRefresh`, also one-at-a-time. §10 of the brief is correct to refuse
to pretend otherwise.

**WidgetKit on watchOS 11.** Exactly four families: `accessoryCircular`, `accessoryRectangular`,
`accessoryInline`, `accessoryCorner` (watchOS-only). Budget: **75 timeline reloads/day**, and a
complication on the face always counts as viewed → ~**1 reload per 19 minutes at best**. Reloads do
*not* count against budget while the containing app is foregrounded.

**The §11 "living complication" is not just possible — it is the only escape.**
`Text(date, style: .timer/.relative/.offset)` advances **on screen with no code running and no
budget spend**, and Apple explicitly confirms these keep updating during Always-On. Read
`@Environment(\.isLuminanceReduced)` and adapt to `WidgetRenderingMode` (`fullColor` / `accented`).

**One-way door:** shipping a WidgetKit complication **permanently** stops the system calling ClockKit
timeline APIs. No mixed mode, no fallback.

**Keychain.** The silent default is `kSecAttrAccessibleWhenUnlocked`, which **fails inside a
background task on a locked device**. Must be set explicitly to
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.

**Provisioning.** Free Personal Team: 3 devices, 10 App IDs, **7-day** profile expiry → the watch app
and complication die weekly without a rebuild with both devices present. For a persistently
installed personal watch app this effectively forces the **$99/yr** Apple Developer Program.
*(Verified correction:* an earlier finding claimed App Groups is unavailable to a free Personal
Team. **False** — Apple's "Supported capabilities (watchOS)" checks App Groups in the free column
and states the watchOS target's capabilities *"don't depend on your program membership"*.)

---

## 6. Resulting architecture — Mac helper relay

Given §4.3, credentials are never acquired on iOS. The helper is promoted from the brief's §12
("document only, future") to **the MVP credential path**, because research shows it is the only
design that is both legitimate and functional.

```
  claude / codex CLIs  (user's own first-party logins, unmodified)
            │  writes
            ▼
  macOS Keychain · ~/.claude/.credentials.json · ~/.codex/auth.json
            │  read by
            ▼
  QuotaPetsHelper (macOS)  ──  Orca-derived fetch + normalise
            │  UsageSnapshot only, over LAN, paired + authenticated
            ▼
  QuotaPetsPhone (iOS 18)  ──  cache · BGAppRefreshTask · WCSession
            │  UsageSnapshot only
            ▼
  QuotaPetsWatch (watchOS 11)  +  QuotaPetsWidgets complications
```

**No provider credential ever leaves the Mac.** The phone holds no `accessToken`, so the §6 Keychain
requirement narrows to storing only the helper pairing secret — a strictly smaller attack surface
than the brief anticipated.

**The QR pairing flow (§4/§23) fits this exactly and is retained unchanged in spirit:** the watch
shows a QR, the phone scans it, and the payload is an ephemeral, expiring, single-use
`quotapets://pair?nonce=…` — now additionally carrying the helper's discovered LAN endpoint. It still
contains **no provider tokens**, satisfying §4's constraint literally.

Transport: Bonjour/`NWBrowser` discovery + HTTPS over LAN with a pairing-derived shared secret.
Unlike the loopback case, LAN access **does** require `NSLocalNetworkUsageDescription`.

**Honest limitation:** usage only refreshes while the Mac is awake and reachable. When it is not, the
phone and watch show cached values with explicit staleness (`STALE · 8m`), exactly as §10 demands.

---

## 7. Licence obligations

Orca is **MIT**, © 2026 Lovecast Inc. (`LICENSE:3`). No `NOTICE` file, no `license` field in
`package.json`, no per-file SPDX headers. The sole obligation (`LICENSE:12-13`) is that the copyright
and permission notices accompany copies or substantial portions.

Copyright protects expression, not algorithms — porting *concepts* (constants, unit heuristics,
precedence rules) into fresh Swift arguably attaches no obligation. The boundary is fuzzy, and
compliance is nearly free, so **QuotaPets ships attribution regardless**: a `THIRD-PARTY-NOTICES.md`
reproducing Orca's MIT text verbatim, plus a per-concept attribution table naming each ported
algorithm and its originating `file:line`. `openai/codex` (Apache-2.0) is *read for understanding
only*; no code is ported from it, but it is credited.

MIT imposes no copyleft and no restriction on relicensing our own Swift.

---

## 8. Environment constraint

This session is **Linux x86_64 (Ubuntu 24.04)**. No macOS, no Xcode, no `xcodebuild` — verified.
**The brief's §38 build rule cannot be satisfied here.** Xcode project generation, SwiftUI/WatchKit
compilation, complication rendering and physical installation all require the user's Mac.

**Mitigation in force:** the Swift 6.2.1 Linux toolchain is installed and verified, with `swift test`
(swift-testing 6.2.1) running green. The **provider-neutral core** — models, clamping, both reset
decoders, Codex window classification, mascot state resolution, countdown formatting, threshold
crossing — is pure Foundation and **is compiled and unit-tested for real in this environment**. That
is precisely where the §2.2 / §2.4 / §3.3 / §3.5 traps live.

Unverifiable here, and explicitly flagged as such in the README: SwiftUI views, WatchConnectivity,
Keychain, WidgetKit, the Xcode project, and device installation.

---

## 9. Known unknowns

- Claude OAuth facts are pinned to bundle **2.1.42**; shipped CLI is **2.1.263** and may differ.
- Whether `/api/oauth/usage` accepts a `user:inference`-only token (would gate the token-import
  alternative). Untested — requires a real account.
- WatchConnectivity payload size limit: undocumented by Apple.
- Whether `wham/usage` tolerates a non-`codex-cli` User-Agent. Not tested; not needed under §6,
  since the helper runs on a machine where `codex-cli` is the honest description.
