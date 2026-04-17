import Foundation

/// Forwards incoming proxy requests to the configured upstream API and streams
/// responses back to the local client.
///
/// Protocol-specific request parsing, lineage, and keepalive semantics are
/// delegated to the injected `ProxyAPIHandler`.
final class ProxyForwarder: Sendable {
    private static let maxLoggedStreamingResponseBytes = 4 * 1024 * 1024

    let upstreamBaseURL: String
    private let apiFlavor: ProxyAPIFlavor
    private let apiHandler: any ProxyAPIHandler
    private let eventLogger: ProxyEventLogger?
    private let proxyPort: Int
    /// Shared session for non-streaming requests — preserves TCP/TLS connection reuse.
    private let nonStreamingSession: URLSession
    private let nonStreamingPoolDelegate: NonStreamingPoolDelegate

    init(
        upstreamBaseURL: String,
        apiFlavor: ProxyAPIFlavor,
        apiHandler: any ProxyAPIHandler,
        eventLogger: ProxyEventLogger? = nil,
        proxyPort: Int = 0
    ) {
        self.upstreamBaseURL = upstreamBaseURL
        self.apiFlavor = apiFlavor
        self.apiHandler = apiHandler
        self.eventLogger = eventLogger
        self.proxyPort = proxyPort

        let poolDelegate = NonStreamingPoolDelegate()
        self.nonStreamingPoolDelegate = poolDelegate
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 600
        self.nonStreamingSession = URLSession(configuration: config,
                                               delegate: poolDelegate,
                                               delegateQueue: nil)
    }

    /// Forward a proxy request upstream and write the response back through the writer.
    func forward(
        request: ProxyHTTPRequest,
        sessionStore: ProxySessionStore,
        metrics: ProxyMetricsStore
    ) async {
        let sessionIdentity = apiHandler.sessionIdentity(for: request)
        let model = apiHandler.extractModel(from: request.body)
        let supportsTrackedSession = sessionIdentity.flavor != nil
        let promptDescriptor = supportsTrackedSession ? apiHandler.promptDescriptor(from: request.body) : nil

        await forwardRequest(
            request: request,
            sessionIdentity: sessionIdentity,
            model: model,
            promptDescriptor: promptDescriptor,
            sessionStore: sessionStore,
            metrics: metrics
        )
    }

    // MARK: - Streaming forwarding

