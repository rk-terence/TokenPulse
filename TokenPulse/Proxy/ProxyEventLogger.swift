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

    // MARK: - Properties

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

    // MARK: - Request logging

    func logRequestStarted(
        session: String,
        model: String?,
        method: String,
        path: String,
        upstreamURL: String,
        streaming: Bool
    ) -> Int64? {
        guard enabled else { return nil }
        do {
            let database = try openDatabaseIfNeeded()
            try pruneExpiredIfNeeded(in: database)
            let sql = """
                INSERT INTO proxy_requests (session, model, method, path, upstream_url, streaming, started_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                throw LoggerStorageError.prepareFailed(message: errorMessage(from: database))
            }
            defer { sqlite3_finalize(statement) }
            bind(session, to: 1, in: statement)
            bind(model, to: 2, in: statement)
            bind(method, to: 3, in: statement)
            bind(path, to: 4, in: statement)
            bind(upstreamURL, to: 5, in: statement)
            bind(streaming, to: 6, in: statement)
            bind(isoFormatter.string(from: Date()), to: 7, in: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw LoggerStorageError.stepFailed(message: errorMessage(from: database))
            }
            return sqlite3_last_insert_rowid(database)
        } catch {
            ProxyLogger.log("ProxyEventLogger: failed to log request started: \(error)")
            return nil
        }
    }

    func logRequestCompleted(
        requestID: Int64?,
        session: String,
        model: String?,
        request: LoggedRequest,
        response: LoggedResponse,
        durationMs: Int,
        statusCode: Int,
        tokenUsage: TokenUsage,
        errored: Bool
    ) {
        guard enabled else { return }
        do {
            let database = try openDatabaseIfNeeded()
            if let requestID {
                let sql = """
                    UPDATE proxy_requests SET
                        completed_at = ?, status_code = ?, duration_ms = ?,
                        upstream_request_id = ?,
                        input_tokens = ?, output_tokens = ?,
                        cache_read_tokens = ?, cache_creation_tokens = ?,
                        errored = ?
                    WHERE id = ?
                    """
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                    throw LoggerStorageError.prepareFailed(message: errorMessage(from: database))
                }
                defer { sqlite3_finalize(statement) }
                bind(isoFormatter.string(from: Date()), to: 1, in: statement)
                bind(statusCode, to: 2, in: statement)
                bind(durationMs, to: 3, in: statement)
                bind(extractUpstreamRequestID(from: response.headers), to: 4, in: statement)
                bind(tokenUsage.inputTokens, to: 5, in: statement)
                bind(tokenUsage.outputTokens, to: 6, in: statement)
                bind(tokenUsage.cacheReadInputTokens, to: 7, in: statement)
                bind(tokenUsage.cacheCreationInputTokens, to: 8, in: statement)
                bind(errored, to: 9, in: statement)
                bind(requestID, to: 10, in: statement)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw LoggerStorageError.stepFailed(message: errorMessage(from: database))
                }
                try insertContentIfNeeded(
                    serializeContent(request: request, response: response),
                    requestID: requestID,
                    in: database
                )
            } else {
                // Standalone INSERT for cases where logRequestStarted failed
                try pruneExpiredIfNeeded(in: database)
                let sql = """
                    INSERT INTO proxy_requests (
                        session, model, method, path, upstream_url, streaming,
                        started_at, completed_at, status_code, duration_ms,
                        upstream_request_id,
                        input_tokens, output_tokens,
                        cache_read_tokens, cache_creation_tokens,
                        errored
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                    throw LoggerStorageError.prepareFailed(message: errorMessage(from: database))
                }
                defer { sqlite3_finalize(statement) }
                let now = isoFormatter.string(from: Date())
                bind(session, to: 1, in: statement)
                bind(model, to: 2, in: statement)
                bind(request.method, to: 3, in: statement)
                bind(request.path, to: 4, in: statement)
                bind(request.upstreamURL, to: 5, in: statement)
                bind(request.streaming, to: 6, in: statement)
                bind(now, to: 7, in: statement)
                bind(now, to: 8, in: statement)
                bind(statusCode, to: 9, in: statement)
                bind(durationMs, to: 10, in: statement)
                bind(extractUpstreamRequestID(from: response.headers), to: 11, in: statement)
                bind(tokenUsage.inputTokens, to: 12, in: statement)
                bind(tokenUsage.outputTokens, to: 13, in: statement)
                bind(tokenUsage.cacheReadInputTokens, to: 14, in: statement)
                bind(tokenUsage.cacheCreationInputTokens, to: 15, in: statement)
                bind(errored, to: 16, in: statement)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw LoggerStorageError.stepFailed(message: errorMessage(from: database))
                }
                let insertedID = sqlite3_last_insert_rowid(database)
                try insertContentIfNeeded(
                    serializeContent(request: request, response: response),
                    requestID: insertedID,
                    in: database
                )
            }
        } catch {
            ProxyLogger.log("ProxyEventLogger: failed to log request completed: \(error)")
        }
    }

    func logRequestFailed(
        requestID: Int64?,
        session: String,
        model: String?,
        request: LoggedRequest,
        response: LoggedResponse?,
        durationMs: Int,
        error: String
    ) {
        guard enabled else { return }
        do {
            let database = try openDatabaseIfNeeded()
            let upstreamRequestID = response.flatMap { extractUpstreamRequestID(from: $0.headers) }
            let statusCode = response?.statusCode

            if let requestID {
                // UPDATE existing row
                let sql = """
                    UPDATE proxy_requests SET
                        completed_at = ?, status_code = ?, duration_ms = ?,
                        upstream_request_id = ?, error = ?, errored = 1
                    WHERE id = ?
                    """
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                    throw LoggerStorageError.prepareFailed(message: errorMessage(from: database))
                }
                defer { sqlite3_finalize(statement) }
                bind(isoFormatter.string(from: Date()), to: 1, in: statement)
                bind(statusCode, to: 2, in: statement)
                bind(durationMs, to: 3, in: statement)
                bind(upstreamRequestID, to: 4, in: statement)
                bind(error, to: 5, in: statement)
                bind(requestID, to: 6, in: statement)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw LoggerStorageError.stepFailed(message: errorMessage(from: database))
                }
                try insertContentIfNeeded(
                    serializeContent(request: request, response: response),
                    requestID: requestID,
                    in: database
                )
            } else {
                // Standalone INSERT for cases where logRequestStarted was not called
                try pruneExpiredIfNeeded(in: database)
                let sql = """
                    INSERT INTO proxy_requests (
                        session, model, method, path, upstream_url, streaming,
                        started_at, completed_at, status_code, duration_ms,
                        upstream_request_id, error, errored
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)
                    """
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                    throw LoggerStorageError.prepareFailed(message: errorMessage(from: database))
                }
                defer { sqlite3_finalize(statement) }
                let now = isoFormatter.string(from: Date())
                bind(session, to: 1, in: statement)
                bind(model, to: 2, in: statement)
                bind(request.method, to: 3, in: statement)
                bind(request.path, to: 4, in: statement)
                bind(request.upstreamURL, to: 5, in: statement)
                bind(request.streaming, to: 6, in: statement)
                bind(now, to: 7, in: statement)
                bind(now, to: 8, in: statement)
                bind(statusCode, to: 9, in: statement)
                bind(durationMs, to: 10, in: statement)
                bind(upstreamRequestID, to: 11, in: statement)
                bind(error, to: 12, in: statement)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw LoggerStorageError.stepFailed(message: errorMessage(from: database))
                }
                let insertedID = sqlite3_last_insert_rowid(database)
                try insertContentIfNeeded(
                    serializeContent(request: request, response: response),
                    requestID: insertedID,
                    in: database
                )
            }
        } catch let dbError {
            ProxyLogger.log("ProxyEventLogger: failed to log request failed: \(dbError)")
        }
    }

    // MARK: - Keepalive logging

    func logKeepaliveSent(session: String) -> Int64? {
        guard enabled else { return nil }
        do {
            let database = try openDatabaseIfNeeded()
            try pruneExpiredIfNeeded(in: database)
            let sql = "INSERT INTO proxy_keepalives (session, started_at) VALUES (?, ?)"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                throw LoggerStorageError.prepareFailed(message: errorMessage(from: database))
            }
            defer { sqlite3_finalize(statement) }
            bind(session, to: 1, in: statement)
            bind(isoFormatter.string(from: Date()), to: 2, in: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw LoggerStorageError.stepFailed(message: errorMessage(from: database))
            }
            return sqlite3_last_insert_rowid(database)
        } catch {
            ProxyLogger.log("ProxyEventLogger: failed to log keepalive sent: \(error)")
            return nil
        }
    }

    func logKeepaliveCompleted(
        keepaliveID: Int64?,
        session: String,
        success: Bool,
        statusCode: Int?,
        durationMs: Int,
        upstreamRequestID: String?,
        tokenUsage: TokenUsage,
        error: String?
    ) {
        guard enabled else { return }
        do {
            let database = try openDatabaseIfNeeded()
            if let keepaliveID {
                let sql = """
                    UPDATE proxy_keepalives SET
                        completed_at = ?, success = ?, status_code = ?, duration_ms = ?,
                        upstream_request_id = ?,
                        input_tokens = ?, output_tokens = ?,
                        cache_read_tokens = ?, cache_creation_tokens = ?,
                        error = ?
                    WHERE id = ?
                    """
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                    throw LoggerStorageError.prepareFailed(message: errorMessage(from: database))
                }
                defer { sqlite3_finalize(statement) }
                bind(isoFormatter.string(from: Date()), to: 1, in: statement)
                bind(success, to: 2, in: statement)
                bind(statusCode, to: 3, in: statement)
                bind(durationMs, to: 4, in: statement)
                bind(upstreamRequestID, to: 5, in: statement)
                bind(tokenUsage.inputTokens, to: 6, in: statement)
                bind(tokenUsage.outputTokens, to: 7, in: statement)
                bind(tokenUsage.cacheReadInputTokens, to: 8, in: statement)
                bind(tokenUsage.cacheCreationInputTokens, to: 9, in: statement)
                bind(error, to: 10, in: statement)
                bind(keepaliveID, to: 11, in: statement)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw LoggerStorageError.stepFailed(message: errorMessage(from: database))
                }
            } else {
                // Standalone INSERT for cases where logKeepaliveSent failed
                try pruneExpiredIfNeeded(in: database)
                let now = isoFormatter.string(from: Date())
                let sql = """
                    INSERT INTO proxy_keepalives (
                        session, started_at, completed_at, success, status_code, duration_ms,
                        upstream_request_id,
                        input_tokens, output_tokens,
                        cache_read_tokens, cache_creation_tokens,
                        error
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                    throw LoggerStorageError.prepareFailed(message: errorMessage(from: database))
                }
                defer { sqlite3_finalize(statement) }
                bind(session, to: 1, in: statement)
                bind(now, to: 2, in: statement)
                bind(now, to: 3, in: statement)
                bind(success, to: 4, in: statement)
                bind(statusCode, to: 5, in: statement)
                bind(durationMs, to: 6, in: statement)
                bind(upstreamRequestID, to: 7, in: statement)
                bind(tokenUsage.inputTokens, to: 8, in: statement)
                bind(tokenUsage.outputTokens, to: 9, in: statement)
                bind(tokenUsage.cacheReadInputTokens, to: 10, in: statement)
                bind(tokenUsage.cacheCreationInputTokens, to: 11, in: statement)
                bind(error, to: 12, in: statement)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw LoggerStorageError.stepFailed(message: errorMessage(from: database))
                }
            }
        } catch {
            ProxyLogger.log("ProxyEventLogger: failed to log keepalive completed: \(error)")
        }
    }

    // MARK: - Lifecycle logging

    func logProxyStarted(port: Int) {
        insertLifecycleEvent(type: "proxy_started", port: port)
    }

    func logProxyStopped() {
        insertLifecycleEvent(type: "proxy_stopped")
    }

    func logSessionExpired(session: String) {
        insertLifecycleEvent(type: "session_expired", session: session)
    }

    func logKeepaliveDisabled(session: String, reason: String, failureCount: Int) {
        insertLifecycleEvent(type: "keepalive_disabled", session: session, reason: reason, failureCount: failureCount)
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

    // MARK: - Private: Database lifecycle

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

            // Migration: drop legacy tables
            try execute("DROP TABLE IF EXISTS proxy_event_content;", in: database)
            try execute("DROP TABLE IF EXISTS proxy_events;", in: database)

            try execute(
                """
                CREATE TABLE IF NOT EXISTS proxy_requests (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    session TEXT NOT NULL,
                    model TEXT,
                    method TEXT NOT NULL,
                    path TEXT NOT NULL,
                    upstream_url TEXT NOT NULL,
                    streaming INTEGER NOT NULL,
                    started_at TEXT NOT NULL,
                    completed_at TEXT,
                    status_code INTEGER,
                    duration_ms INTEGER,
                    upstream_request_id TEXT,
                    input_tokens INTEGER,
                    output_tokens INTEGER,
                    cache_read_tokens INTEGER,
                    cache_creation_tokens INTEGER,
                    error TEXT,
                    errored INTEGER
                );
                """,
                in: database
            )

            try execute(
                """
                CREATE TABLE IF NOT EXISTS proxy_keepalives (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    session TEXT NOT NULL,
                    started_at TEXT NOT NULL,
                    completed_at TEXT,
                    success INTEGER,
                    status_code INTEGER,
                    duration_ms INTEGER,
                    upstream_request_id TEXT,
                    input_tokens INTEGER,
                    output_tokens INTEGER,
                    cache_read_tokens INTEGER,
                    cache_creation_tokens INTEGER,
                    error TEXT
                );
                """,
                in: database
            )

            try execute(
                """
                CREATE TABLE IF NOT EXISTS proxy_lifecycle (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    ts TEXT NOT NULL,
                    type TEXT NOT NULL,
                    session TEXT,
                    port INTEGER,
                    reason TEXT,
                    failure_count INTEGER
                );
                """,
                in: database
            )

            try execute(
                """
                CREATE TABLE IF NOT EXISTS proxy_request_content (
                    request_id INTEGER PRIMARY KEY,
                    upstream_request_id TEXT,
                    request_json TEXT,
                    response_json TEXT,
                    FOREIGN KEY(request_id) REFERENCES proxy_requests(id) ON DELETE CASCADE
                );
                """,
                in: database
            )

            // Indexes
            try execute("CREATE INDEX IF NOT EXISTS idx_proxy_requests_started_at ON proxy_requests(started_at);", in: database)
            try execute("CREATE INDEX IF NOT EXISTS idx_proxy_requests_session ON proxy_requests(session, started_at);", in: database)
            try execute("CREATE INDEX IF NOT EXISTS idx_proxy_requests_model ON proxy_requests(model, started_at);", in: database)
            try execute("CREATE INDEX IF NOT EXISTS idx_proxy_requests_status ON proxy_requests(status_code, started_at);", in: database)
            try execute("CREATE INDEX IF NOT EXISTS idx_proxy_requests_upstream_rid ON proxy_requests(upstream_request_id);", in: database)
            try execute("CREATE INDEX IF NOT EXISTS idx_proxy_keepalives_started_at ON proxy_keepalives(started_at);", in: database)
            try execute("CREATE INDEX IF NOT EXISTS idx_proxy_keepalives_session ON proxy_keepalives(session, started_at);", in: database)
            try execute("CREATE INDEX IF NOT EXISTS idx_proxy_lifecycle_ts ON proxy_lifecycle(ts);", in: database)
            try execute("CREATE INDEX IF NOT EXISTS idx_proxy_request_content_upstream_rid ON proxy_request_content(upstream_request_id);", in: database)
        } catch {
            sqlite3_close(database)
            throw error
        }

        self.database = database
        return database
    }

    // MARK: - Private: Pruning

    private func pruneExpiredIfNeeded(in database: OpaquePointer) throws {
        let now = Date()
        if let lastPruneAt, now.timeIntervalSince(lastPruneAt) < Self.pruneInterval {
            return
        }
        let cutoff = isoFormatter.string(from: now.addingTimeInterval(-Self.maxEventAge))
        // proxy_request_content is CASCADE-deleted via proxy_requests FK
        try executePrune("DELETE FROM proxy_requests WHERE started_at < ?;", cutoff: cutoff, in: database)
        try executePrune("DELETE FROM proxy_keepalives WHERE started_at < ?;", cutoff: cutoff, in: database)
        try executePrune("DELETE FROM proxy_lifecycle WHERE ts < ?;", cutoff: cutoff, in: database)
        try execute("PRAGMA wal_checkpoint(PASSIVE);", in: database)
        lastPruneAt = now
    }

    private func executePrune(_ sql: String, cutoff: String, in database: OpaquePointer) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw LoggerStorageError.prepareFailed(message: errorMessage(from: database))
        }
        defer { sqlite3_finalize(statement) }
        bind(cutoff, to: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw LoggerStorageError.stepFailed(message: errorMessage(from: database))
        }
    }

    // MARK: - Private: Lifecycle event insertion

    private func insertLifecycleEvent(
        type: String,
        session: String? = nil,
        port: Int? = nil,
        reason: String? = nil,
        failureCount: Int? = nil
    ) {
        guard enabled else { return }
        do {
            let database = try openDatabaseIfNeeded()
            let sql = """
                INSERT INTO proxy_lifecycle (ts, type, session, port, reason, failure_count)
                VALUES (?, ?, ?, ?, ?, ?)
                """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                throw LoggerStorageError.prepareFailed(message: errorMessage(from: database))
            }
            defer { sqlite3_finalize(statement) }
            bind(isoFormatter.string(from: Date()), to: 1, in: statement)
            bind(type, to: 2, in: statement)
            bind(session, to: 3, in: statement)
            bind(port, to: 4, in: statement)
            bind(reason, to: 5, in: statement)
            bind(failureCount, to: 6, in: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw LoggerStorageError.stepFailed(message: errorMessage(from: database))
            }
        } catch {
            ProxyLogger.log("ProxyEventLogger: failed to log lifecycle event: \(error)")
        }
    }

    // MARK: - Private: Content serialization

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

    // MARK: - Private: Content insertion

    private func insertContentIfNeeded(_ content: EventContent?, requestID: Int64, in database: OpaquePointer) throws {
        guard capturesContent, let content else { return }

        let sql = """
            INSERT OR REPLACE INTO proxy_request_content (
                request_id, upstream_request_id, request_json, response_json
            ) VALUES (?, ?, ?, ?)
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw LoggerStorageError.prepareFailed(message: errorMessage(from: database))
        }
        defer { sqlite3_finalize(statement) }

        bind(requestID, to: 1, in: statement)
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

    // MARK: - Private: Status snapshot helpers

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

    // MARK: - Private: SQLite helpers

    private func execute(_ sql: String, in database: OpaquePointer) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw LoggerStorageError.execFailed(message: errorMessage(from: database))
        }
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

    // MARK: - Errors

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
