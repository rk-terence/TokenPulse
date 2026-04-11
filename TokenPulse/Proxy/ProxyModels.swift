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
