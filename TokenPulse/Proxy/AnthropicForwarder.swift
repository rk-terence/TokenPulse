import Foundation

/// Forwards incoming proxy requests to the configured upstream Anthropic-compatible
/// API and streams responses back to the local client.
///
/// This type is `Sendable` — it holds only immutable config and a `Sendable` URLSession.
final class AnthropicForwarder: Sendable {
    private static let maxLoggedStreamingResponseBytes = 4 * 1024 * 1024

    let upstreamBaseURL: String
    /// Shared session used for non-streaming requests only.
    private let session: URLSession
    private let eventLogger: ProxyEventLogger?
    private let proxyPort: Int

    init(upstreamBaseURL: String, eventLogger: ProxyEventLogger? = nil, proxyPort: Int = 0) {
        self.upstreamBaseURL = upstreamBaseURL
        self.eventLogger = eventLogger
        self.proxyPort = proxyPort

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300  // Long timeout for streaming
        config.timeoutIntervalForResource = 600
        self.session = URLSession(configuration: config)
    }

    /// Forward a proxy request upstream and write the response back through the writer.
    func forward(
        request: ProxyHTTPRequest,
        sessionStore: ProxySessionStore,
        metrics: ProxyMetricsStore,
        keepaliveManager: KeepaliveManager?
    ) async {
        // 1. Extract session ID and update session store.
        let sessionID = request.headerValue(for: "X-Claude-Code-Session-Id") ?? "unknown"
        await sessionStore.touch(sessionID)
        await sessionStore.incrementInFlight(sessionID)

        // Store request context for keepalive use.
        let model = extractModel(from: request.body)
        await sessionStore.storeRequestContext(
            body: request.body,
            headers: request.headers,
            model: model,
            for: sessionID
        )

        await forwardRequest(
            request: request,
            sessionID: sessionID,
            model: model,
            sessionStore: sessionStore,
            metrics: metrics,
            keepaliveManager: keepaliveManager
        )
        await sessionStore.decrementInFlight(sessionID)
    }

    // MARK: - Streaming forwarding

