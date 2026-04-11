# Design Doc: Add a Local Anthropic Proxy + Cache Keepalive to TokenPulse

## Summary

Extend TokenPulse from a passive usage monitor into a **combined monitor + local Anthropic-compatible proxy** for personal use on macOS. The proxy will listen on `localhost`, forward Claude Code `POST /v1/messages` requests upstream, track sessions using `X-Claude-Code-Session-Id`, and send periodic keepalive requests to preserve Anthropic prompt-cache warmth across long generations and idle gaps. TokenPulse remains lightweight: live proxy/session state stays in memory, while optional JSON/JSONL disk output is used for observability and debugging. This fits TokenPulse’s existing design philosophy: small codebase, simple file-backed config, and machine-readable local output.

## Motivation

Anthropic prompt caching uses a default **5-minute TTL**, refreshes when cached content is used again, and also offers an optional **1-hour TTL**. In practice, your observed API-console logs suggest that **long in-flight streamed generations do not keep the cache warm by themselves**, so a later turn can fall back to a cache write instead of a cheaper cache read. Anthropic’s public docs are consistent with that interpretation but do not explicitly document TTL refresh during active streaming. This makes a local keepalive workaround reasonable for personal use when you want to stay on the default 5-minute cache pricing model instead of moving to the vendor-supported 1-hour TTL.

## Goals

- Add a minimal local proxy for Anthropic `POST /v1/messages`
- Preserve streaming behavior for Claude Code
- Scope proxy state per Claude Code session using `X-Claude-Code-Session-Id`
- Keep the most recent cache-key-equivalent request warm with periodic keepalives
- Surface proxy/cache metrics in TokenPulse UI and file exports
- Keep the implementation small, auditable, and personal-use friendly

## Non-goals

- Building a general-purpose AI gateway
- Supporting many providers through the proxy layer
- Persisting all prompts by default
- Multi-user auth, tenancy, or centralized admin UI
- Replacing TokenPulse’s current polling-based provider monitoring

## Key product decision

Do **not** model the proxy as a new `UsageProvider`.

`ProviderManager` and `PollingManager` are `@MainActor` classes built around short-lived polling refresh cycles. `UsageProvider` itself is a `Sendable` protocol (not `@MainActor`), but is called from `@MainActor` code. A local proxy is different: it needs long-lived streaming passthrough, background keepalive tasks, session tracking, and disconnect handling. The proxy should be a separate subsystem that publishes summarized metrics back into the existing UI/export layer.

## External facts the design relies on

Claude Code sends `X-Claude-Code-Session-Id` on every API request. The Claude Code changelog documents this header as being intended for proxies to aggregate requests from one session without parsing the body. Anthropic prompt caching caches the prompt **prefix**, has a default **5-minute lifetime**, refreshes when cached content is used again, and supports an optional **1-hour TTL** (at **2x** base input price, compared to **1.25x** for the default 5-minute TTL). These are the core external contracts this design depends on.

* * *

## Architecture

### High-level flow

`Claude Code -> TokenPulse Local Proxy -> upstream API (ZenMux or other compatible gateway)`

TokenPulse will now have two parallel subsystems:

1. **Existing monitoring path**
   - unchanged
   - polls provider usage on a timer
   - updates menu bar and popover UI
2. **New proxy path**
   - local HTTP listener on `127.0.0.1:8080`
   - handles Anthropic-compatible `/v1/messages`
   - forwards to configurable upstream (ZenMux or other gateway)
   - streams response back to Claude Code
   - manages per-session keepalive loops

This keeps the current app behavior intact while adding an optional local proxy mode.

### Recommended Swift module layout

Add a new folder:

```text
TokenPulse/
├── Proxy/
│   ├── LocalProxyController.swift
│   ├── ProxyHTTPServer.swift
│   ├── AnthropicForwarder.swift
│   ├── ProxySessionStore.swift
│   ├── ProxySession.swift
│   ├── KeepaliveManager.swift
│   ├── ProxyMetricsStore.swift
│   ├── ProxyEventLogger.swift
│   └── ProxyModels.swift
```

