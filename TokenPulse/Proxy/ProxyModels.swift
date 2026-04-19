import Foundation

/// Direction of proxy byte flow relative to the local machine.
/// `.upload` = request body bytes leaving the proxy toward upstream.
/// `.download` = response bytes arriving from upstream.
enum TrafficDirection: Sendable {
    case upload
    case download
}

enum ProxyAPIFlavor: String, CaseIterable, Identifiable, Sendable, Codable {
    case anthropicMessages
    case openAIResponses

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anthropicMessages:
            return String(localized: "Anthropic Messages")
        case .openAIResponses:
            return String(localized: "OpenAI Responses")
        }
    }

    var summaryLabel: String {
        switch self {
        case .anthropicMessages:
            return String(localized: "Anthropic")
        case .openAIResponses:
            return String(localized: "OpenAI")
        }
    }

    var sessionAgentName: String {
        switch self {
        case .anthropicMessages:
            return String(localized: "Claude Code")
        case .openAIResponses:
            return String(localized: "Codex")
        }
    }

    var supportedRouteDescription: String {
        switch self {
        case .anthropicMessages:
            return "/v1/messages"
        case .openAIResponses:
            return "/v1/responses"
        }
    }

    var sessionPrefix: String {
        switch self {
        case .anthropicMessages:
            return "anthropic"
        case .openAIResponses:
            return "openai"
        }
    }
}

enum ProxySessionID {
    static let other = "other"

    static func make(_ rawID: String, flavor: ProxyAPIFlavor) -> String {
        "\(flavor.sessionPrefix):\(normalizedRawID(rawID))"
    }

    static func flavor(for sessionID: String) -> ProxyAPIFlavor? {
        if sessionID.hasPrefix("\(ProxyAPIFlavor.anthropicMessages.sessionPrefix):") {
            return .anthropicMessages
        }
        if sessionID.hasPrefix("\(ProxyAPIFlavor.openAIResponses.sessionPrefix):") {
            return .openAIResponses
        }
        return nil
    }

    static func isOther(_ sessionID: String) -> Bool {
        sessionID == other
    }

    static func supportsTrackedSession(_ sessionID: String) -> Bool {
        flavor(for: sessionID) != nil
    }

    /// Sessions that the lineage tree tracks get the longer retention window.
    /// Untracked ("other") traffic uses the short window.
    static func usesShortRetentionWindow(for sessionID: String) -> Bool {
        if isOther(sessionID) {
            return true
        }
        return flavor(for: sessionID) == nil
    }

    static func displayID(for sessionID: String) -> String {
        if isOther(sessionID) {
            return String(localized: "Other")
        }
        let rawID: Substring
        if let separator = sessionID.firstIndex(of: ":") {
            rawID = sessionID[sessionID.index(after: separator)...]
        } else {
            rawID = Substring(sessionID)
        }
        let cleaned = String(rawID)
        return cleaned.isEmpty ? "unknown" : cleaned
    }

    static func shortDisplayID(for sessionID: String) -> String {
        if isOther(sessionID) {
            return displayID(for: sessionID)
        }
        return String(displayID(for: sessionID).prefix(8))
    }

    static func normalizedOptionalRawID(_ rawID: String?) -> String? {
        guard let rawID else { return nil }
        let trimmed = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func normalizedRawID(_ rawID: String) -> String {
        let trimmed = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "unknown" : trimmed
    }
}

struct ProxySessionIdentity: Sendable {
    let flavor: ProxyAPIFlavor?
    let rawSessionID: String?
    let parentRawSessionID: String?

    static let other = ProxySessionIdentity(
        flavor: nil,
        rawSessionID: nil,
        parentRawSessionID: nil
    )

    static func tracked(
        rawSessionID: String,
        flavor: ProxyAPIFlavor,
        parentRawSessionID: String? = nil
    ) -> ProxySessionIdentity {
        guard let normalizedRawSessionID = ProxySessionID.normalizedOptionalRawID(rawSessionID) else {
            return .other
        }

        let normalizedParent = ProxySessionID.normalizedOptionalRawID(parentRawSessionID)
        return ProxySessionIdentity(
            flavor: flavor,
            rawSessionID: normalizedRawSessionID,
            parentRawSessionID: normalizedParent == normalizedRawSessionID ? nil : normalizedParent
        )
    }
}

// MARK: - Lightweight model for the proxy passthrough

/// For Phase 1 passthrough, we store the raw body as Data and only extract
/// the `stream` field to determine whether the client wants SSE.
/// Everything else passes through byte-for-byte.
enum ProxyRequestBody {