    private func forwardRequest(
        request: ProxyHTTPRequest,
        sessionID: String,
        model: String?,
        sessionStore: ProxySessionStore,
        metrics: ProxyMetricsStore,
        keepaliveManager: KeepaliveManager?
    ) async {
        // requestID is created below, after URL validation, so we only track
        // real upstream attempts (not proxy-side config errors).
        let urlString = upstreamBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            + request.path
        let wantsStreaming = ProxyRequestBody.isStreaming(from: request.body)
        let requestStartedAt = Date()
        let requestLog = ProxyEventLogger.LoggedRequest(
            method: request.method,
            path: request.path,
            upstreamURL: urlString,
            headers: request.headers,
            body: request.body,
            streaming: wantsStreaming
        )
        await eventLogger?.logRequestStarted(
            session: sessionID,
            model: model,
            method: request.method,
            path: request.path,
            upstreamURL: urlString,
            streaming: wantsStreaming
        )

        guard let url = URL(string: urlString) else {
            await metrics.recordFailed()
            let response = proxyErrorResponse(
                status: 502,
                message: String(localized: "Bad Gateway: invalid upstream URL")
            )
            await eventLogger?.logRequestFailed(
                session: sessionID,
                model: model,
                request: requestLog,
                response: response.loggedResponse,
                durationMs: ProxyHTTPUtils.elapsedMilliseconds(since: requestStartedAt),
                error: "invalid upstream URL"
            )
            writeErrorToClient(writer: request.writer, response: response)
            return
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = request.body

        for header in request.headers {
            let lowered = header.name.lowercased()
            if lowered == "host" || lowered == "content-length" || lowered == "transfer-encoding" {
                continue
            }
            urlRequest.addValue(header.value, forHTTPHeaderField: header.name)
        }

        // Register the in-flight request in the session store for real-time UI display.
        let requestID = UUID()
        await sessionStore.startRequest(id: requestID, sessionID: sessionID)
        await sessionStore.recordBytesSent(request.body.count)

        if wantsStreaming {
            await forwardStreaming(
                urlRequest: urlRequest,
                writer: request.writer,
                requestID: requestID,
                sessionStore: sessionStore,
                metrics: metrics,
                sessionID: sessionID,
                model: model,
                requestLog: requestLog,
                requestStartedAt: requestStartedAt
            )
        } else {
            await forwardNonStreaming(
                urlRequest: urlRequest,
                writer: request.writer,
                requestID: requestID,
                sessionStore: sessionStore,
                metrics: metrics,
                sessionID: sessionID,
                model: model,
                requestLog: requestLog,
                requestStartedAt: requestStartedAt
            )
        }

        await writeStatusSnapshot(
            sessionStore: sessionStore,
            metrics: metrics,
            keepaliveManager: keepaliveManager
        )

        await keepaliveManager?.startOrReset(sessionID: sessionID, headers: request.headers)
    }

    private func forwardStreaming(
        urlRequest: URLRequest,
        writer: ResponseWriter,
        requestID: UUID,
        sessionStore: ProxySessionStore,
        metrics: ProxyMetricsStore,
        sessionID: String,
        model: String?,
        requestLog: ProxyEventLogger.LoggedRequest,
        requestStartedAt: Date
    ) async {
        do {
            // Create a per-request streaming delegate and session so we receive
            // natural TCP-segment-sized chunks instead of byte-by-byte iteration.
            let streamingDelegate = StreamingDelegate()
            streamingDelegate.onUploadProgress = { totalBytesSent in
                Task {
                    await sessionStore.updateRequestBytesSent(
                        id: requestID,
                        totalBytesSent: Int(totalBytesSent)
                    )
                }
            }
            let delegateConfig = URLSessionConfiguration.default
            delegateConfig.timeoutIntervalForRequest = 300
            delegateConfig.timeoutIntervalForResource = 600
            let delegateSession = URLSession(configuration: delegateConfig,
                                              delegate: streamingDelegate,
                                              delegateQueue: nil)
            defer { delegateSession.invalidateAndCancel() }

            // Use uploadTask for reliable didSendBodyData progress callbacks.
            let bodyData = urlRequest.httpBody ?? Data()
            var uploadRequest = urlRequest
            uploadRequest.httpBody = nil
            let dataTask = delegateSession.uploadTask(with: uploadRequest, from: bodyData)
            let chunks = streamingDelegate.chunkStream

            dataTask.resume()

            // Track the upstream status code for event logging.
            var upstreamStatusCode = 0
            var capturedResponseHeaders: [(name: String, value: String)] = []
            let shouldCaptureResponseBody = eventLogger != nil
            var capturedResponseBody = Data()
            var capturedResponseBytes = 0

            // Wrap the entire streaming operation — including header wait — in a
            // cancellation handler so the upstream task is cancelled if the client
            // disconnects at any point (during header wait OR chunk streaming).
            try await withTaskCancellationHandler {
                // Await the HTTP response headers.
                let httpResponse = try await streamingDelegate.awaitResponse()
                upstreamStatusCode = httpResponse.statusCode
                capturedResponseHeaders = ProxyHTTPUtils.allHeaders(from: httpResponse)

                // Write the head with upstream status and headers.
                var responseHeaders = buildResponseHeaders(from: httpResponse, streaming: true)

                // For streaming, use chunked transfer encoding to the client.
                // Remove any content-length since we are chunking.
                responseHeaders.removeAll(where: { $0.name.lowercased() == "content-length" })

                // Ensure Transfer-Encoding: chunked is present.
                if !responseHeaders.contains(where: { $0.name.lowercased() == "transfer-encoding" }) {
                    responseHeaders.append((name: "Transfer-Encoding", value: "chunked"))
                }

                writer.writeHead(status: httpResponse.statusCode, headers: responseHeaders)
                // Headers received — transition to generating state.
                await sessionStore.markRequestGenerating(id: requestID)

                // Stream chunks through to the client.
                for await chunk in chunks {
                    try Task.checkCancellation()
                    await sessionStore.updateRequestBytes(id: requestID, additionalBytes: chunk.count)
                    if shouldCaptureResponseBody {
                        capturedResponseBytes += chunk.count
                        Self.appendForLogging(
                            chunk,
                            to: &capturedResponseBody,
                            maxBytes: Self.maxLoggedStreamingResponseBytes
                        )
                    }
                    writer.writeChunk(chunk)
                }
            } onCancel: {
                dataTask.cancel()
            }

            writer.end()
            await sessionStore.finishRequest(id: requestID, errored: false)
            await metrics.recordForwarded()
            let responseLog = ProxyEventLogger.LoggedResponse(
                statusCode: upstreamStatusCode,
                headers: capturedResponseHeaders,
                body: capturedResponseBody,
                source: "upstream",
                bodyBytes: capturedResponseBytes,
                bodyTruncated: capturedResponseBytes > capturedResponseBody.count
            )
            let (cacheRead, cacheCreation) = ProxyHTTPUtils.parseCacheMetrics(from: capturedResponseBody)
            await eventLogger?.logRequestCompleted(
                session: sessionID,
                model: model,
                request: requestLog,
                response: responseLog,
                durationMs: ProxyHTTPUtils.elapsedMilliseconds(since: requestStartedAt),
                statusCode: upstreamStatusCode,
                cacheReadTokens: cacheRead,
                cacheCreationTokens: cacheCreation
            )

        } catch is CancellationError {
            // Client disconnected — no error response needed.
            await sessionStore.finishRequest(id: requestID, errored: true)
            ProxyLogger.log("Streaming request cancelled (client disconnect)")
            await eventLogger?.logRequestFailed(
                session: sessionID,
                model: model,
                request: requestLog,
                response: nil,
                durationMs: ProxyHTTPUtils.elapsedMilliseconds(since: requestStartedAt),
                error: "client disconnected"
            )
        } catch {
            await sessionStore.finishRequest(id: requestID, errored: true)
            await metrics.recordFailed()
            let response = proxyErrorResponse(
                status: 502,
                message: String(localized: "Bad Gateway: upstream error: \(error.localizedDescription)")
            )
            await eventLogger?.logRequestFailed(
                session: sessionID,
                model: model,
                request: requestLog,
                response: response.loggedResponse,
                durationMs: ProxyHTTPUtils.elapsedMilliseconds(since: requestStartedAt),
                error: error.localizedDescription
            )
            writeErrorToClient(writer: writer, response: response)
        }
    }

    // MARK: - Non-streaming forwarding

    private func forwardNonStreaming(
        urlRequest: URLRequest,
        writer: ResponseWriter,
        requestID: UUID,
        sessionStore: ProxySessionStore,
        metrics: ProxyMetricsStore,
        sessionID: String,
        model: String?,
        requestLog: ProxyEventLogger.LoggedRequest,
        requestStartedAt: Date
    ) async {
        do {
            // Mark as generating while we wait for the full response.
            await sessionStore.markRequestGenerating(id: requestID)
            let (data, response) = try await session.data(for: urlRequest)

            guard let httpResponse = response as? HTTPURLResponse else {
                await sessionStore.finishRequest(id: requestID, errored: true)
                await metrics.recordFailed()
                let proxyResponse = proxyErrorResponse(
                    status: 502,
                    message: String(localized: "Bad Gateway: non-HTTP response from upstream")
                )
                await eventLogger?.logRequestFailed(
                    session: sessionID,
                    model: model,
                    request: requestLog,
                    response: proxyResponse.loggedResponse,
                    durationMs: ProxyHTTPUtils.elapsedMilliseconds(since: requestStartedAt),
                    error: "non-HTTP response from upstream"
                )
                writeErrorToClient(writer: writer, response: proxyResponse)
                return
            }

            var responseHeaders = buildResponseHeaders(from: httpResponse, streaming: false)
            responseHeaders.append((name: "Content-Length", value: "\(data.count)"))

            writer.writeHead(status: httpResponse.statusCode, headers: responseHeaders)
            if !data.isEmpty {
                await sessionStore.updateRequestBytes(id: requestID, additionalBytes: data.count)
            }
            if !data.isEmpty {
                writer.writeChunk(data)
            }
            writer.end()
            await sessionStore.finishRequest(id: requestID, errored: false)
            await metrics.recordForwarded()

            // For non-streaming, parse cache metrics from the response body.
            let (cacheRead, cacheCreation) = ProxyHTTPUtils.parseCacheMetrics(from: data)
            let responseLog = ProxyEventLogger.LoggedResponse(
                statusCode: httpResponse.statusCode,
                headers: ProxyHTTPUtils.allHeaders(from: httpResponse),
                body: data,
                source: "upstream"
            )
            await eventLogger?.logRequestCompleted(
                session: sessionID,
                model: model,
                request: requestLog,
                response: responseLog,
                durationMs: ProxyHTTPUtils.elapsedMilliseconds(since: requestStartedAt),
                statusCode: httpResponse.statusCode,
                cacheReadTokens: cacheRead,
                cacheCreationTokens: cacheCreation
            )

        } catch {
            await sessionStore.finishRequest(id: requestID, errored: true)
            await metrics.recordFailed()
            let response = proxyErrorResponse(
                status: 502,
                message: String(localized: "Bad Gateway: upstream error: \(error.localizedDescription)")
            )
            await eventLogger?.logRequestFailed(
                session: sessionID,
                model: model,
                request: requestLog,
                response: response.loggedResponse,
                durationMs: ProxyHTTPUtils.elapsedMilliseconds(since: requestStartedAt),
                error: error.localizedDescription
            )
            writeErrorToClient(writer: writer, response: response)
        }
    }

    // MARK: - Helpers

    /// Build response headers from the upstream HTTPURLResponse, filtering hop-by-hop headers.
    private func buildResponseHeaders(
        from response: HTTPURLResponse,
        streaming: Bool
    ) -> [(name: String, value: String)] {
        var headers: [(name: String, value: String)] = []
        let skipHeaders: Set<String> = [
            "content-length", "transfer-encoding", "connection", "keep-alive"
        ]

        for (key, value) in response.allHeaderFields {
            guard let name = key as? String, let val = value as? String else { continue }
            if skipHeaders.contains(name.lowercased()) { continue }
            headers.append((name: name, value: val))
        }

        headers.append((name: "Connection", value: "close"))

        return headers
    }

    /// Send a proxy-generated error response to the client.
    private func writeErrorToClient(
        writer: ResponseWriter,
        response: (headers: [(name: String, value: String)], body: Data, loggedResponse: ProxyEventLogger.LoggedResponse)
    ) {
        writer.writeHead(status: response.loggedResponse.statusCode, headers: response.headers)
        writer.writeChunk(response.body)
        writer.end()
    }

    /// Extract the model name from a JSON request body.
    private func extractModel(from body: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return nil
        }
        return json["model"] as? String
    }

