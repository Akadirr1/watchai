# Contributing

## Setup

```bash
npm install
AUTH_TOKEN=$(openssl rand -hex 32) DATA_DIR=./tmp npm run dev
```

The watch app needs macOS:

```bash
cp Secrets.xcconfig.example Secrets.xcconfig   # fill in your server URL
brew install xcodegen && xcodegen generate && open QuotaPets.xcodeproj
```

## Tests

```bash
npm run typecheck
npm test                              # server
cd QuotaPetsShared && swift test      # watch core — runs on Linux too
```

The Swift package is Foundation-only on purpose: it builds and tests without a Mac. Please
keep it that way. Anything needing SwiftUI, WidgetKit or the Security framework belongs in
`Apps/`, not in the package.

## Before you change the provider adapters

Both usage endpoints are private and unversioned, and four non-obvious rules are load
bearing. Each has a test. If one fails, the test is probably right:

1. **Claude sends `utilization`**, falling back to `used_percentage`. It never sends
   `used_percent` — decoding only that name yields no Claude data at all.
2. **Claude reset timestamps** are seconds *or* milliseconds, split at `> 1e10`. The
   comparison is strictly greater-than, so exactly `1e10` means seconds.
3. **Codex `reset_at` is unconditionally Unix seconds.** Applying Claude's rule mis-scales
   anything above `1e10`. The two decoders are separate on purpose — do not merge them.
4. **Codex classifies windows by duration, not position.** `primary_window` is not
   guaranteed to be the 5-hour one, and the positional fallback applies only to a window
   whose duration was unrecognised.

`docs/provider-research.md` explains where each of these came from, with file and line
citations into the upstream sources.

## Two things that will fail review

- Logging a provider response body, a request header, or any part of a token.
- Adding a network call to a host outside `src/providers/endpoints.ts`. A test enforces
  the allowlist; that test is the "QuotaPets never runs prompts" guarantee.

## Commits

Explain *why*, not *what* — the diff already says what. Several decisions in this project
look arbitrary until you know what was ruled out, and the commit log is where that lives.
