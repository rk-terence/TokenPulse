import Foundation

struct OpenAIResponsesProxyAPIHandler: ProxyAPIHandler {
    let flavor: ProxyAPIFlavor = .openAIResponses

    func acceptsRequest(method: String, path: String) -> Bool {
        method.uppercased() == "POST"
            && (path == "/v1/responses" || path.hasPrefix("/v1/responses?"))
    }

    func upstreamPath(for requestPath: String) -> String {
        requestPath
    }

    /// Codex traffic carries `session_id` + matching `x-codex-window-id`.
    /// Sub-agents add `x-codex-parent-thread-id`, but with the lineage tree in
    /// place we no longer collapse threads server-side — the tree groups by
    /// fingerprint. We retain the session ID only for UI grouping.
    func sessionIdentity(for request: ProxyHTTPRequest) -> ProxySessionIdentity {
        guard let sessionID = normalizedHeaderValue("session_id", in: request),
              windowHeaderMatchesSessionID(request, sessionID: sessionID) else {
            return .other
        }
        return .tracked(rawSessionID: sessionID, flavor: .openAIResponses)
    }

    func extractModel(from body: Data) -> String? {
        jsonObject(from: body)?["model"] as? String
    }

    func isStreamingRequest(body: Data) -> Bool {
        (jsonObject(from: body)?["stream"] as? Bool) ?? false
    }

    func lineageFingerprint(from body: Data) -> LineageFingerprint? {
        ProxyRequestBody.lineageFingerprint(from: body, flavor: flavor)
    }

    func normalizedLineageMessages(from body: Data) -> [ContentTree.NormalizedMessage] {
        ProxyRequestBody.normalizedLineageMessages(from: body, flavor: flavor)
    }

    func previousResponseID(from body: Data) -> String? {
        ProxyRequestBody.previousResponseID(from: body)
    }

    func extractResponseID(from data: Data, streaming: Bool) -> String? {
        if streaming {
            return extractResponseIDFromStreaming(data)
        }
        return (jsonObject(from: data)?["id"] as? String)
    }

    func parseTokenUsage(from data: Data, streaming: Bool) -> TokenUsage {
        if streaming {
            return parseTokenUsageFromStreaming(data)
        }
        return parseTokenUsageFromJSON(data)
    }

    func isResponseComplete(_ usage: TokenUsage) -> Bool {
        // `response.completed` carries `status == "completed"`. `status == "incomplete"`
        // means upstream stopped early (e.g. hit max_output_tokens) and the turn is
        // partial — treat as incomplete. Missing status = malformed response.
        usage.stopReason == "completed"
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

    private func extractResponseIDFromStreaming(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var result: String?
        text.enumerateLines { line, stop in
            guard line.hasPrefix("data: ") else { return }
            let payload = line.dropFirst(6)
            guard payload != "[DONE]",
                  let lineData = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = json["type"] as? String,
                  type == "response.completed" || type == "response.incomplete",
                  let response = json["response"] as? [String: Any],
                  let id = response["id"] as? String else {
                return
            }
            result = id
            stop = true
        }
        return result
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
