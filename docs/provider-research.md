# QuotaPets — Provider Research

**Status:** Phase 0 (research). No implementation code has been written yet.
**Date:** 2026-09-08
**Purpose:** Satisfy the "research before implementation" rule. This document records what was
verified against primary sources, what could not be verified, and what is therefore blocked.

> **Rule applied throughout:** every provider fact below is cited to a file and line in a source
> tree that was actually cloned and read, or to an official document. Where a fact could not be
> established from a primary source, it is listed under *Unknowns* rather than guessed at.

---

## 0. Sources actually inspected

| Source | How obtained | Licence |
|---|---|---|
| `stablyai/orca` | `git clone --depth 1 https://github.com/stablyai/orca` | MIT, © 2026 Lovecast Inc. |

### Orca files read in full

All ten files named in the brief exist in the current `main`. Line counts are from the clone:

| File | Lines | What it establishes |
|---|---|---|
| `src/main/rate-limits/claude-active-usage-fetch.ts` | 248 | Claude fetch orchestration + fallback ladder |
| `src/main/rate-limits/claude-oauth-usage-request.ts` | 103 | Claude usage endpoint, headers, response shape |
| `src/main/rate-limits/claude-oauth-credentials.ts` | 160 | Where Claude credentials are *read from* |
| `src/main/rate-limits/claude-usage-window.ts` | 76 | Claude window normalisation + timestamp units |
| `src/main/rate-limits/codex-backend-usage-client.ts` | 134 | Codex usage endpoint + response shape |
| `src/main/rate-limits/codex-backend-auth.ts` | 98 | Codex credential source + request headers |
| `src/main/rate-limits/codex-rate-limit-window-classification.ts` | 75 | Duration-based window classification |
| `src/main/rate-limits/codex-rate-limit-window-mapper.ts` | 38 | Codex window normalisation + timestamp units |
| `src/cli/handlers/account.ts` | 337 | How login is delegated |
| `src/shared/rate-limit-types.ts` | 147 | Orca's normalised model |

---

## 1. The single most important finding

**Orca does not implement OAuth for either provider. It does not contain a single authorize or
token endpoint.**

An exhaustive scan of every Anthropic/OpenAI URL literal in Orca's TypeScript sources returns
only these eight, none of which is an authentication endpoint:

```
https://api.anthropic.com/
https://api.anthropic.com/api/oauth/usage
https://api.openai.com/auth
https://api.openai.com/profile
https://api.openai.com/v1/audio/transcriptions
https://chatgpt.com/backend-api/wham/rate-limit-reset-credits
https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume
https://chatgpt.com/backend-api/wham/usage
```

Orca obtains credentials in exactly two ways:

1. **It shells out to the real vendor CLI to perform the login**, attaching it to the user's own
   terminal so the vendor's own OAuth flow runs unmodified —
   `src/cli/handlers/account.ts:218` spawns `claude auth login --claudeai`, and
   `src/cli/handlers/account.ts:259` spawns `codex login --device-auth`.
2. **It then reads the credential files those CLIs wrote** — see §2.3 and §3.2 below.

Orca's own comment at `src/cli/handlers/account.ts:256` explains the device-auth choice:

> *"plain OAuth binds a loopback callback the user's browser cannot reach on a headless/SSH host;
> device auth is explicitly designed for this flow."*

**Consequence for QuotaPets.** The brief's instruction "do not invent OAuth — Orca delegates to the
CLIs" is exactly correct, and it is a much sharper constraint than it first appears: Orca's
credential-acquisition strategy is *"be on the same machine as a logged-in CLI and read its files."*
That strategy has no iOS equivalent. iOS has no `claude` binary, no `codex` binary, no
`~/.claude/.credentials.json`, no `~/.codex/auth.json`, and no shared macOS Keychain. §4 addresses
what this means.

---

## 2. Claude usage — verified mechanism

### 2.1 Endpoint and headers

From `claude-oauth-usage-request.ts:8` and `:72-79`:

```
GET https://api.anthropic.com/api/oauth/usage

Authorization:   Bearer <OAuth access token>
anthropic-beta:  oauth-2025-04-20
User-Agent:      claude-code/2.1.0
```

Timeout is 10 000 ms (`:9`).

Both `anthropic-beta` and `User-Agent` are **version-bearing strings that will rot.** The brief's
instruction to isolate them is correct; in the Swift port they belong in one
`ClaudeProtocolConstants` value, not scattered across the adapter.

### 2.2 Response shape and the `utilization` subtlety

The response type is declared at `claude-oauth-usage-request.ts:19-26`, and the two windows we care
about are mapped at `:90-91`:

```ts
session: mapClaudeUsageWindow(data.five_hour,  300),    // 300 min  = 5 hours
weekly:  mapClaudeUsageWindow(data.seven_day,  10080),  // 10080 min = 7 days
```

