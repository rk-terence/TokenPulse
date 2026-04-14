---
title: Proxy Subsystem
description: Architecture, request flow, keepalive behavior, request observability, retention, and event logging details for the local Anthropic-compatible proxy.
---

The proxy is an optional local HTTP proxy that sits between AI tools (e.g. Claude Code) and an upstream Anthropic-compatible API. It forwards requests transparently while adding two capabilities: cache-warming keepalives that reduce costs by preventing prompt cache eviction, and usage observability with per-request token tracking and cost estimation.

# Why it exists

Anthropic's prompt caching charges a 25% premium on cache writes but offers a 90% discount on cache reads. When a cached prompt expires (5-minute TTL), the next request incurs the full write cost again. The proxy sends periodic minimal requests to keep the cache warm between real requests, converting expensive cache misses into cheap cache reads. It also provides complete visibility into token usage, model selection, and per-request cost that the upstream API does not surface to end users.

# Architecture

```
                           +--------------------------+
                           | LocalProxyController     |
                           | @MainActor, @Observable  |
                           | lifecycle owner, UI state |
                           +-----+----+----+----+-----+
                                 |    |    |    |
              +------------------+    |    |    +------------------+
              |                       |    |                       |
   +----------v-----------+  +-------v----v-------+  +-----------v-----------+
   | ProxyHTTPServer       |  | ProxySessionStore   |  | ProxyMetricsStore     |
   | Sendable (locks)      |  | actor               |  | actor                 |
   | Network.framework     |  | per-session state    |  | aggregated counters   |
   | 127.0.0.1 listener    |  | request activity     |  | savings formula       |
   +----------+------------+  +----------+----------+  +-----------+-----------+
              |                          |                          |
   +----------v-----------+  +----------v-----------+  +-----------v-----------+
   | AnthropicForwarder    |  | KeepaliveManager     |  | ProxyEventLogger      |
   | Sendable (immutable)  |  | actor                |  | actor                 |
   | URLSession forwarding |  | per-session loops    |  | SQLite (WAL mode)     |
   | streaming + buffered  |  | cache warming        |  | status snapshots      |
   +----------+------------+  +----------------------+  +-----------------------+
              |
   +----------v-----------+
   | ProxyModels.swift     |
   | value types, utils    |
   | TokenUsage, pricing   |
   +----------------------+
```

## Actor isolation model

The subsystem uses four distinct isolation domains:

| Component | Isolation | Rationale |
|-----------|-----------|-----------|
| `LocalProxyController` | `@MainActor` | Owns `@Observable` state for SwiftUI binding. Only holds UI snapshots -- never does I/O. |
| `ProxySessionStore` | `actor` | Mutable per-session state (in-flight counts, token accumulators, request context). Must serialize concurrent access from forwarder and keepalive manager. |
| `KeepaliveManager` | `actor` | Owns per-session `Task` handles and generation counters. Isolated to prevent races on task lifecycle. |
| `ProxyMetricsStore` | `actor` | Simple aggregated counters. Separate actor avoids contention with the more complex session store. |
| `ProxyEventLogger` | `actor` | All SQLite and file I/O. Isolated so database writes never block the main thread or request forwarding. |
| `ProxyHTTPServer` | `Sendable` (lock-based) | Uses `NSLock`-protected `LockedBox` containers for connection and task tracking. Runs on a dedicated `DispatchQueue`. Cannot be an actor because Network.framework callbacks require synchronous state access. |
| `AnthropicForwarder` | `Sendable` (immutable) | Holds only immutable config and a thread-safe `URLSession`. All mutable state is passed in as actor references. |

The design keeps all hot-path state (session tracking, metrics, event logging) off `@MainActor`. The controller's 2-second refresh task and 50ms traffic-coalesced refresh read snapshots from the actors and publish them to `@Observable` properties on the main thread.

## Session retention vs UI visibility

The proxy keeps session state in memory longer than it keeps every session visible in the popover.

- **Retention in memory**: a session is evicted only when it has no in-flight requests and its most recent activity (`max(lastSeenAt, lastKeepaliveAt)`) is older than 24 hours.
- **Visibility in UI**: a session row is shown when it was active within the last 10 minutes, or when it still has active requests. Retained done requests do not keep an otherwise inactive session visible.
- **Request visibility follows session visibility**: requests are rendered only inside their parent session row, so if a session is filtered out of the UI, all of its requests are hidden with it.

