---
title: Proxy Keep-alive Mechanism
description: Design for synthetic Anthropic cache-warming requests in the TokenPulse proxy gateway.
---

Keep-alive is TokenPulse's planned proxy-side cache-warming mechanism. It sends synthetic Anthropic Messages requests derived from a selected Claude Code lineage path so the upstream prompt-cache prefix stays warm while the user is likely to continue the same session.

This mechanism is not a normal generation feature. A keep-alive request exists to refresh Anthropic prompt-cache state, measure whether the refresh worked, and stay out of the user's durable conversation history.

# Status and scope

The first iteration of keep-alive ships as a manual MVP:

- manual, user-triggered, and disabled by default behind `ConfigService.keepaliveEnabled` (Settings ▸ Proxy ▸ Keep-alive)
- Anthropic Messages only
- Claude Code sessions only (Anthropic-flavored sessions in the proxy)
- one selected lineage path per conversation; activating on a new request replaces the previous selection for that conversation
- visible in the proxy UI as the **orange leaf indicator** on the selected done row, **a yellow ⚡ row while a warm is in flight**, **a gray ⚡ row at the bottom of the session for the latest completed warm**, and an inline **`ka $xx (n_ka)`** cluster in the session header carrying the cumulative warm-cost subtotal and warm-attempt count
- excluded from the content tree as real conversation work — synthetic warm requests never become tree nodes
- logged and costed separately from organic requests via the `proxy_keepalives` SQLite table (event-log schema v7) and the per-session `KeepaliveSessionHistory` bucket (`ProxySessionStore.keepaliveHistoryBySession`)

Automatic idle keep-alive can be considered later, but only after the manual path proves that synthetic requests consistently produce high cache reads and low incremental cache writes.

# References

Relevant Anthropic documentation:

- Prompt caching: <https://platform.claude.com/docs/en/build-with-claude/prompt-caching>
- Tool call handling: <https://platform.claude.com/docs/en/agents-and-tools/tool-use/handle-tool-calls>
- Tool use with prompt caching: <https://platform.claude.com/docs/en/agents-and-tools/tool-use/tool-use-with-prompt-caching>
- Adaptive thinking and effort: <https://platform.claude.com/docs/en/build-with-claude/adaptive-thinking>

# Terms

- **Organic request**: a request sent by the client tool, such as Claude Code.
- **Warm request**: a synthetic request sent by TokenPulse to refresh prompt-cache state.
- **Selected path**: the single root-to-leaf lineage path chosen by the user for keep-alive.
- **Frontier**: the latest content block TokenPulse wants the next real Claude Code request to reuse from cache.
- **Breakpoint**: the block carrying Anthropic `cache_control`.
- **Synthetic suffix**: the minimal user-side tail appended after the breakpoint so Anthropic returns a tiny response.
- **Unresolved tool use**: an assistant `tool_use` whose real `tool_result` has not yet appeared in an organic request. From the proxy's perspective this includes both a long-running tool and a tool waiting for user permission.

# API constraints

Prompt caching is prefix and exact-match based. Keep-alive should preserve the request shape that the next organic Claude Code request is likely to reuse.

Do not mutate cache-identity fields in a warm request:

- `model`
- `system`
- `tools`
- `tool_choice`
- `thinking`
- `output_config.effort`
- context-management fields
- beta headers and other Anthropic cache-affecting headers

Changing effort, thinking, tools, or `tool_choice` to make the synthetic response cheaper can defeat the cache-warming purpose.

Anthropic tool-use protocol also matters. When an assistant message contains `tool_use` blocks, the next user message must begin with matching `tool_result` blocks. A warm request that appends ordinary user text after an unresolved `tool_use` must therefore insert matching placeholder `tool_result` blocks first.

# Eligibility

A request is eligible for manual keep-alive activation only when all of these are true:

- The selected request belongs to Anthropic Messages traffic.
- The request reached a successful terminal state (`succeeded == true`).
- The request's full upstream exchange (raw request body + headers + raw response) is still cached in TokenPulse's bounded recent-exchange ring (capacity `ProxySessionStore.recentKeepaliveExchangeCapacity`, currently 64). Older requests roll out of the ring; the user must pick a fresher leaf.

`ProxySessionStore.activateKeepalive(forRequestID:)` enforces these and returns one of:

