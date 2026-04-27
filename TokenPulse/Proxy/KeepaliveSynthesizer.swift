import Foundation

/// Builds Anthropic Messages "warm" request bodies from a source request body
/// and the response that ended at the keep-alive frontier.
///
/// Pure / headless: no I/O, no actor dependencies, no logging. Phase 3
/// wires this into the forwarder; the audit fields the planning step
/// returns feed phase 4's event-log row.
///
/// The two reconstruction cases match `docs/proxy-keepalive.md`:
///
/// - **assistant_text** — the source response ended with normal assistant
///   text. Append the assistant message; place `cache_control` on the last
///   text block; add a tiny synthetic user suffix outside the cached prefix.
///
/// - **assistant_tool_use** — the source response ended with one or more
///   unresolved client `tool_use` blocks. Append the assistant message
///   verbatim; place `cache_control` on the last `tool_use`; insert
///   placeholder `tool_result` blocks for every unresolved `tool_use.id`,
///   then the synthetic suffix. Placeholders are protocol shims only and
///   live outside the cached prefix.
///
/// `exactReplay(observedRequestBody:)` covers the third case from the spec:
/// when a real follow-up request resolving the prior `tool_use` has already
/// been observed, we send it byte-for-byte instead of reconstructing.
///
/// Cache-identity fields (`model`, `system`, `tools`, `tool_choice`,
/// `thinking`, `output_config.effort`, beta headers) are preserved by
/// touching only the `messages` array. Existing message-level
/// `cache_control` markers are stripped before installing the new moving
/// breakpoint; system-level and tools-level cache anchors are untouched.
enum KeepaliveSynthesizer {

    /// Placeholder text Claude Code itself uses when filling in a missing
    /// tool result via `/btw`. Keeping the same string avoids cache
    /// drift if the warmer and a real `/btw` round both send a placeholder
    /// against the same frontier.
    static let placeholderToolResultText = "[Tool result missing due to internal error]"

    /// Synthetic user suffix appended after the moving breakpoint. The text
    /// is intentionally trivial so Anthropic returns a small response —
    /// `max_tokens` and `thinking` are not mutated by design (see spec).
    static let syntheticSuffixText = "say hi"

    enum FrontierKind: String, Sendable {
        case assistantText = "assistant_text"
        case assistantToolUse = "assistant_tool_use"
        case exactReplay = "exact_replay"
    }

    /// Reasons synthesis can refuse. Mirrors the eligibility/refusal table in
    /// `docs/proxy-keepalive.md`. Selection-level checks (errored source,
    /// branched path, non-Anthropic flavor) are upstream of this type — by
    /// the time we get here we know we are looking at a successful Anthropic
    /// done request.
    enum RefusalReason: Sendable, Equatable {
        case sourceBodyUnparseable
        case sourceResponseUnparseable
        case sourceResponseIncomplete(stopReason: String?)
        case noEligibleFrontierBlock
        case unpairedToolUseIDs
    }

    struct Plan: Sendable {
        let frontierKind: FrontierKind
        let body: Data
        /// Human-readable descriptor of where the cache breakpoint was
        /// installed, e.g. `"messages[7].content[2] (text)"`. Persisted to
        /// the keep-alive audit row.
        let frontierDescriptor: String
        let placeholderToolResultsInserted: Bool
        let placeholderToolUseIDs: [String]
    }

    enum Outcome: Sendable {
        case plan(Plan)
        case refused(RefusalReason)
    }

    // MARK: - Public entry points