Done requests are stored in memory per session. They are not time-evicted. A done request disappears only when it is replaced by a newer done request whose prompt contains the older prompt for the same model, or when the entire session expires.

Replacement uses a normalized prompt descriptor built from prompt-shaping request fields (`system`, `tools`, `tool_choice`, `thinking`, and ordered `messages`). The descriptor intentionally ignores or normalizes request-shape differences that would otherwise defeat containment checks even when the conversational context is effectively nested. In particular:

- Claude Code injects a `system` entry beginning with `x-anthropic-billing-header:` whose `cch=...` value changes across requests.
- `cache_control` metadata may appear on one request and be omitted from an equivalent replayed message on a later request.
- Message content may be encoded either as a plain string or as an array of text blocks.

Those differences are excluded or normalized before replacement matching so later same-model requests can correctly replace earlier requests in the done list.

# Request flow

A complete request lifecycle from client connection to response delivery:

```
1. Client connects to 127.0.0.1:<port>
2. ProxyHTTPServer accepts NWConnection, starts on server DispatchQueue
3. Server reads data incrementally until \r\n\r\n header boundary found
4. Headers parsed: method, path, header tuples, Content-Length validation
5. If Content-Length present, body accumulated until complete
6. Route validation: only POST /v1/messages accepted (404/405 otherwise)
7. NWResponseWriter created, request dispatched to handler closure
8. AnthropicForwarder.forward() invoked:
   a. Extract X-Claude-Code-Session-Id header (default: "unknown")
   b. Touch session in ProxySessionStore (create if new)
   c. Increment in-flight count
   d. Store request context (body, headers, model)
   e. Extract model name from JSON body
   f. Log request start to ProxyEventLogger
   g. Build upstream URLRequest (copy headers, skip host/content-length/transfer-encoding)
   h. Determine streaming mode from body's "stream" field
   i. Forward via streaming or non-streaming path (see below)
   j. Write status snapshot
   k. If the request completed without error, evaluate lineage and start/reset keepalive
   l. Decrement in-flight count
```

## Streaming path (SSE)

When the request body has `"stream": true`:

1. Per-request `StreamingDelegate` and ephemeral `URLSession` created
2. Upload task started; `didSendBodyData` callbacks track upload progress
3. When upload completes, request transitions to `.waiting` state
4. Response headers awaited via `AsyncStream<Result<HTTPURLResponse, Error>>`
5. Headers forwarded to client with `Transfer-Encoding: chunked`
6. Request transitions to `.receiving`
7. Data chunks arrive via `didReceive data:` delegate callback
8. Each chunk: written to client via chunked encoding, bytes tracked in session store
9. Response body accumulated up to 4MB for token usage parsing
10. On stream completion: chunked terminator sent, token usage parsed from SSE events
11. Token usage and cost recorded in session store and metrics store

## Non-streaming path (buffered JSON)

When the request body has `"stream": false` (or absent):

1. Shared `NonStreamingPoolDelegate` session used for TCP/TLS connection reuse
2. `TaskContext` registered by task identifier for multiplexed callbacks
3. Upload task started with progress tracking
4. Response headers awaited, body chunks accumulated in memory
5. Complete response written to client with `Content-Length` header
6. Token usage parsed from JSON response body
7. Token usage and cost recorded

## Error handling

- Invalid upstream URL: 502 Bad Gateway (Anthropic JSON error format)
- Upstream connection/timeout errors: 502 Bad Gateway
- Client disconnect during streaming: upstream task cancelled, logged as client disconnect
- Upstream 4xx/5xx: forwarded to client as-is (status code preserved)
- Headers too large (>64KB): 400 Bad Request
- Content-Length too large (>50MB): 400 Bad Request
- Duplicate Content-Length: 400 Bad Request (request smuggling prevention)

All proxy-generated error responses use Anthropic's error JSON format:

```json
{
  "type": "error",
  "error": {
    "type": "api_error",
    "message": "Bad Gateway: upstream error: ..."
  }
}
```

# Keepalive strategy

## How it works

When a real request completes successfully for a session, the proxy evaluates it against the tracked main-agent lineage. Only non-errored done requests are candidates — failed requests are ignored so lineage is never established from a request that didn't succeed upstream. If the request is accepted as a lineage continuation, the proxy starts (or resets) a keepalive loop for that session.

