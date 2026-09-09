# Third-Party Notices

QuotaPets ports algorithmic concepts from the projects below. Each ported behaviour is
listed with the exact source file and line it derives from, so the provenance of every
non-obvious rule in `QuotaPetsShared` is traceable.

No source code was copied verbatim; the Swift implementations are original. Attribution
is provided regardless, because the line between "concept" and "expression" is fuzzy and
compliance is nearly free.

---

## Orca — https://github.com/stablyai/orca

Usage-fetching and window-normalisation concepts are derived from Orca.

### Ported concepts

| QuotaPets | Orca source | Concept |
|---|---|---|
| `ClaudeUsagePayload.resolvedUsedPercent` | `claude-usage-window.ts:61-66` | `utilization` takes precedence over `used_percentage` |
| `ClaudeResetTimestamp` | `claude-usage-window.ts:11-30` | 1e10 magnitude heuristic separating second and millisecond epochs |
| `ClaudeUsageMapper` | `claude-oauth-usage-request.ts:90-91` | `five_hour` → 5-hour, `seven_day` → weekly |
| `CodexWindowClassifier` | `codex-rate-limit-window-classification.ts:1-74` | Duration-based window classification, ±1 minute tolerance, narrow positional fallback |
| `CodexResetTimestamp` | `codex-rate-limit-window-mapper.ts:14-16` | `reset_at` is unconditionally Unix seconds |
| `CodexWindowPayload.durationMinutes` | `codex-backend-usage-client.ts:39-45` | `ceil(limit_window_seconds / 60)`, positive values only |
| `CodexUsageMapper.decode` | `codex-backend-usage-client.ts:74-76` | Absent `plan_type` signals a schema change |
| `UsageWindow.clamp` | `claude-usage-window.ts:71`, `codex-rate-limit-window-mapper.ts:32` | Clamp used percentage into 0...100 |
| `ProviderError` / `HTTPStatusClassifier` | `rate-limit-types.ts:20-34` | Failure-kind taxonomy |

Deliberate divergences are documented in `docs/provider-research.md` §3.5 — notably that
QuotaPets keeps two separate reset-timestamp decoders rather than one shared helper,
because Orca's own codebase applies opposite meanings to the 1e10 boundary in
`claude-usage-window.ts:16` and `codex-reset-credit-client.ts:46`.

### Licence

    MIT License
    
    Copyright (c) 2026 Lovecast Inc.
    
    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:
    
    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.
    
    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.

---

## OpenAI Codex CLI — https://github.com/openai/codex

Licensed under Apache-2.0. **Read for research only** — see `docs/provider-research.md`
§4.2. No code or algorithm is ported from it. It is credited because its source was the
primary evidence for the authentication findings that led QuotaPets to adopt the macOS
helper relay rather than a native login flow.