    /// Reconstruct a warm request body from a source request and its observed
    /// response. The source body is the upstream JSON the source request
    /// actually sent; the response is the raw upstream response bytes
    /// (Anthropic SSE when `sourceWasStreaming`, otherwise non-streaming
    /// JSON).
    static func synthesize(
        sourceRequestBody: Data,
        sourceResponse: Data,
        sourceWasStreaming: Bool
    ) -> Outcome {
        guard let body = jsonObject(sourceRequestBody),
              let messagesAny = body["messages"] as? [Any] else {
            return .refused(.sourceBodyUnparseable)
        }

        let extracted: ExtractedAssistantTurn
        switch extractAssistantTurn(from: sourceResponse, streaming: sourceWasStreaming) {
        case .success(let value):
            extracted = value
        case .failure:
            return .refused(.sourceResponseUnparseable)
        }

        if let refusal = refusalForIncompleteResponse(stopReason: extracted.stopReason) {
            return .refused(refusal)
        }

        guard !extracted.contentBlocks.isEmpty else {
            return .refused(.noEligibleFrontierBlock)
        }

        let strippedMessages = strippedMessageLevelCacheControl(from: messagesAny)
        let toolUseScan = scanToolUse(extracted.contentBlocks)

        if toolUseScan.hasUnpairedID {
            return .refused(.unpairedToolUseIDs)
        }

        if !toolUseScan.ids.isEmpty {
            return synthesizeToolUseFrontier(
                body: body,
                strippedMessages: strippedMessages,
                contentBlocks: extracted.contentBlocks,
                unresolvedToolUseIDs: toolUseScan.ids
            )
        }

        return synthesizeTextFrontier(
            body: body,
            strippedMessages: strippedMessages,
            contentBlocks: extracted.contentBlocks
        )
    }

    /// Wrap an observed organic request body as an exact-replay warm plan.
    /// Use this when an organic follow-up resolving the prior `tool_use`
    /// has already arrived — the body is the exact frontier and shouldn't
    /// be reconstructed.
    static func exactReplay(observedRequestBody: Data) -> Outcome {
        guard var body = jsonObject(observedRequestBody) else {
            return .refused(.sourceBodyUnparseable)
        }
        body["stream"] = false
        guard let serialized = serialize(body) else {
            return .refused(.sourceBodyUnparseable)
        }
        return .plan(Plan(
            frontierKind: .exactReplay,
            body: serialized,
            frontierDescriptor: "exact_replay",
            placeholderToolResultsInserted: false,
            placeholderToolUseIDs: []
        ))
    }

    // MARK: - Frontier construction

    private static func synthesizeTextFrontier(
        body: [String: Any],
        strippedMessages: [[String: Any]],
        contentBlocks: [[String: Any]]
    ) -> Outcome {
        guard let lastTextIndex = lastIndex(of: "text", in: contentBlocks) else {
            return .refused(.noEligibleFrontierBlock)
        }

        var assistantBlocks = contentBlocks
        assistantBlocks[lastTextIndex] = withCacheControl(assistantBlocks[lastTextIndex])

        let assistantMessage: [String: Any] = [
            "role": "assistant",
            "content": assistantBlocks,
        ]

        let userMessage: [String: Any] = [
            "role": "user",
            "content": [
                ["type": "text", "text": syntheticSuffixText] as [String: Any],
            ],
        ]

        var updatedBody = body
        var newMessages = strippedMessages
        newMessages.append(assistantMessage)
        newMessages.append(userMessage)
        updatedBody["messages"] = newMessages
        updatedBody["stream"] = false

        guard let serialized = serialize(updatedBody) else {
            return .refused(.sourceBodyUnparseable)
        }

        let assistantMessageIndex = newMessages.count - 2
        return .plan(Plan(
            frontierKind: .assistantText,
            body: serialized,
            frontierDescriptor: "messages[\(assistantMessageIndex)].content[\(lastTextIndex)] (text)",
            placeholderToolResultsInserted: false,
            placeholderToolUseIDs: []
        ))
    }