    /// Attempts to read the `stream` field from a JSON body without
    /// deserializing the entire payload.
    static func isStreaming(from body: Data) -> Bool {
        guard let json = jsonObject(from: body) else {
            return false
        }
        return (json["stream"] as? Bool) ?? false
    }

    /// Extract the model ID from a request body.
    static func model(from body: Data) -> String? {
        jsonObject(from: body)?["model"] as? String
    }

    // MARK: - Lineage extraction

    /// Build a `LineageFingerprint` from a request body. Returns nil only when
    /// the body lacks a `model` field — all other cache-key fields are optional.
    static func lineageFingerprint(from body: Data, flavor: ProxyAPIFlavor) -> LineageFingerprint? {
        guard let json = jsonObject(from: body),
              let model = json["model"] as? String else {
            return nil
        }
        let systemKey = (flavor == .openAIResponses) ? "instructions" : "system"
        let thinkingKey = (flavor == .openAIResponses) ? "reasoning" : "thinking"
        let systemStr: String?
        if let sys = normalizedSystemPrompt(json[systemKey]) {
            systemStr = canonicalString(for: sys)
        } else {
            systemStr = nil
        }
        let toolsStr: String?
        if let tools = json["tools"] as? [Any], !tools.isEmpty {
            toolsStr = canonicalString(for: tools)
        } else {
            toolsStr = nil
        }
        let toolChoiceStr: String?
        if let tc = json["tool_choice"] {
            toolChoiceStr = canonicalString(for: tc)
        } else {
            toolChoiceStr = nil
        }
        let thinkingStr: String?
        if let thinking = json[thinkingKey] {
            thinkingStr = canonicalString(for: thinking)
        } else {
            thinkingStr = nil
        }
        return LineageFingerprint(
            flavor: flavor,
            model: model,
            systemCanonical: systemStr,
            toolsCanonical: toolsStr,
            toolChoiceCanonical: toolChoiceStr,
            thinkingCanonical: thinkingStr
        )
    }

    /// Extract the normalized messages list (for Anthropic) or input list (for OpenAI Responses).
    /// Returns an empty array when neither field is present (e.g. OpenAI using `previous_response_id` alone).
    static func normalizedLineageMessages(
        from body: Data,
        flavor: ProxyAPIFlavor
    ) -> [LineageTree.NormalizedMessage] {
        guard let json = jsonObject(from: body) else { return [] }
        let field = (flavor == .openAIResponses) ? "input" : "messages"
        // OpenAI's `input` may be a string OR an array; Anthropic's `messages` is always an array.
        if let rawArray = json[field] as? [Any] {
            return normalizedLineageMessages(from: rawArray)
        }
        if flavor == .openAIResponses, let rawString = json[field] as? String {
            // Promote a bare string to a synthetic single-user-message array.
            let promoted: [[String: Any]] = [["role": "user", "content": rawString]]
            return normalizedLineageMessages(from: promoted)
        }
        return []
    }

    /// Extract `previous_response_id` from an OpenAI Responses request body.
    static func previousResponseID(from body: Data) -> String? {
        guard let json = jsonObject(from: body) else { return nil }
        return json["previous_response_id"] as? String
    }

    private static func normalizedLineageMessages(from rawArray: [Any]) -> [LineageTree.NormalizedMessage] {
        var result: [LineageTree.NormalizedMessage] = []
        result.reserveCapacity(rawArray.count)
        for element in rawArray {
            guard let normalized = normalizedValue(element) as? [String: Any],
                  let role = normalized["role"] as? String else { continue }
            let canonical = canonicalString(for: normalized) ?? ""
            let contentHash = LineageHash.sha256Hex(canonical)
            let rawJSON = (try? JSONSerialization.data(withJSONObject: normalized, options: [.sortedKeys])) ?? Data()
            result.append(LineageTree.NormalizedMessage(
                role: role,
                contentHash: contentHash,
                rawJSON: rawJSON
            ))
        }
        return result
    }

    private static func jsonObject(from body: Data) -> [String: Any]? {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return nil
        }
        return json
    }

    private static func appendCanonicalLine(label: String, value: Any?, to lines: inout [String]) {
        guard let value, let canonical = canonicalString(for: value) else {
            return
        }
        lines.append("\(label):\(canonical)")
    }

