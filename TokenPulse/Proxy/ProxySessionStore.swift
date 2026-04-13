import Foundation

/// Tracks active Claude Code sessions by their `X-Claude-Code-Session-Id`.
actor ProxySessionStore {

    struct Session: Sendable {
        let sessionID: String
        var lastSeenAt: Date
        var inFlightRequestCount: Int
        // Phase 2 additions:
        var lastRequestBody: Data?
        var lastRequestHeaders: [(name: String, value: String)]
        var lastKnownModel: String?
        var lastKeepaliveAt: Date?
        var keepaliveSuccessCount: Int
        var keepaliveFailureCount: Int
        var lastCacheReadTokens: Int?
        var lastCacheCreationTokens: Int?
        var isKeepaliveDisabled: Bool
        // Per-session request counters (completed/errored real requests):
        var completedRequestCount: Int
        var erroredRequestCount: Int
        // Cumulative token usage and estimated cost:
        var totalInputTokens: Int
        var totalOutputTokens: Int
        var totalCacheReadInputTokens: Int
        var totalCacheCreationInputTokens: Int
        var estimatedCostUSD: Double
    }

    /// A snapshot of a session's stats and its currently active requests, for UI display.
    struct SessionSnapshot: Sendable {
        let sessionID: String
        let lastSeenAt: Date
        let lastKeepaliveAt: Date?
        let completedRequestCount: Int
        let erroredRequestCount: Int
        let keepaliveTotalCount: Int
        let activeRequests: [ProxyRequestActivity]
        let totalInputTokens: Int
        let totalOutputTokens: Int
        let totalCacheReadInputTokens: Int
        let totalCacheCreationInputTokens: Int
        let estimatedCostUSD: Double
    }

    private var sessions: [String: Session] = [:]
    /// In-flight requests keyed by their UUID, with the owning session ID stored alongside.
    private var activeRequests: [UUID: (sessionID: String, activity: ProxyRequestActivity)] = [:]

    // Byte counters for throughput and one-shot upload display.
    private var totalBytesReceived: Int = 0
    private var lastRequestBodyBytes: Int = 0

    /// Cumulative estimated cost (USD) across all sessions since the proxy started.
    /// Separate from per-session costs so it survives session expiration.
    private var cumulativeEstimatedCostUSD: Double = 0

    /// Callback fired when data traffic occurs (upload start or download chunk).
    /// Called from within the actor — callers should dispatch to MainActor as needed.
    private var onTraffic: (@Sendable () -> Void)?

    /// Set the traffic callback. Called from outside the actor isolation.
    func setTrafficCallback(_ callback: @escaping @Sendable () -> Void) {
        onTraffic = callback
    }

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
                lastRequestHeaders: [],
                lastKnownModel: nil,
                lastKeepaliveAt: nil,
                keepaliveSuccessCount: 0,
                keepaliveFailureCount: 0,
                lastCacheReadTokens: nil,
                lastCacheCreationTokens: nil,
                isKeepaliveDisabled: false,
                completedRequestCount: 0,
                erroredRequestCount: 0,
                totalInputTokens: 0,
                totalOutputTokens: 0,
                totalCacheReadInputTokens: 0,
                totalCacheCreationInputTokens: 0,
                estimatedCostUSD: 0
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
            session.inFlightRequestCount > 0
                || max(session.lastSeenAt, session.lastKeepaliveAt ?? .distantPast) >= cutoff
        }.count
    }

    /// Look up a single session by ID.
    func session(for sessionID: String) -> Session? {
        sessions[sessionID]
    }

    /// Mark a session's keepalive as permanently disabled (e.g. after cumulative failures).
    func disableKeepalive(for sessionID: String) {
        if var session = sessions[sessionID] {
            session.isKeepaliveDisabled = true
            sessions[sessionID] = session
        }
    }

    /// Whether keepalive has been disabled for a session.
    func isKeepaliveDisabled(for sessionID: String) -> Bool {
        sessions[sessionID]?.isKeepaliveDisabled ?? false
    }

    // MARK: - Phase 2 keepalive support

    /// Store the most recent request body, headers, and model for a session.
    func storeRequestContext(
        body: Data,
        headers: [(name: String, value: String)],
        model: String?,
        for sessionID: String
    ) {
        if var session = sessions[sessionID] {
            session.lastRequestBody = body
            session.lastRequestHeaders = headers
            session.lastKnownModel = model
            sessions[sessionID] = session
        }
    }

    /// Retrieve the last stored request body for keepalive use.
    func lastRequestBody(for sessionID: String) -> Data? {
        sessions[sessionID]?.lastRequestBody
    }

    /// Sessions that already have enough request context to arm keepalive immediately.
    func keepaliveBootstrapSessions() -> [(sessionID: String, headers: [(name: String, value: String)])] {
        sessions.values.compactMap { session in
            guard session.lastRequestBody != nil, !session.lastRequestHeaders.isEmpty else {
                return nil
            }
            return (sessionID: session.sessionID, headers: session.lastRequestHeaders)
        }
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
            } else {
                session.keepaliveFailureCount += 1
            }
            session.lastCacheReadTokens = cacheReadTokens
            session.lastCacheCreationTokens = cacheCreationTokens
            sessions[sessionID] = session
        }
    }

    // MARK: - Token usage accumulation

    /// Record token usage and estimated cost for a completed request in this session.
    func recordTokenUsage(_ usage: TokenUsage, model: String?, for sessionID: String) {
        guard var session = sessions[sessionID] else { return }
        session.totalInputTokens += usage.inputTokens ?? 0
        session.totalOutputTokens += usage.outputTokens ?? 0
        session.totalCacheReadInputTokens += usage.cacheReadInputTokens ?? 0
        session.totalCacheCreationInputTokens += usage.cacheCreationInputTokens ?? 0
        if let pricing = ModelPricingTable.pricing(for: model) {
            let cost = usage.cost(for: pricing)
            session.estimatedCostUSD += cost
            cumulativeEstimatedCostUSD += cost
        }
        sessions[sessionID] = session
    }

    /// Cumulative estimated cost since proxy start (survives session expiration).
    func totalEstimatedCostUSD() -> Double {
        cumulativeEstimatedCostUSD
    }

    /// Reset all transient counters while keeping sessions operational for keepalive.
    /// Preserves request context (body, headers, model) needed by keepalive loops.
    /// Reset only the cumulative cost estimate to zero. Per-session costs are preserved.
    func resetCost() {
        cumulativeEstimatedCostUSD = 0
    }

    // MARK: - Request activity tracking

    /// Register a new in-flight request. Call immediately before starting the upstream fetch.
    func startRequest(id: UUID, sessionID: String) {
        let activity = ProxyRequestActivity(
            id: id,
            state: .uploading,
            bytesSent: 0,
            bytesReceived: 0,
            lastDataAt: nil,
            startedAt: Date(),
            receivingStartedAt: nil,
            firstDataAt: nil,
            completedAt: nil
        )
        activeRequests[id] = (sessionID: sessionID, activity: activity)
        onTraffic?()
    }

    /// Transition a request from `.uploading` to `.waiting` once the upload is complete.
    func markRequestWaiting(id: UUID) {
        guard var entry = activeRequests[id] else { return }
        guard entry.activity.state == .uploading else { return }  // Only advance from .uploading
        entry.activity.state = .waiting
        entry.activity.lastDataAt = Date()
        activeRequests[id] = entry
        onTraffic?()
    }

    /// Transition a request from `.uploading` or `.waiting` to `.receiving` once response headers arrive.
    func markRequestReceiving(id: UUID) {
        guard var entry = activeRequests[id] else { return }
        guard entry.activity.state == .uploading || entry.activity.state == .waiting else { return }  // Only advance from .uploading or .waiting
        entry.activity.state = .receiving
        entry.activity.lastDataAt = Date()
        entry.activity.receivingStartedAt = Date()
        activeRequests[id] = entry
        onTraffic?()
    }

    /// Record the timestamp of the first upstream data chunk (once per request).
    /// This is more accurate than `receivingStartedAt` for TTFT measurement on
    /// streaming responses where headers may arrive before the first token.
    func markFirstDataReceived(id: UUID) {
        guard var entry = activeRequests[id] else { return }
        guard entry.activity.firstDataAt == nil else { return }  // Only record the first chunk
        entry.activity.firstDataAt = Date()
        activeRequests[id] = entry
        // No onTraffic call — updateRequestBytes follows immediately and handles that.
    }

    /// Update the cumulative bytes sent to upstream for a request.
    func updateRequestBytesSent(id: UUID, totalBytesSent: Int) {
        guard var entry = activeRequests[id] else { return }
        entry.activity.bytesSent = totalBytesSent
        activeRequests[id] = entry
        onTraffic?()
    }

    /// Accumulate bytes received and refresh the last-data timestamp.
    func updateRequestBytes(id: UUID, additionalBytes: Int) {
        guard var entry = activeRequests[id] else { return }
        entry.activity.bytesReceived += additionalBytes
        entry.activity.lastDataAt = Date()
        activeRequests[id] = entry
        totalBytesReceived += additionalBytes
        onTraffic?()
    }

    /// Record bytes sent upstream for a new request (call once per request at start).
    func recordBytesSent(_ bytes: Int) {
        lastRequestBodyBytes = bytes
    }

    /// Size of the most recent request body in bytes. Used for one-shot upload display.
    func lastUploadSize() -> Int { lastRequestBodyBytes }

    /// Cumulative bytes received since the actor was created. Used for KB/s computation.
    func cumulativeBytesReceived() -> Int { totalBytesReceived }

    /// Transition a request to `.done` with optional token/cost data, and stamp a removal deadline.
    /// The request stays in the active set until pruned by `snapshotSessionActivities`.
    func markRequestDone(id: UUID, errored: Bool, tokenUsage: TokenUsage?, estimatedCost: Double?) {
        guard var entry = activeRequests[id] else { return }
        entry.activity.state = .done
        entry.activity.completedAt = Date()
        entry.activity.removeAfter = Date().addingTimeInterval(6)
        entry.activity.tokenUsage = tokenUsage
        entry.activity.estimatedCost = estimatedCost
        activeRequests[id] = entry

        if var session = sessions[entry.sessionID] {
            if errored {
                session.erroredRequestCount += 1
            } else {
                session.completedRequestCount += 1
            }
            sessions[entry.sessionID] = session
        }
        onTraffic?()
    }

    /// Return a snapshot of all sessions with their stats and in-flight requests,
    /// sorted by most-recently-seen first. Prunes done requests whose deadline has passed.
    func snapshotSessionActivities() -> [SessionSnapshot] {
        // Prune done requests whose removal deadline has passed.
        let now = Date()
        let expiredIDs = activeRequests.filter { (_, entry) in
            if case .done = entry.activity.state,
               let removeAfter = entry.activity.removeAfter,
               removeAfter <= now {
                return true
            }
            return false
        }.map(\.key)
        for id in expiredIDs {
            activeRequests.removeValue(forKey: id)
        }

        var requestsBySession: [String: [ProxyRequestActivity]] = [:]
        for (_, entry) in activeRequests {
            requestsBySession[entry.sessionID, default: []].append(entry.activity)
        }
        return sessions.values.map { session in
            SessionSnapshot(
                sessionID: session.sessionID,
                lastSeenAt: session.lastSeenAt,
                lastKeepaliveAt: session.lastKeepaliveAt,
                completedRequestCount: session.completedRequestCount,
                erroredRequestCount: session.erroredRequestCount,
                keepaliveTotalCount: session.keepaliveSuccessCount + session.keepaliveFailureCount,
                activeRequests: requestsBySession[session.sessionID] ?? [],
                totalInputTokens: session.totalInputTokens,
                totalOutputTokens: session.totalOutputTokens,
                totalCacheReadInputTokens: session.totalCacheReadInputTokens,
                totalCacheCreationInputTokens: session.totalCacheCreationInputTokens,
                estimatedCostUSD: session.estimatedCostUSD
            )
        }.sorted {
            max($0.lastSeenAt, $0.lastKeepaliveAt ?? .distantPast)
                > max($1.lastSeenAt, $1.lastKeepaliveAt ?? .distantPast)
        }
    }

    // MARK: - Session expiration

    /// Remove sessions that have been idle since the given date.
    /// Skips sessions with in-flight requests to avoid dropping state mid-stream.
    /// Returns the session IDs that were removed.
    func expireSessions(olderThan date: Date) -> [String] {
        var expired: [String] = []
        for (id, session) in sessions
            where max(session.lastSeenAt, session.lastKeepaliveAt ?? .distantPast) < date
                && session.inFlightRequestCount == 0 {
            expired.append(id)
        }
        for id in expired {
            sessions.removeValue(forKey: id)
        }
        return expired
    }
}
