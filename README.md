# QuotaPets

Claude and Codex subscription quota, on your wrist, as a mascot that visibly runs out of
energy as you run out of quota.

Native iPhone + Apple Watch. SwiftUI, WidgetKit complications, WatchConnectivity.
No web view, no React Native, no cloud backend.

> **Status: partially built.** Phases 0-3 and the provider core of 5/6 are done, mascots are
> drawn and animated, and the shared logic is tested. The Apple targets have **never been
> compiled** — see [Build status](#build-status) before trusting anything visual.

---

## Architecture

Authentication is the thing that shapes this app, and not in the way the original design
assumed. The research in [`docs/provider-research.md`](docs/provider-research.md)
established that **neither provider's login can be legitimately reproduced in an iOS
app** — so QuotaPets does not try.

```
  claude / codex CLIs        ← your own first-party logins, unmodified
          │ write
          ▼
  macOS Keychain · ~/.claude/.credentials.json · ~/.codex/auth.json
          │ read by
          ▼
  QuotaPetsHelper (macOS)    ← the ONLY component that holds a credential
          │ normalised UsageSnapshot, over LAN
          ▼
  QuotaPetsPhone (iOS 18)    ← cache · BGAppRefreshTask · WCSession
          │ UsageSnapshot only
          ▼
  QuotaPetsWatch (watchOS 11) + QuotaPetsWidgets complications
```

**No provider credential ever reaches iOS.** The phone's Keychain duty shrinks to a
pairing secret — a strictly smaller attack surface than a token-holding design.

| Component | Platform | Role |
|---|---|---|
| `QuotaPetsShared` | any | Models, decoders, mascot logic. Foundation-only, **86 tests** |
| `QuotaPetsHelper` | macOS 14+ | Reads CLI credentials, fetches usage, serves snapshots |
| `QuotaPetsPhone` | iOS 18+ | Pairing, cache, background refresh, watch sync |
| `QuotaPetsWatch` | watchOS 11+ | Mascot UI, two provider pages |
| `QuotaPetsWidgets` | watchOS 11+ | Complications |

---

## Build

The Xcode project is **generated**, not committed. `project.yml` is the source of truth.

```bash
brew install xcodegen
xcodegen generate
open QuotaPets.xcodeproj
```

Run the shared test suite anywhere with a Swift toolchain — no Mac required:

```bash
cd QuotaPetsShared && swift test
```

### Build status

| Layer | Verified? | How |
|---|---|---|
| `QuotaPetsShared` logic | ✅ **Yes** | 86 tests, Swift 6.2.1, strict concurrency, passing |
| `project.yml` → Xcode project | ✅ **Yes** | XcodeGen 2.46 run; targets, deployment targets, bundle IDs and plists inspected |
| SwiftUI views | ❌ **No** | Requires Xcode |
| WatchConnectivity, Keychain, WidgetKit | ❌ **No** | Requires Xcode |
| Install on a physical Series 7 | ❌ **No** | Requires a Mac and a device |

The unverified layers were written on Linux with no Apple toolchain. **Expect compile
errors on first build** — API misuse that only `xcodebuild` can catch. The shared package
was deliberately kept Foundation-only so the highest-risk logic (provider parsing, window
classification, timestamp units) could be tested for real rather than asserted.

---

## Provider mechanisms

Both endpoints are **private and unversioned**. Each is quarantined behind one adapter,
and every constant lives in `ProviderEndpoints.swift`.

**Claude** — `GET https://api.anthropic.com/api/oauth/usage`, headers
`Authorization: Bearer`, `anthropic-beta: oauth-2025-04-20`, `User-Agent: claude-code/…`.
Maps `five_hour` → 5-hour and `seven_day` → weekly.

**Codex** — `GET https://chatgpt.com/backend-api/wham/usage`, headers
`Authorization: Bearer`, `User-Agent: codex-cli`, `OpenAI-Beta: codex-1`,
`originator: Codex Desktop`, plus `ChatGPT-Account-Id` when present.

### Four traps, each pinned by a test

1. **Claude sends `utilization`, not `used_percent`.** The original spec assumed the
   latter. Decoding only that name yields *no Claude data at all*. Precedence is
   `utilization` → `used_percentage`.
2. **Claude reset timestamps are seconds *or* milliseconds**, disambiguated by a `> 1e10`
   magnitude test with a strict greater-than, so exactly `1e10` means seconds.
3. **Codex `reset_at` is unconditionally Unix seconds.** Applying Claude's heuristic here
   mis-scales anything above `1e10`. The two decoders are separate on purpose.
4. **Codex windows classify by duration, not position.** `primary_window` is *not*
   guaranteed to be the 5-hour one. Positional fallback applies only when a duration is
   unrecognised — never to a window that positively classified as the other kind.

### When a provider changes shape

Symptom: `PROVIDER ERROR` on the watch, `providerResponseChanged` in Diagnostics.
Both mappers reject payloads that decode but carry nothing recognisable, rather than
silently showing zeros. Fix in `ClaudeUsagePayload` / `CodexUsagePayload` and add a
fixture test — the suite is built to make that a five-minute change.

---

## Refresh behaviour, honestly stated

**Foreground:** both providers every 60s, staggered by 30s so they never fire together.

**Background:** best-effort only. `BGAppRefreshTask` has **no guaranteed interval** —
Apple documents `earliestBeginDate` as a floor and disclaims any launch promise. A 60s
background cadence is not achievable and the app does not pretend otherwise; every
surface showing a number also shows its freshness (`UPDATED 42s AGO` / `STALE · 8m`).

**Two Apple constraints that shaped the design:**

- **The phone cannot wake the watch.** Apple states `sendMessage` from iOS "does not wake
  up the corresponding WatchKit extension." Only watch→phone wakes the counterpart, so
  the watch pulls and the phone stages data via `updateApplicationContext`.
- **Complications get 75 timeline reloads/day** — about one per 19 minutes. The
  countdown stays alive between reloads via `Text(_:style:.timer)`, which advances on
  screen with no code running, no budget spend, and keeps updating during Always-On.
  That is the entire "living complication" mechanism; there is no other way to do it.

---

## Mascots

The mascots are **drawn in code**, not shipped as images. Two original characters —
Claude soft and round with a spark tuft, Codex angular with a blinking cursor eye.

This is not a placeholder. Drawing them means they can actually *animate per energy
state* rather than swapping static frames: they breathe (squash on Y only, so the
silhouette keeps its footprint), blink at irregular intervals, sink and tilt as quota
drains, and finally sleep with a drifting `z z`. A tired pet blinks more slowly because a
blink and a droop are the same mechanism — no extra artwork needed.

Live preview, no Xcode required:
**[Mascot Lab](https://claude.ai/code/artifact/adddbd0a-104f-41c2-bf1f-4838e92ec152)** —
drag the quota sliders and watch both pets react.

Geometry lives in `Apps/QuotaPetsWatch/Mascots/PetShapes.swift`. `PetPose` is a per-state
value table, so tuning a mood is editing numbers, not redrawing.

### Supplying your own art (optional)

If you'd rather use your own images, drop them into the watch target's asset catalog and
they take precedence automatically — no code change:

```
claudeMascot-hyper   claudeMascot-happy   claudeMascot-normal
claudeMascot-tired   claudeMascot-exhausted   claudeMascot-empty
codexMascot-<the same six>
```

`claudeMascot` / `codexMascot` act as fallbacks. Note that supplied images are static —
the drawn pets are the animated path.

### Energy states

`pressure = min(fiveHourRemaining, weeklyRemaining)` — the *tighter* window drives the
mascot, and the UI marks which one, so a tired pet is explainable.

| Remaining | State |
|---|---|
| 75–100 | hyper |
| 50–75 | happy |
| 30–50 | normal |
| 15–30 | tired |
| 0–15 | exhausted |
| 0 | empty |

---

## Security

- Provider credentials live **only on the Mac**, read from what the CLIs wrote.
- Nothing credential-shaped is logged, committed, or placed in a QR code. A test asserts
  the pairing payload contains no token-shaped field.
- Pairing nonces are 24 random bytes, expiring and single-use.
- No analytics, no telemetry, no third-party SDK, no cloud backend.
- On iOS, Keychain items must use `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` —
  the silent default (`WhenUnlocked`) **fails inside background tasks on a locked
  device**.

**Every external hostname QuotaPets can reach:** `api.anthropic.com`, `chatgpt.com`.
Both are in `ProviderEndpoints.swift`, and nowhere else.

---

## Installing on a physical Watch

watchOS 11 supports Series 6 and later, so a Series 7 on 11.6.2 is in range.

⚠️ **A free Apple ID expires provisioning every 7 days** — profiles, App IDs and device
registrations all lapse, and the watch app and complication die weekly until you rebuild
with both devices present. For something you actually want on your wrist, the $99/yr
Apple Developer Program is effectively required.

App Groups (used to share snapshots with the widget extension) **do** work on a free
Personal Team — verified against Apple's capability reference.

---

## What is not built

Phases 4 and 7–9: the LAN transport between helper and phone, the QR pairing UI, mascot
animation polish, and threshold haptics beyond the shared logic. Mock providers currently
stand in on the phone so the UI is exercisable end to end.

---

## Attribution

Usage-fetching concepts are ported from [Orca](https://github.com/stablyai/orca) (MIT).
Every ported rule is listed with its originating file and line in
[`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md).
