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
/// touching only the `messages` array and the top-level `stream` boolean.
/// Existing message bytes are preserved verbatim so cache-relevant request
/// shape is not disturbed while installing the new moving breakpoint.
enum KeepaliveSynthesizer {

    /// Placeholder text Claude Code itself uses when filling in a missing
    /// tool result via `/btw`. Keeping the same string avoids cache
    /// drift if the warmer and a real `/btw` round both send a placeholder
    /// against the same frontier.
    static let placeholderToolResultText = "[Tool result missing due to internal error]"

    /// Synthetic user suffix appended after the moving breakpoint. The text
    /// is intentionally trivial so Anthropic returns a small response —
    /// `max_tokens` and `thinking` are not mutated by design (see spec).
    static let syntheticSuffixText = "Do not think; reply with exactly this text: hi"

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
              let messagesAny = body["messages"] as? [Any],
              let sourceScan = scanTopLevelObject(sourceRequestBody),
              let messagesCloseIndex = sourceScan.messagesArrayCloseIndex else {
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

        let toolUseScan = scanToolUse(extracted.contentBlocks)

        if toolUseScan.hasUnpairedID {
            return .refused(.unpairedToolUseIDs)
        }

        if !toolUseScan.ids.isEmpty {
            return synthesizeToolUseFrontier(
                sourceRequestBody: sourceRequestBody,
                messagesCloseIndex: messagesCloseIndex,
                existingMessageCount: messagesAny.count,
                contentBlocks: extracted.contentBlocks,
                unresolvedToolUseIDs: toolUseScan.ids
            )
        }

        return synthesizeTextFrontier(
            sourceRequestBody: sourceRequestBody,
            messagesCloseIndex: messagesCloseIndex,
            existingMessageCount: messagesAny.count,
            contentBlocks: extracted.contentBlocks
        )
    }

    /// Wrap an observed organic request body as an exact-replay warm plan.
    /// Use this when an organic follow-up resolving the prior `tool_use`
    /// has already arrived — the body is the exact frontier and shouldn't
    /// be reconstructed.
    static func exactReplay(observedRequestBody: Data) -> Outcome {
        guard jsonObject(observedRequestBody) != nil,
              let body = forcingTopLevelStreamFalse(in: observedRequestBody) else {
            return .refused(.sourceBodyUnparseable)
        }
        return .plan(Plan(
            frontierKind: .exactReplay,
            body: body,
            frontierDescriptor: "exact_replay",
            placeholderToolResultsInserted: false,
            placeholderToolUseIDs: []
        ))
    }

    // MARK: - Frontier construction

    private static func synthesizeTextFrontier(
        sourceRequestBody: Data,
        messagesCloseIndex: Int,
        existingMessageCount: Int,
        contentBlocks: [[String: Any]]
    ) -> Outcome {
        guard let lastTextIndex = lastIndex(of: "text", in: contentBlocks) else {
            return .refused(.noEligibleFrontierBlock)
        }

        guard let assistantMessage = assistantMessageData(
            contentBlocks: contentBlocks,
            cacheControlBlockIndex: lastTextIndex
        ),
            let userMessage = syntheticTextUserMessageData(),
            let spliced = appendingMessages(
                to: sourceRequestBody,
                messagesCloseIndex: messagesCloseIndex,
                existingMessageCount: existingMessageCount,
                assistantMessage: assistantMessage,
                userMessage: userMessage
            ),
            let body = forcingTopLevelStreamFalse(in: spliced) else {
            return .refused(.sourceBodyUnparseable)
        }

        let assistantMessageIndex = existingMessageCount
        return .plan(Plan(
            frontierKind: .assistantText,
            body: body,
            frontierDescriptor: "messages[\(assistantMessageIndex)].content[\(lastTextIndex)] (text)",
            placeholderToolResultsInserted: false,
            placeholderToolUseIDs: []
        ))
    }

