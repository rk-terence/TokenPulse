import Foundation

protocol ProxyAPIHandler: Sendable {
    var keepaliveRequestPath: String { get }

    func acceptsRequest(method: String, path: String) -> Bool
    func upstreamPath(for requestPath: String) -> String
    func sessionIdentity(for request: ProxyHTTPRequest) -> ProxySessionIdentity
    func extractModel(from body: Data) -> String?
    func isStreamingRequest(body: Data) -> Bool
    func promptDescriptor(from body: Data) -> String?
    func isMainAgentRequest(body: Data) -> Bool
    func lineageFingerprint(from body: Data) -> LineageFingerprint?
    func messagesDescriptor(from body: Data) -> String?
    func buildKeepaliveBody(from body: Data) -> Data?
    func parseTokenUsage(from data: Data, streaming: Bool) -> TokenUsage
    func proxyErrorBody(message: String) -> Data
}

struct AnthropicProxyAPIHandler: ProxyAPIHandler {
    let keepaliveRequestPath = "/v1/messages"

    func acceptsRequest(method: String, path: String) -> Bool {
        method.uppercased() == "POST"
            && (path == "/v1/messages" || path.hasPrefix("/v1/messages?"))
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

    func promptDescriptor(from body: Data) -> String? {
        ProxyRequestBody.promptDescriptor(from: body)
    }

    func isMainAgentRequest(body: Data) -> Bool {
        ProxyRequestBody.hasTools(from: body)
            && !ProxyRequestBody.hasJSONSchemaOutputConfig(from: body)
    }

    func lineageFingerprint(from body: Data) -> LineageFingerprint? {
        ProxyRequestBody.lineageFingerprint(from: body)
    }

    func messagesDescriptor(from body: Data) -> String? {
        ProxyRequestBody.messagesDescriptor(from: body)
    }

    func buildKeepaliveBody(from body: Data) -> Data? {
        KeepaliveRequestBuilder.build(from: body)
    }

    func parseTokenUsage(from data: Data, streaming: Bool) -> TokenUsage {
        ProxyHTTPUtils.parseTokenUsage(from: data, streaming: streaming)
    }

    func proxyErrorBody(message: String) -> Data {
        ProxyHTTPUtils.anthropicErrorBody(message: message)
    }
}
