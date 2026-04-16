# TokenPulse — Agent Guide

Use this file for high-signal repo instructions only. Product docs live in [README.md](README.md). Provider API details live in [docs/providers.md](docs/providers.md). Proxy behavior and event schema live in [docs/proxy.md](docs/proxy.md). Animation details live in [docs/animation.md](docs/animation.md).

## Build, install, verify

```bash
# Prerequisite: create Local.xcconfig from Local.xcconfig.example and fill in the required local settings
open TokenPulse.xcodeproj

# Build a debug app bundle
xcodebuild -scheme TokenPulse -configuration Debug build

# Install for local use: build Release and replace ~/Applications/TokenPulse.app
xcodebuild -scheme TokenPulse -configuration Release build
mkdir -p ~/Applications
rm -rf ~/Applications/TokenPulse.app
ditto "$(xcodebuild -scheme TokenPulse -configuration Release -showBuildSettings | awk -F ' = ' '/BUILT_PRODUCTS_DIR/ {print $2; exit}')/TokenPulse.app" ~/Applications/TokenPulse.app
```

- Run Xcode builds outside the sandbox so Xcode services can initialize normally.
- If the user asks to "build" the app, default to a Debug build.
- If the user asks to "install" the app, default to a Release build and replace `~/Applications/TokenPulse.app`.
- Do not rely on `xcodebuild test` in the current shared scheme. Add or select a real test target before using tests as verification.

## Code conventions

- When spawning subagents, set the model to `gpt-5.4`. Choose the reasoning effort level to fit the task.
- Swift strict concurrency checking is enabled. Resolve warnings, not just errors.
- Prefer async/await over completion handlers.
- Use `@Observable` for state, not `ObservableObject` or Combine.
- Prefer SwiftUI for new UI. Use AppKit only where SwiftUI cannot support the feature.
- No force unwraps except in tests.
- Localize all user-facing strings with `NSLocalizedString` or `String(localized:)`.
- Use conventional commits: `feat: short description`, `fix: short description`, `docs: short description`, and similar.

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
- Keepalive send is manual-only in the current implementation. No background keepalive loops.
- Event logging uses SQLite with WAL mode and 24-hour retention.
- Proxy status snapshots are written only when proxy logging is enabled and should stay throttled.
