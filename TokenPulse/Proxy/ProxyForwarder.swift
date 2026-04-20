import Foundation

/// Forwards incoming proxy requests to the configured upstream API and
/// streams responses back to the local client. Attaches every
/// fully-parsed request to the content tree before calling upstream;
/// finalization marks the request as succeeded or errored on completion.
final class ProxyForwarder: Sendable {
    private static let maxLoggedStreamingResponseBytes = 4 * 1024 * 1024
    /// Size of the tail ring-buffer used for terminal-signal parsing.
    /// Anthropic's final `message_delta` + `message_stop` events and OpenAI's
    /// `response.completed` event are all well under this limit, so keeping
    /// the last 64 KB reliably preserves the terminal signal regardless of
    /// how big the response body grew.
    private static let maxParseTailBytes = 64 * 1024

    let upstreamBaseURL: String
    private let apiFlavor: ProxyAPIFlavor
    private let apiHandler: any ProxyAPIHandler
    private let eventLogger: ProxyEventLogger?
    private let proxyPort: Int
    private let upstreamHTTPSProxySetting: UpstreamHTTPSProxySetting
    /// Shared session for non-streaming requests — preserves TCP/TLS connection reuse.
    private let nonStreamingSession: URLSession
    private let nonStreamingPoolDelegate: NonStreamingPoolDelegate

    init(
        upstreamBaseURL: String,
        apiFlavor: ProxyAPIFlavor,
        apiHandler: any ProxyAPIHandler,
        upstreamHTTPSProxySetting: UpstreamHTTPSProxySetting = .disabled,
        eventLogger: ProxyEventLogger? = nil,
        proxyPort: Int = 0
    ) {
        self.upstreamBaseURL = upstreamBaseURL
        self.apiFlavor = apiFlavor
        self.apiHandler = apiHandler
        self.upstreamHTTPSProxySetting = upstreamHTTPSProxySetting
        self.eventLogger = eventLogger
        self.proxyPort = proxyPort

        let poolDelegate = NonStreamingPoolDelegate()
        self.nonStreamingPoolDelegate = poolDelegate
        let config = UpstreamNetworking.makeSessionConfiguration(
            proxyConfiguration: upstreamHTTPSProxySetting.proxyConfiguration,
            timeoutIntervalForRequest: 300,
            timeoutIntervalForResource: 600
        )
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
        await forwardRequest(
            request: request,
            sessionIdentity: sessionIdentity,
            model: model,
            sessionStore: sessionStore,
            metrics: metrics
        )
    }

    // MARK: - Streaming forwarding

    private func forwardRequest(
        request: ProxyHTTPRequest,
        sessionIdentity: ProxySessionIdentity,
        model: String?,
        sessionStore: ProxySessionStore,
        metrics: ProxyMetricsStore
    ) async {
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

        if case .invalid(let message) = upstreamHTTPSProxySetting {
            let sessionID = await sessionStore.resolveSessionID(for: sessionIdentity)
            await metrics.recordFailed()
            let response = proxyErrorResponse(
                status: 502,
                message: String(localized: "Bad Gateway: invalid upstream HTTPS proxy setting: \(message)")
            )
            await eventLogger?.logRequestFailed(
                requestID: nil,
                session: sessionID,
                model: model,
                request: requestLog,
                response: response.loggedResponse,
                durationMs: ProxyHTTPUtils.elapsedMilliseconds(since: requestStartedAt),
                error: "invalid upstream HTTPS proxy setting"
            )
            writeErrorToClient(writer: request.writer, response: response)
            return
        }

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
        let sessionID = await sessionStore.beginRequest(
            identity: sessionIdentity,
            id: requestID,
            model: model
        )
        let fingerprint = apiHandler.lineageFingerprint(from: request.body)
        let normalizedMessages = apiHandler.normalizedLineageMessages(from: request.body)
        let previousResponseID = apiHandler.previousResponseID(from: request.body)
        let loggedRequestID = await eventLogger?.logRequestStarted(
            session: sessionID,
            model: model,
            method: request.method,
            path: request.path,
            upstreamURL: urlString,
            streaming: wantsStreaming
        )
        await sessionStore.recordBytesSent(request.body.count)

        // Attach to the content tree as soon as the request body has been
        // parsed — every request that enters the proxy in its full form is
        // represented in the tree, regardless of whether upstream later
        // accepts or errors. The request starts in an in-flight state and
        // transitions to succeeded / errored via `finishTrackedRequest`.
        if let fingerprint {
            await sessionStore.attachToTree(
                requestID: requestID,
                sessionID: sessionID,
                fingerprint: fingerprint,
                messages: normalizedMessages,
                previousResponseID: previousResponseID
            )
        }

        if wantsStreaming {
            _ = await forwardStreaming(
                urlRequest: urlRequest,
                writer: request.writer,
                requestID: requestID,
                sessionStore: sessionStore,
                metrics: metrics,
                sessionID: sessionID,
                model: model,
                fingerprint: fingerprint,
                normalizedMessages: normalizedMessages,
                previousResponseID: previousResponseID,
                requestLog: requestLog,
                requestStartedAt: requestStartedAt,
                loggedRequestID: loggedRequestID
            )
        } else {
            _ = await forwardNonStreaming(
                urlRequest: urlRequest,
                writer: request.writer,
                requestID: requestID,
                sessionStore: sessionStore,
                metrics: metrics,
                sessionID: sessionID,
                model: model,
                fingerprint: fingerprint,
                normalizedMessages: normalizedMessages,
                previousResponseID: previousResponseID,
                requestLog: requestLog,
                requestStartedAt: requestStartedAt,
                loggedRequestID: loggedRequestID
            )
        }

        await writeStatusSnapshot(
            sessionStore: sessionStore,
            metrics: metrics
        )

        await sessionStore.decrementInFlight(sessionID)
    }

