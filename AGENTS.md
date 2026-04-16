# TokenPulse — Agent Guide

Product description and user-facing docs are in README.md. Provider API specs are in docs/providers.md. This file is for agents working in the codebase.

## Build & run

```bash
# Prerequisite: create Local.xcconfig from Local.xcconfig.example and fill in the required local settings
open TokenPulse.xcodeproj

# Build
xcodebuild -scheme TokenPulse -configuration Debug build

# Run tests if/when a real test target is added to the shared scheme
xcodebuild -scheme TokenPulse -configuration Debug test
```

> For Codex: run the build outside the sandbox so Xcode's plugin and simulator services can initialize normally.

## Git commits

Use conventional commit format: `type: short description` (e.g. `feat: add proxy subsystem`, `fix: correct upstream URL default`). Common types: `feat`, `fix`, `chore`, `refactor`, `docs`, `test`.

## Multi-agent workflow

- This repo maintains role separation for Codex in `.agents/skills/lead`, `.agents/skills/developer`, and `.agents/skills/reviewer`
- Treat those Codex skills as the single source of truth for leader/developer/reviewer behavior
- Do not create or maintain parallel Claude-specific copies of those role definitions in this repo unless the team explicitly decides to support both again

## Code style

- Swift strict concurrency checking enabled — resolve all warnings, not just errors
- Prefer async/await over completion handlers
- Use @Observable (Observation framework) for state, not ObservableObject/Combine
- Prefer SwiftUI for all new views; AppKit only where SwiftUI can't (NSStatusItem, NSPopover)
- No force unwraps except in tests
- All user-facing strings must be localized (NSLocalizedString or String(localized:))

## Key constraints

- Never hardcode API keys, credentials, or session secrets — runtime auth material comes from supported local sources such as Keychain, Codex auth file(s), and Chrome cookie storage
- Minimum 60s polling interval globally across providers
- Always handle provider errors gracefully — dim icon + show stale data rather than crash
- Each provider owns its error classification via `classifyError(_:) -> FailureDisposition`
- ProviderStatus uses 6 cases: unconfigured, pendingFirstLoad, refreshing(lastData:lastMessage:), ready, stale(data:reason:message:), error
- Notifications fire when 5h utilization crosses 50% or 80%, and when quota windows reset (with jitter filtering)
- Do not rely on `xcodebuild test` in the current shared scheme; add or select a real test target/testables before using it as a verification step
- File I/O (config, usage export) must use `.atomic` writes
- Proxy listens on `127.0.0.1` only (IPv4 loopback) — never bind all interfaces
- Keepalive send is manual-only in the current implementation: no background keepalive loops, but keepalive may be auto-disabled for lineage-based reasons such as divergence or failure to identify a main-agent lineage
- Event log uses SQLite with WAL mode; 24-hour retention with opportunistic prune passes after the 5-minute prune interval elapses
- Status snapshots (`~/.tokenpulse/proxy_status.json`) are written when proxy logging is enabled and throttled to a 1-second minimum interval

## Architecture quick ref

```
TokenPulse/
├── App/                        # Entry point, AppDelegate, StatusBarController
├── Models/                     # UsageData, ProviderStatus (6-case enum), WindowUsage
├── Providers/                  # UsageProvider protocol + per-provider implementations
│   ├── UsageProvider.swift     # Protocol: fetchUsage(), classifyError() → FailureDisposition
│   ├── ClaudeProvider.swift    # Keychain OAuth → /api/oauth/usage
│   ├── CodexProvider.swift     # $CODEX_HOME/auth.json or ~/.codex/auth.json → chatgpt.com/backend-api/wham/usage
│   └── ZenMuxProvider.swift    # Management API key → /api/v1/management/subscription/detail, with optional cookie-backed subscription summary path
├── Services/
│   ├── KeychainService.swift   # Security.framework wrapper
│   ├── ConfigService.swift     # ~/.tokenpulse/config.json read/write
│   ├── ChromeCookieService.swift # Chrome encrypted cookie extraction (PBKDF2 + AES-128-CBC)
│   ├── PollingManager.swift    # Timer-based refresh
│   ├── ProviderManager.swift   # Per-provider refresh, state machine, icon model
│   ├── NotificationService.swift # UNUserNotification for threshold/reset alerts and proxy keepalive-disabled notifications
│   └── UsageExporter.swift     # ~/.tokenpulse/raw_usage.json export
├── Proxy/
│   ├── LocalProxyController.swift  # Lifecycle owner: starts/stops server, manages subsystem
│   ├── ProxyHTTPServer.swift       # Network.framework HTTP/1.1 listener on 127.0.0.1
│   ├── ProxyForwarder.swift        # Route-specific forwarding, streaming support, token parsing
│   ├── AnthropicProxyAPIHandler.swift  # Anthropic Messages route semantics + keepalive body generation
│   ├── OpenAIResponsesProxyAPIHandler.swift # OpenAI Responses route semantics + token parsing
│   ├── ProxySessionStore.swift     # Session state, byte counters, traffic callbacks
│   ├── ProxyEventLogger.swift      # SQLite event persistence (proxy_requests/keepalives/lifecycle tables) + status snapshots
│   ├── ProxyMetricsStore.swift     # Aggregated counters and savings estimate
│   └── ProxyModels.swift           # Shared data types (request, activity, utils)
├── Views/                      # SwiftUI: PopoverView, SettingsView
└── Rendering/
    └── BarIconRenderer.swift   # Core Graphics battery bar icon
```

## Sources of truth

- Product features, install, usage → README.md
- Provider API specs, auth flows, response schemas → docs/providers.md
- Proxy architecture, request flow, keepalive economics, event schema → docs/proxy.md
- Slash animation state machine, timing, rendering → docs/animation.md
- Build commands, code style, constraints → this file
