import Foundation
import Network

// MARK: - Request handler type

/// The handler callback invoked for each valid parsed HTTP request.
/// The handler is responsible for writing the response via `ProxyHTTPRequest.writer`.
typealias ProxyRequestHandler = @Sendable (ProxyHTTPRequest) async -> Void

// MARK: - ProxyHTTPServer

/// A minimal HTTP/1.1 server built on Network.framework.
/// Listens on 127.0.0.1 (IPv4 localhost only), accepts connections,
/// parses HTTP requests, and routes them through a handler closure.
final class ProxyHTTPServer: Sendable {

    private let listener: NWListener
    private let queue: DispatchQueue
    private let handler: ProxyRequestHandler
    private let onReady: (@Sendable (UInt16) -> Void)?
    private let onFailure: (@Sendable (String) -> Void)?
    private let startupLock = NSLock()
    private let startupResolved = LockedBox(false)

    /// Lock-protected mutable tracking state for active connections and tasks.
    private let trackingLock = NSLock()
    private let _connectionMap = LockedBox<[ObjectIdentifier: NWConnection]>()
    private let _activeTasks = LockedBox<[ObjectIdentifier: CancellableTask]>()

    /// Maximum allowed Content-Length (50 MB).
    private static let maxContentLength = 50_000_000

    /// Maximum accumulated header bytes before rejecting a request.
    private static let maxHeaderSize = 65_536

