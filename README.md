# TokenPulse

A macOS menu bar app that monitors your AI platform token usage at a glance. It displays a battery-style gauge in the menu bar showing your 5-hour rolling window utilization, so you always know how much capacity you have left.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue) ![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange)

## Features

- **Menu bar gauge** — Battery-style horizontal bar showing remaining capacity, with color coding (green/amber/red)
- **Multiple providers** — Right-click the icon to cycle between providers
- **Click for details** — Left-click opens a popover with per-provider breakdown, quota windows, reset timers, and more
- **Usage notifications** — macOS notifications when a provider's primary window crosses 50% or 80%, and when quota windows reset
- **Graceful degradation** — Shows stale data on transient errors, surfaces auth guidance on credential issues, dims icon when refreshing
- **Configurable polling** — 60s, 2min, or 5min intervals
- **Launch at login** — Optional auto-start via macOS Service Management
- **No Dock icon** — Runs as a pure menu bar app

## Supported providers

| Provider | Auth method | What it shows |
|----------|-------------|---------------|
| **Codex** | Local Codex ChatGPT login (`~/.codex/auth.json`) | 5h window, weekly window, plan tier |
| **Claude** (Anthropic) | Keychain (Claude Code OAuth token) | 5h window, 7-day quota, Opus quota |
| **ZenMux** | Management API key + Chrome cookies (auto-extracted) | 5h window, 7-day quota, monthly utilization*, tier, account status |

## Why TokenPulse?

[CodexBar](https://github.com/steipete/CodexBar) is an excellent menu bar usage tracker with 15+ providers and an active community. TokenPulse exists because it makes different trade-offs:

- **ZenMux support** — TokenPulse supports ZenMux out of the box via their official Management API. ZenMux is a niche provider that CodexBar doesn't cover, and likely too niche for them to want to maintain.
- **One gauge, one glance** — CodexBar shows two stacked bars per provider with multiple display modes. TokenPulse shows a single battery gauge with the remaining percentage right in the icon — you get your answer without interpreting bar heights or switching modes.
- **Minimal by design** — TokenPulse is ~20 source files with a simple `UsageProvider` protocol. No SwiftSyntax macros, no helper processes, no multi-strategy fallback chains. The entire codebase is easy to audit, fork, and modify in an afternoon.
- **Machine-readable output** — Every poll cycle writes raw provider data to `~/.tokenpulse/raw_usage.json`, so shell scripts and other tools can consume it without scraping or IPC. Settings are stored in `~/.tokenpulse/config.json`.

If you use many AI providers and want comprehensive coverage, use CodexBar. If you use Codex, Claude, and/or ZenMux and want something small and direct, TokenPulse is for you.

## Install

### Build from source

Requires Xcode 15+ and macOS 14 Sonoma.

```bash
git clone https://github.com/user/TokenPulse.git
cd TokenPulse
cp Local.xcconfig.example Local.xcconfig
# Edit Local.xcconfig and set your Apple Developer Team ID
open TokenPulse.xcodeproj
```

Build and run from Xcode (`Cmd+R`), or from the command line:

```bash
xcodebuild -scheme TokenPulse -configuration Debug build
```

## Setup

### Claude provider

TokenPulse reads your Claude Code OAuth credentials from the macOS Keychain automatically. If you're signed into [Claude Code](https://claude.ai/claude-code), it should work out of the box — no configuration needed.

### Codex provider

TokenPulse reads your existing Codex ChatGPT login from `~/.codex/auth.json`. To set it up:

1. Install the Codex CLI and sign in with ChatGPT via `codex login`
2. Open **Settings > Providers** and enable **Codex**
3. Refresh TokenPulse

If your Codex CLI is currently using API key billing, run `codex login` to switch to your ChatGPT subscription.

### ZenMux provider

1. Get a **Management API Key** from your [ZenMux dashboard](https://zenmux.ai)
2. Open **Settings > Providers > ZenMux** and paste the key
3. Click **Save** — the key is stored securely in your macOS Keychain

*Monthly utilization requires an active ZenMux session in Chrome. TokenPulse reads Chrome's encrypted cookies automatically (via the Keychain-stored Chrome Safe Storage key). If Chrome cookies are unavailable, everything else still works — only the monthly usage bar is hidden, and the monthly cap is shown as a static value instead.

## Usage

- **Left-click** the menu bar icon to open the detail popover
- **Right-click** to switch between providers
- Click the **gear icon** in the popover to open Settings

The menu bar gauge shows remaining capacity for the active provider's primary window:
- **Green** — more than 50% remaining
- **Amber** — 20–50% remaining
- **Red** — less than 20% remaining

## Data export

TokenPulse writes raw provider data to `~/.tokenpulse/raw_usage.json` after every poll. Example:

```bash
# Get Claude 5-hour utilization
jq '.providers.claude.fiveHour.utilization' ~/.tokenpulse/raw_usage.json

# Check if any provider is in error state
jq '.providers | to_entries[] | select(.value.status == "error")' ~/.tokenpulse/raw_usage.json
```

The file is atomically written, so readers always see a complete snapshot.

## Notifications

TokenPulse sends macOS notifications for important usage events:

| Event | When |
|-------|------|
| **Primary window above 50%** | Utilization crosses the 50% threshold (entering amber zone) |
| **Primary window above 80%** | Utilization crosses the 80% threshold (entering red zone) |
| **Primary quota reset** | The provider's primary quota window resets |
| **Secondary quota reset** | The provider's secondary quota window resets |

Notifications are sent per provider. Grant notification permission when prompted on first launch.

## Project structure

```
TokenPulse/
├── App/            # AppDelegate, StatusBarController, entry point
├── Models/         # UsageData, ProviderStatus, ProviderConfig
├── Providers/      # UsageProvider protocol + Codex, Claude, ZenMux implementations
├── Services/       # KeychainService, ChromeCookieService, ConfigService, PollingManager, ProviderManager, NotificationService
├── Views/          # PopoverView, SettingsView (SwiftUI)
└── Rendering/      # BarIconRenderer (Core Graphics)
```

## Adding a new provider

1. Create a new file in `Providers/` implementing the `UsageProvider` protocol
2. Implement `classifyError(_:)` to map your provider's errors to `FailureDisposition` cases
3. Register it in `AppDelegate.applicationDidFinishLaunching`
4. Add any auth UI to `SettingsView` if needed

## License

MIT
