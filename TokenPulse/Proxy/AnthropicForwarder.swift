import Foundation

/// Forwards incoming proxy requests to the configured upstream Anthropic-compatible
/// API and streams responses back to the local client.
///
/// This type is `Sendable` — it holds only immutable config and a `Sendable` URLSession.
final class AnthropicForwarder: Sendable {

    let upstreamBaseURL: String
    /// Shared session used for non-streaming requests only.
    private let session: URLSession

    init(upstreamBaseURL: String) {
        self.upstreamBaseURL = upstreamBaseURL

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300  // Long timeout for streaming
        config.timeoutIntervalForResource = 600
        self.session = URLSession(configuration: config)
    }

    /// Forward a proxy request upstream and write the response back through the writer.
    func forward(
        request: ProxyHTTPRequest,
        sessionStore: ProxySessionStore,
        metrics: ProxyMetricsStore
    ) async {
        // 1. Extract session ID and update session store.
        let sessionID = request.headerValue(for: "X-Claude-Code-Session-Id") ?? "unknown"
        await sessionStore.touch(sessionID)
        await sessionStore.incrementInFlight(sessionID)

        defer {
            Task {
                await sessionStore.decrementInFlight(sessionID)
            }
        }

        // 2. Build upstream URL.
        let urlString = upstreamBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            + request.path
        guard let url = URL(string: urlString) else {
            await metrics.recordFailed()
            sendErrorToClient(writer: request.writer, status: 502,
                              message: String(localized: "Bad Gateway: invalid upstream URL"))
            return
        }

        // 3. Build upstream URLRequest.
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = request.body

        // Copy all incoming headers.
        for header in request.headers {
            let lowered = header.name.lowercased()
            // Skip hop-by-hop headers that URLSession manages.
            if lowered == "host" || lowered == "content-length" || lowered == "transfer-encoding" {
                continue
            }
            urlRequest.setValue(header.value, forHTTPHeaderField: header.name)
        }

        // 4. Determine if the client wants streaming.
        let wantsStreaming = ProxyRequestBody.isStreaming(from: request.body)

        if wantsStreaming {
            await forwardStreaming(urlRequest: urlRequest, writer: request.writer, metrics: metrics)
        } else {
            await forwardNonStreaming(urlRequest: urlRequest, writer: request.writer, metrics: metrics)
        }
    }

    // MARK: - Streaming forwarding

    private func forwardStreaming(
        urlRequest: URLRequest,
        writer: ResponseWriter,
        metrics: ProxyMetricsStore
    ) async {
        do {
            // Create a per-request streaming delegate and session so we receive
            // natural TCP-segment-sized chunks instead of byte-by-byte iteration.
            let streamingDelegate = StreamingDelegate()
            let delegateConfig = URLSessionConfiguration.default
            delegateConfig.timeoutIntervalForRequest = 300
            delegateConfig.timeoutIntervalForResource = 600
            let delegateSession = URLSession(configuration: delegateConfig,
                                              delegate: streamingDelegate,
                                              delegateQueue: nil)
            defer { delegateSession.invalidateAndCancel() }

            let dataTask = delegateSession.dataTask(with: urlRequest)
            let chunks = streamingDelegate.chunkStream

            dataTask.resume()

            // Wrap the entire streaming operation — including header wait — in a
            // cancellation handler so the upstream task is cancelled if the client
            // disconnects at any point (during header wait OR chunk streaming).
            try await withTaskCancellationHandler {
                // Await the HTTP response headers.
                let httpResponse = try await streamingDelegate.awaitResponse()

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

                // Stream chunks through to the client.
                for await chunk in chunks {
                    try Task.checkCancellation()
                    writer.writeChunk(chunk)
                }
            } onCancel: {
                dataTask.cancel()
            }

            writer.end()
            await metrics.recordForwarded()

        } catch is CancellationError {
            // Client disconnected — no error response needed.
            ProxyLogger.log("Streaming request cancelled (client disconnect)")
        } catch {
            await metrics.recordFailed()
            sendErrorToClient(writer: writer, status: 502,
                              message: String(localized: "Bad Gateway: upstream error: \(error.localizedDescription)"))
        }
    }

    // MARK: - Non-streaming forwarding

    private func forwardNonStreaming(
        urlRequest: URLRequest,
        writer: ResponseWriter,
        metrics: ProxyMetricsStore
    ) async {
        do {
            let (data, response) = try await session.data(for: urlRequest)

            guard let httpResponse = response as? HTTPURLResponse else {
                await metrics.recordFailed()
                sendErrorToClient(writer: writer, status: 502,
                                  message: String(localized: "Bad Gateway: non-HTTP response from upstream"))
                return
            }

            var responseHeaders = buildResponseHeaders(from: httpResponse, streaming: false)
            responseHeaders.append((name: "Content-Length", value: "\(data.count)"))

            writer.writeHead(status: httpResponse.statusCode, headers: responseHeaders)
            if !data.isEmpty {
                writer.writeChunk(data)
            }
            writer.end()
            await metrics.recordForwarded()

        } catch {
            await metrics.recordFailed()
            sendErrorToClient(writer: writer, status: 502,
                              message: String(localized: "Bad Gateway: upstream error: \(error.localizedDescription)"))
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

    /// Send an error response to the client.
    private func sendErrorToClient(writer: ResponseWriter, status: Int, message: String) {
        let body = message.data(using: .utf8) ?? Data()
        writer.writeHead(status: status, headers: [
            (name: "Content-Type", value: "text/plain; charset=utf-8"),
            (name: "Content-Length", value: "\(body.count)"),
            (name: "Connection", value: "close"),
        ])
        writer.writeChunk(body)
        writer.end()
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
