---
title: Cache Warming and Prompt-Caching Notes
description: Empirical notes from TokenPulse proxy logs about Anthropic prompt-caching behavior, Claude Code cache-control placement, background-task notification shape, and future keep-warm design implications.
---

This document records what we observed in TokenPulse's own proxy logs while investigating Claude Code / Anthropic prompt-caching behavior on 2026-04-22 and 2026-04-23.

It is not a product commitment. It is a design note for a possible future manual or automatic cache-warming feature.

For a broader description of Claude Code's Anthropic request-body structure, async/background-task notification shape, and harness-injected message blocks, see [claude-code-anthropic-structure.md](claude-code-anthropic-structure.md).

# Scope

The investigation used TokenPulse's raw proxy capture, not Claude Code's session storage:

- SQLite log: `~/.tokenpulse/proxy_events.sqlite`
- Primary tables:
  - `proxy_requests`
  - `proxy_raw_request_response`

The most useful evidence came from exact captured Anthropic request bodies plus the recorded token counters:

- `cache_read_tokens`
- `cache_creation_tokens`

# Relevant Anthropic prompt-caching rules

Anthropic's prompt-caching docs are the right model for interpreting these logs:

- Explicit `cache_control` can be attached to `system`, `tools`, or `messages` blocks.
- `{"type":"ephemeral"}` is the default short-lived cache mode. Anthropic documents it as a 5-minute cache.
- Anthropic also supports a longer-lived TTL mode, but it was not present in the captured Claude Code traffic.
- Prefix reuse is exact-match based.
- With an explicit breakpoint, Anthropic also checks earlier block boundaries automatically, up to roughly 20 blocks back.
- Thinking blocks cannot be explicitly marked with `cache_control`.
- Anthropic documents special invalidation behavior around thinking blocks and later non-`tool_result` user content.

Reference:

