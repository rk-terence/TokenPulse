# TokenPulse

macOS menu bar app that monitors AI platform token usage (5-hour rolling window) across multiple providers. Displays iStat Menus-style vertical battery bars in the menu bar.

## Tech stack

- Swift 5.9+, SwiftUI, AppKit (NSStatusItem)
- macOS 14+ (Sonoma), universal binary (arm64 + x86_64)
- Core Graphics for menu bar icon rendering
- Security.framework for Keychain access
- SQLite3 + CommonCrypto for Chrome cookie decryption
- Sparkle for auto-update

## Architecture

```
TokenPulse/
├── App/                        # Entry point, AppDelegate, StatusBarController
├── Models/                     # UsageData, ProviderStatus, WindowUsage
├── Providers/                  # UsageProvider protocol + per-provider implementations
│   ├── UsageProvider.swift     # Protocol: fetchUsage() async throws -> UsageData
│   ├── ClaudeProvider.swift    # Keychain OAuth → /api/oauth/usage
│   └── ZenMuxProvider.swift    # Chrome cookie → ZenMux subscription API
├── Services/
│   ├── KeychainService.swift   # Security.framework wrapper
│   ├── ChromeCookieService.swift  # SQLite + AES-128-CBC decryption
│   └── PollingManager.swift    # Timer-based refresh
├── Views/                      # SwiftUI: PopoverView, SettingsView
└── Rendering/
    └── BarIconRenderer.swift   # Core Graphics battery bar icon
```

## Key design decisions

- Menu bar icon: horizontal battery bar (system battery style) showing one provider (can be switched to another provider through mouse right click), each bar = 5h utilization
- Color thresholds: green >=50%, amber 20-51%, red <20%
- LSUIElement = true (no Dock icon)
- Popover on left click: settings, trend chart, detailed breakdown — NOT a repeat of usage bars

## Provider details

Read @docs/providers.md for full API endpoint specs, auth flows, and response schemas.

## Build & run

```bash
# Open in Xcode
open TokenPulse.xcodeproj

# Build from command line
xcodebuild -scheme TokenPulse -configuration Debug build

# Run tests
xcodebuild -scheme TokenPulse -configuration Debug test
```

## Code style

- Swift strict concurrency checking enabled
- Prefer async/await over completion handlers
- Use @Observable (Observation framework) for state, not ObservableObject/Combine
- Prefer SwiftUI for all new views; AppKit only where SwiftUI can't (NSStatusItem, NSPopover)
- No force unwraps except in tests
- All user-facing strings must be localized (NSLocalizedString or String(localized:))

## Important rules

- Never hardcode API keys or credentials — all secrets come from Keychain at runtime
- Chrome cookie decrypted values must stay in memory only, never persisted to disk
- Minimum 60s polling interval for Claude /api/oauth/usage to avoid 429s
- Always handle provider errors gracefully — dim icon + show stale data rather than crash
- Run `xcodebuild test` after any model or provider changes
