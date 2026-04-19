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
    /// Bump when adding columns/tables that require an incompatible rewrite.
    /// On mismatch the whole database is dropped (24h retention means no meaningful loss).
    /// v5: content-tree refactor. `proxy_lineage_segments` removed; replaced by
    /// `proxy_nodes` where each node stores only its delta against its parent.
    /// `proxy_requests.segment_id`/`tail_index` → `node_id`. Body refs changed
    /// to `{conversation_id, node_id}`. `proxy_conversations` gained
    /// `root_node_id`.
    private static let currentSchemaVersion: Int = 5

    struct LoggedRequest: Sendable {
        let method: String
        let path: String
        let upstreamURL: String
        let headers: [(name: String, value: String)]
        let body: Data
        let streaming: Bool
    }

    /// Content-tree context associated with a request. Supplied by callers so
    /// we can write `conversation_id` / `node_id` into `proxy_requests` and
    /// replace the heavy `messages` / `input` field in the body with a compact
    /// reference. Nodes are immutable after creation, so mirror writes are
    /// append-only: insert the root (for brand-new conversations) and the
    /// target node (always) — everything in between was already persisted
    /// when it was the target of its own creating request.
    struct LineageContext: Sendable {
        let conversationID: UUID
        let nodeID: UUID
        let rootNodeID: UUID
        let previousResponseID: String?
        let fingerprintHash: String
        /// Full fingerprint serialized so the conversations table can
        /// rematerialize model / system / tools / thinking without re-parsing
        /// every request body.
        let fingerprint: LineageFingerprint
        let flavor: ProxyAPIFlavor
        /// Root node row — inserted on conversation creation and ignored on
        /// every subsequent mirror pass (INSERT OR IGNORE).
        let rootNodeRow: NodeRow
        /// Target node row — inserted on first mirror of that node and ignored
        /// thereafter (same node keeps the same immutable delta).
        let targetNodeRow: NodeRow

        struct NodeRow: Sendable {
            let id: UUID
            let parentNodeID: UUID?
            let deltaMessagesJSON: String
        }
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
        let metrics: ProxyMetricsStore.Snapshot
    }

    private struct EventContent {
        let upstreamRequestID: String?
        let requestJSON: String?
        let responseJSON: String?
    }

    // MARK: - Properties

    let enabled: Bool

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

    init(enabled: Bool) {
        self.enabled = enabled
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
        errored: Bool,
        lineage: LineageContext? = nil,
        responseID: String? = nil
    ) {
        guard enabled else { return }
        do {
            let database = try openDatabaseIfNeeded()
            if let lineage {
                try mirrorLineage(lineage, in: database)
            }
            if let requestID {
                let sql = """
                    UPDATE proxy_requests SET
                        session = ?, completed_at = ?, status_code = ?, duration_ms = ?,
                        upstream_request_id = ?,
                        input_tokens = ?, output_tokens = ?,
                        cache_read_tokens = ?, cache_creation_tokens = ?,
                        errored = ?,
                        conversation_id = ?, node_id = ?,
                        response_id = ?, previous_response_id = ?, done = ?
                    WHERE id = ?
                    """
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                    throw LoggerStorageError.prepareFailed(message: errorMessage(from: database))
                }
                defer { sqlite3_finalize(statement) }
                bind(session, to: 1, in: statement)
                bind(isoFormatter.string(from: Date()), to: 2, in: statement)
                bind(statusCode, to: 3, in: statement)
                bind(durationMs, to: 4, in: statement)
                bind(extractUpstreamRequestID(from: response.headers), to: 5, in: statement)
                bind(tokenUsage.inputTokens, to: 6, in: statement)
                bind(tokenUsage.outputTokens, to: 7, in: statement)
                bind(tokenUsage.cacheReadInputTokens, to: 8, in: statement)
                bind(tokenUsage.cacheCreationInputTokens, to: 9, in: statement)
                bind(errored, to: 10, in: statement)
                bind(lineage?.conversationID.uuidString, to: 11, in: statement)
                bind(lineage?.nodeID.uuidString, to: 12, in: statement)
                bind(responseID, to: 13, in: statement)
                bind(lineage?.previousResponseID, to: 14, in: statement)
                bind(!errored, to: 15, in: statement)
                bind(requestID, to: 16, in: statement)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw LoggerStorageError.stepFailed(message: errorMessage(from: database))
                }
                try insertContentIfNeeded(
                    serializeContent(request: request, response: response, lineage: lineage),
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
                        errored,
                        conversation_id, node_id,
                        response_id, previous_response_id, done
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                bind(lineage?.conversationID.uuidString, to: 17, in: statement)
                bind(lineage?.nodeID.uuidString, to: 18, in: statement)
                bind(responseID, to: 19, in: statement)
                bind(lineage?.previousResponseID, to: 20, in: statement)
                bind(!errored, to: 21, in: statement)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw LoggerStorageError.stepFailed(message: errorMessage(from: database))
                }
                let insertedID = sqlite3_last_insert_rowid(database)
                try insertContentIfNeeded(
                    serializeContent(request: request, response: response, lineage: lineage),
                    requestID: insertedID,
                    in: database
                )
            }
        } catch {
            ProxyLogger.log("ProxyEventLogger: failed to log request completed: \(error)")
        }
    }

    // MARK: - Lineage mirror

    private func mirrorLineage(_ context: LineageContext, in database: OpaquePointer) throws {
        let now = isoFormatter.string(from: Date())
        // Serialize the full fingerprint so every conversation row captures
        // the cache-identity payload (model + system + tools + tool_choice +
        // thinking). Keep-alive and diagnostics can rebuild a valid replay
        // body without needing the original request.
        let fingerprintJSON: String
        if let data = try? JSONEncoder().encode(context.fingerprint),
           let text = String(data: data, encoding: .utf8) {
            fingerprintJSON = text
        } else {
            fingerprintJSON = "{}"
        }
        // Upsert conversation. `root_node_id` is set once on first insert and
        // never changes; the upsert path refreshes `last_seen` only.
        do {
            let sql = """
                INSERT INTO proxy_conversations
                    (id, flavor, fingerprint_hash, fingerprint_json, root_node_id, first_seen, last_seen)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    fingerprint_json = excluded.fingerprint_json,
                    last_seen = excluded.last_seen
                """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                throw LoggerStorageError.prepareFailed(message: errorMessage(from: database))
            }
            defer { sqlite3_finalize(statement) }
            bind(context.conversationID.uuidString, to: 1, in: statement)
            bind(context.flavor.rawValue, to: 2, in: statement)
            bind(context.fingerprintHash, to: 3, in: statement)
            bind(fingerprintJSON, to: 4, in: statement)
            bind(context.rootNodeID.uuidString, to: 5, in: statement)
            bind(now, to: 6, in: statement)
            bind(now, to: 7, in: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw LoggerStorageError.stepFailed(message: errorMessage(from: database))
            }
        }
        // Insert root and target nodes. Nodes are immutable after creation
        // (deltas never change) so INSERT OR IGNORE is the right conflict
        // policy — the first request in a conversation writes the row; later
        // requests attaching to the same node skip. Each request thus pays
        // at most two INSERTs, regardless of conversation depth.
        try insertNodeRow(context.rootNodeRow, conversationID: context.conversationID, now: now, in: database)
        if context.targetNodeRow.id != context.rootNodeRow.id {
            try insertNodeRow(context.targetNodeRow, conversationID: context.conversationID, now: now, in: database)
        }
        // Refresh the target node's `last_activity` so pruning by last-seen
        // works even for long-lived leaves.
        do {
            let sql = "UPDATE proxy_nodes SET last_activity = ? WHERE id = ?;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                throw LoggerStorageError.prepareFailed(message: errorMessage(from: database))
            }
            defer { sqlite3_finalize(statement) }
            bind(now, to: 1, in: statement)
            bind(context.nodeID.uuidString, to: 2, in: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw LoggerStorageError.stepFailed(message: errorMessage(from: database))
            }
        }
    }

    private func insertNodeRow(
        _ row: LineageContext.NodeRow,
        conversationID: UUID,
        now: String,
        in database: OpaquePointer
    ) throws {
        let sql = """
            INSERT OR IGNORE INTO proxy_nodes
                (id, conversation_id, parent_node_id, delta_messages_json, last_activity)
            VALUES (?, ?, ?, ?, ?)
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw LoggerStorageError.prepareFailed(message: errorMessage(from: database))
        }
        defer { sqlite3_finalize(statement) }
        bind(row.id.uuidString, to: 1, in: statement)
        bind(conversationID.uuidString, to: 2, in: statement)
        bind(row.parentNodeID?.uuidString, to: 3, in: statement)
        bind(row.deltaMessagesJSON, to: 4, in: statement)
        bind(now, to: 5, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw LoggerStorageError.stepFailed(message: errorMessage(from: database))
        }
    }

    /// Remove lineage rows whose tree-side counterparts were just pruned.
    /// Nodes and conversations cascade via `ON DELETE CASCADE`; request rows
    /// retain their IDs but have `node_id`/`conversation_id` NULLed by
    /// `ON DELETE SET NULL`.
    func pruneLineageMirror(
        conversationIDs: Set<UUID>,
        nodeIDs: Set<UUID>
    ) {
        guard enabled else { return }
        guard !conversationIDs.isEmpty || !nodeIDs.isEmpty else { return }
        do {
            let database = try openDatabaseIfNeeded()
            for id in nodeIDs {
                try executeDelete(
                    "DELETE FROM proxy_nodes WHERE id = ?;",
                    value: id.uuidString,
                    in: database
                )
            }
            for id in conversationIDs {
                try executeDelete(
                    "DELETE FROM proxy_conversations WHERE id = ?;",
                    value: id.uuidString,
                    in: database
                )
            }
        } catch {
            ProxyLogger.log("ProxyEventLogger: failed to prune lineage mirror: \(error)")
        }
    }

    private func executeDelete(_ sql: String, value: String, in database: OpaquePointer) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw LoggerStorageError.prepareFailed(message: errorMessage(from: database))
        }
        defer { sqlite3_finalize(statement) }
        bind(value, to: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw LoggerStorageError.stepFailed(message: errorMessage(from: database))
        }
    }

    func logRequestFailed(
        requestID: Int64?,
        session: String,
        model: String?,
        request: LoggedRequest,
        response: LoggedResponse?,
        durationMs: Int,
        error: String,
        lineage: LineageContext? = nil,
        responseID: String? = nil
    ) {
        guard enabled else { return }
        do {
            let database = try openDatabaseIfNeeded()
            // Failed requests that carry a `lineage` context must still have
            // their conversation / node rows mirrored, otherwise the
            // `body_refs` we stash in `proxy_request_content` point at rows
            // that were never written — readers would have no way to
            // reconstruct the original messages for a failure diagnosis.
            if let lineage {
                try mirrorLineage(lineage, in: database)
            }
            let upstreamRequestID = response.flatMap { extractUpstreamRequestID(from: $0.headers) }
            let statusCode = response?.statusCode

            if let requestID {
                // UPDATE existing row
                let sql = """
                    UPDATE proxy_requests SET
                        session = ?, completed_at = ?, status_code = ?, duration_ms = ?,
                        upstream_request_id = ?, error = ?, errored = 1,
                        conversation_id = ?, node_id = ?,
                        response_id = ?, previous_response_id = ?
                    WHERE id = ?
                    """
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                    throw LoggerStorageError.prepareFailed(message: errorMessage(from: database))
                }
                defer { sqlite3_finalize(statement) }
                bind(session, to: 1, in: statement)
                bind(isoFormatter.string(from: Date()), to: 2, in: statement)
                bind(statusCode, to: 3, in: statement)
                bind(durationMs, to: 4, in: statement)
                bind(upstreamRequestID, to: 5, in: statement)
                bind(error, to: 6, in: statement)
                bind(lineage?.conversationID.uuidString, to: 7, in: statement)
                bind(lineage?.nodeID.uuidString, to: 8, in: statement)
                bind(responseID, to: 9, in: statement)
                bind(lineage?.previousResponseID, to: 10, in: statement)
                bind(requestID, to: 11, in: statement)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw LoggerStorageError.stepFailed(message: errorMessage(from: database))
                }
                try insertContentIfNeeded(
                    serializeContent(request: request, response: response, lineage: lineage),
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
                        upstream_request_id, error, errored,
                        conversation_id, node_id,
                        response_id, previous_response_id
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?)
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
                bind(lineage?.conversationID.uuidString, to: 13, in: statement)
                bind(lineage?.nodeID.uuidString, to: 14, in: statement)
                bind(responseID, to: 15, in: statement)
                bind(lineage?.previousResponseID, to: 16, in: statement)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw LoggerStorageError.stepFailed(message: errorMessage(from: database))
                }
                let insertedID = sqlite3_last_insert_rowid(database)
                try insertContentIfNeeded(
                    serializeContent(request: request, response: response, lineage: lineage),
                    requestID: insertedID,
                    in: database
                )
            }
        } catch let dbError {
            ProxyLogger.log("ProxyEventLogger: failed to log request failed: \(dbError)")
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

    // MARK: - Status snapshot

    func writeStatusSnapshot(
        enabled proxyEnabled: Bool,
        port: Int,
        activeSessions: Int,
        metrics: ProxyMetricsStore.Snapshot,
        force: Bool = false
    ) {
        guard self.enabled else { return }

        let snapshot = StatusSnapshot(
            proxyEnabled: proxyEnabled,
            port: port,
            activeSessions: activeSessions,
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

            // Check schema version; on mismatch drop all known tables and rebuild.
            try execute(
                "CREATE TABLE IF NOT EXISTS proxy_schema (version INTEGER PRIMARY KEY);",
                in: database
            )
            let persistedVersion = readSchemaVersion(in: database)
            if persistedVersion != Self.currentSchemaVersion {
                let dropTables = [
                    "proxy_event_content", "proxy_events", "proxy_keepalives",
                    "proxy_request_content", "proxy_requests",
                    "proxy_lineage_segments", "proxy_nodes", "proxy_conversations",
                    "proxy_lifecycle"
                ]
                for table in dropTables {
                    try execute("DROP TABLE IF EXISTS \(table);", in: database)
                }
                try execute("DELETE FROM proxy_schema;", in: database)
                try execute(
                    "INSERT INTO proxy_schema (version) VALUES (\(Self.currentSchemaVersion));",
                    in: database
                )
            }

            try execute(
                """
                CREATE TABLE IF NOT EXISTS proxy_conversations (
                    id TEXT PRIMARY KEY,
                    flavor TEXT NOT NULL,
                    fingerprint_hash TEXT NOT NULL,
                    fingerprint_json TEXT NOT NULL,
                    root_node_id TEXT NOT NULL,
                    first_seen TEXT NOT NULL,
                    last_seen TEXT NOT NULL
                );
                """,
                in: database
            )

            try execute(
                """
                CREATE TABLE IF NOT EXISTS proxy_nodes (
                    id TEXT PRIMARY KEY,
                    conversation_id TEXT NOT NULL REFERENCES proxy_conversations(id) ON DELETE CASCADE,
                    parent_node_id TEXT REFERENCES proxy_nodes(id) ON DELETE CASCADE,
                    delta_messages_json TEXT NOT NULL,
                    last_activity TEXT NOT NULL
                );
                """,
                in: database
            )

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
                    errored INTEGER,
                    conversation_id TEXT REFERENCES proxy_conversations(id) ON DELETE SET NULL,
                    node_id TEXT REFERENCES proxy_nodes(id) ON DELETE SET NULL,
                    response_id TEXT,
                    previous_response_id TEXT,
                    done INTEGER NOT NULL DEFAULT 0
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
                    request_extras_json TEXT,
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
            try execute("CREATE INDEX IF NOT EXISTS idx_proxy_requests_conversation ON proxy_requests(conversation_id);", in: database)
            try execute("CREATE INDEX IF NOT EXISTS idx_proxy_requests_node ON proxy_requests(node_id);", in: database)
            try execute("CREATE INDEX IF NOT EXISTS idx_proxy_requests_response ON proxy_requests(response_id);", in: database)
            try execute("CREATE INDEX IF NOT EXISTS idx_proxy_lifecycle_ts ON proxy_lifecycle(ts);", in: database)
            try execute("CREATE INDEX IF NOT EXISTS idx_proxy_request_content_upstream_rid ON proxy_request_content(upstream_request_id);", in: database)
            try execute("CREATE INDEX IF NOT EXISTS idx_proxy_conversations_fingerprint ON proxy_conversations(fingerprint_hash);", in: database)
            try execute("CREATE INDEX IF NOT EXISTS idx_proxy_nodes_conversation ON proxy_nodes(conversation_id);", in: database)
            try execute("CREATE INDEX IF NOT EXISTS idx_proxy_nodes_parent ON proxy_nodes(parent_node_id);", in: database)
        } catch {
            sqlite3_close(database)
            throw error
        }

        self.database = database
        return database
    }

    private func readSchemaVersion(in database: OpaquePointer) -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT version FROM proxy_schema LIMIT 1;", -1, &statement, nil) == SQLITE_OK else {
            return 0
        }
        defer { sqlite3_finalize(statement) }
        if sqlite3_step(statement) == SQLITE_ROW {
            return Int(sqlite3_column_int64(statement, 0))
        }
        return 0
    }

    // MARK: - Private: Pruning

    private func pruneExpiredIfNeeded(in database: OpaquePointer) throws {
        let now = Date()
        if let lastPruneAt, now.timeIntervalSince(lastPruneAt) < Self.pruneInterval {
            return
        }
        let cutoff = isoFormatter.string(from: now.addingTimeInterval(-Self.maxEventAge))
        // proxy_request_content is CASCADE-deleted via proxy_requests FK.
        try executePrune("DELETE FROM proxy_requests WHERE started_at < ?;", cutoff: cutoff, in: database)
        try executePrune("DELETE FROM proxy_lifecycle WHERE ts < ?;", cutoff: cutoff, in: database)
        // Lineage mirror: in-memory `LineageTree.prune(...)` drives `pruneLineageMirror`
        // while the app is running, but after a restart the tree starts empty and
        // can no longer emit pruning IDs for rows left over from prior runs. Sweep
        // by `last_seen`/`last_activity` here so the mirror tables bound their disk
        // use across restarts. `proxy_requests.conversation_id`/`node_id` use
        // ON DELETE SET NULL so historical request rows survive; nodes CASCADE
        // through `conversations` → `parent_node_id` so a single delete on the
        // conversations table is enough to evict the whole subtree.
        try executePrune("DELETE FROM proxy_conversations WHERE last_seen < ?;", cutoff: cutoff, in: database)
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

    private func serializeContent(
        request: LoggedRequest?,
        response: LoggedResponse?,
        lineage: LineageContext?
    ) -> EventContent? {
        let requestJSON = request.flatMap { jsonString(for: serializeContent(request: $0, lineage: lineage)) }
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

    private func serializeContent(request: LoggedRequest, lineage: LineageContext?) -> [String: Any] {
        [
            "method": request.method,
            "path": request.path,
            "upstreamURL": request.upstreamURL,
            "streaming": request.streaming,
            "headers": serialize(headers: request.headers),
            "body": serializeBodyContent(body: request.body, lineage: lineage),
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
        serializeBodyContent(body: body, byteCount: byteCount, truncated: truncated, lineage: nil)
    }

    /// When `lineage` is non-nil and the body is JSON, strip the cache-identity
    /// fields (already stored once on `proxy_conversations.fingerprint_json`)
    /// and the messages/input array (already stored as per-node deltas in
    /// `proxy_nodes.delta_messages_json`), keeping only per-request extras
    /// plus refs back to the conversation and node.
    ///
    /// Resulting shape (JSON-encoded into `body.text`):
    ///   {
    ///     "body_extras": { max_tokens, stream, temperature, stop_sequences, metadata, ... },
    ///     "body_refs":   {
    ///       "fingerprint":     "<conversation uuid>",
    ///       "content":         { "node_id": "<node uuid>" }
    ///     }
    ///   }
    /// A reader rebuilds the original request body by expanding `fingerprint`
    /// to the conversation's `fingerprint_json` fields and `content.node_id`
    /// to a messages array reconstructed by walking `parent_node_id` from the
    /// node up to the root and concatenating each node's delta.
    private func serializeBodyContent(
        body: Data,
        byteCount: Int? = nil,
        truncated: Bool = false,
        lineage: LineageContext?
    ) -> [String: Any] {
        var serialized: [String: Any] = ["bytes": byteCount ?? body.count]
        if truncated {
            serialized["truncated"] = true
        }
        if let lineage,
           var json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            let fingerprintKeys: [String]
            let messagesKey: String
            switch lineage.flavor {
            case .anthropicMessages:
                fingerprintKeys = ["model", "system", "tools", "tool_choice", "thinking"]
                messagesKey = "messages"
            case .openAIResponses:
                fingerprintKeys = ["model", "instructions", "tools", "tool_choice", "reasoning"]
                messagesKey = "input"
            }
            for key in fingerprintKeys {
                json.removeValue(forKey: key)
            }
            json.removeValue(forKey: messagesKey)
            // `previous_response_id` is captured on `proxy_requests.previous_response_id`.
            json.removeValue(forKey: "previous_response_id")

            let refs: [String: Any] = [
                "fingerprint": lineage.conversationID.uuidString,
                "content": [
                    "node_id": lineage.nodeID.uuidString,
                ],
            ]
            let compact: [String: Any] = [
                "body_extras": json,
                "body_refs": refs,
            ]
            if let collapsed = try? JSONSerialization.data(withJSONObject: compact, options: [.sortedKeys]),
               let text = String(data: collapsed, encoding: .utf8) {
                serialized["encoding"] = "utf8-refs"
                serialized["text"] = text
                return serialized
            }
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
        guard let content else { return }

        let sql = """
            INSERT OR REPLACE INTO proxy_request_content (
                request_id, upstream_request_id, request_extras_json, response_json
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
            "totalRequestsForwarded": snapshot.metrics.totalRequestsForwarded,
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