    /// Create a server that will listen on the given port.
    /// - Parameters:
    ///   - port: TCP port to bind on 127.0.0.1.
    ///   - handler: Async closure invoked for each parsed request.
    /// - Throws: If the NWListener cannot be created.
    init(
        port: UInt16,
        handler: @escaping ProxyRequestHandler,
        onReady: (@Sendable (UInt16) -> Void)? = nil,
        onFailure: (@Sendable (String) -> Void)? = nil
    ) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw ProxyServerError.invalidPort
        }

        let params = NWParameters.tcp
        // Bind to IPv4 loopback only.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)

        self.listener = try NWListener(using: params)
        self.queue = DispatchQueue(label: "com.tokenpulse.proxy.server", qos: .userInitiated)
        self.handler = handler
        self.onReady = onReady
        self.onFailure = onFailure
    }

    /// Start accepting connections.
    func start() {
        listener.stateUpdateHandler = { [weak self] state in
            self?.handleListenerState(state)
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }
        listener.start(queue: queue)
    }

    /// Stop the listener and cancel all connections and in-flight tasks.
    func stop() {
        listener.cancel()

        // Cancel all tracked tasks and connections.
        let tasks: [CancellableTask]
        let connections: [NWConnection]
        trackingLock.lock()
        tasks = Array(_activeTasks.value.values)
        _activeTasks.value.removeAll()
        connections = Array(_connectionMap.value.values)
        _connectionMap.value.removeAll()
        trackingLock.unlock()

        for task in tasks {
            task.cancel()
        }
        for conn in connections {
            conn.cancel()
        }
    }

    /// The actual port the listener is bound to (useful if the OS assigned one).
    var actualPort: UInt16? {
        listener.port?.rawValue
    }

    // MARK: - Listener state

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let port = listener.port {
                ProxyLogger.log("Proxy server listening on 127.0.0.1:\(port.rawValue)")
                resolveStartupIfNeeded {
                    onReady?(port.rawValue)
                }
            }
        case .failed(let error):
            ProxyLogger.log("Proxy server listener failed: \(error)")
            resolveStartupIfNeeded {
                onFailure?(error.localizedDescription)
            }
            listener.cancel()
        case .cancelled:
            ProxyLogger.log("Proxy server listener cancelled")
        default:
            break
        }
    }

    private func resolveStartupIfNeeded(_ body: () -> Void) {
        startupLock.lock()
        let shouldRun = !startupResolved.value
        if shouldRun {
            startupResolved.value = true
        }
        startupLock.unlock()

        guard shouldRun else { return }
        body()
    }

    // MARK: - Connection tracking

    private func trackConnection(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        trackingLock.lock()
        _connectionMap.value[id] = connection
        trackingLock.unlock()
    }

    private func untrackConnection(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        let cancellable: CancellableTask?
        trackingLock.lock()
        _connectionMap.value.removeValue(forKey: id)
        cancellable = _activeTasks.value.removeValue(forKey: id)
        trackingLock.unlock()

        cancellable?.cancel()
    }

    // MARK: - Connection handling

    private func handleNewConnection(_ connection: NWConnection) {
        trackConnection(connection)

        // Monitor connection state to detect client disconnect.
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                self?.untrackConnection(connection)
            default:
                break
            }
        }

        connection.start(queue: queue)
        readRequest(from: connection, accumulated: Data())
    }

    /// Read data from the connection until we have a full HTTP request.
    private func readRequest(from connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] content, _, isComplete, error in

            guard let self else {
                connection.cancel()
                return
            }

            if let error {
                ProxyLogger.log("Connection receive error: \(error)")
                connection.cancel()
                return
            }

            var buffer = accumulated
            if let content {
                buffer.append(content)
            }

            // Try to parse the headers.
            if let headerEnd = self.findHeaderEnd(in: buffer) {
                self.processRequest(connection: connection, buffer: buffer, headerEnd: headerEnd)
            } else if isComplete {
                // Connection closed before we got a full request.
                connection.cancel()
            } else {
                // Reject if headers have grown past the size limit.
                if buffer.count > Self.maxHeaderSize {
                    self.sendErrorResponse(connection: connection, status: 400,
                                          message: String(localized: "Bad Request: headers too large"))
                    return
                }
                // Need more data.
                self.readRequest(from: connection, accumulated: buffer)
            }
        }
    }

    /// Find the `\r\n\r\n` boundary that ends the HTTP headers.
    private func findHeaderEnd(in data: Data) -> Int? {
        let crlf2 = Data([0x0D, 0x0A, 0x0D, 0x0A]) // \r\n\r\n
        guard data.count >= 4 else { return nil }
        for i in 0...(data.count - 4) {
            if data[data.startIndex + i] == crlf2[0],
               data[data.startIndex + i + 1] == crlf2[1],
               data[data.startIndex + i + 2] == crlf2[2],
               data[data.startIndex + i + 3] == crlf2[3] {
                return i + 4 // offset past the double CRLF
            }
        }
        return nil
    }

    /// We have the complete headers. Parse them and read the body if needed.
    private func processRequest(connection: NWConnection, buffer: Data, headerEnd: Int) {
        let headerData = buffer[buffer.startIndex..<(buffer.startIndex + headerEnd)]
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            sendErrorResponse(connection: connection, status: 400,
                              message: String(localized: "Bad Request: invalid header encoding"))
            return
        }

        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, !requestLine.isEmpty else {
            sendErrorResponse(connection: connection, status: 400,
                              message: String(localized: "Bad Request: missing request line"))
            return
        }

        let parts = requestLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else {
            sendErrorResponse(connection: connection, status: 400,
                              message: String(localized: "Bad Request: malformed request line"))
            return
        }

        let method = String(parts[0])
        let path = String(parts[1])

        // Parse headers.
        var headers: [(name: String, value: String)] = []
        for line in lines.dropFirst() where !line.isEmpty {
            if let colonIndex = line.firstIndex(of: ":") {
                let name = String(line[line.startIndex..<colonIndex]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                headers.append((name: name, value: value))
            }
        }

        // Reject duplicate Content-Length headers (request smuggling vector).
        let contentLengthCount = headers.filter({ $0.name.lowercased() == "content-length" }).count
        if contentLengthCount > 1 {
            sendErrorResponse(connection: connection, status: 400,
                              message: String(localized: "Bad Request: duplicate Content-Length"))
            return
        }

        // Determine Content-Length, rejecting invalid values.
        let contentLengthHeader = headers
            .first(where: { $0.name.lowercased() == "content-length" })
        let contentLength: Int
        if let clHeader = contentLengthHeader {
            guard let cl = Int(clHeader.value), cl >= 0, cl <= ProxyHTTPServer.maxContentLength else {
                sendErrorResponse(connection: connection, status: 400,
                                  message: String(localized: "Bad Request: invalid Content-Length"))
                return
            }
            contentLength = cl
        } else {
            contentLength = 0
        }

        // How much body we already have in the buffer.
        let bodyStart = buffer.startIndex + headerEnd
        let alreadyRead = buffer.count - headerEnd
        let remaining = max(0, contentLength - alreadyRead)

        if remaining == 0 {
            // We have the full body already.
            let body = (contentLength > 0) ? buffer[bodyStart..<(bodyStart + contentLength)] : Data()
            dispatchRequest(connection: connection, method: method, path: path,
                            headers: headers, body: Data(body))
        } else {
            // Need to read more body bytes.
            readBody(from: connection, buffer: buffer, bodyStart: bodyStart,
                     totalBodyLength: contentLength, method: method, path: path, headers: headers)
        }
    }

    /// Continue reading until we have `totalBodyLength` bytes of body.
    private func readBody(from connection: NWConnection, buffer: Data, bodyStart: Int,
                          totalBodyLength: Int, method: String, path: String,
                          headers: [(name: String, value: String)]) {
        let alreadyRead = buffer.count - bodyStart
        let remaining = totalBodyLength - alreadyRead
        guard remaining > 0 else {
            let body = buffer[buffer.startIndex + bodyStart..<(buffer.startIndex + bodyStart + totalBodyLength)]
            dispatchRequest(connection: connection, method: method, path: path,
                            headers: headers, body: Data(body))
            return
        }

        connection.receive(minimumIncompleteLength: 1, maximumLength: min(remaining, 65536)) {
            [weak self] content, _, isComplete, error in

            guard let self else {
                connection.cancel()
                return
            }

            if let error {
                ProxyLogger.log("Body read error: \(error)")
                connection.cancel()
                return
            }

            var updated = buffer
            if let content {
                updated.append(content)
            }

            let nowRead = updated.count - bodyStart
            if nowRead >= totalBodyLength {
                let body = updated[updated.startIndex + bodyStart..<(updated.startIndex + bodyStart + totalBodyLength)]
                self.dispatchRequest(connection: connection, method: method, path: path,
                                     headers: headers, body: Data(body))
            } else if isComplete {
                // Connection closed before full body received.
                self.sendErrorResponse(connection: connection, status: 400,
                                       message: String(localized: "Bad Request: incomplete body"))
            } else {
                self.readBody(from: connection, buffer: updated, bodyStart: bodyStart,
                              totalBodyLength: totalBodyLength, method: method, path: path,
                              headers: headers)
            }
        }
    }

    // MARK: - Request routing

    private func dispatchRequest(connection: NWConnection, method: String, path: String,
                                 headers: [(name: String, value: String)], body: Data) {
        // Only support POST /v1/messages
        guard path == "/v1/messages" || path.hasPrefix("/v1/messages?") else {
            sendErrorResponse(connection: connection, status: 404,
                              message: String(localized: "Not Found: only /v1/messages is supported"))
            return
        }
        guard method.uppercased() == "POST" else {
            sendErrorResponse(connection: connection, status: 405,
                              message: String(localized: "Method Not Allowed: only POST is supported"))
            return
        }

        let writer = NWResponseWriter(connection: connection, queue: queue) { [weak self] in
            self?.untrackConnection(connection)
        }
        let request = ProxyHTTPRequest(method: method, path: path, headers: headers,
                                       body: body, writer: writer)

        // Track a CancellableTask BEFORE the Task starts executing, so that
        // a concurrent untrackConnection call can always find and cancel it.
        let cancellable = CancellableTask()
        let connId = ObjectIdentifier(connection)
        trackingLock.lock()
        _activeTasks.value[connId] = cancellable
        trackingLock.unlock()

        let task = Task {
            await self.handler(request)
        }
        cancellable.setTask(task)
    }

    // MARK: - Error responses

    private func sendErrorResponse(connection: NWConnection, status: Int, message: String) {
        let statusText = HTTPStatusText.text(for: status)
        let body = ProxyHTTPUtils.anthropicErrorBody(message: message)
        var response = "HTTP/1.1 \(status) \(statusText)\r\n"
        response += "Content-Type: application/json; charset=utf-8\r\n"
        response += "Content-Length: \(body.count)\r\n"
        response += "Connection: close\r\n"
        response += "\r\n"

        var responseData = response.data(using: .utf8) ?? Data()
        responseData.append(body)

        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

}