    static func canonicalString(for value: Any) -> String? {
        switch value {
        case let string as String:
            return "\"\(escapeJSONString(string))\""
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        case _ as NSNull:
            return "null"
        case let array as [Any]:
            let items = array.compactMap { canonicalString(for: $0) }
            return "[\(items.joined(separator: ","))]"
        case let dictionary as [String: Any]:
            let entries = dictionary.keys.sorted().compactMap { key -> String? in
                guard let rawValue = dictionary[key],
                      let canonicalValue = canonicalString(for: rawValue) else {
                    return nil
                }
                return "\"\(escapeJSONString(key))\":\(canonicalValue)"
            }
            return "{\(entries.joined(separator: ","))}"
        default:
            return nil
        }
    }

    private static func escapeJSONString(_ string: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(string.count)
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"":
                escaped.append("\\\"")
            case "\\":
                escaped.append("\\\\")
            case "\n":
                escaped.append("\\n")
            case "\r":
                escaped.append("\\r")
            case "\t":
                escaped.append("\\t")
            default:
                escaped.append(String(scalar))
            }
        }
        return escaped
    }

    private static func normalizedSystemPrompt(_ value: Any?) -> Any? {
        guard let value else {
            return nil
        }

        if let entries = value as? [[String: Any]] {
            let filtered = entries.filter { entry in
                guard let text = entry["text"] as? String else {
                    return true
                }
                return !text.hasPrefix("x-anthropic-billing-header:")
            }
            return filtered.isEmpty ? nil : filtered
        }

        if let text = value as? String, text.hasPrefix("x-anthropic-billing-header:") {
            return nil
        }

        return value
    }

    private static func normalizedValue(_ value: Any?) -> Any? {
        guard let value else {
            return nil
        }

        if let dictionary = value as? [String: Any] {
            if let role = dictionary["role"] as? String,
               let normalizedMessage = normalizedMessage(role: role, dictionary: dictionary) {
                return normalizedMessage
            }

            var normalized: [String: Any] = [:]
            for key in dictionary.keys.sorted() where key != "cache_control" {
                guard let rawValue = dictionary[key],
                      let cleanedValue = normalizedValue(rawValue) else {
                    continue
                }
                normalized[key] = cleanedValue
            }
            return normalized.isEmpty ? nil : normalized
        }

        if let array = value as? [Any] {
            let normalized = array.compactMap { normalizedValue($0) }
            return normalized.isEmpty ? nil : normalized
        }

        return value
    }

    private static func normalizedMessage(role: String, dictionary: [String: Any]) -> [String: Any]? {
        var normalized: [String: Any] = ["role": role]

        if let content = normalizedMessageContent(dictionary["content"]) {
            normalized["content"] = content
        }

        for key in dictionary.keys.sorted() where key != "role" && key != "content" && key != "cache_control" {
            guard let rawValue = dictionary[key],
                  let cleanedValue = normalizedValue(rawValue) else {
                continue
            }
            normalized[key] = cleanedValue
        }

        return normalized
    }

    private static func normalizedMessageContent(_ value: Any?) -> Any? {
        guard let value else {
            return nil
        }

        if let string = value as? String {
            return [["type": "text", "text": string]]
        }

        return normalizedValue(value)
    }
}

// MARK: - Lineage fingerprint

/// Captures the cache-identity-relevant "shape" of a proxied request.
/// Two requests with different fingerprints cannot share an upstream prompt cache
/// and therefore live in different conversations of the lineage tree.
struct LineageFingerprint: Sendable, Equatable, Codable {
    let flavor: ProxyAPIFlavor
    let model: String
    /// Canonical string of the normalized system prompt / instructions (nil when absent).
    let systemCanonical: String?
    /// Canonical string representation of the `tools` array (nil when absent).
    let toolsCanonical: String?
    /// Canonical string representation of `tool_choice` (nil when absent).
    let toolChoiceCanonical: String?
    /// Canonical string of the full `thinking` / `reasoning` object (nil when absent).
    let thinkingCanonical: String?

    /// Derive the tree `ConversationKey` for this fingerprint.
    var conversationKey: LineageTree.ConversationKey {
        let canonical = [
            "model:\(model)",
            "system:\(systemCanonical ?? "")",
            "tools:\(toolsCanonical ?? "")",
            "tool_choice:\(toolChoiceCanonical ?? "")",
            "thinking:\(thinkingCanonical ?? "")",
        ].joined(separator: "\n")
        return LineageTree.ConversationKey(
            flavor: flavor,
            fingerprintHash: LineageHash.sha256Hex(canonical)
        )
    }
}

