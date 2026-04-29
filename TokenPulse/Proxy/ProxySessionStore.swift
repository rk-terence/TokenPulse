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
    private static let keepaliveReminderDelaySeconds: TimeInterval = 270
    private static let keepaliveReminderActionWindowSeconds: TimeInterval = 20


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
        /// Keep-alive selections whose source request belongs to this
        /// session. Most often empty or a single entry; one session can hold
        /// multiple selections only if it spans multiple conversations.
        let keepaliveSelections: [KeepaliveSelection]
        /// Cumulative warm-request cost from the per-session history bucket.
        /// Persists across stop/restart cycles.
        let keepaliveCostUSD: Double
        /// Total completed warm attempts from the per-session history bucket.
        let keepaliveDoneCount: Int
    }

    /// Session-scoped keep-alive history. Survives selection removal so the popup
    /// can keep showing the session's cumulative warm cost / count and the most
    /// recent done-warm row even after the user clicks Stop.
    struct KeepaliveSessionHistory: Sendable {
        var cumulativeCostUSD: Double = 0
        var cumulativeWarmCount: Int = 0
        var lastWarmActivity: ProxyRequestActivity?
    }

    /// One conversation's manual keep-alive selection. The visible selection
    /// points at the current successful done request on the chosen path,
    /// while the latest warm source may temporarily be its single active
    /// successor. Per `docs/proxy-keepalive.md` we hold at most one selection
    /// per conversation; a new activation replaces the previous one.
    struct KeepaliveSelection: Sendable {
        let conversationID: UUID
        var nodeID: UUID
        var requestID: UUID
        var sessionID: String
        var latestSourceNodeID: UUID
        var latestSourceRequestID: UUID
        var latestSourceSessionID: String
        var latestSourceIsActive: Bool
        let activatedAt: Date
        var lastWarmStartedAt: Date?
        var lastReminderSourceNodeID: UUID?
        var lastReminderSourceRequestID: UUID?
        var lastReminderQuietReferenceAt: Date?
        /// UUID of the warm request currently in flight for this conversation,
        /// or nil when no warm is mid-flight. The UI gates the "Send keep-alive"
        /// menu off this; the actor uses it as a defensive backstop so a stale
        /// click cannot start a second warm before the first lands.
        var inFlightWarmRequestID: UUID?
    }

    /// Result of `beginManualKeepaliveDispatch` — the atomic check-and-set
    /// that ensures at most one warm is in flight per conversation.
    enum KeepaliveDispatchOutcome: Sendable {
        case dispatched(KeepaliveWarmSource, warmID: UUID)
        case alreadyInFlight
        case notSelected
    }

    /// Outcome of `activateKeepalive(forRequestID:)`. Selection-level
    /// eligibility (covered here) is upstream of body-synthesis eligibility
    /// (covered by `KeepaliveSynthesizer.RefusalReason`). The two refusal
    /// surfaces are intentionally separate so the UI can distinguish "you
    /// can't even pick this row" from "we tried to warm and the body wasn't
    /// reconstructible."
    enum KeepaliveActivationResult: Sendable {
        case activated(KeepaliveSelection)
        /// Request ID is not in the in-memory tree. Either it never attached
        /// or it was pruned.
        case unknownRequest
        /// Request hasn't reached a terminal state yet.
        case requestStillInFlight
        /// Request finished but didn't succeed.
        case requestErrored
        /// Conversation is not Anthropic Messages flavored — the manual MVP
        /// only supports Claude Code traffic.
        case unsupportedFlavor
        /// The raw request/response capture for this KA anchor has rolled out of
        /// the recent-exchange ring. The user must pick a fresher request.
        case sourceBodyUnavailable
    }

    /// Why a previously-active selection was dropped without a user request.
    /// Surfaced through `setKeepaliveDeactivatedCallback` for diagnostics
    /// and (phase 6) user notifications.
    enum KeepaliveDeactivationReason: Sendable, Equatable {
        case pathBranched
        case pruned
        case sessionExpired
    }

    /// One captured upstream exchange — the source request body and,
    /// once available, the observed response. Active path sources have only
    /// request data; completed sources add the response frontier used by the
    /// synthesizer. Body data lives only inside the actor — never crosses
    /// out via the snapshot path.
    struct KeepaliveExchange: Sendable {
        let requestHeaders: [(name: String, value: String)]
        let requestBody: Data
        var responseStreaming: Bool?
        var responseBody: Data?
        let recordedAt: Date
    }

    struct KeepaliveWarmSource: Sendable {
        let selection: KeepaliveSelection
        let exchange: KeepaliveExchange
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
    /// parsed; displayable tree requests are consulted for UI display.
    private var contentTree: ContentTree = ContentTree()

    // Byte counters for throughput and one-shot upload display.
    private var totalBytesReceived: Int = 0
    private var lastRequestBodyBytes: Int = 0

    /// Cumulative estimated cost (USD) across all sessions since the proxy started.
    /// Separate from per-session costs so it survives session expiration.
    private var cumulativeEstimatedCostUSD: Double = 0
    private var cumulativeEstimatedCostUSDByAPI: [ProxyAPIFlavor: Double] = [:]

    /// Active keep-alive selections, keyed by conversation. At most one per
    /// conversation; activating a request whose conversation already has a
    /// selection replaces the previous one.
    private var keepaliveSelections: [UUID: KeepaliveSelection] = [:]

    /// Per-session keep-alive history. Keyed by session ID. Survives selection
    /// removal so the session header `ka $xx (n_ka)` cluster and the bottom
    /// gray ⚡ done row remain visible after Stop or auto-deactivation.
    private var keepaliveHistoryBySession: [String: KeepaliveSessionHistory] = [:]

    /// Bounded ring buffer of recent successful Anthropic Messages
    /// exchanges. Activation pulls from this ring — entries that have
    /// rolled out are no longer eligible. Sized to cover normal Claude
    /// Code interaction patterns; larger buffers cost a few MB of body
    /// data with no concrete user benefit.
    private static let recentKeepaliveExchangeCapacity = 64
    private var recentKeepaliveExchanges: [(requestID: UUID, exchange: KeepaliveExchange)] = []

    /// Source exchanges keyed by request ID. Recent successful requests are
    /// retained for activation; active successors on a selected path are
    /// retained so manual warming can follow the path before a response
    /// frontier exists.
    private var keepaliveExchangesByRequestID: [UUID: KeepaliveExchange] = [:]

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
    /// Fired when a previously-active selection is dropped automatically
    /// (path branched, pruned, session expired). Manual deactivation via
    /// `deactivateKeepalive(forConversationID:)` does not fire this.
    private var onKeepaliveDeactivated: (@Sendable (UUID, KeepaliveDeactivationReason) -> Void)?

    /// Set the traffic callback. Called from outside the actor isolation.
    func setTrafficCallback(_ callback: @escaping @Sendable (TrafficDirection?) -> Void) {
        onTraffic = callback
    }

    /// Set the request-done callback. Called from outside the actor isolation.
    func setRequestDoneCallback(_ callback: @escaping @Sendable () -> Void) {
        onRequestDone = callback
    }

    /// Set the auto-deactivation callback. Called from outside the actor isolation.
    func setKeepaliveDeactivatedCallback(
        _ callback: @escaping @Sendable (UUID, KeepaliveDeactivationReason) -> Void
    ) {
        onKeepaliveDeactivated = callback
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
        previousResponseID: String?,
        keepaliveSource: KeepaliveExchange? = nil
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
        updateKeepalivePathOnAttach(
            conversationID: result.conversationID,
            nodeID: result.nodeID,
            requestID: requestID,
            sessionID: sessionID,
            source: keepaliveSource
        )
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
        responseID: String?,
        completedKeepaliveExchange: KeepaliveExchange? = nil
    ) {
        contentTree.finishRequest(
            requestID: requestID,
            succeeded: succeeded,
            tokenUsage: tokenUsage,
            responseID: responseID
        )
        if succeeded, let completedKeepaliveExchange {
            recordKeepaliveCandidate(forRequestID: requestID, exchange: completedKeepaliveExchange)
        }
        updateKeepalivePathOnFinish(requestID: requestID, succeeded: succeeded)
    }

    /// Prune terminal requests and inactive conversation trees, returning
    /// the IDs removed so callers can mirror deletions to SQLite.
    func pruneContentTree(retention: TimeInterval) -> ContentTree.PruneResult {
        let result = contentTree.prune(retention: retention)
        for removed in result.removedRequestIDs {
            treeDoneActivities.removeValue(forKey: removed)
        }
        // A keep-alive selection cannot survive pruning of the conversation,
        // node, or source request it points at — drop it and notify.
        for (conversationID, selection) in keepaliveSelections {
            let droppedByPrune = result.removedConversationIDs.contains(conversationID)
                || result.removedNodeIDs.contains(selection.nodeID)
                || result.removedRequestIDs.contains(selection.requestID)
                || result.removedNodeIDs.contains(selection.latestSourceNodeID)
                || result.removedRequestIDs.contains(selection.latestSourceRequestID)
            if droppedByPrune {
                keepaliveSelections.removeValue(forKey: conversationID)
                pruneUnreferencedKeepaliveExchanges()
                onKeepaliveDeactivated?(conversationID, .pruned)
            }
        }
        // Drop ring-buffer candidates whose underlying request was pruned.
        // Bounded ring size means this is a tiny scan.
        recentKeepaliveExchanges.removeAll { result.removedRequestIDs.contains($0.requestID) }
        keepaliveExchangesByRequestID = keepaliveExchangesByRequestID.filter { requestID, _ in
            !result.removedRequestIDs.contains(requestID) || keepaliveSourceIsReferenced(requestID)
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
    /// Warm (`.keepalive`) requests bypass the normal `beginRequest` entry point
    /// because they're triggered by user action rather than incoming HTTP. To
    /// keep the session alive while the warm runs and prevent `expireSessions`
    /// from sweeping out from under us, this method also touches the session
    /// and increments inFlight when the kind is `.keepalive`. Organic kinds
    /// rely on `beginRequest` for that bookkeeping.
    func startRequest(
        id: UUID,
        sessionID: String,
        model: String?,
        kind: ProxyRequestKind = .request
    ) {
        if kind == .keepalive {
            touch(sessionID)
            incrementInFlight(sessionID)
        }
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
    /// Returns the final activity snapshot — callers (like the keep-alive
    /// forwarder, whose kind doesn't store a done activity) can persist the
    /// snapshot elsewhere before the entry is discarded.
    @discardableResult
    func markRequestDone(id: UUID, errored: Bool, tokenUsage: TokenUsage?, estimatedCost: Double?) -> ProxyRequestActivity? {
        guard var entry = activeRequests.removeValue(forKey: id) else { return nil }
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
                // Tracked traffic: cache the full activity so displayable tree rows have
                // model name / byte counts / timing / cost even after the in-flight
                // entry is dropped.
                treeDoneActivities[id] = entry.activity
            }
        }

        if var session = sessions[entry.sessionID] {
            if isComplete && entry.activity.kind.storesDoneActivity {
                session.completedRequestCount += 1
            } else if !isComplete && entry.activity.kind.storesDoneActivity {
                session.erroredRequestCount += 1
            }
            session.lastRequestDoneAt = completedAt
            // Warm requests increment inFlight in `startRequest` so the session
            // stays alive across `expireSessions` sweeps; mirror the decrement
            // here so the counter returns to zero on every exit path.
            if entry.activity.kind == .keepalive {
                session.inFlightRequestCount = max(0, session.inFlightRequestCount - 1)
            }
            sessions[entry.sessionID] = session
        }
        onTraffic?(nil)
        if isComplete && entry.activity.kind.firesCostParticle {
            onRequestDone?()
        }
        return entry.activity
    }

    // MARK: - Snapshot

    /// Return a snapshot of all sessions with their stats and in-flight requests.
    func snapshotSessionActivities() -> [SessionSnapshot] {
        var activeRequestsBySession: [String: [ProxyRequestActivity]] = [:]
        for (_, entry) in activeRequests {
            activeRequestsBySession[entry.sessionID, default: []].append(entry.activity)
        }

        // Displayable requests come from the content tree — every successful
        // request without a successful descendant, bucketed into the session
        // that sent it.
        // `isPendingReplacement` flags rows whose node has a descendant with
        // an in-flight request so the UI can dim them pending completion.
        // A conversation can span multiple sessions (rare but legal) so we
        // rely on the sessionID stored on each request. Prefer the cached
        // `ProxyRequestActivity` captured at completion so rows show
        // model / bytes / cost; fall back to a tree-only synthesis if the
        // cache has already expired.
        var displayableActivityBySession: [String: [ProxyRequestActivity]] = [:]
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
            displayableActivityBySession[request.sessionID, default: []].append(activity)
        }

        // For untracked sessions ("other" or missing flavor) merge in the
        // short-retention done bucket.
        for (sessionID, requests) in doneRequestsBySession {
            displayableActivityBySession[sessionID, default: []].append(contentsOf: requests)
        }

        var selectionsBySession: [String: [KeepaliveSelection]] = [:]
        for selection in keepaliveSelections.values {
            selectionsBySession[selection.sessionID, default: []].append(selection)
        }

        return sessions.values.map { session in
            // Organic done leaves first, sorted by completion time. Then pin the
            // most recent warm done from the session history bucket at the very
            // end — per docs/proxy-keepalive.md, warm done rows live outside the
            // lineage tree and only the latest survives per session.
            var doneRequests = (displayableActivityBySession[session.sessionID] ?? [])
                .sorted { ($0.completedAt ?? $0.startedAt) < ($1.completedAt ?? $1.startedAt) }
            let history = keepaliveHistoryBySession[session.sessionID]
            if let warm = history?.lastWarmActivity {
                doneRequests.append(warm)
            }
            return SessionSnapshot(
                sessionID: session.sessionID,
                startedAt: session.startedAt,
                lastSeenAt: session.lastSeenAt,
                lastRequestDoneAt: session.lastRequestDoneAt,
                completedRequestCount: session.completedRequestCount,
                erroredRequestCount: session.erroredRequestCount,
                activeRequests: activeRequestsBySession[session.sessionID] ?? [],
                doneRequests: doneRequests,
                totalInputTokens: session.totalInputTokens,
                totalOutputTokens: session.totalOutputTokens,
                totalCacheReadInputTokens: session.totalCacheReadInputTokens,
                totalCacheCreationInputTokens: session.totalCacheCreationInputTokens,
                estimatedCostUSD: session.estimatedCostUSD,
                keepaliveSelections: selectionsBySession[session.sessionID] ?? [],
                keepaliveCostUSD: history?.cumulativeCostUSD ?? 0,
                keepaliveDoneCount: history?.cumulativeWarmCount ?? 0
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
            keepaliveHistoryBySession.removeValue(forKey: id)
        }
        // Drop cached done activities whose tree-side request belonged
        // to an expired session. Rare (the content tree usually outlives
        // sessions) but keeps memory from leaking across evictions.
        treeDoneActivities = treeDoneActivities.filter { requestID, _ in
            guard let request = contentTree.requests[requestID] else { return false }
            return !expiredSet.contains(request.sessionID)
        }
        // Drop selections whose visible or latest source session has expired.
        // The conversation can outlive any single session bucket but the
        // warm source is tied to observed request material from that session.
        for (conversationID, selection) in keepaliveSelections
            where expiredSet.contains(selection.sessionID)
                || expiredSet.contains(selection.latestSourceSessionID) {
            keepaliveSelections.removeValue(forKey: conversationID)
            pruneUnreferencedKeepaliveExchanges()
            onKeepaliveDeactivated?(conversationID, .sessionExpired)
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

    // MARK: - Keep-alive selection

    /// Activate keep-alive on the lineage path leading to the given done
    /// request. The selection is stored against the request's conversation.
    ///
    /// Always creates a fresh selection; there is no resume path.
    /// Activating on any request replaces the prior selection for that
    /// conversation. Historical stats remain in `keepaliveHistoryBySession`
    /// and are unaffected by selection replacement.
    ///
    /// Refuses when the request's exchange has already rolled out of the
    /// recent ring — the warm forwarder needs the source body and headers.
    func activateKeepalive(forRequestID requestID: UUID) -> KeepaliveActivationResult {
        guard let request = contentTree.requests[requestID] else {
            return .unknownRequest
        }
        guard request.finishedAt != nil else {
            return .requestStillInFlight
        }
        guard request.succeeded else {
            return .requestErrored
        }
        guard let node = contentTree.nodes[request.nodeID],
              let conversation = contentTree.conversation(withID: node.conversationID) else {
            return .unknownRequest
        }
        guard conversation.fingerprint.flavor == .anthropicMessages else {
            return .unsupportedFlavor
        }
        guard let recent = recentKeepaliveExchanges.first(where: { $0.requestID == requestID }) else {
            return .sourceBodyUnavailable
        }
        keepaliveExchangesByRequestID[requestID] = recent.exchange
        let selection = KeepaliveSelection(
            conversationID: conversation.id,
            nodeID: node.id,
            requestID: requestID,
            sessionID: request.sessionID,
            latestSourceNodeID: node.id,
            latestSourceRequestID: requestID,
            latestSourceSessionID: request.sessionID,
            latestSourceIsActive: false,
            activatedAt: Date(),
            lastWarmStartedAt: nil,
            lastReminderSourceNodeID: nil,
            lastReminderSourceRequestID: nil,
            lastReminderQuietReferenceAt: nil,
            inFlightWarmRequestID: nil
        )
        keepaliveSelections[conversation.id] = selection
        onTraffic?(nil)
        return .activated(selection)
    }

    /// Manual deactivation. Removes the selection entirely — the orange KA anchor
    /// accent disappears and path tracking stops. Historical KA stats survive
    /// in the per-session `keepaliveHistoryBySession` bucket. Does not fire
    /// the auto-deactivate callback because the user took the action.
    func deactivateKeepalive(forConversationID conversationID: UUID) {
        let removedSelection = keepaliveSelections.removeValue(forKey: conversationID)
        if removedSelection != nil {
            pruneUnreferencedKeepaliveExchanges()
            onTraffic?(nil)
        }
    }

    /// Cache one upstream exchange as a future keep-alive activation
    /// candidate. Called by the forwarder for every successful Anthropic
    /// Messages generation. Older entries fall off when the ring is full.
    func recordKeepaliveCandidate(forRequestID requestID: UUID, exchange: KeepaliveExchange) {
        keepaliveExchangesByRequestID[requestID] = exchange
        recentKeepaliveExchanges.removeAll { $0.requestID == requestID }
        recentKeepaliveExchanges.append((requestID, exchange))
        while recentKeepaliveExchanges.count > Self.recentKeepaliveExchangeCapacity {
            let evicted = recentKeepaliveExchanges.removeFirst()
            if !keepaliveSourceIsReferenced(evicted.requestID) {
                keepaliveExchangesByRequestID.removeValue(forKey: evicted.requestID)
            }
        }
    }

    /// Look up the anchor exchange for an active selection. Used by
    /// the warm forwarder to assemble a synthesized warm body. Nil when
    /// the selection has been cleared or auto-deactivated.
    func keepaliveWarmSource(forConversationID conversationID: UUID) -> KeepaliveWarmSource? {
        guard let selection = keepaliveSelections[conversationID],
              let exchange = keepaliveExchangesByRequestID[selection.requestID] else {
            return nil
        }
        return KeepaliveWarmSource(selection: selection, exchange: exchange)
    }

    /// Atomically begin a manual warm dispatch. Returns `.dispatched` with the
    /// warm source and a fresh warm UUID when no warm is currently in flight
    /// for the conversation, marking the selection as in-flight. Returns
    /// `.alreadyInFlight` when a previous warm is still mid-dispatch, or
    /// `.notSelected` when the conversation has no active selection or its
    /// source exchange has been pruned.
    func beginManualKeepaliveDispatch(
        forConversationID conversationID: UUID
    ) -> KeepaliveDispatchOutcome {
        guard var selection = keepaliveSelections[conversationID],
              let exchange = keepaliveExchangesByRequestID[selection.requestID] else {
            return .notSelected
        }
        if selection.inFlightWarmRequestID != nil {
            return .alreadyInFlight
        }
        let startedAt = Date()
        let warmID = UUID()
        selection.inFlightWarmRequestID = warmID
        selection.lastWarmStartedAt = startedAt
        keepaliveSelections[conversationID] = selection
        return .dispatched(
            KeepaliveWarmSource(selection: selection, exchange: exchange),
            warmID: warmID
        )
    }

    /// Atomically validate a reminder action and begin a warm dispatch.
    /// Stale notification clicks no-op before the forwarder sees any source
    /// material or sends anything upstream.
    func beginReminderKeepaliveDispatch(
        reminder: KeepaliveReminder,
        now: Date = Date()
    ) -> KeepaliveDispatchOutcome {
        let reminderExpiresAt = reminder.issuedAt.addingTimeInterval(Self.keepaliveReminderActionWindowSeconds)
        guard now <= reminderExpiresAt else {
            ProxyLogger.log("Keep-alive: stale reminder action expired for conversation \(reminder.conversationID)")
            return .notSelected
        }
        guard var selection = keepaliveSelections[reminder.conversationID],
              let exchange = keepaliveExchangesByRequestID[selection.requestID] else {
            ProxyLogger.log("Keep-alive: stale reminder action has no active selection for conversation \(reminder.conversationID)")
            return .notSelected
        }
        guard selection.conversationID == reminder.conversationID,
              selection.nodeID == reminder.sourceNodeID,
              selection.requestID == reminder.sourceRequestID,
              selection.sessionID == reminder.sourceSessionID else {
            ProxyLogger.log("Keep-alive: stale reminder action source changed for conversation \(reminder.conversationID)")
            return .notSelected
        }
        guard let currentReference = keepaliveQuietReference(for: selection),
              currentReference == reminder.quietReferenceAt else {
            ProxyLogger.log("Keep-alive: stale reminder action reference changed for conversation \(reminder.conversationID)")
            return .notSelected
        }
        if let lastWarmStartedAt = selection.lastWarmStartedAt,
           lastWarmStartedAt > reminder.issuedAt {
            ProxyLogger.log("Keep-alive: stale reminder action follows a newer warm attempt for conversation \(reminder.conversationID)")
            return .notSelected
        }
        if selection.inFlightWarmRequestID != nil {
            ProxyLogger.log("Keep-alive: refusing reminder warm — already in flight for conversation \(reminder.conversationID)")
            return .alreadyInFlight
        }

        let warmID = UUID()
        selection.inFlightWarmRequestID = warmID
        selection.lastWarmStartedAt = now
        keepaliveSelections[reminder.conversationID] = selection
        return .dispatched(
            KeepaliveWarmSource(selection: selection, exchange: exchange),
            warmID: warmID
        )
    }

    /// Returns reminder notifications whose source has been quiet for 4m30s.
    /// Each source request/node/quiet-reference tuple emits at most once.
    func dueKeepaliveReminders(now: Date = Date()) -> [KeepaliveReminder] {
        var reminders: [KeepaliveReminder] = []
        for (conversationID, var selection) in keepaliveSelections {
            guard selection.inFlightWarmRequestID == nil,
                  let quietReferenceAt = keepaliveQuietReference(for: selection) else {
                continue
            }

            let dueAt = quietReferenceAt.addingTimeInterval(Self.keepaliveReminderDelaySeconds)
            guard now >= dueAt else { continue }
            // Issuance window is intentionally short. Past `dueAt + 20s`
            // (i.e. ~5m of source quiet) the Anthropic ephemeral cache is
            // already at or beyond TTL, so a "reminder" loses its purpose
            // — sending a warm then would create new cache rather than
            // refresh existing cache. The refresh loop ticks frequently
            // enough during normal proxy use that the window is rarely
            // missed; we accept the silent drop in pathological cases
            // (machine sleep/wake, suspended popover) instead of issuing
            // a misleading reminder for a cache that's already gone.
            let expiresAt = dueAt.addingTimeInterval(Self.keepaliveReminderActionWindowSeconds)
            guard now <= expiresAt else { continue }

            let alreadyReminded = selection.lastReminderSourceNodeID == selection.nodeID
                && selection.lastReminderSourceRequestID == selection.requestID
                && selection.lastReminderQuietReferenceAt == quietReferenceAt
            guard !alreadyReminded else { continue }

            selection.lastReminderSourceNodeID = selection.nodeID
            selection.lastReminderSourceRequestID = selection.requestID
            selection.lastReminderQuietReferenceAt = quietReferenceAt
            keepaliveSelections[conversationID] = selection

            reminders.append(KeepaliveReminder(
                conversationID: conversationID,
                sourceNodeID: selection.nodeID,
                sourceRequestID: selection.requestID,
                sourceSessionID: selection.sessionID,
                quietReferenceAt: quietReferenceAt,
                issuedAt: now
            ))
        }
        return reminders
    }

    func keepaliveSelection(forConversationID conversationID: UUID) -> KeepaliveSelection? {
        keepaliveSelections[conversationID]
    }

    func allKeepaliveSelections() -> [KeepaliveSelection] {
        Array(keepaliveSelections.values)
    }

    /// Record the outcome of a synthesized warm request.
    ///
    /// Cost rollup is unconditional — the warm cost lands in the session's
    /// `estimatedCostUSD` and the proxy's per-API breakdown even if the
    /// selection has been removed (user clicked Stop, or auto-deactivation
    /// fired) before the upstream response landed. Otherwise the user is
    /// billed for warm dollars that never appear in any aggregate.
    ///
    /// History bucket update is unconditional — `keepaliveHistoryBySession`
    /// persists across stop/restart cycles so the session header and the
    /// bottom gray ⚡ done row remain visible after deactivation.
    ///
    /// Selection-specific state (only `inFlightWarmRequestID`) is cleared
    /// when the selection still exists.
    func recordKeepaliveResult(
        conversationID: UUID,
        sessionID: String,
        warmID: UUID?,
        estimatedCostUSD: Double,
        warmActivity: ProxyRequestActivity?
    ) {
        let addedCost = max(0, estimatedCostUSD)

        // Cost rollup into session + proxy-wide totals — unconditional.
        if addedCost > 0 {
            if var session = sessions[sessionID] {
                session.estimatedCostUSD += addedCost
                sessions[sessionID] = session
            }
            accumulateCost(addedCost, for: .anthropicMessages)
        }

        // History bucket — unconditional. Survives selection removal.
        var history = keepaliveHistoryBySession[sessionID] ?? KeepaliveSessionHistory()
        history.cumulativeCostUSD += addedCost
        history.cumulativeWarmCount += 1
        if let warmActivity {
            history.lastWarmActivity = warmActivity
        }
        keepaliveHistoryBySession[sessionID] = history

        // Selection-specific updates only when the selection still exists.
        if var selection = keepaliveSelections[conversationID] {
            if let warmID, selection.inFlightWarmRequestID == warmID {
                selection.inFlightWarmRequestID = nil
            }
            keepaliveSelections[conversationID] = selection
        }
        onTraffic?(nil)
    }

    // MARK: - Private helpers

    private func updateKeepalivePathOnAttach(
        conversationID: UUID,
        nodeID: UUID,
        requestID: UUID,
        sessionID: String,
        source: KeepaliveExchange?
    ) {
        guard var selection = keepaliveSelections[conversationID],
              nodeID != selection.nodeID,
              isDescendant(nodeID, of: selection.nodeID) else {
            return
        }

        if let source {
            keepaliveExchangesByRequestID[requestID] = source
        }

        let activeDescendants = activeDescendantRequests(of: selection.nodeID)
        if activeDescendants.count > 1 {
            // Path branched — remove the selection entirely and notify.
            keepaliveSelections.removeValue(forKey: conversationID)
            pruneUnreferencedKeepaliveExchanges()
            onKeepaliveDeactivated?(conversationID, .pathBranched)
            return
        }

        guard activeDescendants.contains(requestID) else { return }
        selection.latestSourceNodeID = nodeID
        selection.latestSourceRequestID = requestID
        selection.latestSourceSessionID = sessionID
        selection.latestSourceIsActive = true
        keepaliveSelections[conversationID] = selection
    }

    private func updateKeepalivePathOnFinish(requestID: UUID, succeeded: Bool) {
        guard let conversationID = keepaliveSelections.first(where: {
            $0.value.latestSourceRequestID == requestID && $0.value.latestSourceIsActive
        })?.key,
              var selection = keepaliveSelections[conversationID] else {
            return
        }

        if succeeded {
            selection.nodeID = selection.latestSourceNodeID
            selection.requestID = selection.latestSourceRequestID
            selection.sessionID = selection.latestSourceSessionID
            selection.latestSourceIsActive = false
        } else {
            selection.latestSourceNodeID = selection.nodeID
            selection.latestSourceRequestID = selection.requestID
            selection.latestSourceSessionID = selection.sessionID
            selection.latestSourceIsActive = false
        }
        keepaliveSelections[conversationID] = selection
        if !succeeded {
            pruneUnreferencedKeepaliveExchanges()
        }
        onTraffic?(nil)
    }

    private func activeDescendantRequests(of nodeID: UUID) -> [UUID] {
        var result: [UUID] = []
        var stack = contentTree.childrenByNode[nodeID] ?? []
        while let current = stack.popLast() {
            for requestID in contentTree.requestsByNode[current] ?? [] {
                if let request = contentTree.requests[requestID], request.finishedAt == nil {
                    result.append(requestID)
                }
            }
            stack.append(contentsOf: contentTree.childrenByNode[current] ?? [])
        }
        return result
    }

    private func isDescendant(_ nodeID: UUID, of ancestorID: UUID) -> Bool {
        var cursor = contentTree.nodes[nodeID]?.parentNodeID
        while let current = cursor {
            if current == ancestorID { return true }
            cursor = contentTree.nodes[current]?.parentNodeID
        }
        return false
    }

    private func keepaliveSourceIsReferenced(_ requestID: UUID) -> Bool {
        keepaliveSelections.values.contains {
            $0.requestID == requestID || $0.latestSourceRequestID == requestID
        }
    }

    private func keepaliveQuietReference(for selection: KeepaliveSelection) -> Date? {
        // Quiet reference is anchored to the most recent cache-write event:
        // either the anchor done's terminal finish time, or the last warm we
        // dispatched (whichever is later). An active descendant reading the
        // cached prefix mid-generation does not extend the cache TTL in a way
        // that helps the warming purpose, so we deliberately ignore
        // `latestSource*.lastDataAt` here.
        let sourceReference: Date?
        if let request = contentTree.requests[selection.requestID] {
            sourceReference = request.finishedAt
        } else {
            sourceReference = treeDoneActivities[selection.requestID]?.completedAt
        }

        guard let sourceReference else { return nil }
        switch selection.lastWarmStartedAt {
        case .some(let warm):
            return max(sourceReference, warm)
        case .none:
            return sourceReference
        }
    }

    private func pruneUnreferencedKeepaliveExchanges() {
        let recentIDs = Set(recentKeepaliveExchanges.map { $0.requestID })
        keepaliveExchangesByRequestID = keepaliveExchangesByRequestID.filter { requestID, _ in
            recentIDs.contains(requestID) || keepaliveSourceIsReferenced(requestID)
        }
    }

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
