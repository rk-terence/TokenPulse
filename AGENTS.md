# TokenPulse — Agent Guide

Use this file for high-signal repo instructions only. Product docs live in [README.md](README.md). Provider API details live in [docs/providers.md](docs/providers.md). Proxy behavior and event schema live in [docs/proxy.md](docs/proxy.md). Animation details live in [docs/animation.md](docs/animation.md).

## Build, install, verify

Builds use Swift Package Manager. Xcode.app is not required; the Command Line Tools (`swift`, `iconutil`, `codesign`) are sufficient.

```bash
# Build a debug binary (at .build/debug/TokenPulse)
swift build

# Package a release .app bundle (adhoc-signed) at dist/TokenPulse.app
bash Scripts/package_app.sh

# Install for local use: replace ~/Applications/TokenPulse.app
mkdir -p ~/Applications
rm -rf ~/Applications/TokenPulse.app
ditto dist/TokenPulse.app ~/Applications/TokenPulse.app
```

- If the user asks to "build" the app, default to `swift build` (debug).
- If the user asks to "install" the app, default to `bash Scripts/package_app.sh` + the `ditto` copy above.
- `Scripts/package_app.sh` honors `CONFIGURATION` (default `release`), `OUTPUT_DIR` (default `dist/`), and `TOKENPULSE_SIGNING` from the current shell environment or `./.env`:
  - `adhoc` (default) — `codesign --sign -` with `TokenPulse/TokenPulse.entitlements`. No developer account needed, but the signature hash changes every rebuild, which re-prompts Keychain ACLs and invalidates Login Items approval.
  - `off` — skip codesign entirely (the bundle won't launch on Apple Silicon).
  - A signing identity string (e.g. `"Developer ID Application: Name (TEAMID)"`) — passed through to `codesign --sign` with `--options runtime` plus entitlements. Use when a stable signature matters (Keychain persistence, Login Items, notarization).
- The entitlements file declares `com.apple.security.app-sandbox = false` only. `keychain-access-groups` is intentionally absent because adhoc signatures cannot legitimately claim team-restricted entitlements on macOS.
- No SwiftPM test target exists yet. Don't claim tests as verification — use a build and, for UI-affecting changes, a smoke launch of `dist/TokenPulse.app`.

## Code conventions

- Swift strict concurrency checking is enabled. Resolve warnings, not just errors.
- Prefer async/await over completion handlers.
- Use `@Observable` for state, not `ObservableObject` or Combine.
- Prefer SwiftUI for new UI. Use AppKit only where SwiftUI cannot support the feature.
- No force unwraps except in tests.
- Localize all user-facing strings with `NSLocalizedString` or `String(localized:)`.
- Use conventional commits: `feat: short description`, `fix: short description`, `docs: short description`, and similar.

> For Codex:
> - When spawning subagents, set the model to `gpt-5.4`. Choose the reasoning effort level to fit the task.

## Product invariants

- Never hardcode API keys, credentials, or session secrets.
- Runtime auth material must come from supported local sources such as Keychain, Codex auth files, and Chrome cookie storage.
- Minimum polling interval is 60 seconds across providers.
- Provider failures must degrade gracefully: dim icon or stale data instead of crashing.
- Each provider owns error classification via `classifyError(_:) -> FailureDisposition`.
- `ProviderStatus` has 6 cases: `unconfigured`, `pendingFirstLoad`, `refreshing(lastData:lastMessage:)`, `ready`, `stale(data:reason:message:)`, `error`.
- Notifications fire when 5-hour utilization crosses 50% or 80%, and when quota windows reset, with jitter filtering.
- File I/O for config and usage export must use `.atomic` writes.
- Proxy must listen on `127.0.0.1` only, never all interfaces.
- Keep-alive is not currently implemented; the UI and wire protocol reserve no space for it. Deferred as future work.
- Proxy content-tree tracking is universal across supported providers (Anthropic Messages, OpenAI Responses), but lineage normalization is provider-specific and minimally destructive. Anthropic strips prompt-caching markers and coalesces equivalent consecutive turns; OpenAI preserves ordered non-message `input` items and normalizes string message `content` to typed text input. Requests with a lineage fingerprint attach to the in-memory `ContentTree` before upstream; node deltas are immutable, `done`/`active` live on requests, and terminal requests prune after 24 hours.
- Event logging uses SQLite with `journal_mode = WAL`, `synchronous = NORMAL`, and 24-hour retention. A single `saveProxyEventLog` toggle controls metadata, lineage-deduplicated payload capture, and the bounded raw source-of-truth request/response table; there is no separate payload or raw-capture opt-in. Raw exact captures are capped to the newest 1000 rows.
- Proxy status snapshots are written whenever `saveProxyEventLog` is true and should stay throttled.
