import Foundation

/// Tracks proxy traffic and maintains the in-memory content tree across all
/// proxied requests.
///
/// - Sessions are a thin UI grouping layer keyed by the agent's session
///   header (e.g. `X-Claude-Code-Session-Id`, OpenAI `session_id`); they do
///   not drive content-tree tracking directly.
/// - The `ContentTree` lives here. Requests attach to it the moment their
///   body has been parsed — before upstream is contacted. Every displayable
///   done row is derived from the tree's content nodes.
actor ProxySessionStore {

    struct CostSnapshot: Sendable {
        let totalEstimatedCostUSD: Double
        let estimatedCostUSDByAPI: [ProxyAPIFlavor: Double]
    }

    struct Session: Sendable {
        var sessionID: String
        var startedAt: Date
        var lastSeenAt: Date
        var lastRequestDoneAt: Date?
        var inFlightRequestCount: Int
        var completedRequestCount: Int
        var erroredRequestCount: Int
        var totalInputTokens: Int
        var totalOutputTokens: Int
        var totalCacheReadInputTokens: Int
        var totalCacheCreationInputTokens: Int
        var estimatedCostUSD: Double
    }

    /// A snapshot of a session's stats and its currently active requests, for UI display.
    struct SessionSnapshot: Sendable {
        let sessionID: String
        let startedAt: Date
        let lastSeenAt: Date
        let lastRequestDoneAt: Date?
        let completedRequestCount: Int
        let erroredRequestCount: Int
        let activeRequests: [ProxyRequestActivity]
        let doneRequests: [ProxyRequestActivity]
        let totalInputTokens: Int
        let totalOutputTokens: Int
        let totalCacheReadInputTokens: Int
        let totalCacheCreationInputTokens: Int
        let estimatedCostUSD: Double
    }

    private var sessions: [String: Session] = [:]
    /// In-flight requests keyed by their UUID, with the owning session ID stored alongside.
    private var activeRequests: [UUID: (sessionID: String, activity: ProxyRequestActivity)] = [:]
    /// Recently completed requests shown in the session's done section (untracked/other sessions
    /// keep their completed requests here on a short timer). For flavored sessions the done
    /// list is derived from the lineage tree leaves and this map is unused.
    private var doneRequestsBySession: [String: [ProxyRequestActivity]] = [:]
    /// Final `ProxyRequestActivity` snapshot for every completed request that
    /// landed in the content tree. Keyed by request UUID, this preserves
    /// model name, byte counts, timing, cost, etc. so the UI can render a
    /// full row for any tree node's requests. Entries are removed when their
    /// corresponding request ages out or its whole conversation tree is
    /// evicted.
    private var treeDoneActivities: [UUID: ProxyRequestActivity] = [:]

    /// The in-memory content tree. Requests attach the moment their body is
    /// parsed; leaf requests are consulted for UI display.
    private var contentTree: ContentTree = ContentTree()

    // Byte counters for throughput and one-shot upload display.
    private var totalBytesReceived: Int = 0
    private var lastRequestBodyBytes: Int = 0

    /// Cumulative estimated cost (USD) across all sessions since the proxy started.
    /// Separate from per-session costs so it survives session expiration.
    private var cumulativeEstimatedCostUSD: Double = 0
    private var cumulativeEstimatedCostUSDByAPI: [ProxyAPIFlavor: Double] = [:]

    /// Callback fired on every state change that should refresh the UI.
    /// The `TrafficDirection?` argument is non-nil when the event corresponds
    /// to actual bytes flowing (for driving the menu bar arrow animations);
    /// it is nil for bookkeeping updates that should still refresh listeners
    /// but not animate traffic arrows.
    /// Called from within the actor — callers should dispatch to MainActor as needed.
    private var onTraffic: (@Sendable (TrafficDirection?) -> Void)?
    /// Fired once per request when it finalizes (success or error). Used by the
    /// menu bar icon to spawn a cost-transformation particle, independent of
    /// the byte-level traffic animation.
    private var onRequestDone: (@Sendable () -> Void)?

    /// Set the traffic callback. Called from outside the actor isolation.
    func setTrafficCallback(_ callback: @escaping @Sendable (TrafficDirection?) -> Void) {
        onTraffic = callback
    }

    /// Set the request-done callback. Called from outside the actor isolation.
    func setRequestDoneCallback(_ callback: @escaping @Sendable () -> Void) {
        onRequestDone = callback
    }

    // MARK: - Session identity

    /// Resolve an incoming request identity into the session bucket used by the UI and metrics.
    func resolveSessionID(for identity: ProxySessionIdentity) -> String {
        guard let flavor = identity.flavor,
              let rawSessionID = identity.rawSessionID else {
            return ProxySessionID.other
        }
        return ProxySessionID.make(rawSessionID, flavor: flavor)
    }

    func currentSessionID(for sessionID: String) -> String { sessionID }

    func currentSessionID(forRequest requestID: UUID, fallback sessionID: String) -> String {
        activeRequests[requestID]?.sessionID ?? sessionID
    }

    /// Register an in-flight request under its owning session bucket.
    func beginRequest(
        identity: ProxySessionIdentity,
        id: UUID,
        model: String?,
        kind: ProxyRequestKind = .request
    ) -> String {
        let sessionID = resolveSessionID(for: identity)
        touch(sessionID)
        incrementInFlight(sessionID)
        startRequest(
            id: id,
            sessionID: sessionID,
            model: model,
            kind: kind
        )
        return sessionID
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
                startedAt: now,
                lastSeenAt: now,
                lastRequestDoneAt: nil,
                inFlightRequestCount: 0,
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

    func session(for sessionID: String) -> Session? {
        sessions[sessionID]
    }

    // MARK: - Content tree integration

    /// Attach a request to the content tree. Called once the request body
    /// has been fully parsed (before upstream is contacted). Stores the full
    /// fingerprint on the conversation so downstream callers never need to
    /// re-derive model / system / tools from the original request body.
    func attachToTree(
        requestID: UUID,
        sessionID: String,
        fingerprint: LineageFingerprint,
        messages: [ContentTree.NormalizedMessage],
        previousResponseID: String?
    ) {
        let result = contentTree.attach(
            requestID: requestID,
            sessionID: sessionID,
            fingerprint: fingerprint,
            messages: messages,
            previousResponseID: previousResponseID
        )
        if var entry = activeRequests[requestID] {
            entry.activity.conversationID = result.conversationID
            entry.activity.nodeID = result.nodeID
            activeRequests[requestID] = entry
        }
        onTraffic?(nil)
    }

    /// Preview what attaching this request would add to the content tree,
    /// without mutating the tree. Used by the content blocklist guard to scan
    /// only the delta messages (content new in this request) before deciding
    /// whether to reject or forward.
    func previewTreeAttach(
        fingerprint: LineageFingerprint,
        messages: [ContentTree.NormalizedMessage],
        previousResponseID: String?
    ) -> ContentTree.AttachPreview {
        contentTree.previewAttach(
            fingerprint: fingerprint,
            messages: messages,
            previousResponseID: previousResponseID
        )
    }

    /// Finalize a tree request. `succeeded` is true only for streams that
    /// completed cleanly — upstream errors, client disconnects, and
    /// incomplete streams all pass `succeeded: false`. No-op when the
    /// request was never attached.
    func finishTrackedRequest(
        requestID: UUID,
        succeeded: Bool,
        tokenUsage: TokenUsage?,
        responseID: String?
    ) {
        contentTree.finishRequest(
            requestID: requestID,
            succeeded: succeeded,
            tokenUsage: tokenUsage,
            responseID: responseID
        )
    }

    /// Prune terminal requests and inactive conversation trees, returning
    /// the IDs removed so callers can mirror deletions to SQLite.
    func pruneContentTree(retention: TimeInterval) -> ContentTree.PruneResult {
        let result = contentTree.prune(retention: retention)
        for removed in result.removedRequestIDs {
            treeDoneActivities.removeValue(forKey: removed)
        }
        return result
    }

    /// Test hook: snapshot of the current tree state, used for diagnostics and UI.
    func contentTreeSnapshot() -> ContentTree { contentTree }

    /// Build the `LineageContext` needed to mirror a request's tree
    /// coordinates into SQLite. Returns nil when the request is not
    /// currently tracked by the tree.
    func lineageContext(for requestID: UUID) -> ProxyEventLogger.LineageContext? {
        guard let request = contentTree.requests[requestID],
              let targetNode = contentTree.nodes[request.nodeID],
              let conversation = contentTree.conversation(withID: targetNode.conversationID),
              let rootNode = contentTree.nodes[conversation.rootNodeID] else {
            return nil
        }
        let fingerprint = conversation.fingerprint
        let targetDeltaJSON = contentTree.cachedDeltaMessagesJSON(for: targetNode.id)
        let rootDeltaJSON = contentTree.cachedDeltaMessagesJSON(for: rootNode.id)

        return ProxyEventLogger.LineageContext(
            conversationID: conversation.id,
            nodeID: targetNode.id,
            rootNodeID: rootNode.id,
            previousResponseID: request.previousResponseID,
            fingerprintHash: fingerprint.conversationKey.fingerprintHash,
            fingerprint: fingerprint,
            flavor: fingerprint.flavor,
            rootNodeRow: ProxyEventLogger.LineageContext.NodeRow(
                id: rootNode.id,
                parentNodeID: nil,
                deltaMessagesJSON: rootDeltaJSON
            ),
            targetNodeRow: ProxyEventLogger.LineageContext.NodeRow(
                id: targetNode.id,
                parentNodeID: targetNode.parentNodeID,
                deltaMessagesJSON: targetDeltaJSON
            )
        )
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
        if let cost = usage.estimatedCost(
            for: ModelPricingTable.pricing(for: model),
            apiFlavor: apiFlavor
        ) {
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
        kind: ProxyRequestKind = .request
    ) {
        let activity = ProxyRequestActivity(
            id: id,
            kind: kind,
            state: .uploading,
            modelID: model,
            conversationID: nil,
            nodeID: nil,
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
        activeRequests[id] = (sessionID: sessionID, activity: activity)
        onTraffic?(.upload)
    }

    /// Transition a request from `.uploading` to `.waiting` once the upload is complete.
    func markRequestWaiting(id: UUID) {
        guard var entry = activeRequests[id] else { return }
        guard entry.activity.state == .uploading else { return }
        entry.activity.state = .waiting
        entry.activity.lastDataAt = Date()
        activeRequests[id] = entry
        onTraffic?(nil)
    }

    /// Transition a request from `.uploading` or `.waiting` to `.receiving` once response headers arrive.
    func markRequestReceiving(id: UUID) {
        guard var entry = activeRequests[id] else { return }
        guard entry.activity.state == .uploading || entry.activity.state == .waiting else { return }
        entry.activity.state = .receiving
        entry.activity.lastDataAt = Date()
        entry.activity.receivingStartedAt = Date()
        activeRequests[id] = entry
        onTraffic?(.download)
    }

    /// Record the timestamp of the first upstream data chunk (once per request).
    func markFirstDataReceived(id: UUID) {
        guard var entry = activeRequests[id] else { return }
        guard entry.activity.firstDataAt == nil else { return }
        entry.activity.firstDataAt = Date()
        activeRequests[id] = entry
    }

    /// Update the cumulative bytes sent to upstream for a request.
    func updateRequestBytesSent(id: UUID, totalBytesSent: Int) {
        guard var entry = activeRequests[id] else { return }
        entry.activity.bytesSent = totalBytesSent
        activeRequests[id] = entry
        onTraffic?(.upload)
    }

    /// Accumulate bytes received and refresh the last-data timestamp.
    func updateRequestBytes(id: UUID, additionalBytes: Int) {
        guard var entry = activeRequests[id] else { return }
        entry.activity.bytesReceived += additionalBytes
        entry.activity.lastDataAt = Date()
        activeRequests[id] = entry
        totalBytesReceived += additionalBytes
        onTraffic?(.download)
    }

    /// Record bytes sent upstream for a new request (call once per request at start).
    func recordBytesSent(_ bytes: Int) {
        lastRequestBodyBytes = bytes
    }

    /// Size of the most recent request body in bytes. Used for one-shot upload display.
    func lastUploadSize() -> Int { lastRequestBodyBytes }

    /// Cumulative bytes received since the actor was created. Used for KB/s computation.
    func cumulativeBytesReceived() -> Int { totalBytesReceived }

    /// Finalize a request. Successful completions that are NOT part of the lineage
    /// tree (unknown flavor or missing fingerprint) land in the short-lived
    /// `doneRequestsBySession` bucket for UI display. Utility completions are
    /// finalized for logging/traffic state but do not affect visible done counts.
    func markRequestDone(id: UUID, errored: Bool, tokenUsage: TokenUsage?, estimatedCost: Double?) {
        guard var entry = activeRequests.removeValue(forKey: id) else { return }
        let completedAt = Date()
        entry.activity.state = .done
        entry.activity.completedAt = completedAt
        entry.activity.tokenUsage = tokenUsage
        entry.activity.estimatedCost = estimatedCost

        let isComplete = !errored
        if isComplete {
            if entry.activity.kind.storesDoneActivity && entry.activity.conversationID == nil {
                // Untracked traffic: keep a short-lived copy in the done bucket.
                insertUntrackedDoneRequest(entry.activity, for: entry.sessionID)
            } else if entry.activity.kind.storesDoneActivity {
                // Tracked traffic: cache the full activity so tree-leaf rendering has
                // model name / byte counts / timing / cost even after the in-flight
                // entry is dropped.
                treeDoneActivities[id] = entry.activity
            }
        }

        if var session = sessions[entry.sessionID] {
            if isComplete && entry.activity.kind.storesDoneActivity {
                session.completedRequestCount += 1
            } else if !isComplete {
                session.erroredRequestCount += 1
            }
            session.lastRequestDoneAt = completedAt
            sessions[entry.sessionID] = session
        }
        onTraffic?(nil)
        if isComplete && entry.activity.kind.storesDoneActivity {
            onRequestDone?()
        }
    }

    // MARK: - Snapshot

    /// Return a snapshot of all sessions with their stats and in-flight requests.
    func snapshotSessionActivities() -> [SessionSnapshot] {
        var activeRequestsBySession: [String: [ProxyRequestActivity]] = [:]
        for (_, entry) in activeRequests {
            activeRequestsBySession[entry.sessionID, default: []].append(entry.activity)
        }

        // Displayable requests come from the content tree — every successful
        // request at a leaf-ish node, bucketed into the session that sent it.
        // `isPendingReplacement` flags rows whose node has a descendant with
        // an in-flight request so the UI can dim them pending completion.
        // A conversation can span multiple sessions (rare but legal) so we
        // rely on the sessionID stored on each request. Prefer the cached
        // `ProxyRequestActivity` captured at completion so rows show
        // model / bytes / cost; fall back to a tree-only synthesis if the
        // cache has already expired.
        var leafActivityBySession: [String: [ProxyRequestActivity]] = [:]
        for displayable in contentTree.displayableRequests() {
            guard let request = contentTree.requests[displayable.requestID] else { continue }
            var activity: ProxyRequestActivity
            if let cached = treeDoneActivities[displayable.requestID] {
                activity = cached
            } else {
                let conversationModel = contentTree
                    .conversation(withID: displayable.conversationID)?
                    .fingerprint
                    .model
                activity = ProxyRequestActivity(
                    id: request.id,
                    kind: .request,
                    state: .done,
                    modelID: conversationModel,
                    conversationID: displayable.conversationID,
                    nodeID: displayable.nodeID,
                    bytesSent: 0,
                    bytesReceived: 0,
                    lastDataAt: nil,
                    startedAt: request.createdAt,
                    receivingStartedAt: nil,
                    firstDataAt: nil,
                    completedAt: request.finishedAt,
                    tokenUsage: request.tokenUsage,
                    estimatedCost: nil
                )
            }
            activity.isPendingReplacement = displayable.isPendingReplacement
            leafActivityBySession[request.sessionID, default: []].append(activity)
        }

        // For untracked sessions ("other" or missing flavor) merge in the
        // short-retention done bucket.
        for (sessionID, requests) in doneRequestsBySession {
            leafActivityBySession[sessionID, default: []].append(contentsOf: requests)
        }

        return sessions.values.map { session in
            SessionSnapshot(
                sessionID: session.sessionID,
                startedAt: session.startedAt,
                lastSeenAt: session.lastSeenAt,
                lastRequestDoneAt: session.lastRequestDoneAt,
                completedRequestCount: session.completedRequestCount,
                erroredRequestCount: session.erroredRequestCount,
                activeRequests: activeRequestsBySession[session.sessionID] ?? [],
                doneRequests: (leafActivityBySession[session.sessionID] ?? [])
                    .sorted { ($0.completedAt ?? $0.startedAt) < ($1.completedAt ?? $1.startedAt) },
                totalInputTokens: session.totalInputTokens,
                totalOutputTokens: session.totalOutputTokens,
                totalCacheReadInputTokens: session.totalCacheReadInputTokens,
                totalCacheCreationInputTokens: session.totalCacheCreationInputTokens,
                estimatedCostUSD: session.estimatedCostUSD
            )
        }.sorted {
            if $0.startedAt != $1.startedAt {
                return $0.startedAt < $1.startedAt
            }
            return $0.sessionID < $1.sessionID
        }
    }

    // MARK: - Session expiration

    /// Remove sessions that have been idle since the given date.
    /// Skips sessions with in-flight requests to avoid dropping state mid-stream.
    /// Idleness is measured against the more recent of `lastSeenAt` (when a
    /// request last started) and `lastRequestDoneAt` (when one last finished);
    /// otherwise a long-running request could complete after the sweep cutoff
    /// yet be evicted before its retention window elapses.
    /// Returns the session IDs that were removed.
    func expireSessions(olderThan date: Date, otherOlderThan otherDate: Date) -> [String] {
        var expired: [String] = []
        for (id, session) in sessions {
            let cutoff = ProxySessionID.usesShortRetentionWindow(for: id) ? otherDate : date
            let lastActivity = max(session.lastSeenAt, session.lastRequestDoneAt ?? .distantPast)
            guard lastActivity < cutoff,
                  session.inFlightRequestCount == 0 else {
                continue
            }
            expired.append(id)
        }
        let expiredSet = Set(expired)
        for id in expired {
            sessions.removeValue(forKey: id)
            doneRequestsBySession.removeValue(forKey: id)
        }
        // Drop cached done-leaf activities whose tree-side request belonged
        // to an expired session. Rare (the content tree usually outlives
        // sessions) but keeps memory from leaking across evictions.
        treeDoneActivities = treeDoneActivities.filter { requestID, _ in
            guard let request = contentTree.requests[requestID] else { return false }
            return !expiredSet.contains(request.sessionID)
        }
        return expired
    }

    /// Remove untracked done requests older than the given cutoff.
    /// Flavored sessions store their done leaves in the lineage tree which
    /// has its own prune cycle.
    func pruneStaleDoneRequests(otherOlderThan otherCutoff: Date) {
        for (sessionID, requests) in doneRequestsBySession {
            let filtered = requests.filter { request in
                (request.completedAt ?? request.startedAt) >= otherCutoff
            }
            if filtered.isEmpty {
                doneRequestsBySession.removeValue(forKey: sessionID)
            } else if filtered.count != requests.count {
                doneRequestsBySession[sessionID] = filtered
            }
        }
    }

    // MARK: - Private helpers

    private func insertUntrackedDoneRequest(_ activity: ProxyRequestActivity, for sessionID: String) {
        var doneRequests = doneRequestsBySession[sessionID] ?? []
        doneRequests.append(activity)
        doneRequestsBySession[sessionID] = doneRequests
    }

    private func accumulateCost(_ cost: Double, for apiFlavor: ProxyAPIFlavor) {
        cumulativeEstimatedCostUSD += cost
        cumulativeEstimatedCostUSDByAPI[apiFlavor, default: 0] += cost
    }
}