    private func forwardStreaming(
        urlRequest: URLRequest,
        writer: ResponseWriter,
        requestID: UUID,
        sessionStore: ProxySessionStore,
        metrics: ProxyMetricsStore,
        sessionID: String,
        model: String?,
        fingerprint: LineageFingerprint?,
        normalizedMessages: [ContentTree.NormalizedMessage],
        previousResponseID: String?,
        requestLog: ProxyEventLogger.LoggedRequest,
        requestStartedAt: Date,
        loggedRequestID: Int64?
    ) async -> Bool {
        var upstreamStatusCode = 0
        var capturedResponseHeaders: [(name: String, value: String)] = []
        let shouldCaptureResponseBody = eventLogger != nil
        var capturedResponseBody = Data()
        var capturedRawResponseBody = Data()
        var capturedResponseBytes = 0
        // Tail ring-buffer for terminal-signal parsing. Accumulates every
        // chunk and trims back to `maxParseTailBytes` after each append so
        // we always have the end of the stream even when the body exceeds
        // `maxLoggedStreamingResponseBytes`.
        var parseTailBuffer = Data()

        do {
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
            let delegateConfig = UpstreamNetworking.makeSessionConfiguration(
                proxyConfiguration: upstreamHTTPSProxySetting.proxyConfiguration,
                timeoutIntervalForRequest: 300,
                timeoutIntervalForResource: 600
            )
            let delegateSession = URLSession(configuration: delegateConfig,
                                              delegate: streamingDelegate,
                                              delegateQueue: nil)
            defer { delegateSession.invalidateAndCancel() }

            let bodyData = urlRequest.httpBody ?? Data()
            var uploadRequest = urlRequest
            uploadRequest.httpBody = nil
            let dataTask = delegateSession.uploadTask(with: uploadRequest, from: bodyData)
            let chunks = streamingDelegate.chunkStream

            dataTask.resume()

            try await withTaskCancellationHandler {
                let httpResponse = try await streamingDelegate.awaitResponse()
                upstreamStatusCode = httpResponse.statusCode
                capturedResponseHeaders = ProxyHTTPUtils.allHeaders(from: httpResponse)

                var responseHeaders = buildResponseHeaders(from: httpResponse, streaming: true)
                responseHeaders.removeAll(where: { $0.name.lowercased() == "content-length" })
                if !responseHeaders.contains(where: { $0.name.lowercased() == "transfer-encoding" }) {
                    responseHeaders.append((name: "Transfer-Encoding", value: "chunked"))
                }

                writer.writeHead(status: httpResponse.statusCode, headers: responseHeaders)
                await sessionStore.markRequestReceiving(id: requestID)

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
                        capturedRawResponseBody.append(chunk)
                    }
                    // Tail ring buffer for terminal-signal parsing. Appended
                    // unconditionally and trimmed so the tail never exceeds
                    // ~2x `maxParseTailBytes` between appends.
                    Self.appendToTail(
                        chunk,
                        to: &parseTailBuffer,
                        capBytes: Self.maxParseTailBytes
                    )
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
            // Parse head + tail separately and merge.
            //  - Head (`capturedResponseBody`, up to 4 MB from the start) carries
            //    Anthropic's `message_start` — source of input/cache tokens.
            //  - Tail (`parseTailBuffer`, last 64 KB) carries Anthropic's
            //    `message_delta` / OpenAI's `response.completed` — source of the
            //    terminal signal + output tokens.
            let headUsage = apiHandler.parseTokenUsage(from: capturedResponseBody, streaming: true)
            let tailUsage = apiHandler.parseTokenUsage(from: parseTailBuffer, streaming: true)
            let tokenUsage = Self.mergeUsage(head: headUsage, tail: tailUsage)
            let responseID = apiHandler.extractResponseID(from: capturedResponseBody, streaming: true)
                ?? apiHandler.extractResponseID(from: parseTailBuffer, streaming: true)
            await metrics.recordTokenUsage(tokenUsage)
            await sessionStore.recordTokenUsage(
                tokenUsage,
                model: model,
                for: sessionID,
                apiFlavor: apiFlavor
            )
            let requestCost = ModelPricingTable.pricing(for: model).map { tokenUsage.cost(for: $0) }
            let isUpstreamError = upstreamStatusCode >= 400
            let isIncomplete = !isUpstreamError && !apiHandler.isResponseComplete(tokenUsage)
            let errored = isUpstreamError || isIncomplete
            await sessionStore.finishTrackedRequest(
                requestID: requestID,
                succeeded: !errored,
                tokenUsage: tokenUsage,
                responseID: responseID
            )
            let lineageContext = await sessionStore.lineageContext(for: requestID)
            await sessionStore.markRequestDone(id: requestID, errored: errored, tokenUsage: tokenUsage, estimatedCost: requestCost)
            let errorString: String?
            if isIncomplete {
                errorString = "incomplete response (no terminal signal)"
            } else {
                errorString = nil
            }
            if let errorString {
                await eventLogger?.logRequestFailed(
                    requestID: loggedRequestID,
                    session: sessionID,
                    model: model,
                    request: requestLog,
                    response: responseLog,
                    rawResponseBody: capturedRawResponseBody,
                    durationMs: ProxyHTTPUtils.elapsedMilliseconds(since: requestStartedAt),
                    error: errorString,
                    lineage: lineageContext,
                    responseID: responseID
                )
            } else {
                await eventLogger?.logRequestCompleted(
                    requestID: loggedRequestID,
                    session: sessionID,
                    model: model,
                    request: requestLog,
                    response: responseLog,
                    rawResponseBody: capturedRawResponseBody,
                    durationMs: ProxyHTTPUtils.elapsedMilliseconds(since: requestStartedAt),
                    statusCode: upstreamStatusCode,
                    tokenUsage: tokenUsage,
                    errored: isUpstreamError,
                    lineage: lineageContext,
                    responseID: responseID
                )
            }
            return errored

        } catch is CancellationError {
            await sessionStore.finishTrackedRequest(
                requestID: requestID,
                succeeded: false,
                tokenUsage: nil,
                responseID: nil
            )
            let lineageContext = await sessionStore.lineageContext(for: requestID)
            await sessionStore.markRequestDone(id: requestID, errored: true, tokenUsage: nil, estimatedCost: nil)
            ProxyLogger.log("Streaming request cancelled (client disconnect)")
            await eventLogger?.logRequestFailed(
                requestID: loggedRequestID,
                session: sessionID,
                model: model,
                request: requestLog,
                response: nil,
                rawResponseBody: nil,
                durationMs: ProxyHTTPUtils.elapsedMilliseconds(since: requestStartedAt),
                error: "client disconnected",
                lineage: lineageContext
            )
            return true
        } catch {
            await sessionStore.finishTrackedRequest(
                requestID: requestID,
                succeeded: false,
                tokenUsage: nil,
                responseID: nil
            )
            let lineageContext = await sessionStore.lineageContext(for: requestID)
            await sessionStore.markRequestDone(id: requestID, errored: true, tokenUsage: nil, estimatedCost: nil)
            await metrics.recordFailed()
            let observedUpstreamResponse = upstreamStatusCode > 0 || !capturedResponseHeaders.isEmpty || capturedResponseBytes > 0
            if observedUpstreamResponse {
                let responseLog = ProxyEventLogger.LoggedResponse(
                    statusCode: upstreamStatusCode,
                    headers: capturedResponseHeaders,
                    body: capturedResponseBody,
                    source: "upstream",
                    bodyBytes: capturedResponseBytes,
                    bodyTruncated: capturedResponseBytes > capturedResponseBody.count
                )
                await eventLogger?.logRequestFailed(
                    requestID: loggedRequestID,
                    session: sessionID,
                    model: model,
                    request: requestLog,
                    response: responseLog,
                    rawResponseBody: capturedRawResponseBody,
                    durationMs: ProxyHTTPUtils.elapsedMilliseconds(since: requestStartedAt),
                    error: error.localizedDescription,
                    lineage: lineageContext
                )
                writer.end()
            } else {
                let response = proxyErrorResponse(
                    status: 502,
                    message: String(localized: "Bad Gateway: upstream error: \(error.localizedDescription)")
                )
                await eventLogger?.logRequestFailed(
                    requestID: loggedRequestID,
                    session: sessionID,
                    model: model,
                    request: requestLog,
                    response: response.loggedResponse,
                    rawResponseBody: response.loggedResponse.body,
                    durationMs: ProxyHTTPUtils.elapsedMilliseconds(since: requestStartedAt),
                    error: error.localizedDescription,
                    lineage: lineageContext
                )
                writeErrorToClient(writer: writer, response: response)
            }
            return true
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
        fingerprint: LineageFingerprint?,
        normalizedMessages: [ContentTree.NormalizedMessage],
        previousResponseID: String?,
        requestLog: ProxyEventLogger.LoggedRequest,
        requestStartedAt: Date,
        loggedRequestID: Int64?
    ) async -> Bool {
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
                let httpResponse = try await taskContext.awaitResponse()
                await sessionStore.markRequestReceiving(id: requestID)

                var responseData = Data()
                for try await chunk in taskContext.chunkStream {
                    await sessionStore.markFirstDataReceived(id: requestID)
                    responseData.append(chunk)
                    await sessionStore.updateRequestBytes(id: requestID, additionalBytes: chunk.count)
                }

                var responseHeaders = buildResponseHeaders(from: httpResponse, streaming: false)
                responseHeaders.append((name: "Content-Length", value: "\(responseData.count)"))

                writer.writeHead(status: httpResponse.statusCode, headers: responseHeaders)
                if !responseData.isEmpty {
                    writer.writeChunk(responseData)
                }
                writer.end()
                await metrics.recordForwarded()

                let tokenUsage = apiHandler.parseTokenUsage(from: responseData, streaming: false)
                let responseID = apiHandler.extractResponseID(from: responseData, streaming: false)
                await metrics.recordTokenUsage(tokenUsage)
                await sessionStore.recordTokenUsage(
                    tokenUsage,
                    model: model,
                    for: sessionID,
                    apiFlavor: apiFlavor
                )
                let requestCost = ModelPricingTable.pricing(for: model).map { tokenUsage.cost(for: $0) }
                let isUpstreamError = httpResponse.statusCode >= 400
                let isIncomplete = !isUpstreamError && !apiHandler.isResponseComplete(tokenUsage)
                let requestErrored = isUpstreamError || isIncomplete
                errored = requestErrored
                await sessionStore.finishTrackedRequest(
                    requestID: requestID,
                    succeeded: !requestErrored,
                    tokenUsage: tokenUsage,
                    responseID: responseID
                )
                let lineageContext = await sessionStore.lineageContext(for: requestID)
                await sessionStore.markRequestDone(id: requestID, errored: requestErrored, tokenUsage: tokenUsage, estimatedCost: requestCost)
                let responseLog = ProxyEventLogger.LoggedResponse(
                    statusCode: httpResponse.statusCode,
                    headers: ProxyHTTPUtils.allHeaders(from: httpResponse),
                    body: responseData,
                    source: "upstream"
                )
                if isIncomplete {
                    await eventLogger?.logRequestFailed(
                        requestID: loggedRequestID,
                        session: sessionID,
                        model: model,
                        request: requestLog,
                        response: responseLog,
                        rawResponseBody: responseData,
                        durationMs: ProxyHTTPUtils.elapsedMilliseconds(since: requestStartedAt),
                        error: "incomplete response (no terminal signal)",
                        lineage: lineageContext,
                        responseID: responseID
                    )
                } else {
                    await eventLogger?.logRequestCompleted(
                        requestID: loggedRequestID,
                        session: sessionID,
                        model: model,
                        request: requestLog,
                        response: responseLog,
                        rawResponseBody: responseData,
                        durationMs: ProxyHTTPUtils.elapsedMilliseconds(since: requestStartedAt),
                        statusCode: httpResponse.statusCode,
                        tokenUsage: tokenUsage,
                        errored: isUpstreamError,
                        lineage: lineageContext,
                        responseID: responseID
                    )
                }
            } onCancel: {
                dataTask.cancel()
            }

        } catch is CancellationError {
            await sessionStore.finishTrackedRequest(
                requestID: requestID,
                succeeded: false,
                tokenUsage: nil,
                responseID: nil
            )
            let lineageContext = await sessionStore.lineageContext(for: requestID)
            await sessionStore.markRequestDone(id: requestID, errored: true, tokenUsage: nil, estimatedCost: nil)
            ProxyLogger.log("Non-streaming request cancelled (client disconnect)")
            await eventLogger?.logRequestFailed(
                requestID: loggedRequestID,
                session: sessionID,
                model: model,
                request: requestLog,
                response: nil,
                rawResponseBody: nil,
                durationMs: ProxyHTTPUtils.elapsedMilliseconds(since: requestStartedAt),
                error: "client disconnected",
                lineage: lineageContext
            )
        } catch {
            await sessionStore.finishTrackedRequest(
                requestID: requestID,
                succeeded: false,
                tokenUsage: nil,
                responseID: nil
            )
            let lineageContext = await sessionStore.lineageContext(for: requestID)
            await sessionStore.markRequestDone(id: requestID, errored: true, tokenUsage: nil, estimatedCost: nil)
            await metrics.recordFailed()
            let response = proxyErrorResponse(
                status: 502,
                message: String(localized: "Bad Gateway: upstream error: \(error.localizedDescription)")
            )
            await eventLogger?.logRequestFailed(
                requestID: loggedRequestID,
                session: sessionID,
                model: model,
                request: requestLog,
                response: response.loggedResponse,
                durationMs: ProxyHTTPUtils.elapsedMilliseconds(since: requestStartedAt),
                error: error.localizedDescription,
                lineage: lineageContext
            )
            writeErrorToClient(writer: writer, response: response)
        }