    private func proxyErrorResponse(
        status: Int,
        message: String
    ) -> (headers: [(name: String, value: String)], body: Data, loggedResponse: ProxyEventLogger.LoggedResponse) {
        let body = ProxyHTTPUtils.anthropicErrorBody(message: message)
        let headers = [
            (name: "Content-Type", value: "application/json; charset=utf-8"),
            (name: "Content-Length", value: "\(body.count)"),
            (name: "Connection", value: "close"),
        ]
        let loggedResponse = ProxyEventLogger.LoggedResponse(
            statusCode: status,
            headers: headers,
            body: body,
            source: "proxy"
        )
        return (headers: headers, body: body, loggedResponse: loggedResponse)
    }

    private static func appendForLogging(_ chunk: Data, to capturedBody: inout Data, maxBytes: Int) {
        let remaining = maxBytes - capturedBody.count
        guard remaining > 0 else { return }
        if chunk.count <= remaining {
            capturedBody.append(chunk)
        } else {
            capturedBody.append(chunk.prefix(remaining))
        }
    }

    /// Write an atomic status snapshot via the event logger.
    private func writeStatusSnapshot(
        sessionStore: ProxySessionStore,
        metrics: ProxyMetricsStore,
        keepaliveManager: KeepaliveManager?
    ) async {
        guard let logger = eventLogger else { return }
        let activeSessions = await sessionStore.activeSessions().count
        let activeKeepalives = await keepaliveManager?.activeCount() ?? 0
        let snapshot = await metrics.snapshot()
        await logger.writeStatusSnapshot(
            enabled: true,
            port: proxyPort,
            activeSessions: activeSessions,
            activeKeepalives: activeKeepalives,
            metrics: snapshot
        )
    }
}

