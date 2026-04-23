---
title: Claude Code Anthropic Request Structure Notes
description: Empirical notes from TokenPulse proxy logs about Claude Code's Anthropic request-body shape, harness-injected blocks, async/background-task notifications, and message assembly patterns.
---

This document records what we observed in TokenPulse's own proxy logs while investigating Claude Code Anthropic request bodies on 2026-04-22 and 2026-04-23.

It is a descriptive note, not a product contract.

# Scope

The observations here came from TokenPulse's exact raw request capture:

- SQLite log: `~/.tokenpulse/proxy_events.sqlite`
- tables:
  - `proxy_requests`
  - `proxy_raw_request_response`

The focus is Anthropic Messages traffic emitted by Claude Code and related harness-side features.

# Basic shape

Claude Code Anthropic requests use the normal Messages API structure:

- top-level request contains `model`, `messages`, `tools`, `thinking`, and related settings
- each item in `messages` is one Anthropic message
- each message has a `role` and a `content` payload
- for array-style content, each item in `content` is a block such as:
  - `text`
  - `thinking`
  - `tool_use`
  - `tool_result`

Claude Code often uses array-style `content`, but it also sometimes sends shorthand string `content` for plain text user messages.

# Stable harness scaffolding

Many Claude Code Anthropic requests included a large initial `user` message made of multiple `<system-reminder>` blocks.

The most common reminder families were:

- `# MCP Server Instructions`
- `The following skills are available for use with the Skill tool:`
- `As you answer the user's questions, you can use the following context:`

Those blocks are harness-side scaffolding, not ordinary user-authored prompt text.

In some sessions, additional `<system-reminder>` families appeared repeatedly:

- task-tools reminder
- diagnostics reminder

# `<system-reminder>` is a wrapper family, not a single feature

The `<system-reminder>` wrapper was used for multiple categories of injected text:

- stable prompt scaffolding
- task-tracking nudges
- diagnostics
- side-question wrappers

So searching for `<system-reminder>` alone is not enough to determine intent. The inner payload matters.

# User-message assembly is composite

Claude Code's `user` messages are not always equivalent to "the latest user prompt."

Observed `user` messages could contain combinations of:

- `tool_result` blocks
- `<system-reminder>` text blocks
- `<task-notification>` text blocks
- `[Request interrupted by user]`
- ordinary user prompt text

Two important consequences follow:

1. the semantic "user prompt" may only be the tail of a larger `user` message
2. a stable cache point inside a `user` message cannot safely be reconstructed from semantics alone

# Observed ordering tendencies

The later experiments support a narrower working hypothesis for mixed `user` messages:

1. `tool_result` blocks, when present, appear first
2. harness-injected reminder / notification blocks appear after that
3. the freshest user-prompt-like text tends to appear last

This is only a working hypothesis, not a guarantee.

Known exception:

- interrupted requests can merge earlier prompt text, interruption markers, task notifications, and a later prompt into one `user` message

# Tool use patterns

## Normal tool use

For ordinary foreground tool calls, the standard Anthropic pattern appeared:

1. assistant message with one or more `tool_use` blocks
2. next user message with matching `tool_result` blocks

For parallel tool use, Claude Code emitted:

- one assistant message containing multiple `tool_use` blocks
- then one user message containing the matching `tool_result` blocks

## Background Bash launch

For async/background Bash execution, Claude Code still used the normal tool-use structure:

1. assistant `tool_use`
2. user `tool_result`

The difference was in the `tool_use` input:

- `name = "Bash"`
- `input.run_in_background = true`

And in the immediate `tool_result` content:

- `Command running in background with ID: ...`
- `Output is being written to: ...`

So the launch acknowledgment is still ordinary `tool_result`, not a special message type.

## Background Bash natural completion

Natural completion used a different shape.

When a background task finished later, the next Anthropic request did **not** use `tool_result` for completion.

Instead, Claude Code injected one or more `user.text` blocks with XML-like payloads:

- `<task-notification>`
- `<task-id>...`
- `<tool-use-id>...`
- `<output-file>...`
- `<status>completed</status>`
- `<summary>...</summary>`

If multiple background tasks finished before the next request, Claude Code grouped them into one `user` message as multiple `text` blocks, one notification per block.

# Side-question wrappers

The observed side-agent / side-question calls used a distinct user-side wrapper:

- `<system-reminder>This is a side question from the user...`

In the captured examples, Claude Code placed this wrapper after a more meaningful cached frontier and moved the breakpoint to:

- `assistant.tool_use` in one case
- `assistant.text` in later cases

This strongly suggests Claude Code treats the side-question wrapper as transient, disposable suffix text rather than part of the desired cached prefix.

# Interruptions

Interrupted requests are special and should be treated carefully in any keep-warm design.

We observed merged `user` messages that contained all of the following in one message:

- earlier user prompt text
- `[Request interrupted by user]`
- `<task-notification>`
- another interruption marker
- later user prompt text

Those merged notification + user-prompt messages only appeared in interrupted flows in the current log sample.

# Prompt-caching implications

These structure findings lead to a few practical rules for Anthropic keep-warm experiments.

## Safe to rely on

- exact replay of an observed request body
- observed assistant-frontier boundaries such as:
  - `assistant.text`
  - `assistant.tool_use`
- observed `user.tool_result` frontiers when replaying the exact real request

## Unsafe to infer

- a synthetic cache boundary inside a Claude Code `user` message based only on semantics
- the exact placement of reminder / notification blocks in a future request
- a natural background completion being represented as `tool_result`

## Best working heuristic

If exact replay is available, prefer it.

If exact replay is not available:

- prefer known assistant boundaries over inferred user-message boundaries
- treat async background completion as a `user.text` task-notification frontier
- treat interrupted request assembly as a special case
