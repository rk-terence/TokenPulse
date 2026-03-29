# TokenPulse

A macOS menu bar app that monitors your AI platform token usage at a glance. It displays a battery-style gauge in the menu bar showing your 5-hour rolling window utilization, so you always know how much capacity you have left.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue) ![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange)

## Features

- **Menu bar gauge** — Battery-style horizontal bar showing remaining capacity, with color coding (green/amber/red)
- **Multiple providers** — Right-click the icon to cycle between providers
- **Click for details** — Left-click opens a popover with per-provider breakdown, 7-day usage, reset timers, and more
- **Configurable polling** — 60s, 2min, or 5min intervals
- **Launch at login** — Optional auto-start via macOS Service Management
- **No Dock icon** — Runs as a pure menu bar app

## Supported providers

| Provider | Auth method | What it shows |
|----------|-------------|---------------|
| **Claude** (Anthropic) | Keychain (Claude Code OAuth token) | 5h window, 7-day quota, Opus quota |
| **ZenMux** | Chrome cookie auto-detect or manual paste | 5h window, 7-day quota, tier info |

## Why TokenPulse?

[CodexBar](https://github.com/steipete/CodexBar) is an excellent menu bar usage tracker with 15+ providers and an active community. TokenPulse exists because it makes different trade-offs:

- **ZenMux support** — TokenPulse supports ZenMux out of the box (via Chrome cookie decryption or manual paste). ZenMux is a niche provider that CodexBar doesn't cover, and likely too niche for them to want to maintain.
- **One gauge, one glance** — CodexBar shows two stacked bars per provider with multiple display modes. TokenPulse shows a single battery gauge with the remaining percentage right in the icon — you get your answer without interpreting bar heights or switching modes.
- **Minimal by design** — TokenPulse is ~20 source files with a simple `UsageProvider` protocol. No SwiftSyntax macros, no helper processes, no multi-strategy fallback chains. The entire codebase is easy to audit, fork, and modify in an afternoon.
- **Machine-readable output** — Every poll cycle writes raw provider data to `~/.tokenpulse/raw_usage.json`, so shell scripts and other tools can consume it without scraping or IPC.

If you use many AI providers and want comprehensive coverage, use CodexBar. If you use Claude and/or ZenMux and want something small and direct, TokenPulse is for you.

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

### ZenMux provider

TokenPulse auto-detects ZenMux session cookies from Chrome. If auto-detect doesn't work (e.g., you use a different browser), you can manually paste cookie values in **Settings > Providers > ZenMux > Manual cookie override**.

## Usage

- **Left-click** the menu bar icon to open the detail popover
- **Right-click** to switch between providers
- Click the **gear icon** in the popover to open Settings

The menu bar gauge shows remaining capacity for the active provider's 5-hour window:
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

## Project structure

```
TokenPulse/
├── App/            # AppDelegate, StatusBarController, entry point
├── Models/         # UsageData, ProviderStatus, ProviderConfig
├── Providers/      # UsageProvider protocol + Claude, ZenMux implementations
├── Services/       # KeychainService, ChromeCookieService, PollingManager
├── Views/          # PopoverView, SettingsView (SwiftUI)
└── Rendering/      # BarIconRenderer (Core Graphics)
```

## Adding a new provider

1. Create a new file in `Providers/` implementing the `UsageProvider` protocol
2. Register it in `AppDelegate.applicationDidFinishLaunching`
3. Add any auth UI to `SettingsView` if needed

## License

MIT