// MARK: - HTTP primitives used by the proxy server

/// A parsed HTTP request received by the local proxy server.
struct ProxyHTTPRequest: Sendable {
    let method: String
    let path: String
    let headers: [(name: String, value: String)]
    let body: Data
    let writer: ResponseWriter

    /// Convenience to look up a header value by name (case-insensitive).
    func headerValue(for name: String) -> String? {
        let lowered = name.lowercased()
        return headers.first(where: { $0.name.lowercased() == lowered })?.value
    }
}

// MARK: - Real-time request activity

/// The source of a request shown in the proxy activity UI.
enum ProxyRequestKind: Sendable {
    case request
}

/// The state of an in-flight proxy request as seen by the UI.
enum ProxyRequestState: Sendable {
    /// Request body is being sent to the upstream server.
    case uploading
    /// Upload complete; awaiting response headers from upstream.
    case waiting
    /// Response headers received; body is streaming or being accumulated.
    case receiving
    /// Request completed — shown in the done section until it expires or is replaced.
    case done
}

/// Live snapshot of a single proxy request (in-flight or recently completed).
struct ProxyRequestActivity: Sendable, Identifiable {
    let id: UUID
    let kind: ProxyRequestKind
    var state: ProxyRequestState
    /// Model ID from the request body, used for done-request replacement matching.
    let modelID: String?
    /// Lineage tree node location: conversation this request belongs to (nil when unclassified).
    var conversationID: UUID?
    /// Lineage tree segment the request's tail lands in.
    var segmentID: UUID?
    /// Inclusive index into the segment's messages array.
    var tailIndex: Int?
    /// Cumulative bytes sent to upstream so far.
    var bytesSent: Int
    /// Cumulative bytes received from upstream so far.
    var bytesReceived: Int
    /// Timestamp of the most recent upstream data chunk, used for freshness coloring.
    var lastDataAt: Date?
    let startedAt: Date
    /// Timestamp when the request transitioned to `.receiving` (response headers arrived).
    var receivingStartedAt: Date?
    /// Timestamp of the first upstream data chunk. Used for TTFT — more accurate than
    /// `receivingStartedAt` for streaming responses where headers arrive before data.
    var firstDataAt: Date?
    /// Timestamp when the request completed (transitioned to `.done`). Used for E2E duration.
    var completedAt: Date?
    /// Token usage for this request, populated when state transitions to `.done`.
    var tokenUsage: TokenUsage?
    /// Estimated cost (USD) for this single request, populated when state transitions to `.done`.
    var estimatedCost: Double?
    /// True when this activity is rendered as a done-tree leaf, but a newer
    /// descendant (still `done=false`) exists. The UI dims such rows because
    /// they are about to be replaced once the descendant completes.
    var isPendingReplacement: Bool = false

    /// Total prompt tokens for display. Some providers report cache-read tokens as a
    /// subset of input tokens, while others report them separately.
    var promptTokens: Int? {
        guard let usage = tokenUsage else { return nil }
        let cacheReadTokens = usage.inputTokensIncludeCacheReads ? 0 : (usage.cacheReadInputTokens ?? 0)
        let total = (usage.inputTokens ?? 0)
                  + cacheReadTokens
                  + (usage.cacheCreationInputTokens ?? 0)
        return total > 0 ? total : nil
    }

}

// MARK: - Token usage

/// Aggregated token counts extracted from an Anthropic API response.
struct TokenUsage: Sendable {
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheReadInputTokens: Int?
    let cacheCreationInputTokens: Int?
    /// Whether `inputTokens` already includes cached input tokens.
    /// Anthropic reports uncached and cached input separately; OpenAI Responses
    /// reports cached tokens as a subset of total input tokens.
    let inputTokensIncludeCacheReads: Bool
    /// The API's stop reason (e.g. "end_turn", "max_tokens", "tool_use").
    /// Non-nil only when the response completed normally.
    let stopReason: String?

    static let empty = TokenUsage(inputTokens: nil, outputTokens: nil,
                                  cacheReadInputTokens: nil, cacheCreationInputTokens: nil,
                                  inputTokensIncludeCacheReads: false,
                                  stopReason: nil)