    private static func synthesizeToolUseFrontier(
        sourceRequestBody: Data,
        messagesCloseIndex: Int,
        existingMessageCount: Int,
        contentBlocks: [[String: Any]],
        unresolvedToolUseIDs: [String]
    ) -> Outcome {
        guard let lastToolUseIndex = lastIndex(of: "tool_use", in: contentBlocks) else {
            return .refused(.noEligibleFrontierBlock)
        }

        guard let assistantMessage = assistantMessageData(
            contentBlocks: contentBlocks,
            cacheControlBlockIndex: lastToolUseIndex
        ),
            let userMessage = syntheticToolResultUserMessageData(toolUseIDs: unresolvedToolUseIDs),
            let spliced = appendingMessages(
                to: sourceRequestBody,
                messagesCloseIndex: messagesCloseIndex,
                existingMessageCount: existingMessageCount,
                assistantMessage: assistantMessage,
                userMessage: userMessage
            ),
            let body = forcingTopLevelStreamFalse(in: spliced) else {
            return .refused(.sourceBodyUnparseable)
        }

        let assistantMessageIndex = existingMessageCount
        return .plan(Plan(
            frontierKind: .assistantToolUse,
            body: body,
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

    // MARK: - Request body splicing

    private static func appendingMessages(
        to sourceRequestBody: Data,
        messagesCloseIndex: Int,
        existingMessageCount: Int,
        assistantMessage: Data,
        userMessage: Data
    ) -> Data? {
        guard messagesCloseIndex >= 0, messagesCloseIndex < sourceRequestBody.count else {
            return nil
        }

        var body = Data()
        body.reserveCapacity(sourceRequestBody.count + assistantMessage.count + userMessage.count + 2)
        body.append(sourceRequestBody.subdata(in: 0..<messagesCloseIndex))
        if existingMessageCount > 0 {
            appendASCII(",", to: &body)
        }
        body.append(assistantMessage)
        appendASCII(",", to: &body)
        body.append(userMessage)
        body.append(sourceRequestBody.subdata(in: messagesCloseIndex..<sourceRequestBody.count))
        return body
    }

    private static func forcingTopLevelStreamFalse(in data: Data) -> Data? {
        guard let scan = scanTopLevelObject(data) else {
            return nil
        }

        if let streamBooleanRange = scan.streamBooleanRange {
            let bytes = Array(data)
            if streamBooleanRange.count == 5,
               bytesMatch(bytes, in: streamBooleanRange, ascii: "false") {
                return data
            }

            var body = Data()
            body.reserveCapacity(data.count + 1)
            body.append(data.subdata(in: 0..<streamBooleanRange.lowerBound))
            appendASCII("false", to: &body)
            body.append(data.subdata(in: streamBooleanRange.upperBound..<data.count))
            return body
        }

        guard !scan.hasTopLevelStream else {
            return nil
        }

        var body = Data()
        let addition = scan.hasTopLevelMembers ? ",\"stream\":false" : "\"stream\":false"
        body.reserveCapacity(data.count + addition.utf8.count)
        body.append(data.subdata(in: 0..<scan.objectCloseIndex))
        appendASCII(addition, to: &body)
        body.append(data.subdata(in: scan.objectCloseIndex..<data.count))
        return body
    }

    private struct TopLevelObjectScan {
        let messagesArrayCloseIndex: Int?
        let streamBooleanRange: Range<Int>?
        let hasTopLevelStream: Bool
        let hasTopLevelMembers: Bool
        let objectCloseIndex: Int
    }

    private static func scanTopLevelObject(_ data: Data) -> TopLevelObjectScan? {
        JSONByteScanner(data: data).scanTopLevelObject()
    }

    private struct JSONByteScanner {
        let bytes: [UInt8]

        init(data: Data) {
            self.bytes = Array(data)
        }

        func scanTopLevelObject() -> TopLevelObjectScan? {
            var index = skipWhitespace(from: 0)
            guard index < bytes.count, bytes[index] == ascii("{") else {
                return nil
            }
            index += 1

            var messagesArrayCloseIndex: Int?
            var streamBooleanRange: Range<Int>?
            var hasTopLevelStream = false
            var hasTopLevelMembers = false

            while true {
                index = skipWhitespace(from: index)
                guard index < bytes.count else {
                    return nil
                }

                if bytes[index] == ascii("}") {
                    return TopLevelObjectScan(
                        messagesArrayCloseIndex: messagesArrayCloseIndex,
                        streamBooleanRange: streamBooleanRange,
                        hasTopLevelStream: hasTopLevelStream,
                        hasTopLevelMembers: hasTopLevelMembers,
                        objectCloseIndex: index
                    )
                }

                guard bytes[index] == ascii("\""),
                      let keyEndQuote = stringEnd(startingAt: index) else {
                    return nil
                }

                guard let key = decodedString(in: index...keyEndQuote) else {
                    return nil
                }
                index = skipWhitespace(from: keyEndQuote + 1)
                guard index < bytes.count, bytes[index] == ascii(":") else {
                    return nil
                }
                index = skipWhitespace(from: index + 1)
                guard index < bytes.count else {
                    return nil
                }

                let valueStart = index
                if key == "messages" {
                    guard bytes[valueStart] == ascii("["),
                          let closeIndex = matchingCloseIndex(startingAt: valueStart) else {
                        return nil
                    }
                    messagesArrayCloseIndex = closeIndex
                    index = closeIndex + 1
                } else {
                    if key == "stream" {
                        hasTopLevelStream = true
                        if let booleanEnd = booleanEnd(startingAt: valueStart) {
                            streamBooleanRange = valueStart..<booleanEnd
                        }
                    }

                    guard let valueEnd = valueEnd(startingAt: valueStart) else {
                        return nil
                    }
                    index = valueEnd
                }

                hasTopLevelMembers = true
                index = skipWhitespace(from: index)
                guard index < bytes.count else {
                    return nil
                }

                if bytes[index] == ascii(",") {
                    index += 1
                    continue
                }

                if bytes[index] == ascii("}") {
                    return TopLevelObjectScan(
                        messagesArrayCloseIndex: messagesArrayCloseIndex,
                        streamBooleanRange: streamBooleanRange,
                        hasTopLevelStream: hasTopLevelStream,
                        hasTopLevelMembers: hasTopLevelMembers,
                        objectCloseIndex: index
                    )
                }

                return nil
            }
        }

        private func valueEnd(startingAt startIndex: Int) -> Int? {
            guard startIndex < bytes.count else {
                return nil
            }

            switch bytes[startIndex] {
            case ascii("\""):
                guard let endQuote = stringEnd(startingAt: startIndex) else {
                    return nil
                }
                return endQuote + 1
            case ascii("{"), ascii("["):
                guard let closeIndex = matchingCloseIndex(startingAt: startIndex) else {
                    return nil
                }
                return closeIndex + 1
            case ascii("t"), ascii("f"):
                return booleanEnd(startingAt: startIndex)
            case ascii("n"):
                return literalEnd(startingAt: startIndex, literal: "null")
            default:
                return numberEnd(startingAt: startIndex)
            }
        }

        private func matchingCloseIndex(startingAt openIndex: Int) -> Int? {
            guard openIndex < bytes.count else {
                return nil
            }

            var expectedClosers: [UInt8] = []
            var index = openIndex
            while index < bytes.count {
                let byte = bytes[index]
                switch byte {
                case ascii("\""):
                    guard let endQuote = stringEnd(startingAt: index) else {
                        return nil
                    }
                    index = endQuote + 1
                case ascii("{"):
                    expectedClosers.append(ascii("}"))
                    index += 1
                case ascii("["):
                    expectedClosers.append(ascii("]"))
                    index += 1
                case ascii("}"), ascii("]"):
                    guard expectedClosers.last == byte else {
                        return nil
                    }
                    expectedClosers.removeLast()
                    if expectedClosers.isEmpty {
                        return index
                    }
                    index += 1
                default:
                    index += 1
                }
            }
            return nil
        }

        private func decodedString(in range: ClosedRange<Int>) -> String? {
            guard range.lowerBound >= 0, range.upperBound < bytes.count else {
                return nil
            }
            let token = Data(bytes[range])
            return (try? JSONSerialization.jsonObject(with: token, options: [.fragmentsAllowed])) as? String
        }

        private func stringEnd(startingAt quoteIndex: Int) -> Int? {
            var index = quoteIndex + 1
            while index < bytes.count {
                switch bytes[index] {
                case ascii("\\"):
                    index += 2
                case ascii("\""):
                    return index
                default:
                    index += 1
                }
            }
            return nil
        }

        private func booleanEnd(startingAt startIndex: Int) -> Int? {
            if let trueEnd = literalEnd(startingAt: startIndex, literal: "true") {
                return trueEnd
            }
            return literalEnd(startingAt: startIndex, literal: "false")
        }

        private func literalEnd(startingAt startIndex: Int, literal: String) -> Int? {
            let literalBytes = Array(literal.utf8)
            guard startIndex + literalBytes.count <= bytes.count else {
                return nil
            }
            for offset in literalBytes.indices where bytes[startIndex + offset] != literalBytes[offset] {
                return nil
            }
            let endIndex = startIndex + literalBytes.count
            guard endIndex == bytes.count || isValueDelimiter(bytes[endIndex]) else {
                return nil
            }
            return endIndex
        }

        private func numberEnd(startingAt startIndex: Int) -> Int? {
            var index = startIndex
            while index < bytes.count, !isValueDelimiter(bytes[index]) {
                index += 1
            }
            guard index > startIndex else {
                return nil
            }
            return index
        }

        private func skipWhitespace(from startIndex: Int) -> Int {
            var index = startIndex
            while index < bytes.count, isWhitespace(bytes[index]) {
                index += 1
            }
            return index
        }
    }

    // MARK: - Synthetic JSON emission

    private static func assistantMessageData(
        contentBlocks: [[String: Any]],
        cacheControlBlockIndex: Int
    ) -> Data? {
        var data = Data()
        appendASCII("{\"role\":\"assistant\",\"content\":[", to: &data)
        for (index, block) in contentBlocks.enumerated() {
            if index > 0 {
                appendASCII(",", to: &data)
            }

            var emittedBlock = block
            if index == cacheControlBlockIndex {
                emittedBlock["cache_control"] = ["type": "ephemeral"]
            }

            guard appendJSONObject(
                emittedBlock,
                preferredKeys: ["type", "id", "name", "input", "text", "thinking", "signature"],
                to: &data
            ) else {
                return nil
            }
        }
        appendASCII("]}", to: &data)
        return data
    }

    private static func syntheticTextUserMessageData() -> Data? {
        var data = Data()
        appendASCII("{\"role\":\"user\",\"content\":[", to: &data)
        guard appendJSONObject(
            ["type": "text", "text": syntheticSuffixText],
            preferredKeys: ["type", "text"],
            to: &data
        ) else {
            return nil
        }
        appendASCII("]}", to: &data)
        return data
    }

    private static func syntheticToolResultUserMessageData(toolUseIDs: [String]) -> Data? {
        var data = Data()
        appendASCII("{\"role\":\"user\",\"content\":[", to: &data)
        for (index, id) in toolUseIDs.enumerated() {
            if index > 0 {
                appendASCII(",", to: &data)
            }
            guard appendJSONObject(
                [
                    "type": "tool_result",
                    "tool_use_id": id,
                    "content": placeholderToolResultText,
                    "is_error": true,
                ],
                preferredKeys: ["type", "tool_use_id", "content", "is_error"],
                to: &data
            ) else {
                return nil
            }
        }
        if !toolUseIDs.isEmpty {
            appendASCII(",", to: &data)
        }
        guard appendJSONObject(
            ["type": "text", "text": syntheticSuffixText],
            preferredKeys: ["type", "text"],
            to: &data
        ) else {
            return nil
        }
        appendASCII("]}", to: &data)
        return data
    }

    private static func appendJSONValue(_ value: Any, to data: inout Data) -> Bool {
        switch value {
        case let string as String:
            appendJSONString(string, to: &data)
            return true
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                appendASCII(number.boolValue ? "true" : "false", to: &data)
            } else {
                appendASCII(number.stringValue, to: &data)
            }
            return true
        case let bool as Bool:
            appendASCII(bool ? "true" : "false", to: &data)
            return true
        case let int as Int:
            appendASCII(String(int), to: &data)
            return true
        case let int64 as Int64:
            appendASCII(String(int64), to: &data)
            return true
        case let double as Double:
            guard double.isFinite else {
                return false
            }
            appendASCII(String(double), to: &data)
            return true
        case let float as Float:
            guard float.isFinite else {
                return false
            }
            appendASCII(String(float), to: &data)
            return true
        case _ as NSNull:
            appendASCII("null", to: &data)
            return true
        case let array as [Any]:
            appendASCII("[", to: &data)
            for (index, item) in array.enumerated() {
                if index > 0 {
                    appendASCII(",", to: &data)
                }
                guard appendJSONValue(item, to: &data) else {
                    return false
                }
            }
            appendASCII("]", to: &data)
            return true
        case let dictionary as [String: Any]:
            return appendJSONObject(dictionary, preferredKeys: [], to: &data)
        default:
            return false
        }
    }

    private static func appendJSONObject(
        _ dictionary: [String: Any],
        preferredKeys: [String],
        to data: inout Data
    ) -> Bool {
        appendASCII("{", to: &data)
        var emittedKeys = Set<String>()
        var needsComma = false

        func appendPair(key: String) -> Bool {
            guard let value = dictionary[key] else {
                return true
            }
            if needsComma {
                appendASCII(",", to: &data)
            }
            appendJSONString(key, to: &data)
            appendASCII(":", to: &data)
            guard appendJSONValue(value, to: &data) else {
                return false
            }
            emittedKeys.insert(key)
            needsComma = true
            return true
        }

        for key in preferredKeys where key != "cache_control" {
            guard appendPair(key: key) else {
                return false
            }
        }

        for key in dictionary.keys.sorted() where !emittedKeys.contains(key) && key != "cache_control" {
            guard appendPair(key: key) else {
                return false
            }
        }

        if dictionary.keys.contains("cache_control") {
            guard appendPair(key: "cache_control") else {
                return false
            }
        }

        appendASCII("}", to: &data)
        return true
    }

    private static func appendJSONString(_ string: String, to data: inout Data) {
        appendASCII("\"", to: &data)
        for scalar in string.unicodeScalars {
            switch scalar.value {
            case 0x08:
                appendASCII("\\b", to: &data)
            case 0x09:
                appendASCII("\\t", to: &data)
            case 0x0A:
                appendASCII("\\n", to: &data)
            case 0x0C:
                appendASCII("\\f", to: &data)
            case 0x0D:
                appendASCII("\\r", to: &data)
            case 0x22:
                appendASCII("\\\"", to: &data)
            case 0x5C:
                appendASCII("\\\\", to: &data)
            case 0x00...0x1F:
                appendASCII(String(format: "\\u%04X", scalar.value), to: &data)
            default:
                appendASCII(String(scalar), to: &data)
            }
        }
        appendASCII("\"", to: &data)
    }

    private static func appendASCII(_ string: String, to data: inout Data) {
        data.append(contentsOf: string.utf8)
    }

    private static func ascii(_ string: String) -> UInt8 {
        string.utf8.first ?? 0
    }

    private static func bytesMatch(_ bytes: [UInt8], in range: Range<Int>, ascii string: String) -> Bool {
        let stringBytes = Array(string.utf8)
        guard range.count == stringBytes.count else {
            return false
        }
        for offset in stringBytes.indices where bytes[range.lowerBound + offset] != stringBytes[offset] {
            return false
        }
        return true
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == ascii(" ") || byte == ascii("\n") || byte == ascii("\r") || byte == ascii("\t")
    }

    private static func isValueDelimiter(_ byte: UInt8) -> Bool {
        isWhitespace(byte) || byte == ascii(",") || byte == ascii("}") || byte == ascii("]")
    }

    // MARK: - JSON helpers

    private static func jsonObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