1. **Extract cache-relevant fields**: The proxy stores the lineage request body per session. The `KeepaliveRequestBuilder` extracts all cache-identity-relevant fields (system prompt, messages, tools, tool_choice, cache_control, thinking config) and discards the rest.

2. **Build minimal request**: `stream` is set to `false` and `max_tokens` is set to 1 (or `budget_tokens + 1` when thinking mode is enabled, since `max_tokens` must exceed `budget_tokens`). This produces the cheapest possible request that still exercises the cache.

3. **Per-session loops**: Each session gets its own `Task` running in the `KeepaliveManager` actor. A generation counter ensures that when a loop is reset (due to a new real request), the old task's cleanup is a no-op.

4. **Loop cycle**: Sleep for the configured interval, then check inactivity timeout and cumulative failure count before sending the keepalive. Parse the response for cache metrics. Record success/failure.

5. **Headers**: The stored headers from the most recent successful lineage request are copied (excluding hop-by-hop headers: host, content-length, transfer-encoding). This preserves authentication and API version headers.

## Auto-disable conditions

A keepalive loop stops under any of these conditions:

| Condition | Behavior |
|-----------|----------|
| Inactivity timeout | Session's `lastSeenAt` exceeds `proxyInactivityTimeoutSeconds` (default: 900s). Loop exits silently. |
| Cumulative failures >= 5 | Keepalive permanently disabled for the session. User notification sent. Lifecycle event logged. |
| Auth failure (401/403) | Keepalive permanently disabled immediately. |
| Proxy shutdown | All loops cancelled via `shutdown()`, which sets `acceptsNewKeepalives = false` and suppresses late status snapshots. |
| New real request | Existing loop cancelled and replaced with a new one (generation counter incremented). |

Failures that count toward the cumulative limit: HTTP 429, HTTP 5xx, non-HTTP responses, and network errors.

## Cost economics

Each keepalive request processes the full prompt through the cache but generates minimal output (1 token). The cost profile:

- **Keepalive cost**: ~0.10x the base input token price per request (cache read rate = 10% of input rate)
- **Avoided cache miss cost**: ~1.15x the base input token price (cache write rate = 125% of input rate, minus the cache read cost)
- **Savings formula**: `max(0, totalCacheReads * 1.15 - totalKeepalivesSent * 0.10)`

Note: `totalCacheReads` in the metrics store is only incremented from keepalive results (not real requests), so it serves as a proxy for "cache misses avoided."

## Configuration

The keepalive system can be reconfigured at runtime without restarting the proxy. `LocalProxyController.updateKeepaliveConfiguration()` calls `KeepaliveManager.reconfigure()`, which restarts all active loops with the new settings and preserved session headers. When keepalive is toggled from disabled to enabled, existing sessions with stored request context are bootstrapped immediately.

# Token usage tracking

## Parsing

Token usage is extracted from upstream responses by `ProxyHTTPUtils.parseTokenUsage()`:

**Non-streaming (JSON)**: Parse the top-level `usage` object:

```json
{
  "usage": {
    "input_tokens": 1200,
    "output_tokens": 350,
    "cache_read_input_tokens": 800,
    "cache_creation_input_tokens": 0
  }
}
```

**Streaming (SSE)**: Usage is split across two event types in the SSE stream:

- `message_start` event: `message.usage` contains `input_tokens`, `cache_read_input_tokens`, `cache_creation_input_tokens`
- `message_delta` event: `usage` contains `output_tokens`

The parser scans SSE lines (`data: ...` prefix), deserializes each as JSON, and stops early after `message_delta` (the last event with usage data). Streaming responses are accumulated up to 4MB for parsing.

## Model pricing table

Cost estimation uses per-model rates (USD per million tokens). The table matches model IDs by longest prefix:

| Model prefix | Input | Output | Cache read | Cache write |
|-------------|-------|--------|------------|-------------|
| `claude-opus-4-6` | $5 | $25 | $0.50 | $6.25 |
| `claude-opus-4-5` | $5 | $25 | $0.50 | $6.25 |
| `claude-opus-4-1` | $15 | $75 | $1.50 | $18.75 |
| `claude-opus-4-` (catch-all) | $15 | $75 | $1.50 | $18.75 |
| `claude-opus-3` | $15 | $75 | $1.50 | $18.75 |
| `claude-sonnet-4` | $3 | $15 | $0.30 | $3.75 |
| `claude-sonnet-3` | $3 | $15 | $0.30 | $3.75 |
| `claude-haiku-4-5` | $1 | $5 | $0.10 | $1.25 |
| `claude-haiku-3-5` | $0.80 | $4 | $0.08 | $1.00 |
| `claude-haiku-3` | $0.25 | $1.25 | $0.03 | $0.30 |

