import Foundation

struct OpenAIResponsesProxyAPIHandler: ProxyAPIHandler {
    let keepaliveRequestPath = "/v1/responses"

    func acceptsRequest(method: String, path: String) -> Bool {
        method.uppercased() == "POST"
            && (path == "/v1/responses" || path.hasPrefix("/v1/responses?"))
    }

    func upstreamPath(for requestPath: String) -> String {
        requestPath
    }

    func sessionID(for request: ProxyHTTPRequest) -> String {
        ProxySessionID.other
    }

    func extractModel(from body: Data) -> String? {
        jsonObject(from: body)?["model"] as? String
    }

    func isStreamingRequest(body: Data) -> Bool {
        (jsonObject(from: body)?["stream"] as? Bool) ?? false
    }

    func promptDescriptor(from body: Data) -> String? {
        nil
    }

    func isMainAgentRequest(body: Data) -> Bool {
        false
    }

    func lineageFingerprint(from body: Data) -> LineageFingerprint? {
        nil
    }

    func messagesDescriptor(from body: Data) -> String? {
        nil
    }

    func buildKeepaliveBody(from body: Data) -> Data? {
        nil
    }

    func parseTokenUsage(from data: Data, streaming: Bool) -> TokenUsage {
        if streaming {
            return parseTokenUsageFromStreaming(data)
        }
        return parseTokenUsageFromJSON(data)
    }

    func proxyErrorBody(message: String) -> Data {
        let payload: [String: Any] = [
            "error": [
                "message": message,
                "type": "invalid_request_error"
            ]
        ]
        return (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
            ?? Data(#"{"error":{"message":"Proxy error","type":"invalid_request_error"}}"#.utf8)
    }

    private func jsonObject(from body: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }

    private func parseTokenUsageFromJSON(_ data: Data) -> TokenUsage {
        guard let json = jsonObject(from: data) else { return .empty }
        return parseUsage(from: json["usage"] as? [String: Any], stopReason: json["status"] as? String)
    }

    private func parseTokenUsageFromStreaming(_ data: Data) -> TokenUsage {
        guard let text = String(data: data, encoding: .utf8) else { return .empty }

        var finalUsage: TokenUsage = .empty
        text.enumerateLines { line, stop in
            guard line.hasPrefix("data: ") else { return }
            let payload = line.dropFirst(6)
            guard payload != "[DONE]",
                  let lineData = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = json["type"] as? String else {
                return
            }

            guard type == "response.completed" || type == "response.incomplete",
                  let response = json["response"] as? [String: Any] else {
                return
            }

            finalUsage = parseUsage(
                from: response["usage"] as? [String: Any],
                stopReason: response["status"] as? String
            )
            stop = true
        }

        return finalUsage
    }

    private func parseUsage(from usage: [String: Any]?, stopReason: String?) -> TokenUsage {
        guard let usage else { return .empty }
        let inputTokens = usage["input_tokens"] as? Int
        let outputTokens = usage["output_tokens"] as? Int
        let inputDetails = usage["input_tokens_details"] as? [String: Any]
        let cachedTokens = inputDetails?["cached_tokens"] as? Int

        return TokenUsage(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadInputTokens: cachedTokens,
            cacheCreationInputTokens: nil,
            inputTokensIncludeCacheReads: true,
            stopReason: stopReason
        )
    }
}