- `.activated(KeepaliveSelection)` — the selected path is activated at the chosen done request, the cached exchange is retained by request ID, and the lineage path is now warmable.
- `.unknownRequest` — the request is not in the in-memory tree (never attached, or pruned).
- `.requestStillInFlight` — the request hasn't finished.
- `.requestErrored` — the request finished but didn't succeed.
- `.unsupportedFlavor` — the conversation isn't Anthropic Messages.
- `.sourceBodyUnavailable` — the request was successful but its raw exchange has rolled out of the recent-exchange ring.

After activation, the source follows the chosen lineage path:

- While there is no active successor, the current selected done request is the latest source. Warm requests use its observed request body plus response body to synthesize the next frontier.
- When exactly one active successor appears under the selected done request, the selection remains active and the warm source moves to that active request's observed request body and headers. There is no response frontier yet, so warm requests use exact replay of that body with `stream: false`.
- When that active successor succeeds, the orange selected-row indicator advances to the new done request and future warm requests synthesize from the new request/response exchange.
- When that active successor fails or is cancelled, the selection stays on the prior successful done request.
- When more than one active successor appears under the selected done request, the path is considered branched and keep-alive is auto-deactivated for that conversation.

Warm requests based on a completed source go through `KeepaliveSynthesizer.synthesize(...)` which can refuse to build a body for these reasons:

- the source response was structurally unparseable
- the source response carried a non-completing `stop_reason` (`max_tokens`, `stop_sequence`, `refusal`, or absent)
- the source response had no usable assistant content blocks
- a `tool_use` block was missing or had an empty `id`

# Body synthesis

Warm requests preserve the upstream body as much as possible. The synthesizer copies the source request body verbatim and only edits the `messages` array; cache-identity fields (`model`, `system`, `tools`, `tool_choice`, `thinking`, `output_config.effort`) and other body extras pass through untouched. Headers come from the cached exchange and go upstream as-is, modulo the standard hop-by-hop filter (`Host` / `Content-Length` / `Transfer-Encoding`).

Synthesized bodies force `stream: false` so the warm response is a single JSON document — `stream` is not a cache-identity field and the response shape only matters to the local handler. The synthetic suffix sent after the moving breakpoint is the literal text `"say hi"`.

Existing system-level cache anchors are preserved. Existing message bytes, including message-level `cache_control` markers, are preserved verbatim; the warmer only appends the new frontier messages and installs the new moving breakpoint in those appended bytes.

Do not synthesize cache breakpoints inside Claude Code `user` messages. User messages can contain harness reminders, task notifications, diagnostics, interruption markers, and user prompt text in provider-specific order. Unless TokenPulse is replaying an exact observed request, user-message interiors are not safe rewrite targets.

## Case 1: assistant text frontier

Use this when the selected done request's assistant response ended in normal assistant text and did not leave unresolved tool use.

1. Append the exact assistant message content that Claude Code is expected to include in the next organic request.
2. Put `cache_control` on the last eligible assistant content block, normally the final assistant text block.
3. Append a tiny synthetic user suffix after the breakpoint, such as a request for a one-token acknowledgement.
4. Keep the synthetic suffix outside the cached prefix.

The intended shape is:

```text
... previous messages
assistant.text              <-- cache_control here
user.text synthetic suffix  <-- outside cached prefix
```

## Case 2: unresolved tool-use frontier

Use this when the selected done request's assistant response ended with one or more unresolved `tool_use` blocks. This can mean the tool is running for a long time or Claude Code is waiting for user permission to start it.

1. Append the exact assistant message, including all `tool_use` blocks.
2. Put `cache_control` on the last assistant `tool_use` block.
3. Add a following user message whose first content blocks are placeholder `tool_result` blocks matching every unresolved `tool_use.id`.
4. Put the tiny synthetic user suffix after the placeholder `tool_result` blocks.
5. Do not put `cache_control` on the placeholder result.

The intended shape is:

```text
... previous messages
assistant.tool_use                 <-- cache_control here
user.tool_result placeholder        <-- protocol shim, outside cached prefix
user.text synthetic suffix          <-- outside cached prefix
```

The placeholder result should be clearly synthetic and error-like. Claude Code has been observed using the text:

```text
[Tool result missing due to internal error]
```

TokenPulse may use the same placeholder text with `is_error: true`, but the placeholder must remain after the breakpoint. Its purpose is only to make the warm request valid under Anthropic's tool-use protocol. It must not become the cache frontier.

When Claude Code later sends the real organic request, that request should reuse the cached prefix through `assistant.tool_use` and then provide the real success or error `tool_result`.