Keep all proxy hot-path state out of `@MainActor` code. Use one or more actors for session state and metrics aggregation, then publish UI-safe summaries back to the main actor.

* * *

## Component design

### 1. LocalProxyController

Owns lifecycle.

Responsibilities:

- load proxy config from `ConfigService`
- start/stop local server
- create shared session store, metrics store, logger, and forwarder
- expose lightweight status to UI

This gets instantiated from `AppDelegate.applicationDidFinishLaunching`, alongside current provider registration and polling startup. `AppDelegate` is already the central bootstrap point, so that is the cleanest place to wire it in.

### 2. ProxyHTTPServer

Minimal local HTTP server.

Responsibilities:

- listen on `127.0.0.1:<port>`
- route `POST /v1/messages`
- reject unsupported endpoints with a clear local error
- parse request headers/body
- hand off to `AnthropicForwarder`

A full server framework is unnecessary. Keep it narrow and local.

### 3. AnthropicForwarder

Responsible for upstream request execution.

Responsibilities:

- forward the incoming request to the configured upstream URL (default: `https://zenmux.ai/api/anthropic`; or another Anthropic-compatible gateway)
- preserve all incoming headers, including `Authorization`, `anthropic-version`, and `anthropic-beta`
- do not assume the upstream is Anthropic directly — the gateway may add or transform headers
- stream upstream chunks back to Claude Code
- capture usage/caching data from the response
- report lifecycle events to metrics/logger/session store

### 4. ProxySessionStore

An actor keyed by `X-Claude-Code-Session-Id`.

Each session stores:

- `sessionID`
- `lastSeenAt`
- `lastRequestBody`
- `lastCacheableRequestBody`
- `keepaliveTask`
- `inFlightRequestCount`
- `lastKeepaliveAt`
- `keepaliveSuccessCount`
- `keepaliveFailureCount`
- `lastCacheReadTokens`
- `lastCacheCreationTokens`
- `lastKnownModel`

This is the authoritative live state for the proxy.

### 5. KeepaliveManager

Runs one keepalive loop per session.

Behavior:

- start or reset when a real `/v1/messages` request arrives
- wait `keepaliveIntervalSeconds` between pings
- stop when inactivity exceeds `proxyInactivityTimeoutSeconds`
- skip or back off after repeated failures

The loop is **per session**, not per request. A canceled user turn should not automatically end keepalive for the entire session.

### 6. ProxyMetricsStore

Aggregated, UI-friendly metrics.

Example fields:

- `proxyEnabled`
- `listeningPort`
- `activeSessionCount`
- `activeKeepaliveCount`
- `totalRequestsForwarded`
- `totalKeepalivesSent`
- `totalCacheReads`
- `totalCacheWrites`
- `estimatedWriteAvoidanceSavings`
- `lastError`

These are the values that should reach the popover/settings UI and file export.

### 7. ProxyEventLogger

Optional lightweight file output.

Recommended files:

- `~/.tokenpulse/proxy_status.json`
- `~/.tokenpulse/proxy_events.jsonl`

`proxy_status.json` is the latest snapshot.

`proxy_events.jsonl` is append-only and suited for debugging, charts, and shell analysis.

This matches TokenPulse’s current pattern of simple machine-readable file output and keeps the design consistent with the existing app.

* * *

## Request lifecycle

### Incoming real request

On each incoming `POST /v1/messages`:

1. Read headers and extract `X-Claude-Code-Session-Id`
2. Store/update session in `ProxySessionStore`
3. Save the most recent request body for that session
4. Forward request to configured upstream (`proxyUpstreamURL` + `/v1/messages`)
5. Stream upstream response back to Claude Code
6. Parse response usage/cache metrics when available
7. Start or reset keepalive loop for that session
8. Update metrics and write optional event log

