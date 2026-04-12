import Foundation

// MARK: - Lightweight model for the proxy passthrough

/// For Phase 1 passthrough, we store the raw body as Data and only extract
/// the `stream` field to determine whether the client wants SSE.
/// Everything else passes through byte-for-byte.
enum ProxyRequestBody {

    /// Attempts to read the `stream` field from a JSON body without
    /// deserializing the entire payload.
    static func isStreaming(from body: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return false
        }
        return (json["stream"] as? Bool) ?? false
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
    /// Awaiting the first response byte — headers not yet received from upstream.
    case sending
    /// Response headers received; body is streaming or being accumulated.
    case generating
}

/// Live snapshot of a single in-flight proxy request.
struct ProxyRequestActivity: Sendable, Identifiable {
    let id: UUID
    var state: ProxyRequestState
    /// Cumulative bytes sent to upstream so far.
    var bytesSent: Int
    /// Cumulative bytes received from upstream so far.
    var bytesReceived: Int
    /// Timestamp of the most recent upstream data chunk, used for freshness coloring.
    var lastDataAt: Date?
    let startedAt: Date
}

// MARK: - Shared proxy utilities

enum ProxyHTTPUtils {

    /// Parse `cache_read_input_tokens` and `cache_creation_input_tokens` from
    /// the upstream JSON response's `usage` object.
    static func parseCacheMetrics(from data: Data) -> (cacheReadTokens: Int?, cacheCreationTokens: Int?) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = json["usage"] as? [String: Any] else {
            return (nil, nil)
        }
        return (usage["cache_read_input_tokens"] as? Int, usage["cache_creation_input_tokens"] as? Int)
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