    private static func synthesizeToolUseFrontier(
        body: [String: Any],
        strippedMessages: [[String: Any]],
        contentBlocks: [[String: Any]],
        unresolvedToolUseIDs: [String]
    ) -> Outcome {
        guard let lastToolUseIndex = lastIndex(of: "tool_use", in: contentBlocks) else {
            return .refused(.noEligibleFrontierBlock)
        }

        var assistantBlocks = contentBlocks
        assistantBlocks[lastToolUseIndex] = withCacheControl(assistantBlocks[lastToolUseIndex])

        let assistantMessage: [String: Any] = [
            "role": "assistant",
            "content": assistantBlocks,
        ]

        var userContent: [[String: Any]] = unresolvedToolUseIDs.map { id in
            [
                "type": "tool_result",
                "tool_use_id": id,
                "content": placeholderToolResultText,
                "is_error": true,
            ]
        }
        userContent.append([
            "type": "text",
            "text": syntheticSuffixText,
        ])

        let userMessage: [String: Any] = [
            "role": "user",
            "content": userContent,
        ]

        var updatedBody = body
        var newMessages = strippedMessages
        newMessages.append(assistantMessage)
        newMessages.append(userMessage)
        updatedBody["messages"] = newMessages
        updatedBody["stream"] = false

        guard let serialized = serialize(updatedBody) else {
            return .refused(.sourceBodyUnparseable)
        }

        let assistantMessageIndex = newMessages.count - 2
        return .plan(Plan(
            frontierKind: .assistantToolUse,
            body: serialized,
            frontierDescriptor: "messages[\(assistantMessageIndex)].content[\(lastToolUseIndex)] (tool_use)",
            placeholderToolResultsInserted: true,
            placeholderToolUseIDs: unresolvedToolUseIDs
        ))
    }

    // MARK: - Response extraction

    private struct ExtractedAssistantTurn {
        let contentBlocks: [[String: Any]]
        let stopReason: String?
    }

    private enum ExtractError: Error {
        case unparseable
    }

    private static func extractAssistantTurn(
        from data: Data,
        streaming: Bool
    ) -> Result<ExtractedAssistantTurn, ExtractError> {
        if !streaming {
            guard let json = jsonObject(data) else {
                return .failure(.unparseable)
            }
            let blocks = (json["content"] as? [[String: Any]]) ?? []
            let stopReason = json["stop_reason"] as? String
            return .success(ExtractedAssistantTurn(contentBlocks: blocks, stopReason: stopReason))
        }

        guard let text = String(data: data, encoding: .utf8) else {
            return .failure(.unparseable)
        }

        var builders: [Int: SSEBlockBuilder] = [:]
        var maxIndex = -1
        var stopReason: String?
        var sawAnyEvent = false

        text.enumerateLines { line, _ in
            guard line.hasPrefix("data: ") else { return }
            let payload = line.dropFirst(6)
            guard payload != "[DONE]",
                  let lineData = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = json["type"] as? String else {
                return
            }
            sawAnyEvent = true

            switch type {
            case "content_block_start":
                guard let index = json["index"] as? Int,
                      let block = json["content_block"] as? [String: Any] else { return }
                builders[index] = SSEBlockBuilder(initial: block)
                maxIndex = max(maxIndex, index)
            case "content_block_delta":
                guard let index = json["index"] as? Int,
                      let delta = json["delta"] as? [String: Any],
                      var builder = builders[index] else { return }
                builder.applyDelta(delta)
                builders[index] = builder
            case "content_block_stop":
                guard let index = json["index"] as? Int,
                      var builder = builders[index] else { return }
                builder.finalize()
                builders[index] = builder
            case "message_delta":
                if let delta = json["delta"] as? [String: Any],
                   let reason = delta["stop_reason"] as? String {
                    stopReason = reason
                }
            default:
                break
            }
        }

        if !sawAnyEvent {
            return .failure(.unparseable)
        }

        var blocks: [[String: Any]] = []
        if maxIndex >= 0 {
            blocks.reserveCapacity(maxIndex + 1)
            for index in 0...maxIndex {
                if let builder = builders[index] {
                    blocks.append(builder.build())
                }
            }
        }
        return .success(ExtractedAssistantTurn(contentBlocks: blocks, stopReason: stopReason))
    }