// MARK: - StreamingDelegate

/// A `URLSessionDataDelegate` that receives upstream chunks in natural TCP segment
/// sizes and pipes them through an `AsyncStream<Data>`. This avoids the byte-by-byte
/// overhead of `URLSession.AsyncBytes` for SSE passthrough.
///
/// The delegate uses a lock to safely bridge between the URLSession delegate queue
/// callbacks and the async consumer. The response is delivered via a one-element
/// `AsyncStream<Result<HTTPURLResponse, Error>>`.
private final class StreamingDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {

    /// Called on each upload progress report with cumulative bytes sent.
    var onUploadProgress: (@Sendable (_ totalBytesSent: Int64) -> Void)?

    private let chunkContinuation: AsyncStream<Data>.Continuation
    let chunkStream: AsyncStream<Data>

    private let responseContinuation: AsyncStream<Result<HTTPURLResponse, Error>>.Continuation
    let responseStream: AsyncStream<Result<HTTPURLResponse, Error>>

    override init() {
        var chunkCont: AsyncStream<Data>.Continuation!
        self.chunkStream = AsyncStream<Data> { chunkCont = $0 }
        self.chunkContinuation = chunkCont

        var respCont: AsyncStream<Result<HTTPURLResponse, Error>>.Continuation!
        self.responseStream = AsyncStream<Result<HTTPURLResponse, Error>>(bufferingPolicy: .bufferingNewest(1)) { respCont = $0 }
        self.responseContinuation = respCont

        super.init()
    }