Cost formula per request:

```
cost = (input_tokens * inputPerMTok
      + output_tokens * outputPerMTok
      + cache_read_tokens * cacheReadPerMTok
      + cache_creation_tokens * cacheWritePerMTok) / 1,000,000
```

Unrecognized model IDs return `nil` pricing and no cost is estimated.

## Accumulation

Token usage is recorded at three levels:

1. **Per-request**: `ProxyRequestActivity.tokenUsage` and `.estimatedCost` populated when the request completes
2. **Per-session**: `ProxySessionStore.Session` accumulates `totalInputTokens`, `totalOutputTokens`, `totalCacheReadInputTokens`, `totalCacheCreationInputTokens`, and `estimatedCostUSD`
3. **Aggregate**: `ProxyMetricsStore` tracks global totals across all sessions

A cumulative cost counter (`cumulativeEstimatedCostUSD`) in `ProxySessionStore` survives session expiration. It can be reset to zero via `resetCost()`.

# Event logging

## Database

Events are persisted to `~/.tokenpulse/proxy_events.sqlite` using SQLite with WAL (Write-Ahead Logging) mode. WAL mode allows concurrent reads during writes and avoids blocking the proxy hot path. Additional pragmas: `foreign_keys = ON`, `synchronous = NORMAL`.

The database is opened lazily on first write. The `SQLITE_OPEN_NOMUTEX` flag is used since the actor provides serialization.

## Tables

### `proxy_requests`

Stores one row per forwarded API request (real requests, not keepalives).

| Column | Type | Description |
|--------|------|-------------|
| `id` | INTEGER PK | Auto-increment row ID |
| `session` | TEXT NOT NULL | Client session ID |
| `model` | TEXT | Model name extracted from request body |
| `method` | TEXT NOT NULL | HTTP method (always POST) |
| `path` | TEXT NOT NULL | Request path (always /v1/messages) |
| `upstream_url` | TEXT NOT NULL | Full upstream URL |
| `streaming` | INTEGER NOT NULL | 1 if SSE streaming, 0 otherwise |
| `started_at` | TEXT NOT NULL | ISO 8601 timestamp |
| `completed_at` | TEXT | ISO 8601 timestamp (null if in-flight) |
| `status_code` | INTEGER | Upstream HTTP status code |
| `duration_ms` | INTEGER | Wall-clock duration in milliseconds |
| `upstream_request_id` | TEXT | `request-id` or `x-request-id` from upstream |
| `input_tokens` | INTEGER | Input token count from response |
| `output_tokens` | INTEGER | Output token count from response |
| `cache_read_tokens` | INTEGER | Cache read input tokens |
| `cache_creation_tokens` | INTEGER | Cache creation input tokens |
| `error` | TEXT | Error message (proxy-side or upstream) |
| `errored` | INTEGER | 1 if the request errored |

Indexes: `started_at`, `(session, started_at)`, `(model, started_at)`, `(status_code, started_at)`, `upstream_request_id`.

### `proxy_keepalives`

Stores one row per keepalive request.

| Column | Type | Description |
|--------|------|-------------|
| `id` | INTEGER PK | Auto-increment row ID |
| `session` | TEXT NOT NULL | Session the keepalive is warming |
| `started_at` | TEXT NOT NULL | ISO 8601 timestamp |
| `completed_at` | TEXT | ISO 8601 timestamp |
| `success` | INTEGER | 1 if successful, 0 if failed |
| `status_code` | INTEGER | Upstream HTTP status code |
| `duration_ms` | INTEGER | Wall-clock duration in milliseconds |
| `upstream_request_id` | TEXT | Upstream request ID header |
| `input_tokens` | INTEGER | Input token count |
| `output_tokens` | INTEGER | Output token count |
| `cache_read_tokens` | INTEGER | Cache read input tokens |
| `cache_creation_tokens` | INTEGER | Cache creation input tokens |
| `error` | TEXT | Error message if failed |

Indexes: `started_at`, `(session, started_at)`.

### `proxy_lifecycle`