### Keepalive request

Every ~4 minutes for an active session:

1. Load most recent cache-key-equivalent request body
2. Build keepalive request
3. Override only fields believed not to affect cache identity:
   - `max_tokens = 1`
   - `stream = false`
4. Send upstream
5. Record whether response showed cache read or cache creation
6. Continue until inactivity timeout or repeated failure threshold

### Downstream disconnect cases

If Claude Code disconnects mid-stream:

- cancel the upstream request
- do **not** immediately end the session
- keep the keepalive loop alive
- rely on inactivity timeout to stop later

This covers both:

- user pressing `ESC` during a turn
- user quitting while a turn is active

The proxy does not need to distinguish those two cases.

* * *

## Cache identity and request-body handling

Use **“same cache-key-relevant prompt prefix”**, not **“exact same request bytes.”**

The proxy should preserve:

- `tools`
- `tool_choice`
- `system`
- `messages`
- cache breakpoints / `cache_control`
- thinking configuration (enabling/disabling extended thinking changes cache identity)

The proxy should not assume that irrelevant request fields can be changed unless validated. In practice, `max_tokens` and `stream` are the intended mutable fields for the keepalive. Treat that as an engineering assumption, not a vendor guarantee.

Implementation recommendation:

- store the last full request body as received
- derive the keepalive body by decoding and mutating a structured model
- preserve key order and serialization style only if testing proves it matters
- add a feature flag to switch between:
  - structured mutation
  - near-verbatim replay with minimal field patching

* * *

## Configuration changes

Extend `ConfigService` with:

```swift
var proxyEnabled: Bool
var proxyUpstreamURL: String
var proxyPort: Int
var keepaliveIntervalSeconds: Int
var proxyInactivityTimeoutSeconds: Int
var saveProxyPayloads: Bool
var saveProxyEventLog: Bool
```

Recommended defaults:

- `proxyEnabled = false`
- `proxyUpstreamURL = "https://zenmux.ai/api/anthropic"`
- `proxyPort = 8080`
- `keepaliveIntervalSeconds = 240`
- `proxyInactivityTimeoutSeconds = 900`
- `saveProxyPayloads = false`
- `saveProxyEventLog = true`

TokenPulse already stores config in a simple JSON file under `~/.tokenpulse/config.json`, so this extension is mechanically straightforward.

* * *

## UI changes

### Settings

Add a new **Claude Proxy** section in `SettingsView`:

- Enable local proxy
- Upstream URL (e.g. `https://zenmux.ai`)
- Port
- Keepalive interval
- Inactivity timeout
- Save event log
- Save raw payloads for debugging

### Popover

Add a compact proxy status section:

- Proxy: on/off
- Port
- Active sessions
- Keepalive loops running
- Last keepalive result
- Cache reads / writes
- Estimated savings

Keep it compact. TokenPulse’s strength is one-glance clarity; avoid turning the UI into a gateway dashboard.

* * *

## Storage and persistence

### Recommended default

For personal use:

- **memory only** for live session state
- **JSON snapshot + JSONL log** for persistence

Do **not** start with SQLite.

Why:

- simpler
- consistent with current app style
- enough for personal debugging and trend tracking
- lower implementation cost

### Suggested files

`~/.tokenpulse/proxy_status.json`

Example:

```json
{
  "enabled": true,
  "port": 8080,
  "activeSessions": 2,
  "activeKeepalives": 2,
  "totalRequestsForwarded": 18,
  "totalKeepalivesSent": 11,
  "cacheReads": 9,
  "cacheWrites": 2,
  "estimatedSavingsBaseInputMultiples": 8.4,
  "lastUpdatedAt": "2026-04-10T19:22:31Z"
}
```

`~/.tokenpulse/proxy_events.jsonl`

Each line:

```json
{"ts":"2026-04-10T19:20:00Z","type":"request_started","session":"...","model":"claude-sonnet-..."}
{"ts":"2026-04-10T19:24:00Z","type":"keepalive_sent","session":"..."}
{"ts":"2026-04-10T19:24:01Z","type":"keepalive_result","session":"...","cacheReadTokens":1234,"cacheCreationTokens":0}
```

### Payload persistence

Default: **off**

If enabled:

- write request payloads to a separate directory
- gzip-compress them
- keep short retention
- clearly label this as storing prompt content locally

This matters because Anthropic’s prompt-caching docs emphasize their own cache behavior, but once TokenPulse persists raw payloads, that privacy boundary moves into your app.

* * *

## Economics model

Anthropic prompt caching on the 5-minute TTL has materially different economics between cache write and cache read. Your design note should treat the value proposition as:

5-minute TTL (what this proxy targets):

- cache write: `1.25x`
- cache read: `0.10x`
- avoided write vs read: `1.15x`
- avoided write with one extra keepalive: `1.05x`

1-hour TTL (the vendor-supported alternative):

- cache write: `2.00x`
- cache read: `0.10x`
- no keepalive needed, but writes cost 60% more than 5-minute writes

The keepalive approach is economically justified when the cost of keepalive pings (`0.10x` each) is less than the savings from avoiding repeated 5-minute cache writes (`1.15x` each). Switching to 1-hour TTL avoids keepalive complexity entirely but increases every cache write from `1.25x` to `2.00x`.

In TokenPulse, compute savings conservatively:

- `estimatedSavings = max(0, avoidedWrites * 1.15 - keepalives * 0.10)`

Also show raw counters so the estimate is transparent.

* * *

## Failure handling

### Upstream `429` or `5xx`

- skips this keep-alive attempt
- keep session alive unless inactivity timeout expires
- surface last error in metrics/UI

### Auth failure

- stop keepalive for that session
- keep proxy alive globally
- show clear local error

### Repeated keepalive cache misses

- mark session as degraded
- optionally stop keepalive after `N` misses
- do not spam upstream if the mechanism is not working

### Network interruption

- retry conservatively
- bounded by inactivity timeout

### App exit

- cancel all in-memory keepalive tasks
- flush final status snapshot
- no special persistence recovery required in `v1`

* * *

## Validation plan

This is the most important engineering checkpoint.

Anthropic returns cache usage data in `usage`, including cache read / creation counters. Use those fields to verify:

1. keepalive requests produce cache reads rather than cache writes
2. the next real user turn benefits from cache reads instead of re-creation

Validation sequence:

1. Run Claude Code through the proxy
2. Send a request with prompt caching enabled
3. Let generation exceed ~5 minutes or idle beyond ~5 minutes
4. Compare behavior:
   - without keepalive
   - with keepalive
5. Confirm that the next request’s usage shifts from cache creation to cache read

Until this test passes, the core mechanism is still only a plausible design.

* * *

## Suggested implementation phases

### Phase 1: local passthrough proxy

Deliverables:

- local server on `localhost:8080`
- handle `POST /v1/messages`
- forward request upstream
- stream response back
- extract `X-Claude-Code-Session-Id`
- basic metrics

Acceptance:

- Claude Code works through the proxy
- no visible streaming regression

### Phase 2: session store + keepalive

Deliverables:

- `ProxySessionStore`
- `KeepaliveManager`
- inactivity timeout
- keepalive request generation

Acceptance:

- one keepalive loop per session
- keepalive stops after inactivity
- downstream disconnect does not immediately kill session state

### Phase 3: observability

Deliverables:

- parse response usage/cache metrics
- `proxy_status.json`
- `proxy_events.jsonl`
- popover/settings proxy status

Acceptance:

- cache read/write counts visible
- event log usable for debugging

### Phase 4: hardening

Deliverables:

- backoff/jitter
- degraded-session handling
- optional payload capture
- better UI wording