        nonStreamingPoolDelegate.unregister(taskIdentifier: dataTask.taskIdentifier)
        return errored
    }

    // MARK: - Helpers

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

    /// Append `chunk` to a tail ring buffer, trimming back to `capBytes` when
    /// the buffer would exceed 2× the cap. The 2× slack avoids reallocating on
    /// every chunk for a long stream.
    private static func appendToTail(_ chunk: Data, to tail: inout Data, capBytes: Int) {
        tail.append(chunk)
        if tail.count > capBytes * 2 {
            tail = tail.suffix(capBytes)
        }
    }

    /// Merge usage parsed from the head (start-of-stream `message_start`) and
    /// the tail (end-of-stream `message_delta` / `response.completed`) so both
    /// input- and output-side counts survive even when the body exceeds the
    /// logging capture cap.
    private static func mergeUsage(head: TokenUsage, tail: TokenUsage) -> TokenUsage {
        TokenUsage(
            inputTokens: head.inputTokens ?? tail.inputTokens,
            outputTokens: tail.outputTokens ?? head.outputTokens,
            cacheReadInputTokens: head.cacheReadInputTokens ?? tail.cacheReadInputTokens,
            cacheCreationInputTokens: head.cacheCreationInputTokens ?? tail.cacheCreationInputTokens,
            inputTokensIncludeCacheReads: head.inputTokensIncludeCacheReads || tail.inputTokensIncludeCacheReads,
            stopReason: tail.stopReason ?? head.stopReason
        )
    }

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
            metrics: snapshot
        )
    }
}

// MARK: - StreamingDelegate

private final class StreamingDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {

    var onUploadProgress: (@Sendable (_ totalBytesSent: Int64) -> Void)?
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
            responseContinuation.yield(.failure(error))
            responseContinuation.finish()
            chunkContinuation.finish(throwing: error)
        } else {
            chunkContinuation.finish()
        }
    }
}

// MARK: - NonStreamingPoolDelegate

private final class NonStreamingPoolDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {

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