    /// SSE content blocks arrive piecewise across `content_block_start`
    /// (initial shape), N × `content_block_delta` (incremental text /
    /// thinking / partial JSON), and `content_block_stop` (finalize). The
    /// builder owns the in-progress block dict and its `partial_json`
    /// accumulator for `tool_use` inputs.
    private struct SSEBlockBuilder {
        var current: [String: Any]
        var partialJSON: String = ""

        init(initial: [String: Any]) {
            self.current = initial
        }

        mutating func applyDelta(_ delta: [String: Any]) {
            guard let type = delta["type"] as? String else { return }
            switch type {
            case "text_delta":
                if let text = delta["text"] as? String {
                    current["text"] = (current["text"] as? String ?? "") + text
                }
            case "input_json_delta":
                if let partial = delta["partial_json"] as? String {
                    partialJSON += partial
                }
            case "thinking_delta":
                if let thinking = delta["thinking"] as? String {
                    current["thinking"] = (current["thinking"] as? String ?? "") + thinking
                }
            case "signature_delta":
                if let signature = delta["signature"] as? String {
                    current["signature"] = (current["signature"] as? String ?? "") + signature
                }
            default:
                break
            }
        }

        mutating func finalize() {
            guard !partialJSON.isEmpty else { return }
            if let data = partialJSON.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) {
                current["input"] = parsed
            }
            partialJSON = ""
        }

        func build() -> [String: Any] {
            current
        }
    }

    // MARK: - Eligibility helpers

    /// Anthropic stop reasons we accept as "this response completed cleanly
    /// enough to extend." Others (`max_tokens`, `stop_sequence`, `refusal`,
    /// missing) signal truncation or refusal — extending those would warm a
    /// prefix the next organic request will not match.
    private static func refusalForIncompleteResponse(stopReason: String?) -> RefusalReason? {
        switch stopReason {
        case "end_turn", "tool_use", "pause_turn":
            return nil
        default:
            return .sourceResponseIncomplete(stopReason: stopReason)
        }
    }

    private struct ToolUseScan {
        let ids: [String]
        let hasUnpairedID: Bool
    }

    /// Collect IDs of client-side `tool_use` blocks. Server-side tool calls
    /// (`server_tool_use`) auto-resolve within the same assistant turn and
    /// don't need placeholders.
    private static func scanToolUse(_ blocks: [[String: Any]]) -> ToolUseScan {
        var ids: [String] = []
        var hasUnpairedID = false
        for block in blocks {
            guard (block["type"] as? String) == "tool_use" else { continue }
            if let id = block["id"] as? String, !id.isEmpty {
                ids.append(id)
            } else {
                hasUnpairedID = true
            }
        }
        return ToolUseScan(ids: ids, hasUnpairedID: hasUnpairedID)
    }

    private static func lastIndex(of blockType: String, in blocks: [[String: Any]]) -> Int? {
        var lastIndex: Int?
        for (index, block) in blocks.enumerated() {
            if (block["type"] as? String) == blockType {
                lastIndex = index
            }
        }
        return lastIndex
    }

    /// Strip message-level `cache_control` from every existing message and
    /// from each block in its `content` array. System- and tool-level cache
    /// anchors live outside `messages` and are untouched.
    private static func strippedMessageLevelCacheControl(from messages: [Any]) -> [[String: Any]] {
        var result: [[String: Any]] = []
        result.reserveCapacity(messages.count)
        for raw in messages {
            guard var dict = raw as? [String: Any] else { continue }
            dict.removeValue(forKey: "cache_control")
            if let blocks = dict["content"] as? [[String: Any]] {
                dict["content"] = blocks.map { block -> [String: Any] in
                    var copy = block
                    copy.removeValue(forKey: "cache_control")
                    return copy
                }
            }
            result.append(dict)
        }
        return result
    }

    private static func withCacheControl(_ block: [String: Any]) -> [String: Any] {
        var copy = block
        copy["cache_control"] = ["type": "ephemeral"]
        return copy
    }

    // MARK: - JSON helpers

    private static func jsonObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func serialize(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object, options: [])
    }
}