## Exact replay

`KeepaliveSynthesizer.exactReplay(observedRequestBody:)` accepts a previously-observed organic request body and wraps it as a `Plan` with `frontierKind == .exactReplay`, forcing `stream: false` so the warm response is parseable as JSON usage. The intended use is to replay a body that already resolves the prior `tool_use` (so reconstruction is unnecessary), or to warm from the latest active request body before a response frontier exists.

Manual warm requests route to exact replay only while the latest keep-alive path source is active. Completed sources still use frontier synthesis.

# Timing

The MVP fires warm requests synchronously in response to the user's "Send keep-alive" click — there is no scheduler. The default Anthropic ephemeral cache lifetime is still 5 minutes; the user is responsible for spacing their clicks.

Auto-deactivation runs in the session store. All paths remove the selection entirely; per-session history in `keepaliveHistoryBySession` is not affected:

- **Path branched** — when the selected done request has more than one in-flight descendant in the lineage tree, the conversation's selection is removed. Detected during `attachToTree`. To restart, the user must right-click a done row and pick `Activate keep-alive` again.
- **Pruned** — when the source request, node, or conversation is removed by the 24-hour content-tree prune cycle, the selection is dropped because there's nothing to point at.
- **Source session expired** — when the source session bucket expires, the selection and its history bucket are both dropped.

Each of these calls back through `LocalProxyController.onKeepaliveDeactivated` so the AppDelegate can surface a user notification (`NotificationService.sendProxyKeepaliveDisabled`, labeled "Proxy keep-alive stopped").

Future automatic keep-alive, if added, should be:

- idle-based rather than periodic forever
- scheduled before expiry, for example around 4m30s with jitter
- stopped when the selected path diverges (already enforced)
- stopped when the session appears complete
- easy to disable globally (`ConfigService.keepaliveEnabled` covers the manual MVP) and per session (per-session disable is future work)

Keep-alive should not continue after the user is clearly done with a session.

# UI behavior

The proxy popover row distinguishes:

- **Organic active requests** — left edge accent: the system accent color, drawn by `RequestActivityRow` when `isActive == true`.
- **Organic done requests** — no left-edge indicator.
- **Selected keep-alive leaf** — left edge accent: orange (`Color.orange`), drawn by `RequestActivityRow` when `isKeepaliveLeaf == true`. A done row is never simultaneously the active indicator and the keep-alive indicator, so the two colors never appear on the same row.
- **Warm active rows** — left edge accent: a yellow ⚡ glyph (`Image(systemName: "bolt.fill")`), drawn whenever `request.kind == .keepalive && isActive == true`. The row carries the same stat fields as an organic active row (model name, ↑ bytes, ↓ bytes, ttft, age) because `ProxyForwarder.sendKeepaliveWarmRequest` registers the warm as a real `ProxyRequestActivity` and drives it via `StreamingDelegate`.
- **Warm done row (latest only)** — left edge accent: a gray ⚡ glyph. Pinned at the bottom of the session's done list. Only one survives per session: each new completion replaces the previous (the activity snapshot lives on `KeepaliveSessionHistory.lastWarmActivity` in `ProxySessionStore.keepaliveHistoryBySession`, updated during `recordKeepaliveResult`). The stat fields differ — instead of the standard ↑/↓/e2e/$ block, the warm done row shows `R%` (cache read), `W%` (cache creation), `e2e`, and `$cost`. For Anthropic, the cache-quality denominator is `input_tokens + cache_read_input_tokens + cache_creation_input_tokens` because cached input tokens are reported separately.

The session header carries an inline `ka $xx (n_ka)` cluster (between `done N` and `$T`) when the session has any completed warm attempts. `$xx` is `keepaliveCostUSD` and `n_ka` is `keepaliveDoneCount` — both read from the per-session `KeepaliveSessionHistory` bucket and persist across stop/restart cycles. The trailing `$T` is the **total** session cost (organic + KA — the rollup happens in `ProxySessionStore.recordKeepaliveResult`). The proxy-wide `$T` at the top of the popover similarly includes warm cost via the `accumulateCost` call inside the same method.

