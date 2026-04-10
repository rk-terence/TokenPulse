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
- ProviderStatus uses 6 cases: unconfigured, pendingFirstLoad, refreshing(lastData:), ready, stale(reason:), error
- Notifications fire when 5h utilization crosses 50% or 80%, and when quota windows reset (with jitter filtering)
- Run `xcodebuild test` after any model or provider changes
- File I/O (config, usage export) must use `.atomic` writes

## Architecture quick ref

```
TokenPulse/
├── App/                        # Entry point, AppDelegate, StatusBarController
├── Models/                     # UsageData, ProviderStatus (6-case enum), WindowUsage
├── Providers/                  # UsageProvider protocol + per-provider implementations
│   ├── UsageProvider.swift     # Protocol: fetchUsage(), classifyError() → FailureDisposition
│   ├── ClaudeProvider.swift    # Keychain OAuth → /api/oauth/usage
│   └── ZenMuxProvider.swift    # Management API key → /api/v1/management/subscription/detail
├── Services/
│   ├── KeychainService.swift   # Security.framework wrapper
│   ├── ConfigService.swift     # ~/.tokenpulse/config.json read/write
│   ├── PollingManager.swift    # Timer-based refresh
│   ├── ProviderManager.swift   # Per-provider refresh, state machine, icon model
│   ├── NotificationService.swift # UNUserNotification for threshold/reset alerts
│   └── UsageExporter.swift     # ~/.tokenpulse/raw_usage.json export
├── Views/                      # SwiftUI: PopoverView, SettingsView
└── Rendering/
    └── BarIconRenderer.swift   # Core Graphics battery bar icon
```

## Team roles

Unless explicitly stated otherwise, the main Claude session is the **leader**.

- **Leader** (main Claude session): owns phasing, architecture decisions, and user approval gates. Spawns the developer for scoped tasks, then sends output to the reviewer via `/codex:rescue`. Iterates the developer ↔ reviewer loop until clean before presenting to the user.
- **Developer** (Claude subagent, `.claude/agents/developer.md`): implements scoped tasks from the leader, builds and verifies. Does not make architecture decisions or advance phases.
- **Reviewer** (Codex, via `/codex:rescue`): reviews developer output for correctness, concurrency safety, and code style. Returns findings to the leader.

Workflow per phase:

1. Leader spawns developer with scoped task
2. Leader sends result to Codex (`/codex:rescue`) for review
3. If issues found, leader sends developer back to fix
4. Repeat 2–3 until clean
5. Leader presents final result to user for approval
6. User approves → leader starts next phase

## Sources of truth

- Product features, install, usage → README.md
- Provider API specs, auth flows, response schemas → docs/providers.md
- Proxy feature design → FEATURE_DESIGN.md
- Build commands, code style, constraints → this file