    /// Compute the estimated cost (USD) using the given pricing rates.
    func cost(for pricing: ModelPricing) -> Double {
        let cachedInputTokens = max(0, cacheReadInputTokens ?? 0)
        let billableInputTokens: Int
        if inputTokensIncludeCacheReads {
            billableInputTokens = max(0, (inputTokens ?? 0) - cachedInputTokens)
        } else {
            billableInputTokens = inputTokens ?? 0
        }

        let input    = Double(billableInputTokens)         * pricing.inputPerMTok
        let output   = Double(outputTokens ?? 0)           * pricing.outputPerMTok
        let cacheRd  = Double(cachedInputTokens)           * pricing.cacheReadPerMTok
        let cacheWr  = Double(cacheCreationInputTokens ?? 0) * pricing.cacheWritePerMTok
        return (input + output + cacheRd + cacheWr) / 1_000_000
    }
}

// MARK: - Model pricing

/// Per-million-token rates for a single model tier (USD).
struct ModelPricing: Sendable {
    let inputPerMTok: Double
    let outputPerMTok: Double
    let cacheReadPerMTok: Double
    let cacheWritePerMTok: Double
}

/// Lookup pricing for supported Anthropic and OpenAI text model IDs.
/// Matches the longest known prefix. Returns nil for unrecognized models.
enum ModelPricingTable {

    /// Resolve a model ID to its pricing tier.
    static func pricing(for modelID: String?) -> ModelPricing? {
        guard let modelID else { return nil }
        let id = modelID.lowercased()
        // Try longest prefixes first to avoid short-prefix false matches.
        for (prefix, pricing) in sortedEntries {
            if id.hasPrefix(prefix) { return pricing }
        }
        return nil
    }

    // Entries sorted by prefix length descending so longer prefixes win.
    private static let sortedEntries: [(String, ModelPricing)] = entries
        .sorted { $0.key.count > $1.key.count }
        .map { ($0.key, $0.value) }