- [Anthropic prompt caching docs](https://docs.anthropic.com/en/docs/build-with-claude/prompt-caching)

# What Claude Code actually emitted

Across all TokenPulse-captured Claude-family requests in the log sample:

- Total Claude-family requests scanned: `150`
- Requests with any explicit `cache_control`: `149`
- Requests with exactly `3` `cache_control` markers: `149`
- Requests with `0` markers: `1`
- Requests with top-level request `cache_control`: `0`
- Requests with tool-schema `tools[*].cache_control`: `0`
- Requests with `ttl: "1h"`: `0`
- Every explicit marker value was exactly `{"type":"ephemeral"}`

## Stable pattern

In practice, Claude Code used the same structure almost every time:

1. `system[1].cache_control = {"type":"ephemeral"}`
2. `system[2].cache_control = {"type":"ephemeral"}`
3. one moving `messages[*].content[*].cache_control = {"type":"ephemeral"}`

So the effective strategy was:

- two fixed system anchors
- one moving conversation-tail anchor

## Moving message breakpoint distribution

The moving message-level breakpoint landed on:

- `118` requests: last `user.tool_result`
- `27` requests: last `user.text`
- `3` requests: `assistant.text`
- `1` request: `assistant.tool_use` for the `Agent` tool, meaning a subagent spawn request

Note:

- the `assistant.text` and `assistant.tool_use` cases were not requests whose final message was from the assistant
- the `assistant.tool_use` case was specifically a subagent invocation through Claude Code's `Agent` tool
- in those exceptions, Claude Code placed the breakpoint on the last meaningful assistant output, then appended a transient user-side wrapper after it
- the observed examples were recap prompts and side-question wrappers, where the meta-instruction itself was intentionally left outside the cached prefix

That strongly suggests Claude Code was trying to keep the reusable cached prefix anchored near the live edge of the conversation, while leaving the newest transient suffix outside the cached boundary when useful.

# Warm-up side calls observed

Two small Opus side calls were used as cache warmers in the same Anthropic session:

- `id=974` at `2026-04-22T12:08:58Z`
- `id=1056` at `2026-04-22T12:32:01Z`

These were not standalone tiny requests. Each one reused the full main-agent request body and appended only a very small tail.

## First warmer

Main-agent request immediately before it:

- `id=960` at `2026-04-22T12:04:33Z`

Side call:

- `id=974`

Observed diff:

- shared prefix: first `48` messages unchanged
- `974` appended:
  - assistant text about delegating to Sonnet
  - assistant `Agent` tool call
  - user `tool_result`
  - side-question wrapper ending in `say "hi"`

Cache-control placement:

- `960`: trailing breakpoint on the last user request
- `974`: breakpoint moved to the assistant `tool_use` for `Agent`
- the side-question wrapper itself was after that breakpoint

## Second warmer

Main-agent request immediately before it:

- `id=1032` at `2026-04-22T12:27:28Z`

Side call:

- `id=1056`

Observed diff:

- shared prefix: first `70` messages unchanged
- `1056` appended:
  - assistant text: `Plan approved. Delegating implementation to sonnet.`
  - assistant `Agent` tool call
  - user `tool_result` plus `say "hi"`
  - assistant reply: `hi`
  - side-question wrapper ending in `say hi`

Cache-control placement:

- `1032`: trailing breakpoint on the last `user.tool_result`
- `1056`: breakpoint moved to the assistant text `hi`
- the side-question wrapper again sat after that breakpoint

## Why this mattered

The warmers did not appear to create a large new cached prefix. They appeared to cheaply refresh a large existing one.

Relevant counters:

- `1032`: `cache_read_tokens=180273`, `cache_creation_tokens=154`
- `1056`: `cache_read_tokens=180427`, `cache_creation_tokens=3507`
- `1076`: `cache_read_tokens=180427`, `cache_creation_tokens=4957`

Interpretation:

- almost the entire prompt was read from cache
- only a very small suffix needed to be written again
- the tiny side tail was enough to keep the large prefix "alive"

The same pattern also showed up around the earlier warmer:

- `960`: `cache_read_tokens=141251`, `cache_creation_tokens=1728`
- `974`: `cache_read_tokens=142979`, `cache_creation_tokens=8521`
- `988`: `cache_read_tokens=151500`, `cache_creation_tokens=518`

# Recap prompt behavior

The same structural pattern showed up for Claude Code's automatic recap prompts.

Two recap requests were found:

- `id=942` at `2026-04-22T11:13:05Z`
- `id=1093` at `2026-04-22T12:39:55Z`

The recap prompt text was:

`The user stepped away and is coming back. Recap in under 40 words, 1-2 plain sentences, no markdown. Lead with the overall goal and current task, then the one next action. Skip root-cause narrative, fix internals, secondary to-dos, and em-dash tangents.`

## Final recap after the session work

Main-agent request immediately before it:

- `id=1077`

Recap request:

- `id=1093`

Observed diff:

- `1077` ended with a `user.tool_result` carrying the moving `ephemeral` marker
- `1093` removed that marker from the `tool_result`
- `1093` appended:
  - assistant text summarizing the latest state
  - that assistant text became the new `ephemeral` breakpoint
  - the recap prompt itself was appended after the breakpoint

Token counters:

- `1077`: `cache_read_tokens=185384`, `cache_creation_tokens=647`
- `1093`: `cache_read_tokens=186031`, `cache_creation_tokens=456`

That is exactly what we want from a cache-friendly recap:

- the meaningful latest answer becomes part of the cached prefix
- the one-off recap instruction stays outside the cached boundary

# Main takeaway

The strongest observed pattern was not "send a tiny ping." It was:

1. keep the large main-agent prefix unchanged
2. add only a tiny new suffix
3. place the explicit moving breakpoint before the most disposable wrapper or meta-instruction

In other words, the cost win seems to come from preserving cache identity for the expensive shared prefix, not from the literal text `say hi`.

The `say hi` payload was just a very cheap way to create a fresh request that still shared almost all of the expensive prefix.

# Additional findings from later experiments

The follow-up experiments on 2026-04-23 refined the earlier keep-warm hypotheses in a few important ways.

## Background Bash tasks use two different user-side shapes

Claude Code's async/background Bash flow used two distinct request shapes:

1. launch acknowledgment
2. later completion notification

### Launch acknowledgment

The assistant `tool_use` blocks explicitly set:

- `name = "Bash"`
- `input.run_in_background = true`

The immediate next user message then carried ordinary `tool_result` blocks whose payloads looked like:

- `Command running in background with ID: ...`
- `Output is being written to: ...`

So the initial "task accepted" event is still represented as normal tool use / tool result traffic.

### Natural completion notification

When those background tasks finished naturally, the next Anthropic request did **not** use `tool_result`.

Instead, Claude Code injected one or more ordinary `user.text` blocks whose text contained XML-like task notifications:

- `<task-notification>`
- `<task-id>...`
- `<tool-use-id>...`
- `<output-file>...`
- `<status>completed</status>`
- `<summary>...</summary>`

If more than one background task finished before the next request, Claude Code grouped them into one `user` message as multiple `text` blocks, one notification per block.

This matters for keep-warm because an async completion frontier is not a `tool_result` frontier once the task has already been accepted into the background. It becomes a `user.text` frontier.

## Task notifications can be grouped, but merged user-prompt cases looked interrupt-specific

In ordinary non-interrupted flows, the observed background completion notifications were either:

- their own `user` message, or
- grouped with other task-related injected text blocks in the same `user` message

We did observe a case where a `<task-notification>` block and ordinary user prompt text coexisted in the same `user` message, but every such example in the log sample also contained `[Request interrupted by user]`.

So the current best working assumption is:

- treat merged task-notification + ordinary user-prompt messages as an interruption-specific edge case
- do not assume that shape is part of the normal Claude Code assembly pattern

## `<system-reminder>` blocks are not always first inside a user message

The earlier intuition that `<system-reminder>` always appears at the start of a `user` message was too strong.

Across the later log sample, `<system-reminder>` blocks appeared:

- as the first block in a large harness-scaffolding message
- after other `<system-reminder>` blocks in that same message
- after `tool_result` blocks in the same `user` message

Observed reminder families included:

- MCP server instructions
- skill inventory
- current-date / context scaffolding
- task-tools reminders
- diagnostics reminders
- side-question wrappers

That means Claude Code's `user` messages are assembled from multiple harness-side components, not just "the user's latest prompt."

## Practical consequence for keep-warm body synthesis

The safest construction strategy is narrower than we first hoped.

### Safest

- exact replay of an observed organic request body
- exact reuse of an in-flight request body when available

### Usually safe

- advancing a breakpoint only to an observed assistant frontier, such as:
  - `assistant.text`
  - `assistant.tool_use`
- advancing to an observed `user.tool_result` frontier only when replaying the exact real request

### Unsafe without exact replay

- synthesizing a new cache point "inside" a Claude Code `user` message based on semantic guesses about where the stable user prompt starts
- assuming that harness reminders always sit before or after the same categories of user-side content
- treating async completion notifications as if they were always standalone messages

In other words:

- if we only have a done request, exact replay or conservative assistant-boundary reuse is the safe default
- if we have the currently in-flight request body, reusing that exact generation request is safer than reconstructing a future Claude Code `user` message

# Implications for a future TokenPulse feature

Keep-alive is not currently implemented in TokenPulse. If we add it later, the proxy/content-tree work should inform the design.

## Likely safe product shapes

- manual per-session "warm cache" action
- per-session toggle while a long-running child/subagent workflow is active
- automatic idle keep-warm with conservative timing and clear visibility

## Eligibility constraints

A future implementation should probably begin with the narrowest possible scope:

- Anthropic Messages traffic only
- only sessions where prompt-caching evidence is already visible in traffic
- only while a conversation appears active or likely to resume soon
- only when we can identify a strong shared prefix from the content tree or exact recent request body

## Body-shaping guidance

If TokenPulse ever synthesizes a keep-warm request, the investigation suggests:

- preserve the upstream request body as much as possible
- avoid mutating `system`, `tools`, or other cache-identity fields
- keep the appended tail extremely small
- keep the transient keep-warm instruction outside the intended cached prefix
- do not assume the literal text matters; the structure matters more than the wording
- do not synthesize new Claude Code `user`-message interiors unless we are replaying an exact observed body shape
- treat async background-task completion frontiers as `user.text` task-notification frontiers, not `tool_result` frontiers

## Timing guidance

The successful manual warmers in this investigation were sent after a few minutes of Opus inactivity while side-agent work continued.

That suggests a future auto-warm strategy, if one exists at all, should be:

- idle-based, not periodic forever
- conservative, not aggressive
- easy to disable globally and per session

TokenPulse should avoid background traffic that continues after a session is clearly done.

## UX and control requirements

If this becomes a real feature, it should have explicit user control:

- global default off
- clear per-session state
- visible request/cost attribution in the proxy UI
- obvious indication that a keep-warm request was synthetic
- an easy way to stop warming immediately

## Logging requirements

Any future implementation should make investigation easy:

- log whether a request was organic or synthetic
- log which request body or content-tree node it was derived from
- log the chosen warm strategy
- surface before/after `cache_read_tokens` and `cache_creation_tokens`

# Non-goals and cautions

- Do not assume this behavior generalizes to non-Anthropic providers.
- Do not assume every Anthropic client places breakpoints like Claude Code.
- Do not assume TokenPulse should rewrite or inject `cache_control` fields into user traffic by default.
- Do not assume a synthetic request is always cheaper than doing nothing.
- Do not assume a warm request should run once a session is truly complete.
- Do not assume Claude Code's `user` messages are equivalent to a clean "user prompt" plus optional tool results. Harness-injected reminders, notifications, diagnostics, and interruption markers can all appear inside them.
- Do not assume a background-task completion will arrive as `tool_result`. In the observed Claude Code Anthropic traffic, natural completion arrived as `user.text` `<task-notification>` blocks.

The evidence here is strong enough to guide experimentation, but not strong enough to justify a silent always-on feature.

# Suggested next step before implementation

Before building product UI or proxy-side synthesis, validate the design with a small experiment layer:

1. manually trigger warm requests for one Anthropic session
2. record the exact request body derivation path
3. compare pre-warm and post-warm `cache_read_tokens` / `cache_creation_tokens`
4. confirm that synthetic requests do not pollute session UX or distort content-tree display

Only after that should TokenPulse consider a manual button, per-session toggle, or automatic policy.
