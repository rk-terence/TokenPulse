import Foundation

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

    /// Build a stable prompt descriptor used for completed-request replacement.
    /// We include the Anthropic prompt-shaping fields and preserve message order
    /// so a later superset prompt contains the earlier prompt as a substring.
    static func promptDescriptor(from body: Data) -> String? {
        guard let json = jsonObject(from: body) else {
            return nil
        }

        var lines: [String] = []
        appendCanonicalLine(label: "system", value: normalizedValue(normalizedSystemPrompt(json["system"])), to: &lines)
        appendCanonicalLine(label: "tools", value: normalizedValue(json["tools"]), to: &lines)
        appendCanonicalLine(label: "tool_choice", value: normalizedValue(json["tool_choice"]), to: &lines)
        appendCanonicalLine(label: "thinking", value: normalizedValue(json["thinking"]), to: &lines)

        if let messages = json["messages"] as? [Any] {
            for message in messages {
                appendCanonicalLine(label: "message", value: normalizedValue(message), to: &lines)
            }
        }

        guard !lines.isEmpty else {
            return nil
        }
        return lines.joined(separator: "\n")
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

    private static func canonicalString(for value: Any) -> String? {
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

// MARK: - Keepalive request builder

/// Transforms a stored request body into a keepalive variant, preserving all
/// cache-identity-relevant fields (system, messages, tools, tool_choice,
/// cache_control, thinking config). Only `max_tokens` and `stream` are changed.
enum KeepaliveRequestBuilder {

    /// Build a keepalive request body from a stored real request body.
    /// Preserves all cache-key-relevant fields including `thinking`.
    /// When thinking is enabled, `max_tokens` must exceed `budget_tokens`,
    /// so we set it to `budget_tokens + 1`. Otherwise `max_tokens` is 1.
    /// Returns nil if the body cannot be parsed as JSON.
    static func build(from originalBody: Data) -> Data? {
        guard var json = try? JSONSerialization.jsonObject(with: originalBody) as? [String: Any] else {
            return nil
        }
        json["stream"] = false

        if let thinking = json["thinking"] as? [String: Any],
           let budgetTokens = thinking["budget_tokens"] as? Int {
            json["max_tokens"] = budgetTokens + 1
        } else {
            json["max_tokens"] = 1
        }

        return try? JSONSerialization.data(withJSONObject: json)
    }
}

// MARK: - Real-time request activity

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
    var state: ProxyRequestState
    /// Model ID from the request body, used for done-request replacement matching.
    let modelID: String?
    /// Stable prompt descriptor built from prompt-shaping fields in the request body.
    let promptDescriptor: String?
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

    /// Total prompt tokens (input + cache read + cache creation) for display. Nil when unavailable.
    var promptTokens: Int? {
        guard let usage = tokenUsage else { return nil }
        let total = (usage.inputTokens ?? 0)
                  + (usage.cacheReadInputTokens ?? 0)
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

    static let empty = TokenUsage(inputTokens: nil, outputTokens: nil,
                                  cacheReadInputTokens: nil, cacheCreationInputTokens: nil)

    /// Compute the estimated cost (USD) using the given pricing rates.
    func cost(for pricing: ModelPricing) -> Double {
        let input    = Double(inputTokens ?? 0)            * pricing.inputPerMTok
        let output   = Double(outputTokens ?? 0)           * pricing.outputPerMTok
        let cacheRd  = Double(cacheReadInputTokens ?? 0)   * pricing.cacheReadPerMTok
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

/// Lookup pricing for an Anthropic model ID string (e.g. "claude-opus-4-6-20260401").
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
        // Opus 4.6 / 4.5 — $5 / $25
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

    /// Legacy wrapper for callers that only need cache metrics (e.g. KeepaliveManager).
    static func parseCacheMetrics(from data: Data) -> (cacheReadTokens: Int?, cacheCreationTokens: Int?) {
        let usage = parseTokenUsage(from: data, streaming: false)
        return (usage.cacheReadInputTokens, usage.cacheCreationInputTokens)
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
            cacheCreationInputTokens: usage["cache_creation_input_tokens"] as? Int
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
                // output_tokens lives at usage.output_tokens
                guard let usage = json["usage"] as? [String: Any] else { return }
                outputTokens = usage["output_tokens"] as? Int
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
            cacheCreationInputTokens: cacheCreationInputTokens
        )
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