    /// Await the HTTP response from the delegate. Returns `nil` if the stream
    /// ends without delivering a response (e.g. task was cancelled before headers).
    func awaitResponse() async throws -> HTTPURLResponse {
        for await result in responseStream {
            switch result {
            case .success(let response):
                return response
            case .failure(let error):
                throw error
            }
        }
        throw ProxyStreamingError.noResponse
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        if let httpResponse = response as? HTTPURLResponse {
            responseContinuation.yield(.success(httpResponse))
        } else {
            responseContinuation.yield(.failure(ProxyStreamingError.nonHTTPResponse))
        }
        responseContinuation.finish()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        chunkContinuation.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        onUploadProgress?(totalBytesSent)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            // If response was never delivered (connection failed before headers),
            // send the error through the response stream.
            responseContinuation.yield(.failure(error))
            responseContinuation.finish()
        }
        chunkContinuation.finish()
    }
}

/// Errors specific to the streaming delegate flow.
private enum ProxyStreamingError: Error, LocalizedError {
    case nonHTTPResponse
    case noResponse

    var errorDescription: String? {
        switch self {
        case .nonHTTPResponse:
            return String(localized: "Bad Gateway: non-HTTP response from upstream")
        case .noResponse:
            return String(localized: "Bad Gateway: no response received from upstream")
        }
    }
}
