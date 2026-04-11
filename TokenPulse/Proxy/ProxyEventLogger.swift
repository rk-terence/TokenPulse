import Foundation

/// Structured event logger for the proxy subsystem. Writes append-only JSONL
/// to `~/.tokenpulse/proxy_events.jsonl` and an atomic status snapshot to
/// `~/.tokenpulse/proxy_status.json`.
///
/// This is an actor (not `@MainActor`) — all file I/O happens off the main thread.
actor ProxyEventLogger {

    let enabled: Bool

    private let eventsFileURL: URL
    private let statusFileURL: URL
    private var fileHandle: FileHandle?
    private let isoFormatter: ISO8601DateFormatter

    private static let directory: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".tokenpulse", isDirectory: true)
    }()

    init(enabled: Bool) {
        self.enabled = enabled
        self.eventsFileURL = Self.directory.appendingPathComponent("proxy_events.jsonl")
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

    func logRequestStarted(session: String, model: String?) {
        var entry: [String: Any] = ["type": "request_started", "session": session]
        if let model { entry["model"] = model }
        appendEvent(entry)
    }

    func logRequestCompleted(
        session: String,
        model: String?,
        statusCode: Int,
        cacheReadTokens: Int?,
        cacheCreationTokens: Int?
    ) {
        var entry: [String: Any] = [
            "type": "request_completed",
            "session": session,
            "statusCode": statusCode,
        ]
        if let model { entry["model"] = model }
        if let cacheReadTokens { entry["cacheReadTokens"] = cacheReadTokens }
        if let cacheCreationTokens { entry["cacheCreationTokens"] = cacheCreationTokens }
        appendEvent(entry)
    }

    func logRequestFailed(session: String, error: String) {
        appendEvent([
            "type": "request_failed",
            "session": session,
            "error": error,
        ])
    }

    func logKeepaliveSent(session: String) {
        appendEvent([
            "type": "keepalive_sent",
            "session": session,
        ])
    }

    func logKeepaliveResult(
        session: String,
        success: Bool,
        cacheReadTokens: Int?,
        cacheCreationTokens: Int?,
        statusCode: Int?
    ) {
        var entry: [String: Any] = [
            "type": "keepalive_result",
            "session": session,
            "success": success,
        ]
        if let cacheReadTokens { entry["cacheReadTokens"] = cacheReadTokens }
        if let cacheCreationTokens { entry["cacheCreationTokens"] = cacheCreationTokens }
        if let statusCode { entry["statusCode"] = statusCode }
        appendEvent(entry)
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
        metrics: ProxyMetricsStore.Snapshot
    ) {
        guard self.enabled else { return }

        let snapshot: [String: Any] = [
            "enabled": proxyEnabled,
            "port": port,
            "activeSessions": activeSessions,
            "activeKeepalives": activeKeepalives,
            "totalRequestsForwarded": metrics.totalRequestsForwarded,
            "totalKeepalivesSent": metrics.totalKeepalivesSent,
            "totalKeepalivesFailed": metrics.totalKeepalivesFailed,
            "cacheReads": metrics.totalCacheReads,
            "cacheWrites": metrics.totalCacheWrites,
            "lastUpdatedAt": isoFormatter.string(from: Date()),
        ]

        do {
            let data = try JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys])
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            try data.write(to: statusFileURL, options: .atomic)
        } catch {
            ProxyLogger.log("ProxyEventLogger: failed to write status snapshot: \(error)")
        }
    }

    // MARK: - Cleanup

    func close() {
        try? fileHandle?.close()
        fileHandle = nil
    }

    // MARK: - Private

    private func appendEvent(_ fields: [String: Any]) {
        guard enabled else { return }

        var entry = fields
        entry["ts"] = isoFormatter.string(from: Date())

        guard let lineData = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else {
            return
        }

        var payload = lineData
        payload.append(contentsOf: [UInt8(ascii: "\n")])

        do {
            let handle = try openFileHandleIfNeeded()
            handle.seekToEndOfFile()
            handle.write(payload)
        } catch {
            ProxyLogger.log("ProxyEventLogger: failed to append event: \(error)")
        }
    }

    private func openFileHandleIfNeeded() throws -> FileHandle {
        if let handle = fileHandle {
            return handle
        }

        let fm = FileManager.default
        try fm.createDirectory(at: Self.directory, withIntermediateDirectories: true)

        if !fm.fileExists(atPath: eventsFileURL.path) {
            fm.createFile(atPath: eventsFileURL.path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: eventsFileURL)
        fileHandle = handle
        return handle
    }
}