    private func forwardRequest(
        request: ProxyHTTPRequest,
        sessionIdentity: ProxySessionIdentity,
        model: String?,
        promptDescriptor: String?,
        sessionStore: ProxySessionStore,
        metrics: ProxyMetricsStore
    ) async {
        // requestID is created below, after URL validation, so we only track
        // real upstream attempts (not proxy-side config errors).
        let upstreamPath = apiHandler.upstreamPath(for: request.path)
        let urlString = upstreamBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            + upstreamPath
        let wantsStreaming = apiHandler.isStreamingRequest(body: request.body)
        let requestStartedAt = Date()
        let requestLog = ProxyEventLogger.LoggedRequest(
            method: request.method,
            path: request.path,
            upstreamURL: urlString,
            headers: request.headers,
            body: request.body,
            streaming: wantsStreaming
        )

        guard let url = URL(string: urlString) else {
            let sessionID = await sessionStore.resolveSessionID(for: sessionIdentity)
            await metrics.recordFailed()
            let response = proxyErrorResponse(
                status: 502,
                message: String(localized: "Bad Gateway: invalid upstream URL")
            )
            await eventLogger?.logRequestFailed(
                requestID: nil,
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
        let isMainAgentShaped = sessionIdentity.flavor != nil && apiHandler.isMainAgentRequest(body: request.body)
        let sessionID = await sessionStore.beginRequest(
            identity: sessionIdentity,
            id: requestID,
            body: request.body,
            headers: request.headers,
            model: model,
            promptDescriptor: promptDescriptor,
            isMainAgentShaped: isMainAgentShaped
        )
        let supportsTrackedSession = ProxySessionID.supportsTrackedSession(sessionID)
        let supportsKeepalive = apiFlavor.supportsKeepalive && supportsTrackedSession
        let loggedRequestID = await eventLogger?.logRequestStarted(
            session: sessionID,
            model: model,
            method: request.method,
            path: request.path,
            upstreamURL: urlString,
            streaming: wantsStreaming
        )
        await sessionStore.recordBytesSent(request.body.count)

        let errored: Bool
        if wantsStreaming {
            errored = await forwardStreaming(
                urlRequest: urlRequest,
                requestPath: request.path,
                requestBody: request.body,
                requestHeaders: request.headers,
                writer: request.writer,
                requestID: requestID,
                sessionStore: sessionStore,
                metrics: metrics,
                sessionID: sessionID,
                model: model,
                supportsTrackedSession: supportsTrackedSession,
                requestLog: requestLog,
                requestStartedAt: requestStartedAt,
                loggedRequestID: loggedRequestID
            )
        } else {
            errored = await forwardNonStreaming(
                urlRequest: urlRequest,
                requestPath: request.path,
                requestBody: request.body,
                requestHeaders: request.headers,
                writer: request.writer,
                requestID: requestID,
                sessionStore: sessionStore,
                metrics: metrics,
                sessionID: sessionID,
                model: model,
                supportsTrackedSession: supportsTrackedSession,
                requestLog: requestLog,
                requestStartedAt: requestStartedAt,
                loggedRequestID: loggedRequestID
            )
        }

        await writeStatusSnapshot(
            sessionStore: sessionStore,
            metrics: metrics
        )

        // Only Anthropic tracked sessions participate in lineage/keepalive.
        if !errored && supportsKeepalive {
            let lineageResult = await sessionStore.evaluateAndTrackLineage(
                path: request.path,
                body: request.body,
                headers: request.headers,
                model: model,
                for: sessionID,
                using: apiHandler
            )

            switch lineageResult {
            case .tracked:
                break
            case .diverged(let reason):
                await sessionStore.clearMainAgentFlag(requestID: requestID, sessionID: sessionID)
                let shortSessionID = ProxySessionID.shortDisplayID(for: sessionID)
                await eventLogger?.logKeepaliveDisabled(
                    session: sessionID,
                    reason: "lineage_diverged: \(reason)",
                    failureCount: 0
                )
                await MainActor.run {
                    NotificationService.shared.sendProxyKeepaliveDisabled(
                        sessionID: shortSessionID,
                        reason: reason
                    )
                }
            case .ignored, .pendingIdentification, .alreadyDisabled:
                if isMainAgentShaped {
                    await sessionStore.clearMainAgentFlag(requestID: requestID, sessionID: sessionID)
                }
            }
        }

        let currentSessionID = await sessionStore.currentSessionID(for: sessionID)
        await sessionStore.decrementInFlight(currentSessionID)
    }

    private func forwardStreaming(
        urlRequest: URLRequest,
        requestPath: String,
        requestBody: Data,
        requestHeaders: [(name: String, value: String)],
        writer: ResponseWriter,
        requestID: UUID,
        sessionStore: ProxySessionStore,
        metrics: ProxyMetricsStore,
        sessionID: String,
        model: String?,
        supportsTrackedSession: Bool,
        requestLog: ProxyEventLogger.LoggedRequest,
        requestStartedAt: Date,
        loggedRequestID: Int64?
    ) async -> Bool {
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
            streamingDelegate.onUploadComplete = {
                Task {
                    await sessionStore.markRequestWaiting(id: requestID)
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
                // Headers received — transition to receiving state.
                await sessionStore.markRequestReceiving(id: requestID)
                if supportsTrackedSession, (200..<300).contains(httpResponse.statusCode) {
                    await sessionStore.markAcceptedLineageRequestActive(
                        id: requestID,
                        path: requestPath,
                        body: requestBody,
                        headers: requestHeaders,
                        for: sessionID,
                        using: apiHandler
                    )
                }

                // Stream chunks through to the client.
                for try await chunk in chunks {
                    try Task.checkCancellation()
                    await sessionStore.markFirstDataReceived(id: requestID)
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
            await metrics.recordForwarded()
            let responseLog = ProxyEventLogger.LoggedResponse(
                statusCode: upstreamStatusCode,
                headers: capturedResponseHeaders,
                body: capturedResponseBody,
                source: "upstream",
                bodyBytes: capturedResponseBytes,
                bodyTruncated: capturedResponseBytes > capturedResponseBody.count
            )
            let tokenUsage = apiHandler.parseTokenUsage(from: capturedResponseBody, streaming: true)
            let currentSessionID = await sessionStore.currentSessionID(forRequest: requestID, fallback: sessionID)
            await metrics.recordTokenUsage(tokenUsage)
            await sessionStore.recordTokenUsage(
                tokenUsage,
                model: model,
                for: currentSessionID,
                apiFlavor: apiFlavor
            )
            let requestCost = ModelPricingTable.pricing(for: model).map { tokenUsage.cost(for: $0) }
            let isUpstreamError = upstreamStatusCode >= 400
            await sessionStore.markRequestDone(id: requestID, errored: isUpstreamError, tokenUsage: tokenUsage, estimatedCost: requestCost)
            let eventLogSessionID = await sessionStore.currentSessionID(for: sessionID)
            await eventLogger?.logRequestCompleted(
                requestID: loggedRequestID,
                session: eventLogSessionID,
                model: model,
                request: requestLog,
                response: responseLog,
                durationMs: ProxyHTTPUtils.elapsedMilliseconds(since: requestStartedAt),
                statusCode: upstreamStatusCode,
                tokenUsage: tokenUsage,
                errored: isUpstreamError
            )
            return isUpstreamError

        } catch is CancellationError {
            // Client disconnected — no error response needed.
            await sessionStore.markRequestDone(id: requestID, errored: true, tokenUsage: nil, estimatedCost: nil)
            ProxyLogger.log("Streaming request cancelled (client disconnect)")
            let currentSessionID = await sessionStore.currentSessionID(for: sessionID)
            await eventLogger?.logRequestFailed(
                requestID: loggedRequestID,
                session: currentSessionID,
                model: model,
                request: requestLog,
                response: nil,
                durationMs: ProxyHTTPUtils.elapsedMilliseconds(since: requestStartedAt),
                error: "client disconnected"
            )
            return true
        } catch {
            await sessionStore.markRequestDone(id: requestID, errored: true, tokenUsage: nil, estimatedCost: nil)
            await metrics.recordFailed()
            let response = proxyErrorResponse(
                status: 502,
                message: String(localized: "Bad Gateway: upstream error: \(error.localizedDescription)")
            )
            let currentSessionID = await sessionStore.currentSessionID(for: sessionID)
            await eventLogger?.logRequestFailed(
                requestID: loggedRequestID,
                session: currentSessionID,
                model: model,
                request: requestLog,
                response: response.loggedResponse,
                durationMs: ProxyHTTPUtils.elapsedMilliseconds(since: requestStartedAt),
                error: error.localizedDescription
            )
            writeErrorToClient(writer: writer, response: response)
            return true
        }
    }

    // MARK: - Non-streaming forwarding

    private func forwardNonStreaming(
        urlRequest: URLRequest,
        requestPath: String,
        requestBody: Data,
        requestHeaders: [(name: String, value: String)],
        writer: ResponseWriter,
        requestID: UUID,
        sessionStore: ProxySessionStore,
        metrics: ProxyMetricsStore,
        sessionID: String,
        model: String?,
        supportsTrackedSession: Bool,
        requestLog: ProxyEventLogger.LoggedRequest,
        requestStartedAt: Date,
        loggedRequestID: Int64?
    ) async -> Bool {
        // Use the shared non-streaming session for TCP/TLS connection reuse.
        // Per-task callbacks are routed through the multiplexing pool delegate.
        var errored = true
        let taskContext = NonStreamingPoolDelegate.TaskContext()
        taskContext.onUploadProgress = { totalBytesSent in
            Task {
                await sessionStore.updateRequestBytesSent(
                    id: requestID,
                    totalBytesSent: Int(totalBytesSent)
                )
            }
        }
        taskContext.onUploadComplete = {
            Task {
                await sessionStore.markRequestWaiting(id: requestID)
            }
        }

        let bodyData = urlRequest.httpBody ?? Data()
        var uploadRequest = urlRequest
        uploadRequest.httpBody = nil
        let dataTask = nonStreamingSession.uploadTask(with: uploadRequest, from: bodyData)
        nonStreamingPoolDelegate.register(taskIdentifier: dataTask.taskIdentifier, context: taskContext)

        do {
            dataTask.resume()

            try await withTaskCancellationHandler {
                // Await response headers — phase: .waiting -> .receiving
                let httpResponse = try await taskContext.awaitResponse()
                await sessionStore.markRequestReceiving(id: requestID)
                if supportsTrackedSession, (200..<300).contains(httpResponse.statusCode) {
                    await sessionStore.markAcceptedLineageRequestActive(
                        id: requestID,
                        path: requestPath,
                        body: requestBody,
                        headers: requestHeaders,
                        for: sessionID,
                        using: apiHandler
                    )
                }

                // Accumulate all response body chunks.
                var responseData = Data()
                for try await chunk in taskContext.chunkStream {
                    await sessionStore.markFirstDataReceived(id: requestID)
                    responseData.append(chunk)
                    await sessionStore.updateRequestBytes(id: requestID, additionalBytes: chunk.count)
                }

                // Write complete response to client.
                var responseHeaders = buildResponseHeaders(from: httpResponse, streaming: false)
                responseHeaders.append((name: "Content-Length", value: "\(responseData.count)"))

                writer.writeHead(status: httpResponse.statusCode, headers: responseHeaders)
                if !responseData.isEmpty {
                    writer.writeChunk(responseData)
                }
                writer.end()
                await metrics.recordForwarded()

                let tokenUsage = apiHandler.parseTokenUsage(from: responseData, streaming: false)
                let currentSessionID = await sessionStore.currentSessionID(forRequest: requestID, fallback: sessionID)
                await metrics.recordTokenUsage(tokenUsage)
                await sessionStore.recordTokenUsage(
                    tokenUsage,
                    model: model,
                    for: currentSessionID,
                    apiFlavor: apiFlavor
                )
                let requestCost = ModelPricingTable.pricing(for: model).map { tokenUsage.cost(for: $0) }
                let isUpstreamError = httpResponse.statusCode >= 400
                errored = isUpstreamError
                await sessionStore.markRequestDone(id: requestID, errored: isUpstreamError, tokenUsage: tokenUsage, estimatedCost: requestCost)
                let eventLogSessionID = await sessionStore.currentSessionID(for: sessionID)
                let responseLog = ProxyEventLogger.LoggedResponse(
                    statusCode: httpResponse.statusCode,
                    headers: ProxyHTTPUtils.allHeaders(from: httpResponse),
                    body: responseData,
                    source: "upstream"
                )
                await eventLogger?.logRequestCompleted(
                    requestID: loggedRequestID,
                    session: eventLogSessionID,
                    model: model,
                    request: requestLog,
                    response: responseLog,
                    durationMs: ProxyHTTPUtils.elapsedMilliseconds(since: requestStartedAt),
                    statusCode: httpResponse.statusCode,
                    tokenUsage: tokenUsage,
                    errored: isUpstreamError
                )
            } onCancel: {
                dataTask.cancel()
            }

        } catch is CancellationError {
            await sessionStore.markRequestDone(id: requestID, errored: true, tokenUsage: nil, estimatedCost: nil)
            ProxyLogger.log("Non-streaming request cancelled (client disconnect)")
            let currentSessionID = await sessionStore.currentSessionID(for: sessionID)
            await eventLogger?.logRequestFailed(
                requestID: loggedRequestID,
                session: currentSessionID,
                model: model,
                request: requestLog,
                response: nil,
                durationMs: ProxyHTTPUtils.elapsedMilliseconds(since: requestStartedAt),
                error: "client disconnected"
            )
        } catch {
            await sessionStore.markRequestDone(id: requestID, errored: true, tokenUsage: nil, estimatedCost: nil)
            await metrics.recordFailed()
            let response = proxyErrorResponse(
                status: 502,
                message: String(localized: "Bad Gateway: upstream error: \(error.localizedDescription)")
            )
            let currentSessionID = await sessionStore.currentSessionID(for: sessionID)
            await eventLogger?.logRequestFailed(
                requestID: loggedRequestID,
                session: currentSessionID,
                model: model,
                request: requestLog,
                response: response.loggedResponse,
                durationMs: ProxyHTTPUtils.elapsedMilliseconds(since: requestStartedAt),
                error: error.localizedDescription
            )
            writeErrorToClient(writer: writer, response: response)
        }

        nonStreamingPoolDelegate.unregister(taskIdentifier: dataTask.taskIdentifier)
        return errored
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

    private func proxyErrorResponse(
        status: Int,
        message: String
    ) -> (headers: [(name: String, value: String)], body: Data, loggedResponse: ProxyEventLogger.LoggedResponse) {
        let body = apiHandler.proxyErrorBody(message: message)
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
        metrics: ProxyMetricsStore
    ) async {
        guard let logger = eventLogger else { return }
        let activeSessions = await sessionStore.activeSessions().count
        let snapshot = await metrics.snapshot()
        await logger.writeStatusSnapshot(
            enabled: true,
            port: proxyPort,
            activeSessions: activeSessions,
            activeKeepalives: 0,
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

    /// Called once when the upload finishes (totalBytesSent == totalBytesExpectedToSend).
    var onUploadComplete: (@Sendable () -> Void)?

    private let chunkContinuation: AsyncThrowingStream<Data, Error>.Continuation
    let chunkStream: AsyncThrowingStream<Data, Error>

    private let responseContinuation: AsyncStream<Result<HTTPURLResponse, Error>>.Continuation
    let responseStream: AsyncStream<Result<HTTPURLResponse, Error>>

    override init() {
        var chunkCont: AsyncThrowingStream<Data, Error>.Continuation!
        self.chunkStream = AsyncThrowingStream<Data, Error> { chunkCont = $0 }
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
        if totalBytesSent >= totalBytesExpectedToSend {
            onUploadComplete?()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            // If response was never delivered (connection failed before headers),
            // send the error through the response stream.
            responseContinuation.yield(.failure(error))
            responseContinuation.finish()
            // Also propagate through chunk stream so mid-body failures are caught.
            chunkContinuation.finish(throwing: error)
        } else {
            chunkContinuation.finish()
        }
    }
}

// MARK: - NonStreamingPoolDelegate

/// Multiplexing delegate for non-streaming requests. Routes URLSession callbacks
/// by task identifier so a single long-lived session can serve all non-streaming
/// requests, preserving TCP/TLS and HTTP/2 connection reuse.
private final class NonStreamingPoolDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {

    /// Per-task async streams and callbacks, mirroring `StreamingDelegate` but
    /// keyed by `taskIdentifier` for multiplexed use on a shared session.
    final class TaskContext: @unchecked Sendable {
        var onUploadProgress: (@Sendable (_ totalBytesSent: Int64) -> Void)?
        var onUploadComplete: (@Sendable () -> Void)?

        private let chunkContinuation: AsyncThrowingStream<Data, Error>.Continuation
        let chunkStream: AsyncThrowingStream<Data, Error>

        private let responseContinuation: AsyncStream<Result<HTTPURLResponse, Error>>.Continuation
        private let responseStream: AsyncStream<Result<HTTPURLResponse, Error>>

        init() {
            var chunkCont: AsyncThrowingStream<Data, Error>.Continuation!
            self.chunkStream = AsyncThrowingStream<Data, Error> { chunkCont = $0 }
            self.chunkContinuation = chunkCont

            var respCont: AsyncStream<Result<HTTPURLResponse, Error>>.Continuation!
            self.responseStream = AsyncStream<Result<HTTPURLResponse, Error>>(bufferingPolicy: .bufferingNewest(1)) { respCont = $0 }
            self.responseContinuation = respCont
        }

        func awaitResponse() async throws -> HTTPURLResponse {
            for await result in responseStream {
                switch result {
                case .success(let response): return response
                case .failure(let error): throw error
                }
            }
            throw ProxyStreamingError.noResponse
        }

        fileprivate func yieldResponse(_ response: HTTPURLResponse) {
            responseContinuation.yield(.success(response))
            responseContinuation.finish()
        }

        fileprivate func yieldResponseError(_ error: Error) {
            responseContinuation.yield(.failure(error))
            responseContinuation.finish()
        }

        fileprivate func yieldChunk(_ data: Data) {
            chunkContinuation.yield(data)
        }

        fileprivate func finishChunks(error: Error? = nil) {
            if let error {
                chunkContinuation.finish(throwing: error)
            } else {
                chunkContinuation.finish()
            }
        }
    }

    private let lock = NSLock()
    private var contexts: [Int: TaskContext] = [:]

    func register(taskIdentifier: Int, context: TaskContext) {
        lock.withLock { contexts[taskIdentifier] = context }
    }

    func unregister(taskIdentifier: Int) {
        lock.withLock { _ = contexts.removeValue(forKey: taskIdentifier) }
    }

    private func context(for task: URLSessionTask) -> TaskContext? {
        lock.withLock { contexts[task.taskIdentifier] }
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        if let ctx = context(for: dataTask), let httpResponse = response as? HTTPURLResponse {
            ctx.yieldResponse(httpResponse)
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        context(for: dataTask)?.yieldChunk(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        guard let ctx = context(for: task) else { return }
        ctx.onUploadProgress?(totalBytesSent)
        if totalBytesSent >= totalBytesExpectedToSend {
            ctx.onUploadComplete?()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let ctx = context(for: task) else { return }
        if let error {
            ctx.yieldResponseError(error)
            ctx.finishChunks(error: error)
        } else {
            ctx.finishChunks()
        }
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
