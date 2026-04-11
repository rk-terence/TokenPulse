import Foundation

/// Tracks active Claude Code sessions by their `X-Claude-Code-Session-Id`.
actor ProxySessionStore {

    struct Session: Sendable {
        let sessionID: String
        var lastSeenAt: Date
        var inFlightRequestCount: Int
        // Phase 2 additions:
        var lastRequestBody: Data?
        var lastKnownModel: String?
        var lastKeepaliveAt: Date?
        var keepaliveSuccessCount: Int
        var keepaliveFailureCount: Int
        var lastCacheReadTokens: Int?
        var lastCacheCreationTokens: Int?
    }

    private var sessions: [String: Session] = [:]

    /// Record that a session was seen (creates it if new) and return its state.
    @discardableResult
    func touch(_ sessionID: String) -> Session {
        let now = Date()
        if var existing = sessions[sessionID] {
            existing.lastSeenAt = now
            sessions[sessionID] = existing
            return existing
        } else {
            let session = Session(
                sessionID: sessionID,
                lastSeenAt: now,
                inFlightRequestCount: 0,
                lastRequestBody: nil,
                lastKnownModel: nil,
                lastKeepaliveAt: nil,
                keepaliveSuccessCount: 0,
                keepaliveFailureCount: 0,
                lastCacheReadTokens: nil,
                lastCacheCreationTokens: nil
            )
            sessions[sessionID] = session
            return session
        }
    }

    func incrementInFlight(_ sessionID: String) {
        if var session = sessions[sessionID] {
            session.inFlightRequestCount += 1
            sessions[sessionID] = session
        }
    }

    func decrementInFlight(_ sessionID: String) {
        if var session = sessions[sessionID] {
            session.inFlightRequestCount = max(0, session.inFlightRequestCount - 1)
            sessions[sessionID] = session
        }
    }

    func activeSessions() -> [Session] {
        Array(sessions.values)
    }

    /// Count of sessions that have been seen recently (within the given interval)
    /// or still have in-flight requests.
    func recentSessionCount(within interval: TimeInterval) -> Int {
        let cutoff = Date().addingTimeInterval(-interval)
        return sessions.values.filter { session in
            session.inFlightRequestCount > 0 || session.lastSeenAt >= cutoff
        }.count
    }

    /// Look up a single session by ID.
    func session(for sessionID: String) -> Session? {
        sessions[sessionID]
    }

    // MARK: - Phase 2 keepalive support

    /// Store the most recent request body and model for a session.
    func storeRequestBody(_ body: Data, model: String?, for sessionID: String) {
        if var session = sessions[sessionID] {
            session.lastRequestBody = body
            session.lastKnownModel = model
            sessions[sessionID] = session
        }
    }

    /// Retrieve the last stored request body for keepalive use.
    func lastRequestBody(for sessionID: String) -> Data? {
        sessions[sessionID]?.lastRequestBody
    }

    /// Record keepalive result for a session.
    func recordKeepaliveResult(
        for sessionID: String,
        success: Bool,
        cacheReadTokens: Int?,
        cacheCreationTokens: Int?
    ) {
        if var session = sessions[sessionID] {
            session.lastKeepaliveAt = Date()
            if success {
                session.keepaliveSuccessCount += 1
                session.keepaliveFailureCount = 0
            } else {
                session.keepaliveFailureCount += 1
            }
            session.lastCacheReadTokens = cacheReadTokens
            session.lastCacheCreationTokens = cacheCreationTokens
            sessions[sessionID] = session
        }
    }

    /// Remove sessions that haven't been seen since the given date.
    /// Skips sessions with in-flight requests to avoid dropping state mid-stream.
    /// Returns the session IDs that were removed.
    func expireSessions(olderThan date: Date) -> [String] {
        var expired: [String] = []
        for (id, session) in sessions
            where session.lastSeenAt < date && session.inFlightRequestCount == 0 {
            expired.append(id)
        }
        for id in expired {
            sessions.removeValue(forKey: id)
        }
        return expired
    }
}