// MARK: - LockedBox

/// A mutable container whose access is serialized by an external `NSLock`.
private final class LockedBox<Value: Sendable>: @unchecked Sendable {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}

extension LockedBox where Value == [ObjectIdentifier: NWConnection] {
    convenience init() {
        self.init([:])
    }
}

extension LockedBox where Value == [ObjectIdentifier: CancellableTask] {
    convenience init() {
        self.init([:])
    }
}

// MARK: - CancellableTask

/// A thread-safe wrapper that allows a `Task` to be registered for cancellation
/// before the `Task` value is available. This closes the race where
/// `untrackConnection` fires between Task creation and tracking.
private final class CancellableTask: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var isCancelled = false

    /// Store the actual Task. If `cancel()` was already called, cancels immediately.
    func setTask(_ task: Task<Void, Never>) {
        lock.lock()
        self.task = task
        let shouldCancel = isCancelled
        lock.unlock()
        if shouldCancel {
            task.cancel()
        }
    }

    /// Cancel the underlying Task, or mark for cancellation if not yet set.
    func cancel() {
        lock.lock()
        isCancelled = true
        let t = task
        lock.unlock()
        t?.cancel()
    }
}

// MARK: - NWResponseWriter

/// Writes HTTP responses through an NWConnection using chunked transfer encoding
/// when streaming, or a single payload otherwise.
/// All writes are serialized through a dedicated serial DispatchQueue.
final class NWResponseWriter: ResponseWriter, @unchecked Sendable {
    private let connection: NWConnection
    private let writeQueue: DispatchQueue
    private var headWritten = false
    private var isChunked = false
    private var ended = false
    private let onEnd: (@Sendable () -> Void)?

