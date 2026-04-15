import Foundation

/// Tracks active proxy sessions, including Anthropic and conservatively
/// identified Codex/OpenAI sessions.
actor ProxySessionStore {

    struct CostSnapshot: Sendable {
        let totalEstimatedCostUSD: Double
        let estimatedCostUSDByAPI: [ProxyAPIFlavor: Double]
    }

    struct KeepaliveRequestContext: Sendable {
        let body: Data
        let headers: [(name: String, value: String)]
    }

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
        var lastKeepaliveTokenUsage: TokenUsage?
        var isKeepaliveDisabled: Bool
        var keepaliveMode: KeepaliveMode
        // Per-session request counters (completed/errored real requests):
        var completedRequestCount: Int
        var erroredRequestCount: Int
        // Cumulative token usage and estimated cost:
        var totalInputTokens: Int
        var totalOutputTokens: Int
        var totalCacheReadInputTokens: Int
        var totalCacheCreationInputTokens: Int
        var estimatedCostUSD: Double
        // Lineage tracking for keepalive:
        var totalRequestsSeen: Int
        var lineageFingerprint: LineageFingerprint?
        var lineageMessagesDescriptor: String?
        var lineageRequestBody: Data?
        var lineageRequestHeaders: [(name: String, value: String)]
        var lineageEstablished: Bool
        var keepaliveDisabledReason: String?
        var activeAcceptedLineageRequestID: UUID?
        var activeAcceptedLineageRequestBody: Data?
        var activeAcceptedLineageRequestHeaders: [(name: String, value: String)]
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
        let doneRequests: [ProxyRequestActivity]
        let lastKeepaliveRequest: ProxyRequestActivity?
        let totalInputTokens: Int
        let totalOutputTokens: Int
        let totalCacheReadInputTokens: Int
        let totalCacheCreationInputTokens: Int
        let estimatedCostUSD: Double
        let isKeepaliveDisabled: Bool
        let keepaliveDisabledReason: String?
        let keepaliveMode: KeepaliveMode
        let lineageEstablished: Bool
        let lastKeepaliveTokenUsage: TokenUsage?
    }

    /// Result of evaluating an incoming request against the tracked main-agent lineage.
    enum LineageEvaluation: Sendable {
        /// Request accepted as a main-agent continuation; keepalive body updated.
        case tracked
        /// Request does not look like the main agent (side traffic); ignored.
        case ignored
        /// Was tracking, but this request diverges; keepalive disabled for the session.
        case diverged(reason: String)
        /// Keepalive already disabled for this session.
        case alreadyDisabled
        /// Within the first 2 requests; still identifying the main agent.
        case pendingIdentification
    }

    private var sessions: [String: Session] = [:]
    /// In-flight requests keyed by their UUID, with the owning session ID stored alongside.
    private var activeRequests: [UUID: (sessionID: String, activity: ProxyRequestActivity)] = [:]
    /// Recently completed requests shown in the session's done section.
    private var doneRequestsBySession: [String: [ProxyRequestActivity]] = [:]
    /// Only the most recent completed keepalive is shown per session.
    private var lastKeepaliveRequestBySession: [String: ProxyRequestActivity] = [:]

    // Byte counters for throughput and one-shot upload display.
    private var totalBytesReceived: Int = 0
    private var lastRequestBodyBytes: Int = 0

    /// Cumulative estimated cost (USD) across all sessions since the proxy started.
    /// Separate from per-session costs so it survives session expiration.
    private var cumulativeEstimatedCostUSD: Double = 0
    private var cumulativeEstimatedCostUSDByAPI: [ProxyAPIFlavor: Double] = [:]

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
                lastKeepaliveTokenUsage: nil,
                isKeepaliveDisabled: false,
                keepaliveMode: .off,
                completedRequestCount: 0,
                erroredRequestCount: 0,
                totalInputTokens: 0,
                totalOutputTokens: 0,
                totalCacheReadInputTokens: 0,
                totalCacheCreationInputTokens: 0,
                estimatedCostUSD: 0,
                totalRequestsSeen: 0,
                lineageFingerprint: nil,
                lineageMessagesDescriptor: nil,
                lineageRequestBody: nil,
                lineageRequestHeaders: [],
                lineageEstablished: false,
                keepaliveDisabledReason: nil,
                activeAcceptedLineageRequestID: nil,
                activeAcceptedLineageRequestBody: nil,
                activeAcceptedLineageRequestHeaders: []
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

    /// Set the keepalive mode for a session. Clears the disabled reason when switching to `.off`.
    func setKeepaliveMode(_ mode: KeepaliveMode, for sessionID: String) {
        if var session = sessions[sessionID] {
            session.keepaliveMode = mode
            if mode == .off {
                session.isKeepaliveDisabled = false
                session.keepaliveDisabledReason = nil
            }
            sessions[sessionID] = session
        }
    }

    /// Whether a manual keepalive can be sent for a session right now.
    func canSendManualKeepalive(for sessionID: String) -> Bool {
        guard let session = sessions[sessionID] else { return false }
        return session.keepaliveMode == .manual
            && !session.isKeepaliveDisabled
            && session.lineageEstablished
            && keepaliveRequestContext(for: session) != nil
    }

    // MARK: - Lineage tracking

    /// Evaluate an incoming request against the tracked main-agent lineage.
    /// Updates lineage state and returns an evaluation that tells the caller
    /// whether to start/reset keepalive, stop it, or leave it alone.
    func evaluateAndTrackLineage(
        body: Data,
        headers: [(name: String, value: String)],
        model: String?,
        for sessionID: String,
        using apiHandler: any ProxyAPIHandler
    ) -> LineageEvaluation {
        guard var session = sessions[sessionID] else { return .ignored }

        // Already disabled — nothing to do.
        if session.isKeepaliveDisabled {
            return .alreadyDisabled
        }

        session.totalRequestsSeen += 1
        sessions[sessionID] = session

        // Classify the incoming request.
        let isMainAgentShaped = apiHandler.isMainAgentRequest(body: body)

        // Phase 1: Lineage not yet established — identify the main agent from
        // the first 2 requests. We store a candidate fingerprint on the first
        // main-agent-shaped request but keep the window open until 2 requests
        // have been seen.
        if !session.lineageEstablished {
            if isMainAgentShaped {
                if session.lineageFingerprint == nil {
                    // First main-agent-shaped request — store as candidate.
                    guard let fingerprint = apiHandler.lineageFingerprint(from: body) else {
                        return .ignored
                    }
                    session.lineageFingerprint = fingerprint
                    session.lineageMessagesDescriptor = apiHandler.messagesDescriptor(from: body)
                    session.lineageRequestBody = body
                    session.lineageRequestHeaders = headers
                    // Close the window if this is already request #2.
                    if session.totalRequestsSeen >= 2 {
                        session.lineageEstablished = true
                    }
                    sessions[sessionID] = session
                    return .tracked
                } else {
                    // Second main-agent-shaped request in window — close the
                    // window and fall through to the continuation check below.
                    session.lineageEstablished = true
                    sessions[sessionID] = session
                }
            } else {
                // Not main-agent-shaped.
                if session.totalRequestsSeen >= 2 && session.lineageFingerprint == nil {
                    // Past identification window without finding a main agent.
                    disableKeepaliveWithReason(
                        for: sessionID,
                        reason: String(localized: "no main-agent candidate in first 2 requests")
                    )
                    return .diverged(reason: "no main-agent candidate in first 2 requests")
                }
                if session.totalRequestsSeen >= 2 && session.lineageFingerprint != nil {
                    // Window closed with a candidate already stored — establish it.
                    session.lineageEstablished = true
                    sessions[sessionID] = session
                }
                return session.lineageEstablished ? .ignored : .pendingIdentification
            }
        }

        // Reload session after potential updates above.
        guard let currentSession = sessions[sessionID] else { return .ignored }

        // Phase 2: Lineage established — classify against tracked fingerprint.
        if !isMainAgentShaped {
            return .ignored
        }

        guard let tracked = currentSession.lineageFingerprint else { return .ignored }
        guard let incoming = apiHandler.lineageFingerprint(from: body) else { return .ignored }

        // Step 1: Check if system + messages indicate a continuation of the
        // main agent. If not, this is side traffic (e.g. a subagent with a
        // different system prompt) — ignore it without disabling keepalive.
        if incoming.systemCanonical != tracked.systemCanonical {
            return .ignored
        }

        let incomingMessages = apiHandler.messagesDescriptor(from: body)
        if let trackedMessages = currentSession.lineageMessagesDescriptor,
           let incomingMsg = incomingMessages {
            if !incomingMsg.hasPrefix(trackedMessages) {
                let trackedCount = trackedMessages.components(separatedBy: "\nmessage:").count
                let incomingCount = incomingMsg.components(separatedBy: "\nmessage:").count
                if incomingCount < trackedCount {
                    // Fewer messages — side traffic, not a divergence.
                    return .ignored
                }
                let reason = String(localized: "messages not append-only")
                disableKeepaliveWithReason(for: sessionID, reason: reason)
                return .diverged(reason: reason)
            }
        }

        // Step 2: System + messages match the main agent continuation. Now
        // check cache-invalidating fields — if any changed, this is a true
        // divergence that would break the prompt cache.
        if incoming.model != tracked.model {
            let reason = "model changed: \(tracked.model) → \(incoming.model)"
            disableKeepaliveWithReason(for: sessionID, reason: reason)
            return .diverged(reason: reason)
        }
        if incoming.toolsCanonical != tracked.toolsCanonical {
            let reason = String(localized: "tools changed")
            disableKeepaliveWithReason(for: sessionID, reason: reason)
            return .diverged(reason: reason)
        }
        if incoming.toolChoiceCanonical != tracked.toolChoiceCanonical {
            let reason = String(localized: "tool_choice changed")
            disableKeepaliveWithReason(for: sessionID, reason: reason)
            return .diverged(reason: reason)
        }
        if incoming.thinkingCanonical != tracked.thinkingCanonical {
            let reason = String(localized: "thinking config changed")
            disableKeepaliveWithReason(for: sessionID, reason: reason)
            return .diverged(reason: reason)
        }

        // All checks pass — promote this request as the latest lineage point.
        if var updated = sessions[sessionID] {
            updated.lineageMessagesDescriptor = incomingMessages
            updated.lineageRequestBody = body
            updated.lineageRequestHeaders = headers
            sessions[sessionID] = updated
        }
        return .tracked
    }

    /// Prefer an accepted in-flight main-agent continuation as the keepalive source,
    /// falling back to the last completed tracked lineage request.
    func keepaliveRequestContext(for sessionID: String) -> KeepaliveRequestContext? {
        guard let session = sessions[sessionID] else { return nil }
        return keepaliveRequestContext(for: session)
    }

    /// Track an accepted upstream request as the freshest keepalive source while it is still active.
    func markAcceptedLineageRequestActive(
        id: UUID,
        body: Data,
        headers: [(name: String, value: String)],
        for sessionID: String,
        using apiHandler: any ProxyAPIHandler
    ) {
        guard var session = sessions[sessionID] else { return }
        guard session.lineageEstablished, !session.isKeepaliveDisabled else { return }
        guard apiHandler.isMainAgentRequest(body: body) else { return }
        guard let tracked = session.lineageFingerprint,
              let incoming = apiHandler.lineageFingerprint(from: body) else {
            return
        }

        guard incoming.systemCanonical == tracked.systemCanonical,
              incoming.model == tracked.model,
              incoming.toolsCanonical == tracked.toolsCanonical,
              incoming.toolChoiceCanonical == tracked.toolChoiceCanonical,
              incoming.thinkingCanonical == tracked.thinkingCanonical else {
            return
        }

        let incomingMessages = apiHandler.messagesDescriptor(from: body)
        if let trackedMessages = session.lineageMessagesDescriptor {
            guard let incomingMessages, incomingMessages.hasPrefix(trackedMessages) else {
                return
            }
        }

        session.activeAcceptedLineageRequestID = id
        session.activeAcceptedLineageRequestBody = body
        session.activeAcceptedLineageRequestHeaders = headers
        sessions[sessionID] = session
    }

    /// Disable keepalive with a human-readable reason for UI display.
    func disableKeepaliveWithReason(for sessionID: String, reason: String) {
        if var session = sessions[sessionID] {
            session.isKeepaliveDisabled = true
            session.keepaliveDisabledReason = reason
            sessions[sessionID] = session
        }
    }

    /// Re-enable keepalive for a session after a user-initiated disable.
    /// Clears the disabled flag and reason. Lineage state is preserved so the
    /// next tracked request can resume the keepalive loop.
    func enableKeepalive(for sessionID: String) {
        if var session = sessions[sessionID] {
            session.isKeepaliveDisabled = false
            session.keepaliveDisabledReason = nil
            sessions[sessionID] = session
        }
    }

    /// The reason keepalive was disabled for a session, if any.
    func keepaliveDisabledReason(for sessionID: String) -> String? {
        sessions[sessionID]?.keepaliveDisabledReason
    }

    /// Record keepalive result for a session. On success, accumulates cost.
    func recordKeepaliveResult(
        for sessionID: String,
        success: Bool,
        tokenUsage: TokenUsage,
        apiFlavor: ProxyAPIFlavor
    ) {
        if var session = sessions[sessionID] {
            session.lastKeepaliveAt = Date()
            if success {
                session.keepaliveSuccessCount += 1
                session.lastKeepaliveTokenUsage = tokenUsage
                // Accumulate keepalive cost into the session total.
                if let pricing = ModelPricingTable.pricing(for: session.lastKnownModel) {
                    let cost = tokenUsage.cost(for: pricing)
                    session.estimatedCostUSD += cost
                    accumulateCost(cost, for: apiFlavor)
                }
            } else {
                session.keepaliveFailureCount += 1
            }
            sessions[sessionID] = session
        }
    }

    // MARK: - Token usage accumulation

    /// Record token usage and estimated cost for a completed request in this session.
    func recordTokenUsage(
        _ usage: TokenUsage,
        model: String?,
        for sessionID: String,
        apiFlavor: ProxyAPIFlavor
    ) {
        guard var session = sessions[sessionID] else { return }
        session.totalInputTokens += usage.inputTokens ?? 0
        session.totalOutputTokens += usage.outputTokens ?? 0
        session.totalCacheReadInputTokens += usage.cacheReadInputTokens ?? 0
        session.totalCacheCreationInputTokens += usage.cacheCreationInputTokens ?? 0
        if let pricing = ModelPricingTable.pricing(for: model) {
            let cost = usage.cost(for: pricing)
            session.estimatedCostUSD += cost
            accumulateCost(cost, for: apiFlavor)
        }
        sessions[sessionID] = session
    }

    /// Cumulative estimated cost since proxy start (survives session expiration).
    func costSnapshot() -> CostSnapshot {
        CostSnapshot(
            totalEstimatedCostUSD: cumulativeEstimatedCostUSD,
            estimatedCostUSDByAPI: cumulativeEstimatedCostUSDByAPI
        )
    }

    /// Reset all transient counters while keeping sessions operational for keepalive.
    /// Preserves request context (body, headers, model) needed by keepalive loops.
    /// Reset only the cumulative cost estimate to zero. Per-session costs are preserved.
    func resetCost() {
        cumulativeEstimatedCostUSD = 0
        cumulativeEstimatedCostUSDByAPI.removeAll()
    }

    // MARK: - Request activity tracking

    /// Register a new in-flight request. Call immediately before starting the upstream fetch.
    func startRequest(
        id: UUID,
        sessionID: String,
        model: String?,
        promptDescriptor: String?,
        isMainAgentShaped: Bool,
        kind: ProxyRequestKind = .request
    ) {
        let activity = ProxyRequestActivity(
            id: id,
            kind: kind,
            state: .uploading,
            modelID: model,
            promptDescriptor: promptDescriptor,
            isMainAgentShaped: isMainAgentShaped,
            bytesSent: 0,
            bytesReceived: 0,
            lastDataAt: nil,
            startedAt: Date(),
            receivingStartedAt: nil,
            firstDataAt: nil,
            completedAt: nil,
            tokenUsage: nil,
            estimatedCost: nil
        )
        if kind == .keepalive {
            activeRequests = activeRequests.filter { key, value in
                key == id || value.sessionID != sessionID || !value.activity.isKeepalive
            }
            lastKeepaliveRequestBySession.removeValue(forKey: sessionID)
        }
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

    /// Finalize a request, promoting only non-errored responses into the session's
    /// done section where prompt-based replacement is evaluated.
    func markRequestDone(id: UUID, errored: Bool, tokenUsage: TokenUsage?, estimatedCost: Double?) {
        guard var entry = activeRequests.removeValue(forKey: id) else { return }
        let completedAt = Date()
        entry.activity.state = .done
        entry.activity.completedAt = completedAt
        entry.activity.tokenUsage = tokenUsage
        entry.activity.estimatedCost = estimatedCost

        // A response is "complete" when no transport/HTTP error occurred.
        // We don't require stopReason because the streaming capture buffer
        // may be truncated (4 MB cap) and miss the final message_delta event.
        let isComplete = !errored
        if isComplete && entry.activity.isKeepalive {
            lastKeepaliveRequestBySession[entry.sessionID] = entry.activity
        } else if isComplete {
            insertDoneRequest(entry.activity, for: entry.sessionID)
        }

        if var session = sessions[entry.sessionID] {
            if session.activeAcceptedLineageRequestID == id {
                session.activeAcceptedLineageRequestID = nil
                session.activeAcceptedLineageRequestBody = nil
                session.activeAcceptedLineageRequestHeaders = []
            }
            if isComplete {
                session.completedRequestCount += 1
            } else {
                session.erroredRequestCount += 1
            }
            sessions[entry.sessionID] = session
        }
        onTraffic?()
    }

    /// Return a snapshot of all sessions with their stats and in-flight requests,
    /// sorted by most-recently-seen first.
    func snapshotSessionActivities() -> [SessionSnapshot] {
        var activeRequestsBySession: [String: [ProxyRequestActivity]] = [:]
        for (_, entry) in activeRequests {
            activeRequestsBySession[entry.sessionID, default: []].append(entry.activity)
        }
        return sessions.values.map { session in
            SessionSnapshot(
                sessionID: session.sessionID,
                lastSeenAt: session.lastSeenAt,
                lastKeepaliveAt: session.lastKeepaliveAt,
                completedRequestCount: session.completedRequestCount,
                erroredRequestCount: session.erroredRequestCount,
                keepaliveTotalCount: session.keepaliveSuccessCount + session.keepaliveFailureCount,
                activeRequests: activeRequestsBySession[session.sessionID] ?? [],
                doneRequests: doneRequestsBySession[session.sessionID] ?? [],
                lastKeepaliveRequest: lastKeepaliveRequestBySession[session.sessionID],
                totalInputTokens: session.totalInputTokens,
                totalOutputTokens: session.totalOutputTokens,
                totalCacheReadInputTokens: session.totalCacheReadInputTokens,
                totalCacheCreationInputTokens: session.totalCacheCreationInputTokens,
                estimatedCostUSD: session.estimatedCostUSD,
                isKeepaliveDisabled: session.isKeepaliveDisabled,
                keepaliveDisabledReason: session.keepaliveDisabledReason,
                keepaliveMode: session.keepaliveMode,
                lineageEstablished: session.lineageEstablished,
                lastKeepaliveTokenUsage: session.lastKeepaliveTokenUsage
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
    func expireSessions(olderThan date: Date, otherOlderThan otherDate: Date) -> [String] {
        var expired: [String] = []
        for (id, session) in sessions {
            let cutoff = ProxySessionID.isOther(id) ? otherDate : date
            guard max(session.lastSeenAt, session.lastKeepaliveAt ?? .distantPast) < cutoff,
                  session.inFlightRequestCount == 0 else {
                continue
            }
            expired.append(id)
        }
        for id in expired {
            sessions.removeValue(forKey: id)
            doneRequestsBySession.removeValue(forKey: id)
            lastKeepaliveRequestBySession.removeValue(forKey: id)
        }
        return expired
    }

    /// Remove non-main-agent done requests older than the given cutoff.
    /// Main-agent requests persist for the session lifetime.
    func pruneStaleDoneRequests(olderThan cutoff: Date, otherOlderThan otherCutoff: Date) {
        for (sessionID, requests) in doneRequestsBySession {
            let filtered = requests.filter { request in
                if ProxySessionID.isOther(sessionID) {
                    return (request.completedAt ?? request.startedAt) >= otherCutoff
                }
                return request.isMainAgentShaped || (request.completedAt ?? request.startedAt) >= cutoff
            }
            if filtered.isEmpty {
                doneRequestsBySession.removeValue(forKey: sessionID)
            } else if filtered.count != requests.count {
                doneRequestsBySession[sessionID] = filtered
            }
        }
    }

    /// Clear the main-agent flag on a done request after lineage evaluation
    /// determines it is not part of the tracked main-agent lineage.
    func clearMainAgentFlag(requestID: UUID, sessionID: String) {
        guard var doneRequests = doneRequestsBySession[sessionID] else { return }
        guard let index = doneRequests.firstIndex(where: { $0.id == requestID }) else { return }
        doneRequests[index].isMainAgentShaped = false
        doneRequestsBySession[sessionID] = doneRequests
        onTraffic?()
    }

    private func insertDoneRequest(_ activity: ProxyRequestActivity, for sessionID: String) {
        var doneRequests = doneRequestsBySession[sessionID] ?? []
        if let replacementIndex = replacementIndex(for: activity, in: doneRequests) {
            doneRequests.remove(at: replacementIndex)
        }
        doneRequests.append(activity)
        doneRequestsBySession[sessionID] = doneRequests
    }

    private func accumulateCost(_ cost: Double, for apiFlavor: ProxyAPIFlavor) {
        cumulativeEstimatedCostUSD += cost
        cumulativeEstimatedCostUSDByAPI[apiFlavor, default: 0] += cost
    }

    private func keepaliveRequestContext(for session: Session) -> KeepaliveRequestContext? {
        if let body = session.activeAcceptedLineageRequestBody {
            return KeepaliveRequestContext(
                body: body,
                headers: session.activeAcceptedLineageRequestHeaders
            )
        }
        if let body = session.lineageRequestBody {
            return KeepaliveRequestContext(
                body: body,
                headers: session.lineageRequestHeaders
            )
        }
        return nil
    }

    private func replacementIndex(
        for newActivity: ProxyRequestActivity,
        in doneRequests: [ProxyRequestActivity]
    ) -> Int? {
        guard let newPrompt = newActivity.promptDescriptor, !newPrompt.isEmpty else {
            return nil
        }

        return doneRequests.enumerated()
            .filter { _, oldActivity in
                guard oldActivity.modelID == newActivity.modelID,
                      let oldPrompt = oldActivity.promptDescriptor,
                      !oldPrompt.isEmpty else {
                    return false
                }
                return newPrompt.contains(oldPrompt)
            }
            .max { lhs, rhs in
                let lhsLength = lhs.element.promptDescriptor?.count ?? 0
                let rhsLength = rhs.element.promptDescriptor?.count ?? 0
                if lhsLength == rhsLength {
                    return (lhs.element.completedAt ?? lhs.element.startedAt)
                        < (rhs.element.completedAt ?? rhs.element.startedAt)
                }
                return lhsLength < rhsLength
            }?
            .offset
    }
}