So the mapping the brief asks for — `five_hour → fiveHour`, `seven_day → weekly` — is confirmed.

**Correction to the brief.** §2 of the brief describes the percentage field as `used_percent`. That
is not what Orca reads. `claude-usage-window.ts:4-8` declares the input as:

```ts
export type ClaudeUsageWindowInput = {
  utilization?: number
  used_percentage?: number
  resets_at?: string | number
}
```

and `:61-66` reads **`utilization` first, falling back to `used_percentage`** — never
`used_percent`. A Swift port that decodes only `used_percent` would silently produce *no* Claude
data. The port must accept both keys, in that precedence order.

Both are *used* percentages, consistent with the brief's "keep used as canonical" rule. The value is
clamped to `0...100` at `:71`.

### 2.3 Where the token comes from (and why it matters)

`claude-oauth-credentials.ts` reads, in order (`:135-148`):

1. **macOS Keychain**, and only on macOS — `:68` returns empty immediately unless
   `process.platform === 'darwin'`. It tries a config-dir-scoped entry, then a legacy entry
   (`:72-92`).
2. **`~/.claude/.credentials.json`** — path built at `:121-124`.

The file's shape is declared at `:10-16`:

```ts
type ClaudeCredentials = {
  claudeAiOauth?: {
    accessToken?: string
    refreshToken?: string
    expiresAt?: number
  }
}
```

Note the deliberate choice at `:47`:

> *"expiresAt is not authoritative for the usage endpoint; let the server decide."*

Orca does **not** pre-emptively refresh on local expiry; it fires the request and reacts to the
server's rejection. That is a good behaviour to port — local clock skew cannot cause a spurious
"expired" state.

**Refresh is also delegated.** When the token is rejected, `claude-active-usage-fetch.ts:105-114`
calls `repairClaudeCredentialsThenRetryOAuth(...)`, and `:116-128` falls back to
`fetchClaudeUsageViaCli(...)` — i.e. it re-invokes the Claude CLI. Orca never calls a token
endpoint itself.

### 2.4 Timestamp units — a real trap

`claude-usage-window.ts:11-30` handles `resets_at` that may be an ISO string, a numeric string, or a
number, in **either seconds or milliseconds**. The disambiguation is a magnitude test at `:16`:

```ts
return value > 10_000_000_000 ? value : value * 1000
```

with the reasoning at `:10`:

> *"1e10 sits between any plausible seconds epoch (<2286) and any millisecond epoch (>2001), so it
> distinguishes the two units without extra metadata."*

This heuristic must be ported verbatim in behaviour. Getting it wrong yields reset times in 1970 or
the year 56 000.

---

## 3. Codex usage — verified mechanism

### 3.1 Endpoint and headers

From `codex-backend-usage-client.ts:68` and `codex-backend-auth.ts:88-96`:

```
GET https://chatgpt.com/backend-api/wham/usage

Authorization:      Bearer <access token>
User-Agent:         codex-cli
OpenAI-Beta:        codex-1
originator:         Codex Desktop
ChatGPT-Account-Id: <account id>     // only when present
```

Timeout 10 000 ms (`codex-backend-auth.ts:10`).

This is a **private, unversioned backend endpoint of the ChatGPT web product.** It carries no
stability guarantee whatsoever. The brief's instruction to quarantine it behind a single adapter is
not optional hygiene — it is the only thing that will keep a schema change from becoming a crash.

### 3.2 Where the token comes from

`codex-backend-auth.ts:70-72` resolves the Codex home as
`options.codexHomePath ?? $CODEX_HOME ?? ~/.codex`, then reads `auth.json` (`:81`). Shape at
`:14-19`:

```ts
type CodexAuthFile = {
  tokens?: {
    access_token?: string
    account_id?: string
  }
}
```

Same story as Claude: a file on disk written by a CLI that does not exist on iOS.

### 3.3 Window classification — the part worth porting carefully

The brief is right that primary/secondary must not be trusted positionally.
`codex-rate-limit-window-classification.ts` classifies by **duration**:

- `CODEX_SESSION_WINDOW_MINUTES = 300` (`:1`)
- `CODEX_WEEKLY_WINDOW_MINUTES = 10080` (`:2`)
- Tolerance `±1 minute` (`:5`), justified at `:4`: *"tolerate the one-minute drift seen in older
  Codex bucket lengths without absorbing other durations."*

The algorithm (`:43-74`):

1. Keep only windows whose `usedPercent` is a finite number (`:21-25`).
2. For each of `[primary, secondary]`, classify by duration within tolerance; first match wins per
   kind (`:54-64`).
3. **Fallback, and note how narrow it is** (`:66-72`): the legacy positional mapping
   `primary→session, secondary→weekly` is applied *only* when that window's duration classified as
   `null` — i.e. only when the duration is missing or unrecognised. A window that positively
   classifies as weekly is **never** also treated as the session window.