Stores proxy lifecycle events (start, stop, session expiration, keepalive disable).

| Column | Type | Description |
|--------|------|-------------|
| `id` | INTEGER PK | Auto-increment row ID |
| `ts` | TEXT NOT NULL | ISO 8601 timestamp |
| `type` | TEXT NOT NULL | Event type (see below) |
| `session` | TEXT | Session ID (when applicable) |
| `port` | INTEGER | Listening port (for `proxy_started`) |
| `reason` | TEXT | Disable reason (for `keepalive_disabled`) |
| `failure_count` | INTEGER | Cumulative failures (for `keepalive_disabled`) |

Event types: `proxy_started`, `proxy_stopped`, `session_expired`, `keepalive_disabled`.

Index: `ts`.

### `proxy_request_content`

Optional table for full request/response payload capture (enabled by `saveProxyPayloads`). Uses foreign key cascade delete from `proxy_requests`.

| Column | Type | Description |
|--------|------|-------------|
| `request_id` | INTEGER PK | References `proxy_requests(id)` |
| `upstream_request_id` | TEXT | Upstream request ID for cross-reference |
| `request_json` | TEXT | Serialized request (method, path, headers, body) |
| `response_json` | TEXT | Serialized response (status, headers, body) |

Bodies are serialized as UTF-8 text when possible, otherwise base64. Streaming responses are capped at 4MB of accumulated data; the `truncated` flag indicates when the body was cut short.

Index: `upstream_request_id`.

## Retention and pruning

- Maximum event age: 24 hours
- Prune sweep interval: every 5 minutes (checked before each new event insertion)
- Pruning deletes from all three primary tables (`proxy_requests`, `proxy_keepalives`, `proxy_lifecycle`) where `started_at` / `ts` is older than the cutoff
- `proxy_request_content` rows are cascade-deleted when their parent `proxy_requests` row is pruned
- A `PRAGMA wal_checkpoint(PASSIVE)` follows each prune sweep

## INSERT strategy

Request logging uses a two-phase approach:

1. `logRequestStarted()` inserts a row with only the start fields, returns the row ID
2. `logRequestCompleted()` or `logRequestFailed()` updates the existing row via the returned ID

If the initial insert fails, the completion/failure method falls back to a standalone INSERT with all fields.

# Status snapshots

The proxy writes an atomic JSON snapshot to `~/.tokenpulse/proxy_status.json` after each request completion and each keepalive iteration. This file can be read by external tools to monitor proxy state.

## Format

```json
{
  "enabled": true,
  "port": 8080,
  "activeSessions": 2,
  "activeKeepalives": 1,
  "totalRequestsForwarded": 47,
  "totalKeepalivesSent": 12,
  "totalKeepalivesFailed": 0,
  "cacheReads": 10,
  "cacheWrites": 3,
  "totalInputTokens": 245000,
  "totalOutputTokens": 18200,
  "totalCacheReadInputTokens": 180000,
  "totalCacheCreationInputTokens": 12000,
  "lastUpdatedAt": "2026-04-13T10:30:00Z"
}
```

## Throttling

Writes are throttled to a minimum 1-second interval to avoid excessive disk I/O during high-throughput streaming. When a snapshot arrives within the throttle window:

1. The snapshot is stored as `pendingStatusSnapshot`
2. A delayed `Task` is scheduled for the remaining throttle interval
3. When the task fires, the pending snapshot is written

Force writes (used during proxy shutdown) bypass the throttle and cancel any pending flush.

During `KeepaliveManager.shutdown()`, status snapshot writes are suppressed entirely so the controller can write the final state.

# Configuration

All proxy settings live in `~/.tokenpulse/config.json` and are managed by `ConfigService`. Changes take effect on next proxy start unless otherwise noted.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `proxyEnabled` | Bool | `false` | Whether the proxy starts automatically with the app |
| `proxyPort` | Int | `8080` | TCP port to bind on 127.0.0.1 |
| `proxyUpstreamURL` | String | `"https://zenmux.ai/api/anthropic"` | Base URL for upstream API forwarding |
| `keepaliveEnabled` | Bool | `false` | Whether cache-warming keepalive loops are active |
| `keepaliveIntervalSeconds` | Int | `240` | Seconds between keepalive requests per session |
| `proxyInactivityTimeoutSeconds` | Int | `900` | Seconds of session inactivity before keepalive stops |
| `saveProxyEventLog` | Bool | `true` | Whether to persist events to SQLite |
| `saveProxyPayloads` | Bool | `false` | Whether to capture full request/response payloads in SQLite |