Right-click context menus on done request rows expose **Activate keep-alive** (when no selection exists for this leaf) or **Send keep-alive** / **Stop keep-alive** (when this row is the selected leaf). Clicking Stop removes the selection; to restart, the user must right-click a done row again and pick **Activate keep-alive** — there is no Resume action. The session header menu adds matching **Send keep-alive** / **Stop keep-alive** entries beside **Hide session** when at least one selection exists in the session. The **Activate** entry is gated on `ConfigService.keepaliveEnabled`; **Send** / **Stop** stay visible for already-active selections so a user who toggles the global flag off can still wind down. Warm rows themselves expose no menu — `RequestActivityRow.supportsKeepaliveMenu` filters on `request.kind.storesDoneActivity` which `.keepalive` returns false for.

# Concurrency

At most one warm runs per conversation at any given time. The actor-level check-and-set is `ProxySessionStore.beginManualKeepaliveDispatch(forConversationID:)`, which atomically returns `.dispatched(KeepaliveWarmSource, warmID:)` (and stamps `inFlightWarmRequestID = warmID` on the selection) only when no warm is currently in flight; otherwise it returns `.alreadyInFlight`. `recordKeepaliveResult` clears `inFlightWarmRequestID` matching the warm UUID on every exit path (success, failure, refused, cancelled).

The popup gates the menu off the same flag: `SessionActivity.hasKeepaliveInFlight` disables the session-menu **Send keep-alive**, and `SessionActivity.isKeepaliveInFlight(forConversationID:)` disables the row-level **Send keep-alive**. The actor-level refusal remains as a defensive backstop in case a click slips through between render and dispatch.

# Logging

Every warm request emits one row to the `proxy_keepalives` table (added in event-log schema v7) when `ConfigService.saveProxyEventLog` is on. The row carries the spec-required audit fields, mapped one-to-one onto columns by `ProxyEventLogger.logKeepaliveAttempt(_:)`:

| Spec field | Column |
| --- | --- |
| synthetic request id | `id` |
| started / completed timestamps | `started_at`, `completed_at` |
| source conversation / node / request | `conversation_id`, `source_node_id`, `source_request_id` |
| source session id | `source_session` |
| frontier kind (`assistant_text`, `assistant_tool_use`, `exact_replay`, or `refused`) | `frontier_kind` |
| frontier block descriptor (e.g. `messages[7].content[2] (text)`) | `frontier_descriptor` |
| placeholder inserted | `placeholder_inserted` |
| placeholder tool_use IDs (JSON array) | `placeholder_tool_use_ids` |
| upstream HTTP status / request id | `upstream_status`, `upstream_request_id` |
| `cache_read_input_tokens` | `cache_read_tokens` |
| `cache_creation_input_tokens` | `cache_creation_tokens` |
| output tokens | `output_tokens` |
| estimated warm cost (USD) | `estimated_cost_usd` |
| succeeded | `succeeded` |
| failure reason | `failure_reason` |

Refusals from `KeepaliveSynthesizer` and pre-flight failures (invalid upstream URL, invalid HTTPS proxy setting) record a row with `frontier_kind = "refused"` (for synthesis refusals) or with the chosen frontier kind plus `succeeded = 0` and a populated `failure_reason` (for pre-flight failures). Selections that vanish racily between user-click and the synthesizer (e.g. user-deactivation arriving first) emit no row, since there is nothing to attribute the attempt to.

Rows are pruned with the rest of the proxy event log on the 24-hour retention cycle. Raw exact request/response capture still obeys the bounded raw-capture policy and is unaffected by keep-alive.

# Verification

A warm request counts as successful when it returns a 2xx upstream response with parseable usage. The audit row captures the cache-read / cache-creation / output token counts that the spec uses to judge whether the cache was actually warmed. The current MVP does **not** automatically compare the warm-prefix tokens to the next organic request's tokens — that comparison is done manually against `proxy_keepalives` joined to `proxy_requests` while inspecting the SQLite database.

A warm strategy should be treated as successful only when:

- the audit row reports high `cache_read_tokens` relative to the selected prefix
- the audit row's incremental `cache_creation_tokens` stays low
- the next organic Claude Code request reuses the warmed prefix in its `proxy_requests.cache_read_tokens`
- the synthetic suffix text and placeholder tool results do not appear in the later main-path request body

Manual smoke testing remains the verification path; no automated tests cover keep-alive yet.

# Non-goals

- Do not implement always-on keep-alive as the first version.
- Do not generalize this behavior to non-Anthropic providers without separate evidence.
- Do not rewrite ordinary user traffic to improve cache placement.
- Do not invent real tool results. Placeholder results are protocol shims only.
- Do not change effort, thinking, or tool choice to reduce warm-request output.
