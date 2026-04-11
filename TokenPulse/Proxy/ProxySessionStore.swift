import Foundation

/// Tracks active Claude Code sessions by their `X-Claude-Code-Session-Id`.
/// Phase 1 only stores session existence and in-flight request counts.
actor ProxySessionStore {

    struct Session: Sendable {
        let sessionID: String
        var lastSeenAt: Date
        var inFlightRequestCount: Int
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
            let session = Session(sessionID: sessionID, lastSeenAt: now, inFlightRequestCount: 0)
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
}