The `ProxyEventLogger` is enabled when either `saveProxyEventLog` or `saveProxyPayloads` is true. Payload capture (`proxy_request_content` table) requires `saveProxyPayloads` specifically.

Keepalive settings (`keepaliveEnabled`, `keepaliveIntervalSeconds`, `proxyInactivityTimeoutSeconds`) can be changed at runtime via `LocalProxyController.updateKeepaliveConfiguration()` without stopping the proxy.

# Constraints

| Constraint | Value | Enforced by |
|------------|-------|-------------|
| Bind address | `127.0.0.1` (IPv4 loopback only) | `ProxyHTTPServer` via `NWEndpoint.hostPort(host: .ipv4(.loopback))` |
| Supported endpoint | `POST /v1/messages` only | `ProxyHTTPServer.dispatchRequest()` |
| Max Content-Length | 50 MB (`50_000_000` bytes) | `ProxyHTTPServer.processRequest()` |
| Max header size | 64 KB (`65_536` bytes) | `ProxyHTTPServer.readRequest()` |
| Max concurrent keepalive loops | 1 per session (design limit: 5 sessions) | `KeepaliveManager.activeTasks` dictionary |
| Max cumulative keepalive failures | 5 per session | `KeepaliveManager.maxCumulativeFailures` |
| Session retention | 24 hours since last activity | `LocalProxyController.sessionRetentionSeconds` |
| Session expiration sweep | Every 60 seconds | `LocalProxyController.sessionExpirationSweepInterval` |
| Session UI visibility cutoff | 10 minutes since last activity, unless active or done requests still exist | `LocalProxyController.startRefreshTask()` / `scheduleTrafficRefresh()` |
| Done request retention | Until replaced or session expiration | `ProxySessionStore` |
| Event retention | 24 hours | `ProxyEventLogger.maxEventAge` |
| Event prune sweep | Every 5 minutes | `ProxyEventLogger.pruneInterval` |
| Status snapshot throttle | 1-second minimum interval | `ProxyEventLogger.statusSnapshotThrottleInterval` |
| Streaming response capture | 4 MB max for token parsing | `AnthropicForwarder.maxLoggedStreamingResponseBytes` |
| UI refresh interval | 2 seconds (periodic) + 50ms coalesced (traffic) | `LocalProxyController.startRefreshTask()` / `scheduleTrafficRefresh()` |
| URLSession timeouts | 300s request / 600s resource (forwarding); 30s request / 60s resource (keepalive) | `AnthropicForwarder` and `KeepaliveManager` init |

# Key files

| File | Role |
|------|------|
| `Proxy/LocalProxyController.swift` | `@MainActor` lifecycle owner; starts/stops server; publishes `@Observable` UI state; periodic and traffic-triggered refresh tasks |
| `Proxy/ProxyHTTPServer.swift` | Network.framework HTTP/1.1 listener; connection tracking; header/body parsing; `NWResponseWriter` for chunked and buffered responses |
| `Proxy/AnthropicForwarder.swift` | Builds upstream `URLRequest`; streaming via per-request `StreamingDelegate`; non-streaming via shared `NonStreamingPoolDelegate` session; token usage parsing and recording |
| `Proxy/KeepaliveManager.swift` | Actor; per-session keepalive loops with generation counters; failure counting; inactivity timeout; reconfiguration without restart |
| `Proxy/ProxySessionStore.swift` | Actor; session lifecycle (touch/expire); in-flight request tracking with state machine (uploading/waiting/receiving/done); token accumulation; byte counters; traffic callbacks |
| `Proxy/ProxyEventLogger.swift` | Actor; SQLite database management (WAL mode); request/keepalive/lifecycle event tables; pruning; status snapshot writes with throttling |
| `Proxy/ProxyMetricsStore.swift` | Actor; aggregated counters for forwarded/failed requests, keepalives, cache hits/misses; savings formula |
| `Proxy/ProxyModels.swift` | Value types: `ProxyHTTPRequest`, `ProxyRequestActivity`, `ProxyRequestState`, `TokenUsage`, `ModelPricing`, `ModelPricingTable`, `KeepaliveRequestBuilder`, `ResponseWriter` protocol, `ProxyHTTPUtils` |