That last point is the subtle bit. A naive "classify, else fall back to position" implementation
would mis-assign a payload where `primary_window` is the 7-day window; Orca's version will not.

Duration arrives as seconds and is converted at `codex-backend-usage-client.ts:39-45`:
`windowDurationMins = ceil(limit_window_seconds / 60)`, and only when it is finite and `> 0`.

### 3.4 Response shape

`codex-backend-usage-client.ts:18-31`:

```ts
type BackendRateLimitWindow = {
  used_percent?: number
  limit_window_seconds?: number
  reset_at?: number
}
type BackendUsageResponse = {
  plan_type?: string
  rate_limit?: {
    primary_window?:   BackendRateLimitWindow | null
    secondary_window?: BackendRateLimitWindow | null
  } | null
  rate_limit_reset_credits?: ...
}
```

Here the field genuinely *is* `used_percent` (unlike Claude — the two providers differ, and the
brief's single `used_percent` assumption is only half right).

**Guard worth porting:** `:74-76` rejects the whole payload when `plan_type` is not a string. It is
a cheap schema-sanity check that distinguishes "authenticated, real payload" from "we got handed an
HTML error page or a login redirect", which is exactly the `providerResponseChanged` signal the
brief asks for in §25.

### 3.5 Timestamp units — different from Claude

`codex-rate-limit-window-mapper.ts:14-16`:

```ts
// Why: Codex returns resetsAt as Unix seconds, not milliseconds.
const date = new Date(raw.resetsAt * 1000)
```

**Codex `reset_at` is unconditionally Unix seconds. Claude `resets_at` needs the magnitude
heuristic.** These are two different rules and must not be merged into one shared helper. Codex
values are additionally required to be `> 0` (`:14`).

Percent is clamped `0...100` at `:32`.

---

## 4. Authentication feasibility on iOS

> This section is the one the brief flags as a potential STOP condition. It is completed in the
> committed version of this document once the parallel primary-source investigation of the two CLI
> login flows returns. Nothing here will be asserted without evidence.

### 4.1 The structural problem, already established

Orca's approach is *co-location*: be on the same machine as a logged-in CLI, read its files, and
re-invoke it to repair credentials. Every one of those three moves is unavailable to an iOS app:

| Orca move | iOS equivalent |
|---|---|
| Read macOS Keychain item written by `claude` | None — iOS Keychain is per-app-sandbox |
| Read `~/.claude/.credentials.json` | None — no such file, no shared filesystem |
| Read `~/.codex/auth.json` | None |
| `spawn('claude', ['auth','login','--claudeai'])` | None — iOS cannot exec binaries |
| `spawn('codex', ['login','--device-auth'])` | None |

So QuotaPets cannot port Orca's auth approach. It must either (a) reproduce the vendor OAuth flow
natively, or (b) receive credentials/usage from a machine that has a logged-in CLI. Which of those
is legitimate is the subject of the pending investigation.

*(remainder of §4 pending research completion)*

---

## 5. Environment constraint discovered during Phase 0

**This session runs on Linux x86_64 (Ubuntu 24.04). There is no macOS, no Xcode, and no
`xcodebuild`.** Verified: `uname -a` reports Linux; `which xcodebuild swift swiftc xcrun` returns
nothing; `sw_vers` does not exist.

The brief's §38 ("after every meaningful Apple-side phase, run xcodebuild") **cannot be satisfied in
this environment.** This is a hard, environmental blocker, not a matter of effort. Its consequences
are set out in the summary that accompanies this document; the short version is that Xcode project
generation, SwiftUI/WatchKit compilation, complication rendering, and physical-device installation
all require a Mac.

A partial mitigation is being pursued: the Swift 6.2.1 Linux toolchain can compile and unit-test the
**provider-neutral core** — models, percentage clamping, window classification, timestamp parsing,
mascot state resolution, countdown formatting — because that layer is pure Foundation with no
SwiftUI, WatchConnectivity, or Security-framework dependency. That is precisely the layer where the
subtle bugs identified in §2.2, §2.4, §3.3 and §3.5 live, so testing it for real is worth doing.
UI, Keychain, WatchConnectivity, WidgetKit and the Xcode project remain unverifiable here.

---

## 6. Licence obligations

Orca is **MIT**, © 2026 Lovecast Inc. MIT permits porting concepts and code into a derived work,
including a differently-licensed one, provided the copyright notice and permission notice are
retained. QuotaPets will carry a `THIRD-PARTY-NOTICES.md` reproducing Orca's MIT notice and naming
the specific files whose logic was ported, with a per-concept attribution table. Every ported
algorithm is listed in §2 and §3 above with its originating file and line.

---

*Sections 4 (auth feasibility) and 7+ (target structure, data model, refresh design) are completed
in the committed revision of this document.*
