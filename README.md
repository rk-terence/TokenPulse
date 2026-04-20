# TokenPulse

A macOS menu bar app that monitors AI platform token usage and adds local proxy observability for supported AI tools. A compact `↑ ↓ | NN%` menu bar icon shows the active provider's primary-window utilization at a glance, while the optional proxy tracks per-session traffic, token usage, and estimated cost.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue) ![Swift 5](https://img.shields.io/badge/Swift-5-orange)

## Features

### Usage monitoring

- **Menu bar icon** — Compact `↑ ↓ | NN%` display with upload/download activity and the active provider's primary-window utilization
- **Multiple providers** — Right-click the icon to cycle between providers
- **Click for details** — Left-click opens a popover with per-provider breakdown, quota windows, reset timers, and more
- **Usage notifications** — macOS notifications when a provider's primary window crosses 50% or 80%, and when quota windows reset
- **Graceful degradation** — Shows stale data on transient errors, surfaces auth guidance on credential issues, dims icon when refreshing
- **Machine-readable export** — Provider refresh results update a normalized status snapshot at `~/.tokenpulse/raw_usage.json` for shell scripts and external tools

### Local proxy

- **Universal lineage tree** — Groups proxied requests by provider-specific cache identity (model + system/instructions + tools + `tool_choice` + thinking/reasoning). Anthropic strips prompt-caching markers; OpenAI preserves ordered `input` items, including non-message items, while normalizing string content shorthands to typed text input.
- **Per-session cost tracking** — Tracks token usage, bytes transferred, and estimated cost per tracked proxy session
- **Streaming support** — Full HTTP/1.1 proxy with SSE streaming passthrough; parses token usage from both JSON and SSE responses
- **Traffic indicator** — Menu bar arrows and bar animate when the proxy forwards requests and completions
- **Event logging** — Structured SQLite event log with 24-hour retention, lineage-deduplicated payload capture, and a bounded raw request/response table for exact source-of-truth copies
- **Status snapshots** — Atomic JSON snapshots at `~/.tokenpulse/proxy_status.json` for external tooling whenever `saveProxyEventLog` is enabled

### General

- **Configurable polling** — 60s, 2min, or 5min intervals
- **Outbound HTTPS proxy** — Optional upstream proxy support for provider refreshes and proxied upstream traffic
- **Launch at login** — Optional auto-start via macOS Service Management
- **No Dock icon** — Runs as a pure menu bar app

## Supported providers

| Provider | Auth method | What it shows |
|----------|-------------|---------------|
| **Codex** | Local Codex ChatGPT login (`$CODEX_HOME/auth.json` when `CODEX_HOME` is set; otherwise `~/.codex/auth.json`) | 5h window, weekly window, plan tier |
| **ZenMux** | Management API key | 5h window, 7-day quota, monthly cap, tier, account status |

## Why TokenPulse?

