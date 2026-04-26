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
- visible in the proxy UI as the **orange leaf indicator** on the selected done row, plus a per-session footer carrying the warm-cost subtotal and the time since the last warm request
- excluded from the content tree as real conversation work — synthetic warm requests never become tree nodes
- logged and costed separately from organic requests via the `proxy_keepalives` SQLite table (event-log schema v7) and the conversation's `KeepaliveSelection.cumulativeCostUSD`

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

- `.activated(KeepaliveSelection)` — the selection is anchored, the cached exchange is pinned, and the lineage path is now warmable.
- `.unknownRequest` — the request is not in the in-memory tree (never attached, or pruned).
- `.requestStillInFlight` — the request hasn't finished.
- `.requestErrored` — the request finished but didn't succeed.
- `.unsupportedFlavor` — the conversation isn't Anthropic Messages.
- `.sourceBodyUnavailable` — the request was successful but its raw exchange has rolled out of the recent-exchange ring.

Once activated, every subsequent warm request goes through `KeepaliveSynthesizer.synthesize(...)` which can refuse to build a body for these reasons:

- the source response was structurally unparseable
- the source response carried a non-completing `stop_reason` (`max_tokens`, `stop_sequence`, `refusal`, or absent)
- the source response had no usable assistant content blocks
- a `tool_use` block was missing or had an empty `id`

# Body synthesis

Warm requests preserve the upstream body as much as possible. The synthesizer copies the source request body verbatim and only edits the `messages` array; cache-identity fields (`model`, `system`, `tools`, `tool_choice`, `thinking`, `output_config.effort`) and other body extras pass through untouched. Headers come from the cached exchange and go upstream as-is, modulo the standard hop-by-hop filter (`Host` / `Content-Length` / `Transfer-Encoding`).

Synthesized bodies force `stream: false` so the warm response is a single JSON document — `stream` is not a cache-identity field and the response shape only matters to the local handler. The synthetic suffix sent after the moving breakpoint is the literal text `"say hi"`.

Existing system-level cache anchors are preserved. Existing message-level `cache_control` markers are stripped from every message and every `content` block before the new moving breakpoint is installed; this keeps the total `cache_control` count within Anthropic's per-request limit.

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

`KeepaliveSynthesizer.exactReplay(observedRequestBody:)` accepts a previously-observed organic request body and wraps it as a `Plan` with `frontierKind == .exactReplay`. The intended use is to replay a body that already resolves the prior `tool_use` (so reconstruction is unnecessary).

The MVP does not yet auto-route to this path — every manual warm request goes through `synthesize(...)`. Wiring exact replay to follow-up organic requests is future work and lives behind issue #4's "automatic keep-alive" track.

# Timing

The MVP fires warm requests synchronously in response to the user's "Send keep-alive" click — there is no scheduler. The default Anthropic ephemeral cache lifetime is still 5 minutes; the user is responsible for spacing their clicks.

Auto-deactivation is automatic, however, and runs in the session store:

- **Path branched** — when a node has more than one in-flight successor in the lineage tree, the conversation's selection is dropped. Detected during `attachToTree`.
- **Pruned** — when the source request, node, or conversation is removed by the 24-hour content-tree prune cycle, the selection is dropped.
- **Source session expired** — when the source session bucket expires, the selection is dropped.

Each of these calls back through `LocalProxyController.onKeepaliveDeactivated` so the AppDelegate can surface a user notification (`NotificationService.sendProxyKeepaliveDisabled`).

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
- **Synthetic warm requests** — never appear as a row. The forwarder fork bypasses `attachToTree` and never registers a `ProxyRequestActivity`. Their existence is communicated only through the per-session keep-alive footer.

The session keep-alive footer renders below the row list when the session has at least one active selection. It carries:

- the literal label `keep-alive` in orange
- the cumulative warm-cost subtotal (only when > 0)
- the time since the most recent successful or failed warm, formatted with `compactElapsed` (the same 4-character format the per-request age timer uses); `--:--` placeholder when no warm has been sent yet

Right-click context menus on done request rows expose **Activate keep-alive** (when no selection is anchored on this leaf) or **Send keep-alive** / **Stop keep-alive** (when this row is the selected leaf). The session header menu adds matching **Send keep-alive** / **Stop keep-alive** entries beside **Hide session** when at least one selection exists in the session. The **Activate** entry is gated on `ConfigService.keepaliveEnabled`; **Send** / **Stop** stay visible for already-anchored selections so a user who toggles the global flag off can still wind down.

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