Acceptance:

- stable behavior under upstream errors
- minimal noise when keepalive stops being useful

* * *

## Suggested task split for your coding agents

Since you are using agent roles, here is a clean breakdown.

### Leader

Owns:

- final architecture decisions
- interface contracts
- merge decisions
- validation criteria
- final docs

Prompt focus:

- preserve TokenPulse simplicity
- keep proxy isolated from provider polling path
- insist on measured validation before feature claims

### Developer

Owns implementation in this order:

1. proxy server + upstream forwarding
2. session store
3. keepalive loop
4. config + settings
5. metrics export

Guardrails:

- no broad refactors
- no gateway framework
- no SQLite in `v1`
- no moving existing provider logic into proxy code

### Reviewer

Owns:

- streaming correctness review
- actor/concurrency review
- cancellation/disconnect handling
- privacy/storage review
- validation-plan review

Checklist:

- no `@MainActor` hot-path mistakes
- no leaked tasks on session expiry
- no accidental prompt persistence by default
- no breaking of current polling UX

* * *

## Claude subagent setup for this work

Since Claude Code supports custom subagents and skills, the setup is:

- shared repo rules in `AGENTS.md` (via `CLAUDE.md`): build commands, code style, constraints, architecture
- orchestration via `/lead` skill (`.claude/skills/lead.md`): activated on demand in any session
- developer implementation via subagent (`.claude/agents/developer.md`): scoped tasks only
- code review via `/codex:rescue`: correctness, concurrency, and style

The orchestration workflow is decoupled from the main session. Any session can do regular work or activate leader mode by invoking `/lead`. Subagents do not see the orchestration layer — they only see their own task scope and the shared `AGENTS.md` constraints.

* * *

## Acceptance criteria

The feature is done when all of these are true:

- Claude Code can use `ANTHROPIC_BASE_URL=http://localhost:8080`
- TokenPulse forwards `POST /v1/messages` correctly to the configured upstream (ZenMux or other gateway)
- streaming works normally
- sessions are tracked by `X-Claude-Code-Session-Id`
- keepalive loops start/reset/stop correctly
- cache metrics are captured and visible
- local file outputs are stable and machine-readable
- no raw payloads are stored by default
- app remains lightweight and easy to audit
- empirical tests show that keepalive improves cache-read behavior for the target workflow

* * *

## Open questions

- Does changing `max_tokens` and `stream` preserve Anthropic cache identity in all relevant cases?
- Are there additional request fields that invalidate the cache entry unexpectedly?
- Should the proxy expose any local auth or bind only to loopback?
- Should payload capture support redaction before disk write?
- Is there any need to support non-Claude clients in `v2`?
- Does ZenMux (or other Anthropic-compatible gateways) pass through prompt caching headers and `cache_control` breakpoints transparently, or does the gateway layer affect cache identity? This must be validated empirically — the proxy's keepalive mechanism is only useful if the upstream gateway preserves Anthropic's caching behavior end-to-end.
- Do upstream gateways return the same `cache_read_input_tokens` / `cache_creation_input_tokens` usage fields in their responses, or do they strip or rename them?

* * *

## Recommended first commit sequence

1. Add config fields and settings toggles
2. Add `Proxy/` folder with empty controller/store/models
3. Wire proxy start/stop from `AppDelegate`
4. Implement local `/v1/messages` passthrough
5. Add session extraction and metrics
6. Add keepalive loop
7. Add JSON status/event export
8. Add popover/settings visibility
9. Run validation experiment
10. Tighten docs and defaults

* * *

## Final recommendation

Build this as a **small, isolated proxy subsystem inside TokenPulse**, not as a new provider and not as a general gateway. Keep live state in memory, write only lightweight JSON/JSONL observability files by default, and treat cache-refresh behavior as an empirical feature that must be validated in your environment before claiming success. That approach matches both TokenPulse’s current architecture and your personal-use constraint.