[CodexBar](https://github.com/steipete/CodexBar) is an excellent menu bar usage tracker with 15+ providers and an active community. TokenPulse exists because it makes different trade-offs:

- **Local observability proxy** — TokenPulse can sit between your AI tools and the upstream API, adding per-session traffic, token, and cost visibility plus a universal lineage tree for popup display, lineage-aware payload deduplication, and bounded raw request/response capture. It gives you a view into usage that upstream tools usually do not expose locally.
- **ZenMux support** — TokenPulse supports ZenMux out of the box via their official Management API. ZenMux is a niche provider that CodexBar doesn't cover, and likely too niche for them to want to maintain.
- **One glance, no mode switch** — CodexBar shows two stacked bars per provider with multiple display modes. TokenPulse shows the active provider's primary-window utilization directly in the icon, so you can read current usage without opening a detail view.
- **Minimal by design** — TokenPulse is ~28 source files with a simple `UsageProvider` protocol and an actor-based proxy subsystem. No SwiftSyntax macros, no helper processes, no multi-strategy fallback chains. The entire codebase is easy to audit, fork, and modify.
- **Machine-readable output** — Provider refresh results write a normalized snapshot to `~/.tokenpulse/raw_usage.json`, and the proxy can write status snapshots to `~/.tokenpulse/proxy_status.json` whenever proxy logging infrastructure is enabled. Shell scripts and external tools can consume both without scraping or IPC.

If you use many AI providers and want comprehensive coverage, use CodexBar. If you use Codex and/or ZenMux and want something small and direct with local proxy observability, TokenPulse is for you.

## Install

### Build from source

Requires macOS 14 Sonoma and the Xcode Command Line Tools (`xcode-select --install`). Xcode.app is not required — the full toolchain ships with the Command Line Tools.

```bash
git clone https://github.com/rk-terence/TokenPulse.git
cd TokenPulse

# Debug build
swift build

# Release .app bundle at dist/TokenPulse.app (adhoc-signed)
bash Scripts/package_app.sh

# Install to ~/Applications
mkdir -p ~/Applications
rm -rf ~/Applications/TokenPulse.app
ditto dist/TokenPulse.app ~/Applications/TokenPulse.app
```

#### Signing mode

`Scripts/package_app.sh` reads `TOKENPULSE_SIGNING`:

| Value | Behavior |
|---|---|
| `adhoc` (default) | `codesign --sign -` with `TokenPulse.entitlements`. Launches locally without a developer account. Each rebuild produces a new signature hash, so macOS Keychain and Login Items will prompt for re-approval after every rebuild. |
| `off` | No codesign step. Only useful for debugging the packaging flow. |
| A signing identity | Passed to `codesign --sign`. Adds hardened runtime (`--options runtime`) and applies the entitlements. Use this for a stable signature that doesn't retrigger Keychain/Login Items prompts on rebuild, e.g.:<br/>`TOKENPULSE_SIGNING="Developer ID Application: Your Name (TEAMID)" bash Scripts/package_app.sh` |

## Setup

### Codex provider

TokenPulse reads your existing Codex ChatGPT login from `$CODEX_HOME/auth.json` when `CODEX_HOME` is set. If `CODEX_HOME` is not set, it reads `~/.codex/auth.json`. There is no fallback to `~/.codex/auth.json` when `CODEX_HOME` is set. To set it up:

1. Install the Codex CLI and sign in with ChatGPT via `codex login`
2. Open **Settings > Providers** and enable **Codex**
3. Refresh TokenPulse

If your Codex CLI is currently using API key billing, or TokenPulse shows the Codex provider as not connected because the auth file is unreadable or missing token data, run `codex login` to refresh your ChatGPT subscription login.

### ZenMux provider

1. Get a **Management API Key** from your [ZenMux dashboard](https://zenmux.ai)
2. Open **Settings > Providers > ZenMux** and paste the key
3. Click **Save** — the key is stored securely in your macOS Keychain

TokenPulse uses the management API only for ZenMux. The app shows the monthly cap and billing-cycle reset date exposed by that API, but not a monthly utilization percentage.

## Usage

- **Left-click** the menu bar icon to open the detail popover
- **Right-click** to switch between providers
- Click the **gear icon** in the popover to open Settings

The menu bar icon reads left to right as `↑ ↓ | NN%`:
- **↑ cyan arrow** — glows when the proxy is sending bytes upstream
- **↓ mint arrow** — glows when the proxy is receiving bytes downstream
- **| bar** — neutral gray; warms to orange and carries a particle toward the percentage each time a request completes, as a visual cue that cost just accrued
- **NN%** — the active provider's primary-window (5-hour) utilization; shows `FUL` at 100% in alert red

When the proxy is off, the arrows and bar dim; the percentage stays at its normal brightness because it reflects provider polls, not proxy traffic.

## Local proxy

TokenPulse includes an optional local HTTP proxy that sits between your AI tools and upstream APIs. It currently serves **Anthropic Messages** (`/v1/messages`) and **OpenAI Responses** (`/v1/responses`) on the same local port. It forwards requests transparently while adding two capabilities: a **universal lineage tree** for popup display and lineage-aware payload capture, and **per-session observability** that tracks token usage, bytes, and estimated cost.

### Setup

1. Open **Settings > Proxy** and toggle **Enable local proxy**
2. Set the **Anthropic upstream URL** (defaults to `https://zenmux.ai/api/anthropic`). OpenAI Responses upstream defaults to `https://api.openai.com`
3. Point your AI tool at the proxy:

```bash
export ANTHROPIC_BASE_URL=http://127.0.0.1:8080
```

The proxy listens on `127.0.0.1` only (IPv4 loopback) and never binds all interfaces.

### How it works

The proxy is a full HTTP/1.1 server built on Network.framework. Anthropic Messages traffic uses `X-Claude-Code-Session-Id` for tracked sessions; OpenAI Responses traffic is tracked as Codex session traffic when `session_id` is present and matches the `x-codex-window-id` prefix (`<session_id>:<window_generation>`). The UI groups that traffic by session while the lineage tree handles content-level conversation grouping. Non-Codex OpenAI traffic is grouped as `Other`.

- **Forwarding** — Requests are forwarded to the upstream URL with streaming SSE passthrough. Token usage is parsed from JSON responses and from terminal usage events in SSE streams.
- **Cost tracking** — Per-session counters track input/output/cache-read/cache-write tokens and estimate cost using per-model pricing tables. The popover shows active sessions with their request counts and running cost.
- **Traffic indicator** — When the proxy forwards a request, the menu bar arrows glow and the bar/particle track animates to reflect request and completion activity.

### Keepalive status

Keep-alive (cache-warming replay requests) is not currently implemented. The previous Anthropic-specific manual keepalive surface was removed in favor of the universal lineage tree and shared observability model. A future iteration may reintroduce cache-warming on top of that tree, but it is not part of the live product today.

### Observability

When `saveProxyEventLog` is enabled, the proxy writes structured event logs to `~/.tokenpulse/proxy_events.sqlite` (SQLite with WAL mode and `synchronous = NORMAL`) and atomic status snapshots to `~/.tokenpulse/proxy_status.json` (throttled to 1-second intervals). Events are pruned after 24 hours with 5-minute sweep cycles.

Payload capture is part of the same `saveProxyEventLog` toggle; there is no separate raw-capture opt-in. Lineage-deduplicated per-request extras live in `proxy_request_content`; conversation fingerprints live in `proxy_conversations`; content-tree node deltas are stored in `proxy_nodes.delta_messages_json`; request rows live in `proxy_requests`; lifecycle events live in `proxy_lifecycle`; and exact request/response copies are also stored in `proxy_raw_request_response`, capped to the newest 1000 rows. Streaming response capture is truncated to 4 MB per request.

For the full proxy architecture, request flow, lineage-tree semantics, and SQLite schema, see [docs/proxy.md](docs/proxy.md).

### Configuration

All fields are in `~/.tokenpulse/config.json`:

| Field | Default | Description |
|-------|---------|-------------|
| `proxyEnabled` | `false` | Start the local proxy on launch |
| `proxyPort` | `8080` | Listening port on 127.0.0.1 |
| `anthropicUpstreamURL` | `https://zenmux.ai/api/anthropic` | Anthropic Messages upstream base URL |
| `openAIUpstreamURL` | `https://api.openai.com` | OpenAI Responses upstream base URL |
| `useSystemUpstreamProxy` | `true` | Use the current macOS HTTP/HTTPS proxy settings for outbound upstream traffic when no custom proxy is enabled |
| `upstreamHTTPSProxyEnabled` | `false` | Enable custom upstream proxy overrides |
| `upstreamHTTPProxyURL` | `""` | Custom HTTP proxy URL for HTTP traffic only |
| `upstreamHTTPSProxyURL` | `""` | Custom HTTPS proxy URL for HTTPS traffic only |
| `saveProxyEventLog` | `true` | Master on/off for the proxy event log. When enabled, SQLite metadata, lineage-deduplicated payloads, bounded raw request/response captures, and status snapshots are written; when disabled, no database is opened |

## Data export

TokenPulse updates a normalized provider status snapshot at `~/.tokenpulse/raw_usage.json` whenever a provider refresh result is applied. Example:

```bash
# Get Codex 5-hour utilization
jq '.providers.codex.fiveHour.utilization' ~/.tokenpulse/raw_usage.json

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
Provider usage notifications are sent per provider. Grant notification permission when prompted on first launch.

## Project structure

```
TokenPulse/
├── App/            # AppDelegate, StatusBarController, entry point
├── Models/         # UsageData, ProviderStatus, ProviderConfig
├── Providers/      # UsageProvider protocol + Codex and ZenMux implementations
├── Services/       # KeychainService, ConfigService, PollingManager, ProviderManager, NotificationService
├── Proxy/          # HTTP server, route handlers, request forwarder, session store, event logger, metrics
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
