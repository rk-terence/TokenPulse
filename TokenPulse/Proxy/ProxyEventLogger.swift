import Foundation
import SQLite3

/// Structured event logger for the proxy subsystem. Writes events into
/// `~/.tokenpulse/proxy_events.sqlite` and an atomic status snapshot to
/// `~/.tokenpulse/proxy_status.json`.
///
/// This is an actor (not `@MainActor`) — all file I/O happens off the main thread.
actor ProxyEventLogger {
    private static let maxEventAge: TimeInterval = 24 * 60 * 60
    private static let pruneInterval: TimeInterval = 5 * 60
    private static let statusSnapshotThrottleInterval: TimeInterval = 1

    struct LoggedRequest: Sendable {
        let method: String
        let path: String
        let upstreamURL: String
        let headers: [(name: String, value: String)]
        let body: Data
        let streaming: Bool
    }

    struct LoggedResponse: Sendable {
        let statusCode: Int
        let headers: [(name: String, value: String)]
        let body: Data
        let source: String
        let bodyBytes: Int
        let bodyTruncated: Bool

        init(
            statusCode: Int,
            headers: [(name: String, value: String)],
            body: Data,
            source: String,
            bodyBytes: Int? = nil,
            bodyTruncated: Bool = false
        ) {
            self.statusCode = statusCode
            self.headers = headers
            self.body = body
            self.source = source
            self.bodyBytes = bodyBytes ?? body.count
            self.bodyTruncated = bodyTruncated
        }
    }

    private struct StatusSnapshot: Sendable {
        let proxyEnabled: Bool
        let port: Int
        let activeSessions: Int
        let activeKeepalives: Int
        let metrics: ProxyMetricsStore.Snapshot
    }

    private struct EventContent {
        let upstreamRequestID: String?
        let requestJSON: String?
        let responseJSON: String?
    }

    let enabled: Bool
    let capturesContent: Bool

    private let databaseFileURL: URL
    private let statusFileURL: URL
    private var database: OpaquePointer?
    private let isoFormatter: ISO8601DateFormatter
    private var lastPruneAt: Date?
    private var lastStatusSnapshotWriteAt: Date?
    private var pendingStatusSnapshot: StatusSnapshot?
    private var pendingStatusSnapshotTask: Task<Void, Never>?

    private static let directory: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".tokenpulse", isDirectory: true)
    }()

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(enabled: Bool, capturesContent: Bool = false) {
        self.enabled = enabled
        self.capturesContent = capturesContent
        self.databaseFileURL = Self.directory.appendingPathComponent("proxy_events.sqlite")
        self.statusFileURL = Self.directory.appendingPathComponent("proxy_status.json")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        self.isoFormatter = formatter
    }

    // MARK: - Event logging

    func logProxyStarted(port: Int) {
        appendEvent(["type": "proxy_started", "port": port])
    }

    func logProxyStopped() {
        appendEvent(["type": "proxy_stopped"])
    }

    func logRequestStarted(
        session: String,
        model: String?,
        method: String,
        path: String,
        upstreamURL: String,
        streaming: Bool
    ) {
        var entry: [String: Any] = ["type": "request_started", "session": session]
        if let model { entry["model"] = model }
        entry["method"] = method
        entry["path"] = path
        entry["upstreamURL"] = upstreamURL
        entry["streaming"] = streaming
        appendEvent(entry)
    }

    func logRequestCompleted(
        session: String,
        model: String?,
        request: LoggedRequest,
        response: LoggedResponse,
        durationMs: Int,
        statusCode: Int,
        tokenUsage: TokenUsage
    ) {
        var entry: [String: Any] = [
            "type": "request_completed",
            "session": session,
            "statusCode": statusCode,
        ]
        if let model { entry["model"] = model }
        entry["durationMs"] = durationMs
        entry["streaming"] = request.streaming
        entry["upstreamRequestID"] = extractUpstreamRequestID(from: response.headers)
        entry["request"] = serializeMetadata(request: request)
        entry["response"] = serializeMetadata(response: response)
        if let v = tokenUsage.inputTokens { entry["inputTokens"] = v }
        if let v = tokenUsage.outputTokens { entry["outputTokens"] = v }
        if let v = tokenUsage.cacheReadInputTokens { entry["cacheReadTokens"] = v }
        if let v = tokenUsage.cacheCreationInputTokens { entry["cacheCreationTokens"] = v }
        appendEvent(
            entry,
            content: serializeContent(request: request, response: response)
        )
    }

    func logRequestFailed(
        session: String,
        model: String?,
        request: LoggedRequest,
        response: LoggedResponse?,
        durationMs: Int,
        error: String
    ) {
        var entry: [String: Any] = [
            "type": "request_failed",
            "session": session,
            "error": error,
            "durationMs": durationMs,
            "streaming": request.streaming,
            "request": serializeMetadata(request: request),
        ]
        if let model { entry["model"] = model }
        if let response {
            entry["response"] = serializeMetadata(response: response)
            entry["statusCode"] = response.statusCode
            entry["upstreamRequestID"] = extractUpstreamRequestID(from: response.headers)
        }
        appendEvent(
            entry,
            content: serializeContent(request: request, response: response)
        )
    }

    func logKeepaliveSent(
        session: String,
        request: LoggedRequest
    ) {
        appendEvent([
            "type": "keepalive_sent",
            "session": session,
            "request": serializeMetadata(request: request),
        ])
    }

    func logKeepaliveResult(
        session: String,
        success: Bool,
        request: LoggedRequest,
        response: LoggedResponse?,
        durationMs: Int,
        error: String?,
        tokenUsage: TokenUsage,
        statusCode: Int?
    ) {
        var entry: [String: Any] = [
            "type": "keepalive_result",
            "session": session,
            "success": success,
            "durationMs": durationMs,
            "request": serializeMetadata(request: request),
        ]
        if let response {
            entry["response"] = serializeMetadata(response: response)
            entry["upstreamRequestID"] = extractUpstreamRequestID(from: response.headers)
        }
        if let error { entry["error"] = error }
        if let v = tokenUsage.inputTokens { entry["inputTokens"] = v }
        if let v = tokenUsage.outputTokens { entry["outputTokens"] = v }
        if let v = tokenUsage.cacheReadInputTokens { entry["cacheReadTokens"] = v }
        if let v = tokenUsage.cacheCreationInputTokens { entry["cacheCreationTokens"] = v }
        if let statusCode { entry["statusCode"] = statusCode }
        appendEvent(
            entry,
            content: serializeContent(request: request, response: response)
        )
    }

    func logSessionExpired(session: String) {
        appendEvent([
            "type": "session_expired",
            "session": session,
        ])
    }

    func logKeepaliveDisabled(session: String, reason: String, failureCount: Int) {
        appendEvent([
            "type": "keepalive_disabled",
            "session": session,
            "reason": reason,
            "failureCount": failureCount,
        ])
    }

    // MARK: - Status snapshot

    func writeStatusSnapshot(
        enabled proxyEnabled: Bool,
        port: Int,
        activeSessions: Int,
        activeKeepalives: Int,
        metrics: ProxyMetricsStore.Snapshot,
        force: Bool = false
    ) {
        guard self.enabled else { return }

        let snapshot = StatusSnapshot(
            proxyEnabled: proxyEnabled,
            port: port,
            activeSessions: activeSessions,
            activeKeepalives: activeKeepalives,
            metrics: metrics
        )
        let now = Date()

        if force {
            pendingStatusSnapshot = nil
            pendingStatusSnapshotTask?.cancel()
            pendingStatusSnapshotTask = nil
            persistStatusSnapshot(snapshot, at: now)
            return
        }

        if let lastStatusSnapshotWriteAt,
           now.timeIntervalSince(lastStatusSnapshotWriteAt) < Self.statusSnapshotThrottleInterval {
            pendingStatusSnapshot = snapshot
            schedulePendingStatusSnapshotFlush(
                after: Self.statusSnapshotThrottleInterval - now.timeIntervalSince(lastStatusSnapshotWriteAt)
            )
            return
        }

        persistStatusSnapshot(snapshot, at: now)
    }

    // MARK: - Cleanup

    func close() {
        pendingStatusSnapshotTask?.cancel()
        pendingStatusSnapshotTask = nil
        pendingStatusSnapshot = nil
        if let database {
            sqlite3_close(database)
            self.database = nil
        }
    }

    // MARK: - Private

    private func appendEvent(_ fields: [String: Any], content: EventContent? = nil) {
        guard enabled else { return }

        var entry = fields
        entry["ts"] = isoFormatter.string(from: Date())

        do {
            let database = try openDatabaseIfNeeded()
            try pruneExpiredEventsIfNeeded(in: database)
            let payloadData = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
            guard let payloadJSON = String(data: payloadData, encoding: .utf8) else { return }

            let sql = """
                INSERT INTO proxy_events (
                    ts, type, session, model, success, status_code, duration_ms, streaming,
                    method, path, upstream_url, upstream_request_id, cache_read_tokens, cache_creation_tokens,
                    error, reason, failure_count, port, payload_json, input_tokens, output_tokens
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                throw LoggerStorageError.prepareFailed(message: errorMessage(from: database))
            }
            defer { sqlite3_finalize(statement) }

            let request = entry["request"] as? [String: Any]

            bind(entry["ts"] as? String, to: 1, in: statement)
            bind(entry["type"] as? String, to: 2, in: statement)
            bind(entry["session"] as? String, to: 3, in: statement)
            bind(entry["model"] as? String, to: 4, in: statement)
            bind(entry["success"] as? Bool, to: 5, in: statement)
            bind(entry["statusCode"] as? Int, to: 6, in: statement)
            bind(entry["durationMs"] as? Int, to: 7, in: statement)
            bind((entry["streaming"] as? Bool) ?? (request?["streaming"] as? Bool), to: 8, in: statement)
            bind((entry["method"] as? String) ?? (request?["method"] as? String), to: 9, in: statement)
            bind((entry["path"] as? String) ?? (request?["path"] as? String), to: 10, in: statement)
            bind((entry["upstreamURL"] as? String) ?? (request?["upstreamURL"] as? String), to: 11, in: statement)
            bind(entry["upstreamRequestID"] as? String, to: 12, in: statement)
            bind(entry["cacheReadTokens"] as? Int, to: 13, in: statement)
            bind(entry["cacheCreationTokens"] as? Int, to: 14, in: statement)
            bind(entry["error"] as? String, to: 15, in: statement)
            bind(entry["reason"] as? String, to: 16, in: statement)
            bind(entry["failureCount"] as? Int, to: 17, in: statement)
            bind(entry["port"] as? Int, to: 18, in: statement)
            bind(payloadJSON, to: 19, in: statement)
            bind(entry["inputTokens"] as? Int, to: 20, in: statement)
            bind(entry["outputTokens"] as? Int, to: 21, in: statement)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw LoggerStorageError.stepFailed(message: errorMessage(from: database))
            }

            let eventID = sqlite3_last_insert_rowid(database)
            try insertContentIfNeeded(content, eventID: eventID, in: database)
        } catch {
            ProxyLogger.log("ProxyEventLogger: failed to persist event: \(error)")
        }
    }

    private func openDatabaseIfNeeded() throws -> OpaquePointer {
        if let database {
            return database
        }

        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)

        var database: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(databaseFileURL.path, &database, flags, nil) == SQLITE_OK, let database else {
            let message = database.flatMap { errorMessage(from: $0) } ?? "unknown"
            sqlite3_close(database)
            throw LoggerStorageError.openFailed(message: message)
        }

        do {
            try execute("PRAGMA foreign_keys = ON;", in: database)
            try execute("PRAGMA journal_mode = WAL;", in: database)
            try execute("PRAGMA synchronous = NORMAL;", in: database)
            try execute(
                """
                CREATE TABLE IF NOT EXISTS proxy_events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    ts TEXT NOT NULL,
                    type TEXT NOT NULL,
                    session TEXT,
                    model TEXT,
                    success INTEGER,
                    status_code INTEGER,
                    duration_ms INTEGER,
                    streaming INTEGER,
                    method TEXT,
                    path TEXT,
                    upstream_url TEXT,
                    upstream_request_id TEXT,
                    cache_read_tokens INTEGER,
                    cache_creation_tokens INTEGER,
                    error TEXT,
                    reason TEXT,
                    failure_count INTEGER,
                    port INTEGER,
                    payload_json TEXT NOT NULL
                );
                """,
                in: database
            )
            try addColumnIfMissing(
                "upstream_request_id TEXT",
                named: "upstream_request_id",
                to: "proxy_events",
                in: database
            )
            try addColumnIfMissing(
                "input_tokens INTEGER",
                named: "input_tokens",
                to: "proxy_events",
                in: database
            )
            try addColumnIfMissing(
                "output_tokens INTEGER",
                named: "output_tokens",
                to: "proxy_events",
                in: database
            )
            try execute(
                """
                CREATE TABLE IF NOT EXISTS proxy_event_content (
                    event_id INTEGER PRIMARY KEY,
                    upstream_request_id TEXT,
                    request_json TEXT,
                    response_json TEXT,
                    FOREIGN KEY(event_id) REFERENCES proxy_events(id) ON DELETE CASCADE
                );
                """,
                in: database
            )
            try execute("CREATE INDEX IF NOT EXISTS idx_proxy_events_ts ON proxy_events(ts);", in: database)
            try execute("CREATE INDEX IF NOT EXISTS idx_proxy_events_type_ts ON proxy_events(type, ts);", in: database)
            try execute("CREATE INDEX IF NOT EXISTS idx_proxy_events_session_ts ON proxy_events(session, ts);", in: database)
            try execute("CREATE INDEX IF NOT EXISTS idx_proxy_events_model_ts ON proxy_events(model, ts);", in: database)
            try execute("CREATE INDEX IF NOT EXISTS idx_proxy_events_status_ts ON proxy_events(status_code, ts);", in: database)
            try execute("CREATE INDEX IF NOT EXISTS idx_proxy_events_upstream_request_id ON proxy_events(upstream_request_id);", in: database)
            try execute("CREATE INDEX IF NOT EXISTS idx_proxy_event_content_upstream_request_id ON proxy_event_content(upstream_request_id);", in: database)
        } catch {
            sqlite3_close(database)
            throw error
        }

        self.database = database
        return database
    }

    private func pruneExpiredEventsIfNeeded(in database: OpaquePointer) throws {
        let now = Date()
        if let lastPruneAt, now.timeIntervalSince(lastPruneAt) < Self.pruneInterval {
            return
        }

        let cutoff = isoFormatter.string(from: now.addingTimeInterval(-Self.maxEventAge))
        let sql = "DELETE FROM proxy_events WHERE ts < ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw LoggerStorageError.prepareFailed(message: errorMessage(from: database))
        }
        defer { sqlite3_finalize(statement) }

        bind(cutoff, to: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw LoggerStorageError.stepFailed(message: errorMessage(from: database))
        }

        try execute("PRAGMA wal_checkpoint(PASSIVE);", in: database)
        lastPruneAt = now
    }

    private func serializeMetadata(request: LoggedRequest) -> [String: Any] {
        [
            "method": request.method,
            "path": request.path,
            "upstreamURL": request.upstreamURL,
            "streaming": request.streaming,
            "body": serializeBodyMetadata(byteCount: request.body.count),
        ]
    }

    private func serializeMetadata(response: LoggedResponse) -> [String: Any] {
        [
            "statusCode": response.statusCode,
            "source": response.source,
            "body": serializeBodyMetadata(
                byteCount: response.bodyBytes,
                truncated: response.bodyTruncated
            ),
        ]
    }

    private func serializeContent(request: LoggedRequest?, response: LoggedResponse?) -> EventContent? {
        guard capturesContent else { return nil }

        let requestJSON = request.flatMap { jsonString(for: serializeContent(request: $0)) }
        let responseJSON = response.flatMap { jsonString(for: serializeContent(response: $0)) }
        let capturedUpstreamRequestID = response.flatMap { extractUpstreamRequestID(from: $0.headers) }

        if requestJSON == nil && responseJSON == nil {
            return nil
        }

        return EventContent(
            upstreamRequestID: capturedUpstreamRequestID,
            requestJSON: requestJSON,
            responseJSON: responseJSON
        )
    }

    private func serializeContent(request: LoggedRequest) -> [String: Any] {
        [
            "method": request.method,
            "path": request.path,
            "upstreamURL": request.upstreamURL,
            "streaming": request.streaming,
            "headers": serialize(headers: request.headers),
            "body": serializeBodyContent(body: request.body),
        ]
    }

    private func serializeContent(response: LoggedResponse) -> [String: Any] {
        [
            "statusCode": response.statusCode,
            "source": response.source,
            "headers": serialize(headers: response.headers),
            "body": serializeBodyContent(
                body: response.body,
                byteCount: response.bodyBytes,
                truncated: response.bodyTruncated
            ),
        ]
    }

    private func serialize(headers: [(name: String, value: String)]) -> [[String: String]] {
        headers.map { ["name": $0.name, "value": $0.value] }
    }

    private func serializeBodyMetadata(byteCount: Int, truncated: Bool = false) -> [String: Any] {
        var serialized: [String: Any] = ["bytes": byteCount]
        if truncated {
            serialized["truncated"] = true
        }
        return serialized
    }

    private func serializeBodyContent(body: Data, byteCount: Int? = nil, truncated: Bool = false) -> [String: Any] {
        var serialized: [String: Any] = ["bytes": byteCount ?? body.count]
        if truncated {
            serialized["truncated"] = true
        }
        if let text = String(data: body, encoding: .utf8) {
            serialized["encoding"] = "utf8"
            serialized["text"] = text
        } else {
            serialized["encoding"] = "base64"
            serialized["base64"] = body.base64EncodedString()
        }
        return serialized
    }

    private func insertContentIfNeeded(_ content: EventContent?, eventID: Int64, in database: OpaquePointer) throws {
        guard capturesContent, let content else { return }

        let sql = """
            INSERT OR REPLACE INTO proxy_event_content (
                event_id, upstream_request_id, request_json, response_json
            ) VALUES (?, ?, ?, ?)
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw LoggerStorageError.prepareFailed(message: errorMessage(from: database))
        }
        defer { sqlite3_finalize(statement) }

        bind(eventID, to: 1, in: statement)
        bind(content.upstreamRequestID, to: 2, in: statement)
        bind(content.requestJSON, to: 3, in: statement)
        bind(content.responseJSON, to: 4, in: statement)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw LoggerStorageError.stepFailed(message: errorMessage(from: database))
        }
    }

    private func jsonString(for value: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func extractUpstreamRequestID(from headers: [(name: String, value: String)]) -> String? {
        for header in headers where header.name.caseInsensitiveCompare("request-id") == .orderedSame {
            return header.value
        }
        for header in headers where header.name.caseInsensitiveCompare("x-request-id") == .orderedSame {
            return header.value
        }
        return nil
    }

    private func schedulePendingStatusSnapshotFlush(after delaySeconds: TimeInterval) {
        guard pendingStatusSnapshotTask == nil else { return }
        pendingStatusSnapshotTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, delaySeconds)))
            await self?.flushPendingStatusSnapshotIfNeeded()
        }
    }

    private func flushPendingStatusSnapshotIfNeeded() {
        pendingStatusSnapshotTask = nil
        guard let pendingStatusSnapshot else { return }
        self.pendingStatusSnapshot = nil
        persistStatusSnapshot(pendingStatusSnapshot, at: Date())
    }

    private func persistStatusSnapshot(_ snapshot: StatusSnapshot, at writeDate: Date) {
        let payload: [String: Any] = [
            "enabled": snapshot.proxyEnabled,
            "port": snapshot.port,
            "activeSessions": snapshot.activeSessions,
            "activeKeepalives": snapshot.activeKeepalives,
            "totalRequestsForwarded": snapshot.metrics.totalRequestsForwarded,
            "totalKeepalivesSent": snapshot.metrics.totalKeepalivesSent,
            "totalKeepalivesFailed": snapshot.metrics.totalKeepalivesFailed,
            "cacheReads": snapshot.metrics.totalCacheReads,
            "cacheWrites": snapshot.metrics.totalCacheWrites,
            "totalInputTokens": snapshot.metrics.totalInputTokens,
            "totalOutputTokens": snapshot.metrics.totalOutputTokens,
            "totalCacheReadInputTokens": snapshot.metrics.totalCacheReadInputTokens,
            "totalCacheCreationInputTokens": snapshot.metrics.totalCacheCreationInputTokens,
            "lastUpdatedAt": isoFormatter.string(from: writeDate),
        ]

        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            try data.write(to: statusFileURL, options: .atomic)
            lastStatusSnapshotWriteAt = writeDate
        } catch {
            ProxyLogger.log("ProxyEventLogger: failed to write status snapshot: \(error)")
        }
    }

    private func execute(_ sql: String, in database: OpaquePointer) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw LoggerStorageError.execFailed(message: errorMessage(from: database))
        }
    }

    private func addColumnIfMissing(
        _ definition: String,
        named columnName: String,
        to tableName: String,
        in database: OpaquePointer
    ) throws {
        guard !table(tableName, hasColumn: columnName, in: database) else { return }
        try execute("ALTER TABLE \(tableName) ADD COLUMN \(definition);", in: database)
    }

    private func table(_ tableName: String, hasColumn columnName: String, in database: OpaquePointer) -> Bool {
        let sql = "PRAGMA table_info(\(tableName));"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(statement) }

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let name = sqlite3_column_text(statement, 1) else { continue }
            if String(cString: name) == columnName {
                return true
            }
        }
        return false
    }

    private func bind(_ value: String?, to index: Int32, in statement: OpaquePointer?) {
        guard let statement else { return }
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, Self.sqliteTransient)
    }

    private func bind(_ value: Int?, to index: Int32, in statement: OpaquePointer?) {
        guard let statement else { return }
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_int64(statement, index, sqlite3_int64(value))
    }

    private func bind(_ value: Int64?, to index: Int32, in statement: OpaquePointer?) {
        guard let statement else { return }
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_int64(statement, index, value)
    }

    private func bind(_ value: Bool?, to index: Int32, in statement: OpaquePointer?) {
        bind(value.map { $0 ? 1 : 0 }, to: index, in: statement)
    }

    private func errorMessage(from database: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(database))
    }

    private enum LoggerStorageError: Error, CustomStringConvertible {
        case openFailed(message: String)
        case execFailed(message: String)
        case prepareFailed(message: String)
        case stepFailed(message: String)

        var description: String {
            switch self {
            case .openFailed(let message):
                return "failed to open database: \(message)"
            case .execFailed(let message):
                return "failed to initialize database: \(message)"
            case .prepareFailed(let message):
                return "failed to prepare insert: \(message)"
            case .stepFailed(let message):
                return "failed to write event: \(message)"
            }
        }
    }
}