    // swiftlint:disable line_length
    private static let entries: [String: ModelPricing] = [
        // OpenAI GPT-5.4 family
        "gpt-5.4-mini":      ModelPricing(inputPerMTok: 0.75, outputPerMTok: 4.50, cacheReadPerMTok: 0.075, cacheWritePerMTok: 0),
        "gpt-5.4-nano":      ModelPricing(inputPerMTok: 0.20, outputPerMTok: 1.25, cacheReadPerMTok: 0.02, cacheWritePerMTok: 0),
        "gpt-5.4":           ModelPricing(inputPerMTok: 2.50, outputPerMTok: 15.0, cacheReadPerMTok: 0.25, cacheWritePerMTok: 0),
        // OpenAI GPT-5.3 family
        "gpt-5.3-codex":     ModelPricing(inputPerMTok: 1.75, outputPerMTok: 14.0, cacheReadPerMTok: 0.175, cacheWritePerMTok: 0),
        "gpt-5.3-chat":      ModelPricing(inputPerMTok: 1.75, outputPerMTok: 14.0, cacheReadPerMTok: 0.175, cacheWritePerMTok: 0),
        "gpt-5.3":           ModelPricing(inputPerMTok: 1.75, outputPerMTok: 14.0, cacheReadPerMTok: 0.175, cacheWritePerMTok: 0),
        // OpenAI GPT-5.2 / 5.1 / 5 family
        "gpt-5.2":           ModelPricing(inputPerMTok: 1.75, outputPerMTok: 14.0, cacheReadPerMTok: 0.175, cacheWritePerMTok: 0),
        "gpt-5.1":           ModelPricing(inputPerMTok: 1.25, outputPerMTok: 10.0, cacheReadPerMTok: 0.125, cacheWritePerMTok: 0),
        "gpt-5-mini":        ModelPricing(inputPerMTok: 0.25, outputPerMTok: 2.0, cacheReadPerMTok: 0.025, cacheWritePerMTok: 0),
        "gpt-5-nano":        ModelPricing(inputPerMTok: 0.05, outputPerMTok: 0.40, cacheReadPerMTok: 0.005, cacheWritePerMTok: 0),
        "gpt-5":             ModelPricing(inputPerMTok: 1.25, outputPerMTok: 10.0, cacheReadPerMTok: 0.125, cacheWritePerMTok: 0),
        // OpenAI GPT-4.1 / 4o family
        "gpt-4.1-mini":      ModelPricing(inputPerMTok: 0.40, outputPerMTok: 1.60, cacheReadPerMTok: 0.10, cacheWritePerMTok: 0),
        "gpt-4.1-nano":      ModelPricing(inputPerMTok: 0.10, outputPerMTok: 0.40, cacheReadPerMTok: 0.025, cacheWritePerMTok: 0),
        "gpt-4.1":           ModelPricing(inputPerMTok: 2.0, outputPerMTok: 8.0, cacheReadPerMTok: 0.50, cacheWritePerMTok: 0),
        "gpt-4o-mini":       ModelPricing(inputPerMTok: 0.15, outputPerMTok: 0.60, cacheReadPerMTok: 0.075, cacheWritePerMTok: 0),
        "gpt-4o":            ModelPricing(inputPerMTok: 2.50, outputPerMTok: 10.0, cacheReadPerMTok: 1.25, cacheWritePerMTok: 0),
        // Opus 4.7 / 4.6 / 4.5 — $5 / $25
        "claude-opus-4-7":   ModelPricing(inputPerMTok: 5,  outputPerMTok: 25, cacheReadPerMTok: 0.50, cacheWritePerMTok: 6.25),
        "claude-opus-4-6":   ModelPricing(inputPerMTok: 5,  outputPerMTok: 25, cacheReadPerMTok: 0.50, cacheWritePerMTok: 6.25),
        "claude-opus-4-5":   ModelPricing(inputPerMTok: 5,  outputPerMTok: 25, cacheReadPerMTok: 0.50, cacheWritePerMTok: 6.25),
        // Opus 4.1 — $15 / $75
        "claude-opus-4-1":   ModelPricing(inputPerMTok: 15, outputPerMTok: 75, cacheReadPerMTok: 1.50, cacheWritePerMTok: 18.75),
        // Opus 4.0 — $15 / $75 (catch-all for "claude-opus-4-" without 5/6 suffix)
        "claude-opus-4-":    ModelPricing(inputPerMTok: 15, outputPerMTok: 75, cacheReadPerMTok: 1.50, cacheWritePerMTok: 18.75),
        // Opus 3 — $15 / $75
        "claude-opus-3":     ModelPricing(inputPerMTok: 15, outputPerMTok: 75, cacheReadPerMTok: 1.50, cacheWritePerMTok: 18.75),
        // Sonnet (all 4.x and 3.x) — $3 / $15
        "claude-sonnet-4":   ModelPricing(inputPerMTok: 3,  outputPerMTok: 15, cacheReadPerMTok: 0.30, cacheWritePerMTok: 3.75),
        "claude-sonnet-3":   ModelPricing(inputPerMTok: 3,  outputPerMTok: 15, cacheReadPerMTok: 0.30, cacheWritePerMTok: 3.75),
        // Haiku 4.5 — $1 / $5
        "claude-haiku-4-5":  ModelPricing(inputPerMTok: 1,  outputPerMTok: 5,  cacheReadPerMTok: 0.10, cacheWritePerMTok: 1.25),
        // Haiku 3.5 — $0.80 / $4
        "claude-haiku-3-5":  ModelPricing(inputPerMTok: 0.80, outputPerMTok: 4, cacheReadPerMTok: 0.08, cacheWritePerMTok: 1.0),
        // Haiku 3 — $0.25 / $1.25
        "claude-haiku-3":    ModelPricing(inputPerMTok: 0.25, outputPerMTok: 1.25, cacheReadPerMTok: 0.03, cacheWritePerMTok: 0.30),
    ]
    // swiftlint:enable line_length
}

// MARK: - Shared proxy utilities

enum ProxyHTTPUtils {

    /// Parse all token usage fields from an upstream Anthropic API response.
    ///
    /// - Parameters:
    ///   - data: The raw response body bytes.
    ///   - streaming: Whether the response uses SSE (server-sent events) format.
    /// - Returns: A ``TokenUsage`` with whichever fields were found.
    static func parseTokenUsage(from data: Data, streaming: Bool) -> TokenUsage {
        if streaming {
            return parseTokenUsageFromSSE(data)
        } else {
            return parseTokenUsageFromJSON(data)
        }
    }

    // MARK: - Non-streaming JSON parsing

