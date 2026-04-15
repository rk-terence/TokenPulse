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
        guard let codexSessionID = codexSessionID(for: request) else {
            return ProxySessionID.other
        }
        return ProxySessionID.make(codexSessionID, flavor: .openAIResponses)
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

    /// OpenAI does not document a Codex-specific session header contract, so we
    /// only classify traffic as a tracked Codex session when several observed
    /// headers agree on the same identity. Anything less falls back to `other`.
    private func codexSessionID(for request: ProxyHTTPRequest) -> String? {
        guard normalizedHeaderValue("originator", in: request) == "codex-tui",
              let userAgent = normalizedHeaderValue("user-agent", in: request),
              userAgent.hasPrefix("codex-tui/"),
              let sessionID = normalizedHeaderValue("session_id", in: request),
              normalizedHeaderValue("x-client-request-id", in: request) == sessionID,
              windowHeaderMatchesSessionID(request, sessionID: sessionID),
              turnMetadataMatchesSessionID(request, sessionID: sessionID) else {
            return nil
        }

        return sessionID
    }

    private func normalizedHeaderValue(_ name: String, in request: ProxyHTTPRequest) -> String? {
        guard let value = request.headerValue(for: name)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty else {
            return nil
        }
        return value
    }

    private func windowHeaderMatchesSessionID(
        _ request: ProxyHTTPRequest,
        sessionID: String
    ) -> Bool {
        guard let windowID = normalizedHeaderValue("x-codex-window-id", in: request),
              let separator = windowID.lastIndex(of: ":") else {
            return false
        }

        let rawSessionID = String(windowID[..<separator])
        let generation = String(windowID[windowID.index(after: separator)...])
        return rawSessionID == sessionID && UInt64(generation) != nil
    }

    private func turnMetadataMatchesSessionID(
        _ request: ProxyHTTPRequest,
        sessionID: String
    ) -> Bool {
        guard let metadataHeader = normalizedHeaderValue("x-codex-turn-metadata", in: request),
              let metadataData = metadataHeader.data(using: .utf8),
              let metadata = try? JSONSerialization.jsonObject(with: metadataData) as? [String: Any],
              let metadataSessionID = metadata["session_id"] as? String,
              metadataSessionID.trimmingCharacters(in: .whitespacesAndNewlines) == sessionID,
              let turnID = metadata["turn_id"] as? String,
              !turnID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        return true
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
