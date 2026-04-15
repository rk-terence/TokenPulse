# TokenPulse — Agent Guide

Product description and user-facing docs are in README.md. Provider API specs are in docs/providers.md. This file is for agents working in the codebase.

## Build & run

```bash
open TokenPulse.xcodeproj

# Build
xcodebuild -scheme TokenPulse -configuration Debug build

# Run tests
xcodebuild -scheme TokenPulse -configuration Debug test
```

> For Codex: run the build outside the sandbox so Xcode's plugin and simulator services can initialize normally.

## Git commits

Use conventional commit format: `type: short description` (e.g. `feat: add proxy subsystem`, `fix: correct upstream URL default`). Common types: `feat`, `fix`, `chore`, `refactor`, `docs`, `test`.

## Code style

- Swift strict concurrency checking enabled — resolve all warnings, not just errors
- Prefer async/await over completion handlers
- Use @Observable (Observation framework) for state, not ObservableObject/Combine
- Prefer SwiftUI for all new views; AppKit only where SwiftUI can't (NSStatusItem, NSPopover)
- No force unwraps except in tests
- All user-facing strings must be localized (NSLocalizedString or String(localized:))

## Key constraints

- Never hardcode API keys or credentials — all secrets come from Keychain at runtime
- Minimum 60s polling interval for Claude /api/oauth/usage to avoid 429s
- Always handle provider errors gracefully — dim icon + show stale data rather than crash
- Each provider owns its error classification via `classifyError(_:) -> FailureDisposition`
- ProviderStatus uses 6 cases: unconfigured, pendingFirstLoad, refreshing(lastData:lastMessage:), ready, stale(data:reason:message:), error
- Notifications fire when 5h utilization crosses 50% or 80%, and when quota windows reset (with jitter filtering)
- Run `xcodebuild test` after any model or provider changes
- File I/O (config, usage export) must use `.atomic` writes
- Proxy listens on `127.0.0.1` only (IPv4 loopback) — never bind all interfaces
- Keepalive is manual-only in the current implementation: no background keepalive loops or auto-disable-on-failure policy
- Event log uses SQLite with WAL mode; 24-hour retention with 5-minute prune sweeps
- Status snapshots (`~/.tokenpulse/proxy_status.json`) throttled to 1-second minimum interval

## Architecture quick ref

```mermaid
flowchart TD
    root["TokenPulse/"]

    root --> app["App/<br/>Entry point, AppDelegate, StatusBarController"]
    root --> models["Models/<br/>UsageData, ProviderStatus (6-case enum), WindowUsage"]
    root --> providersDir
    root --> servicesDir
    root --> proxyDir
    root --> views["Views/<br/>SwiftUI: PopoverView, SettingsView"]
    root --> renderingDir

    subgraph providersDir["Providers/"]
        usageProvider["UsageProvider.swift<br/>Protocol: fetchUsage(), classifyError() -> FailureDisposition"]
        claudeProvider["ClaudeProvider.swift<br/>Keychain OAuth -> /api/oauth/usage"]
        codexProvider["CodexProvider.swift<br/>~/.codex/auth.json -> chatgpt.com/backend-api/wham/usage"]
        zenmuxProvider["ZenMuxProvider.swift<br/>Management API key -> /api/v1/management/subscription/detail"]
    end

    subgraph servicesDir["Services/"]
        keychainService["KeychainService.swift<br/>Security.framework wrapper"]
        configService["ConfigService.swift<br/>~/.tokenpulse/config.json read/write"]
        chromeCookieService["ChromeCookieService.swift<br/>Chrome encrypted cookie extraction (PBKDF2 + AES-128-CBC)"]
        pollingManager["PollingManager.swift<br/>Timer-based refresh"]
        providerManager["ProviderManager.swift<br/>Per-provider refresh, state machine, icon model"]
        notificationService["NotificationService.swift<br/>UNUserNotification for threshold/reset alerts"]
        usageExporter["UsageExporter.swift<br/>~/.tokenpulse/raw_usage.json export"]
    end

    subgraph proxyDir["Proxy/"]
        localProxyController["LocalProxyController.swift<br/>Lifecycle owner: starts/stops server, manages subsystem"]
        proxyHTTPServer["ProxyHTTPServer.swift<br/>Network.framework HTTP/1.1 listener on 127.0.0.1"]
        proxyForwarder["ProxyForwarder.swift<br/>Route-specific forwarding, streaming support, token parsing"]
        anthropicHandler["AnthropicProxyAPIHandler.swift<br/>Anthropic Messages route semantics + keepalive body generation"]
        openAIHandler["OpenAIResponsesProxyAPIHandler.swift<br/>OpenAI Responses route semantics + token parsing"]
        proxySessionStore["ProxySessionStore.swift<br/>Session state, byte counters, traffic callbacks"]
        proxyEventLogger["ProxyEventLogger.swift<br/>SQLite event persistence (proxy_requests/keepalives/lifecycle tables) + status snapshots"]
        proxyMetricsStore["ProxyMetricsStore.swift<br/>Aggregated counters and savings estimate"]
        proxyModels["ProxyModels.swift<br/>Shared data types (request, activity, utils)"]
    end

    subgraph renderingDir["Rendering/"]
        barIconRenderer["BarIconRenderer.swift<br/>Core Graphics battery bar icon"]
    end
```

## Sources of truth

- Product features, install, usage → README.md
- Provider API specs, auth flows, response schemas → docs/providers.md
- Proxy architecture, request flow, keepalive economics, event schema → docs/proxy.md
- Slash animation state machine, timing, rendering → docs/animation.md
- Build commands, code style, constraints → this file