    init(connection: NWConnection, queue: DispatchQueue, onEnd: (@Sendable () -> Void)? = nil) {
        self.connection = connection
        // Create a serial target queue under the server queue for write serialization.
        self.writeQueue = DispatchQueue(label: "com.tokenpulse.proxy.writer", target: queue)
        self.onEnd = onEnd
    }

    func writeHead(status: Int, headers: [(name: String, value: String)]) {
        writeQueue.sync {
            guard !headWritten, !ended else { return }
            headWritten = true

            // Check if this is a chunked response.
            isChunked = headers.contains(where: {
                $0.name.lowercased() == "transfer-encoding" && $0.value.lowercased().contains("chunked")
            })

            let statusText = HTTPStatusText.text(for: status)
            var head = "HTTP/1.1 \(status) \(statusText)\r\n"
            for header in headers {
                head += "\(header.name): \(header.value)\r\n"
            }
            head += "\r\n"

            if let data = head.data(using: .utf8) {
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error {
                        ProxyLogger.log("Error writing response head: \(error)")
                    }
                })
            }
        }
    }

    func writeChunk(_ data: Data) {
        writeQueue.sync {
            guard headWritten, !ended, !data.isEmpty else { return }

            if isChunked {
                // HTTP chunked encoding: <hex-size>\r\n<data>\r\n
                let hexSize = String(data.count, radix: 16)
                var chunk = Data()
                if let prefix = "\(hexSize)\r\n".data(using: .utf8) {
                    chunk.append(prefix)
                }
                chunk.append(data)
                if let suffix = "\r\n".data(using: .utf8) {
                    chunk.append(suffix)
                }
                connection.send(content: chunk, completion: .contentProcessed { error in
                    if let error {
                        ProxyLogger.log("Error writing chunk: \(error)")
                    }
                })
            } else {
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error {
                        ProxyLogger.log("Error writing data: \(error)")
                    }
                })
            }
        }
    }

    func end() {
        writeQueue.sync {
            guard !ended else { return }
            ended = true

            let onEndCallback = onEnd

            if isChunked {
                // Terminal chunk.
                if let terminator = "0\r\n\r\n".data(using: .utf8) {
                    connection.send(content: terminator, completion: .contentProcessed { [connection] _ in
                        connection.cancel()
                        onEndCallback?()
                    })
                }
            } else {
                connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                                completion: .contentProcessed { [connection] _ in
                    connection.cancel()
                    onEndCallback?()
                })
            }
        }
    }
}

// MARK: - HTTP Status Text Helper

enum HTTPStatusText {
    static func text(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        default: return "Unknown"
        }
    }
}

// MARK: - Server Errors

enum ProxyServerError: Error, LocalizedError {
    case invalidPort

    var errorDescription: String? {
        switch self {
        case .invalidPort:
            return String(localized: "Invalid proxy port number")
        }
    }
}

// MARK: - Internal logger (debug only, no file I/O)

enum ProxyLogger {
    static func log(_ message: String) {
        #if DEBUG
        print("[TokenPulse Proxy] \(message)")
        #endif
    }
}