    private static func parseTokenUsageFromJSON(_ data: Data) -> TokenUsage {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = json["usage"] as? [String: Any] else {
            return .empty
        }
        return TokenUsage(
            inputTokens: usage["input_tokens"] as? Int,
            outputTokens: usage["output_tokens"] as? Int,
            cacheReadInputTokens: usage["cache_read_input_tokens"] as? Int,
            cacheCreationInputTokens: usage["cache_creation_input_tokens"] as? Int,
            inputTokensIncludeCacheReads: false,
            stopReason: json["stop_reason"] as? String
        )
    }

    // MARK: - Streaming SSE parsing

    /// Parse token usage from accumulated SSE chunks. Usage is split across events:
    /// - `message_start`: `message.usage` contains input_tokens, cache_read/creation tokens
    /// - `message_delta`: `usage` contains output_tokens
    private static func parseTokenUsageFromSSE(_ data: Data) -> TokenUsage {
        guard let text = String(data: data, encoding: .utf8) else { return .empty }

        var inputTokens: Int?
        var outputTokens: Int?
        var cacheReadInputTokens: Int?
        var cacheCreationInputTokens: Int?
        var stopReason: String?

        text.enumerateLines { line, stop in
            guard line.hasPrefix("data: ") else { return }
            let payload = line.dropFirst(6) // "data: ".count
            guard payload != "[DONE]",
                  let lineData = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = json["type"] as? String else {
                return
            }

            switch type {
            case "message_start":
                // usage lives at message.usage
                guard let message = json["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any] else { return }
                inputTokens = usage["input_tokens"] as? Int
                cacheReadInputTokens = usage["cache_read_input_tokens"] as? Int
                cacheCreationInputTokens = usage["cache_creation_input_tokens"] as? Int

            case "message_delta":
                // stop_reason lives at delta.stop_reason
                if let delta = json["delta"] as? [String: Any] {
                    stopReason = delta["stop_reason"] as? String
                }
                // output_tokens lives at usage.output_tokens
                if let usage = json["usage"] as? [String: Any] {
                    outputTokens = usage["output_tokens"] as? Int
                }
                // Stop early — message_delta is the last event with usage data.
                stop = true

            default:
                break
            }
        }

        return TokenUsage(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadInputTokens: cacheReadInputTokens,
            cacheCreationInputTokens: cacheCreationInputTokens,
            inputTokensIncludeCacheReads: false,
            stopReason: stopReason
        )
    }

    /// Extract the Anthropic `message.id` from a captured response body.
    /// Returns nil when the body doesn't contain a recognized id field.
    static func extractAnthropicMessageID(from data: Data, streaming: Bool) -> String? {
        if !streaming {
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return json["id"] as? String
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var result: String?
        text.enumerateLines { line, stop in
            guard line.hasPrefix("data: ") else { return }
            let payload = line.dropFirst(6)
            guard payload != "[DONE]",
                  let lineData = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = json["type"] as? String,
                  type == "message_start",
                  let message = json["message"] as? [String: Any],
                  let id = message["id"] as? String else {
                return
            }
            result = id
            stop = true
        }
        return result
    }

    /// Extract all headers from an HTTPURLResponse as name/value tuples.
    static func allHeaders(from response: HTTPURLResponse) -> [(name: String, value: String)] {
        response.allHeaderFields.compactMap { key, value in
            guard let name = key as? String else { return nil }
            return (name: name, value: String(describing: value))
        }
    }

    /// Elapsed time in milliseconds since a start date (minimum 0).
    static func elapsedMilliseconds(since startDate: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(startDate) * 1000))
    }

    /// Build an Anthropic-style JSON error body.
    static func anthropicErrorBody(message: String) -> Data {
        let payload: [String: Any] = [
            "type": "error",
            "error": ["type": "api_error", "message": message],
        ]
        if let body = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) {
            return body
        }
        return Data(#"{"type":"error","error":{"type":"api_error","message":"Proxy error"}}"#.utf8)
    }
}

// MARK: -

/// Protocol for writing HTTP responses back through the connection.
/// Implementations must be `Sendable` because they are shared across
/// the server dispatch queue and async forwarding code.
protocol ResponseWriter: Sendable {
    /// Write the HTTP status line and headers. Call exactly once before any chunks.
    func writeHead(status: Int, headers: [(name: String, value: String)])
    /// Write a chunk of body data. May be called zero or more times.
    func writeChunk(_ data: Data)
    /// Signal the end of the response. After calling this, no further writes are valid.
    func end()
}
