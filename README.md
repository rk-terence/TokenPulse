# TokenPulse

A macOS menu bar app that monitors AI platform token usage and optimizes API costs through a local caching proxy. A battery-style gauge in the menu bar shows your remaining capacity at a glance, while the optional proxy keeps prompt caches warm between requests to reduce cache-write costs.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue) ![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange)

## Features

### Usage monitoring

- **Menu bar gauge** — Battery-style horizontal bar showing remaining capacity, with color coding (green/amber/red)
- **Multiple providers** — Right-click the icon to cycle between providers
- **Click for details** — Left-click opens a popover with per-provider breakdown, quota windows, reset timers, and more
- **Usage notifications** — macOS notifications when a provider's primary window crosses 50% or 80%, and when quota windows reset
- **Graceful degradation** — Shows stale data on transient errors, surfaces auth guidance on credential issues, dims icon when refreshing
- **Machine-readable export** — Every poll writes raw provider data to `~/.tokenpulse/raw_usage.json` for shell scripts and external tools

### Local proxy

- **Cache-warming keepalives** — Sends periodic lightweight requests per session to keep prompt caches warm, saving ~1.15x base input tokens per avoided cache miss at a cost of ~0.10x base input tokens per keepalive
- **Per-session cost tracking** — Tracks token usage, bytes transferred, and estimated cost per Claude Code session in real-time
- **Streaming support** — Full HTTP/1.1 proxy with SSE streaming passthrough; parses token usage from both JSON and SSE responses
- **Traffic indicator** — Menu bar slash animates with a bouncing glow when the proxy is forwarding requests
- **Event logging** — Structured SQLite event log with 24-hour retention; optional gzip payload capture for debugging
- **Status snapshots** — Atomic JSON snapshots at `~/.tokenpulse/proxy_status.json` for external tooling

### General

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

- **Local caching proxy** — TokenPulse can sit between your AI tools and the upstream API, keeping prompt caches warm between requests. This is a cost optimization layer that no usage tracker offers — it actively saves you money rather than just reporting what you've spent.
- **ZenMux support** — TokenPulse supports ZenMux out of the box via their official Management API. ZenMux is a niche provider that CodexBar doesn't cover, and likely too niche for them to want to maintain.
- **One gauge, one glance** — CodexBar shows two stacked bars per provider with multiple display modes. TokenPulse shows a single battery gauge with the remaining percentage right in the icon — you get your answer without interpreting bar heights or switching modes.
- **Minimal by design** — TokenPulse is ~28 source files with a simple `UsageProvider` protocol and an actor-based proxy subsystem. No SwiftSyntax macros, no helper processes, no multi-strategy fallback chains. The entire codebase is easy to audit, fork, and modify.
- **Machine-readable output** — Every poll cycle writes raw provider data to `~/.tokenpulse/raw_usage.json`, and the proxy writes status snapshots to `~/.tokenpulse/proxy_status.json`. Shell scripts and external tools can consume both without scraping or IPC.

If you use many AI providers and want comprehensive coverage, use CodexBar. If you use Codex, Claude, and/or ZenMux and want something small and direct — especially with cost optimization through cache-warming — TokenPulse is for you.

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

## Local proxy

TokenPulse includes an optional local HTTP proxy that sits between your AI tools (e.g. Claude Code) and the upstream Anthropic-compatible API. It forwards requests transparently while adding two capabilities: **cache-warming keepalives** that reduce API costs, and **per-session observability** that tracks token usage, bytes, and estimated cost in real-time.

### Setup

1. Open **Settings > Proxy** and toggle **Enable local proxy**
2. Set the **upstream URL** (defaults to `https://zenmux.ai/api/anthropic`)
3. Point your AI tool at the proxy:

```bash
export ANTHROPIC_BASE_URL=http://localhost:8080
```

The proxy listens on `127.0.0.1` only (IPv4 loopback) and never binds all interfaces.

### How it works

The proxy is a full HTTP/1.1 server built on Network.framework. It identifies sessions via `X-Claude-Code-Session-Id` headers and tracks each independently:

- **Forwarding** — Requests are forwarded to the upstream URL with streaming SSE passthrough. Token usage is parsed from both JSON responses and SSE `data:` chunks in real-time.
- **Cost tracking** — Per-session counters track input/output/cache-read/cache-write tokens and estimate cost using per-model pricing tables. The popover shows active sessions with their request counts and running cost.
- **Traffic indicator** — When the proxy forwards a request, the menu bar slash animates with a bouncing orange glow, settling back to gray when traffic stops.

### Cache-warming keepalives

Anthropic's prompt cache has a 5-minute TTL. If your next request arrives after the cache expires, the full prompt is re-cached at a cost of ~1.25x base input tokens. Keepalives prevent this by sending minimal requests (`max_tokens=1`) that read the cache at ~0.10x base input tokens — a net saving of ~1.15x per avoided cache write.

Keepalives extract cache-relevant fields (system prompt, messages, tools, tool_choice, thinking config) from real requests and replay them periodically. They run per session (up to 5 concurrent), auto-disable after 5 cumulative failures or after the configured inactivity timeout, and stop when the proxy is turned off. The popover shows estimated net savings.

### Observability

The proxy writes structured event logs to `~/.tokenpulse/proxy_events.sqlite` (SQLite, WAL mode) and atomic status snapshots to `~/.tokenpulse/proxy_status.json` (throttled to 1-second intervals). Events are pruned after 24 hours with 5-minute sweep cycles.

Optional payload capture stores gzip-compressed request/response bodies to `~/.tokenpulse/proxy_payloads/` (disabled by default, 24-hour retention).

For the full proxy architecture, request flow, SQLite schema, and keepalive economics, see [docs/proxy.md](docs/proxy.md).

### Configuration

All fields are in `~/.tokenpulse/config.json`:

| Field | Default | Description |
|-------|---------|-------------|
| `proxyEnabled` | `false` | Start the local proxy on launch |
| `proxyPort` | `8080` | Listening port on 127.0.0.1 |
| `proxyUpstreamURL` | `https://zenmux.ai/api/anthropic` | Upstream API to forward requests to |
| `keepaliveEnabled` | `false` | Send cache-warming keepalives between requests |
| `keepaliveIntervalSeconds` | `240` | Seconds between keepalive requests |
| `proxyInactivityTimeoutSeconds` | `900` | Disable keepalives for a session after this many idle seconds |
| `saveProxyEventLog` | `true` | Write event metadata to SQLite |
| `saveProxyPayloads` | `false` | Capture full request/response bodies (privacy-sensitive) |

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
├── Proxy/          # HTTP server, request forwarder, keepalive manager, session store, event logger, metrics
├── Views/          # PopoverView, SettingsView (SwiftUI)
└── Rendering/      # BarIconRenderer (Core Graphics)
```

See also: [docs/proxy.md](docs/proxy.md) (proxy architecture), [docs/providers.md](docs/providers.md) (API specs), [docs/animation.md](docs/animation.md) (icon animation).

## Adding a new provider

1. Create a new file in `Providers/` implementing the `UsageProvider` protocol
2. Implement `classifyError(_:)` to map your provider's errors to `FailureDisposition` cases
3. Register it in `AppDelegate.applicationDidFinishLaunching`
4. Add any auth UI to `SettingsView` if needed

## License

MIT
