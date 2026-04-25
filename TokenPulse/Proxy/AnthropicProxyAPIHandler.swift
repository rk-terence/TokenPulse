import Foundation

protocol ProxyAPIHandler: Sendable {
    var flavor: ProxyAPIFlavor { get }

    func acceptsRequest(method: String, path: String) -> Bool
    func operation(for requestPath: String) -> ProxyRequestOperation
    func upstreamPath(for requestPath: String) -> String
    func sessionIdentity(for request: ProxyHTTPRequest) -> ProxySessionIdentity
    func extractModel(from body: Data) -> String?
    func isStreamingRequest(body: Data) -> Bool

    /// Lineage fingerprint (cache-identity shape) for generation requests.
    /// Utility operations can opt out of tree tracking via `operation(for:)`.
    func lineageFingerprint(from body: Data) -> LineageFingerprint?

    /// Normalized messages / input stack carried by the request body. Empty when
    /// the provider uses `previous_response_id` alone (OpenAI path).
    func normalizedLineageMessages(from body: Data) -> [ContentTree.NormalizedMessage]

    /// OpenAI `previous_response_id` if present; always nil for Anthropic.
    func previousResponseID(from body: Data) -> String?

    /// Extract the upstream response ID from a captured response body.
    /// Anthropic returns `message.id` (`msg_*`); OpenAI returns `response.id` (`resp_*`).
    func extractResponseID(from data: Data, streaming: Bool) -> String?

    func parseTokenUsage(from data: Data, streaming: Bool) -> TokenUsage

    /// Whether the parsed token usage carries a definitive "response complete"
    /// signal from upstream. Used to distinguish a fully-received response from
    /// a 2xx-but-truncated stream.
    ///
    /// - Anthropic: any non-nil `stop_reason` in `message_delta`.
    /// - OpenAI Responses: `status == "completed"` in `response.completed`.
    func isResponseComplete(_ usage: TokenUsage) -> Bool

    func proxyErrorBody(message: String) -> Data
}

struct AnthropicProxyAPIHandler: ProxyAPIHandler {
    let flavor: ProxyAPIFlavor = .anthropicMessages

    func acceptsRequest(method: String, path: String) -> Bool {
        method.uppercased() == "POST"
            && (
                path == "/v1/messages"
                    || path.hasPrefix("/v1/messages?")
                    || path == "/v1/messages/count_tokens"
                    || path.hasPrefix("/v1/messages/count_tokens?")
            )
    }

    func operation(for requestPath: String) -> ProxyRequestOperation {
        if requestPath == "/v1/messages/count_tokens"
            || requestPath.hasPrefix("/v1/messages/count_tokens?") {
            return .tokenCount
        }
        return .generation
    }

    func upstreamPath(for requestPath: String) -> String {
        requestPath
    }

    func sessionIdentity(for request: ProxyHTTPRequest) -> ProxySessionIdentity {
        guard let rawSessionID = request.headerValue(for: "X-Claude-Code-Session-Id") else {
            return .other
        }
        return .tracked(rawSessionID: rawSessionID, flavor: .anthropicMessages)
    }

    func extractModel(from body: Data) -> String? {
        ProxyRequestBody.model(from: body)
    }

    func isStreamingRequest(body: Data) -> Bool {
        ProxyRequestBody.isStreaming(from: body)
    }

    func lineageFingerprint(from body: Data) -> LineageFingerprint? {
        ProxyRequestBody.lineageFingerprint(from: body, flavor: flavor)
    }

    func normalizedLineageMessages(from body: Data) -> [ContentTree.NormalizedMessage] {
        ProxyRequestBody.normalizedLineageMessages(from: body, flavor: flavor)
    }

    func previousResponseID(from body: Data) -> String? {
        nil
    }

    func extractResponseID(from data: Data, streaming: Bool) -> String? {
        ProxyHTTPUtils.extractAnthropicMessageID(from: data, streaming: streaming)
    }

    func parseTokenUsage(from data: Data, streaming: Bool) -> TokenUsage {
        ProxyHTTPUtils.parseTokenUsage(from: data, streaming: streaming)
    }

    func isResponseComplete(_ usage: TokenUsage) -> Bool {
        // Any non-nil stop_reason indicates Anthropic produced a terminal
        // `message_delta` event. Valid values include end_turn, max_tokens,
        // stop_sequence, tool_use, pause_turn, refusal. All count as "server
        // finished producing this message."
        usage.stopReason != nil
    }

    func proxyErrorBody(message: String) -> Data {
        ProxyHTTPUtils.anthropicErrorBody(message: message)
    }
}
