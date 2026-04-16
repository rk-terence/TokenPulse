import Foundation

/// Lifecycle owner for the local proxy. `@MainActor` for UI binding only —
/// the server, forwarder, stores all run off main.
@MainActor
@Observable
final class LocalProxyController {
    private static let sessionExpirationSweepInterval: TimeInterval = 10
    private static let sessionRetentionSeconds: TimeInterval = 24 * 60 * 60
    private static let sessionVisibilitySeconds: TimeInterval = 10 * 60
    private static let sideTrafficDoneRetentionSeconds: TimeInterval = 5 * 60
    private static let otherTrafficRetentionSeconds: TimeInterval = 60

    // MARK: - Per-session activity snapshot for UI

    struct SessionActivity: Sendable, Identifiable {
        let sessionID: String
        let completedRequests: Int
        let erroredRequests: Int
        let keepaliveCount: Int
        let activeRequests: [ProxyRequestActivity]
        let doneRequests: [ProxyRequestActivity]
        let totalInputTokens: Int
        let totalOutputTokens: Int
        let totalCacheReadInputTokens: Int
        let totalCacheCreationInputTokens: Int
        let estimatedCostUSD: Double
        let isKeepaliveDisabled: Bool
        let keepaliveDisabledReason: String?
        let keepaliveMode: KeepaliveMode
        /// Whether lineage is established and a keepalive body is available for manual send.
        let lineageReady: Bool
        let lastKeepaliveAt: Date?
        /// Cache read percentage from the last keepalive response (0–100), nil if no keepalive yet.
        let lastKeepaliveCacheReadPercent: Double?
        /// Output tokens from the last keepalive response, for verification.
        let lastKeepaliveOutputTokens: Int?

        var id: String { sessionID }
        var apiFlavor: ProxyAPIFlavor? { ProxySessionID.flavor(for: sessionID) }
        var displayID: String { ProxySessionID.displayID(for: sessionID) }
        /// First 8 characters of the display session ID — enough to distinguish sessions in the UI.
        var shortID: String { ProxySessionID.shortDisplayID(for: sessionID) }
        var agentName: String? { apiFlavor?.sessionAgentName }
        var rowTitle: String {
            ProxySessionID.isOther(sessionID) ? displayID : shortID
        }
        var isOtherTraffic: Bool { ProxySessionID.isOther(sessionID) }
        var supportsKeepalive: Bool { apiFlavor?.supportsKeepalive ?? false }
        /// Whether a manual keepalive can be sent right now.
        var canSendKeepalive: Bool {
            keepaliveMode == .manual && !isKeepaliveDisabled && lineageReady
        }
    }

    // MARK: - Aggregate metrics snapshot for UI

    struct ProxyStatus: Sendable {
        let activeSessions: Int
        let activeKeepalives: Int
        let totalRequestsForwarded: Int
        let totalKeepalivesSent: Int
        let totalKeepalivesFailed: Int
        let cacheReads: Int
        let cacheWrites: Int
        let estimatedSavings: Double
        let totalInputTokens: Int
        let totalOutputTokens: Int
        let totalCacheReadInputTokens: Int
        let totalCacheCreationInputTokens: Int
        let totalEstimatedCostUSD: Double
        let estimatedCostUSDByAPI: [ProxyAPIFlavor: Double]

        static let empty = ProxyStatus(
            activeSessions: 0, activeKeepalives: 0,
            totalRequestsForwarded: 0, totalKeepalivesSent: 0,
            totalKeepalivesFailed: 0, cacheReads: 0, cacheWrites: 0,
            estimatedSavings: 0,
            totalInputTokens: 0, totalOutputTokens: 0,
            totalCacheReadInputTokens: 0, totalCacheCreationInputTokens: 0,
            totalEstimatedCostUSD: 0,
            estimatedCostUSDByAPI: [:]
        )
    }

    private(set) var isRunning = false
    private(set) var listeningPort: Int = 0
    private(set) var proxyStatus: ProxyStatus = .empty
    private(set) var sessionActivities: [SessionActivity] = []
    /// Size of the most recent upstream request body in bytes (one-shot, not rate).
    private(set) var lastUploadBytes: Int = 0
    /// Download throughput in bytes per second, computed from cumulative deltas every refresh tick.
    private(set) var downloadBytesPerSec: Double = 0

    /// Called on the main actor when the proxy detects data traffic (upload or download).
    var onTrafficEvent: (() -> Void)?

    private var server: ProxyHTTPServer?
    private let sessionStore = ProxySessionStore()
    private let metricsStore = ProxyMetricsStore()
    private let anthropicAPIHandler: any ProxyAPIHandler = AnthropicProxyAPIHandler()
    private let openAIAPIHandler: any ProxyAPIHandler = OpenAIResponsesProxyAPIHandler()
    private var anthropicForwarder: ProxyForwarder?
    private var openAIForwarder: ProxyForwarder?
    private var eventLogger: ProxyEventLogger?
    private var refreshTask: Task<Void, Never>?
    private var trafficRefreshTask: Task<Void, Never>?
    private var trafficRefreshPending = false
    private var currentAnthropicUpstreamURL: String?

    /// Session IDs currently sending a manual keepalive request.
    private(set) var manualKeepaliveInFlight: Set<String> = []
    /// Last manual keepalive result per session (true = success, false = failure).
    private(set) var manualKeepaliveLastResult: [String: Bool] = [:]

    /// Start the proxy server on the given port, serving both supported API routes.
    func start(port: Int, anthropicUpstreamURL: String, openAIUpstreamURL: String) {
        guard server == nil else { return }

        // Read config from ConfigService (both are @MainActor, safe here).
        let config = ConfigService.shared
        currentAnthropicUpstreamURL = anthropicUpstreamURL

        let logger = ProxyEventLogger(
            enabled: config.saveProxyEventLog || config.saveProxyPayloads,
            capturesContent: config.saveProxyPayloads
        )
        self.eventLogger = logger

        let anthropicForwarder = ProxyForwarder(
            upstreamBaseURL: anthropicUpstreamURL,
            apiFlavor: .anthropicMessages,
            apiHandler: anthropicAPIHandler,
            eventLogger: logger,
            proxyPort: port
        )
        let openAIForwarder = ProxyForwarder(
            upstreamBaseURL: openAIUpstreamURL,
            apiFlavor: .openAIResponses,
            apiHandler: openAIAPIHandler,
            eventLogger: logger,
            proxyPort: port
        )
        self.anthropicForwarder = anthropicForwarder
        self.openAIForwarder = openAIForwarder

        // Wire traffic events from session store to MainActor callback.
        Task { [weak self] in
            guard let self else { return }
            let store = self.sessionStore
            await store.setTrafficCallback { [weak self] in
                Task { @MainActor [weak self] in
                    self?.onTrafficEvent?()
                    self?.scheduleTrafficRefresh()
                }
            }
        }

        // Capture actor-isolated stores for the handler closure.
        let sessStore = sessionStore
        let metStore = metricsStore
        let anthropicHandler = anthropicAPIHandler
        let openAIHandler = openAIAPIHandler

        do {
            var startedServer: ProxyHTTPServer?
            let httpServer = try ProxyHTTPServer(
                port: UInt16(clamping: port),
                requestValidator: { method, path in
                    if anthropicHandler.acceptsRequest(method: method, path: path)
                        || openAIHandler.acceptsRequest(method: method, path: path) {
                        return .accepted
                    }

                    // Path matches a known route but method is wrong (e.g. GET /v1/messages).
                    if anthropicHandler.acceptsRequest(method: "POST", path: path)
                        || openAIHandler.acceptsRequest(method: "POST", path: path) {
                        return .rejected(
                            status: 405,
                            message: String(localized: "Method Not Allowed: only POST is supported")
                        )
                    }
                    return .rejected(
                        status: 404,
                        message: String(
                            format: NSLocalizedString(
                                "proxy.notFound.route",
                                value: "Not Found: only %@ and %@ are supported",
                                comment: ""
                            ),
                            ProxyAPIFlavor.anthropicMessages.supportedRouteDescription,
                            ProxyAPIFlavor.openAIResponses.supportedRouteDescription
                        )
                    )
                },
                errorBodyBuilder: { message in
                    Self.errorBody(
                        forPath: nil,
                        message: message,
                        anthropicHandler: anthropicHandler,
                        openAIHandler: openAIHandler
                    )
                },
                handler: { @Sendable request in
                    let route = Self.route(
                        for: request.path,
                        anthropicHandler: anthropicHandler,
                        openAIHandler: openAIHandler
                    )
                    let forwarder = Self.forwarder(
                        for: route,
                        anthropicForwarder: anthropicForwarder,
                        openAIForwarder: openAIForwarder
                    )
                    guard let forwarder else {
                        let body = Self.errorBody(
                            forPath: request.path,
                            message: String(localized: "Not Found"),
                            anthropicHandler: anthropicHandler,
                            openAIHandler: openAIHandler
                        )
                        request.writer.writeHead(
                            status: 404,
                            headers: [
                                (name: "Content-Type", value: Self.jsonContentType),
                                (name: "Content-Length", value: "\(body.count)")
                            ]
                        )
                        request.writer.writeChunk(body)
                        request.writer.end()
                        return
                    }
                    await forwarder.forward(
                        request: request,
                        sessionStore: sessStore,
                        metrics: metStore
                    )
                },
                onReady: { [weak self] actualPort in
                    Task { @MainActor [weak self] in
                        guard let self, let startedServer, self.server === startedServer else { return }
                        self.listeningPort = Int(actualPort)
                        self.isRunning = true
                        ProxyLogger.log("Proxy controller started on port \(self.listeningPort)")
                        self.startRefreshTask()
                        await logger.logProxyStarted(port: self.listeningPort)
                    }
                },
                onFailure: { [weak self] errorMessage in
                    Task { @MainActor [weak self] in
                        guard let self, let startedServer, self.server === startedServer else { return }
                        self.refreshTask?.cancel()
                        self.refreshTask = nil
                        self.server = nil
                        self.anthropicForwarder = nil
                        self.openAIForwarder = nil
                        self.eventLogger = nil
                        self.currentAnthropicUpstreamURL = nil
                        self.isRunning = false
                        self.listeningPort = 0
                        self.proxyStatus = .empty
                        ProxyLogger.log("Failed to start proxy server: \(errorMessage)")
                        await logger.close()
                    }
                }
            )
            startedServer = httpServer
            httpServer.start()
            self.server = httpServer
        } catch {
            currentAnthropicUpstreamURL = nil
            ProxyLogger.log("Failed to start proxy server: \(error)")
        }
    }

    /// Stop the proxy server.
    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        trafficRefreshTask?.cancel()
        trafficRefreshTask = nil
        trafficRefreshPending = false

        server?.stop()
        server = nil
        anthropicForwarder = nil
        openAIForwarder = nil

        let logger = eventLogger
        let metStore = metricsStore

        Task {
            guard let logger else { return }
            await logger.logProxyStopped()
            let snapshot = await metStore.snapshot()
            await logger.writeStatusSnapshot(
                enabled: false,
                port: 0,
                activeSessions: 0,
                activeKeepalives: 0,
                metrics: snapshot,
                force: true
            )
            await logger.close()
        }
        eventLogger = nil

        isRunning = false
        listeningPort = 0
        proxyStatus = .empty
        sessionActivities = []
        lastUploadBytes = 0
        downloadBytesPerSec = 0
        currentAnthropicUpstreamURL = nil
        manualKeepaliveInFlight.removeAll()
        manualKeepaliveLastResult.removeAll()
        ProxyLogger.log("Proxy controller stopped")
    }

    /// Reset the cumulative proxy cost estimate to zero.
    func resetCost() async {
        await sessionStore.resetCost()
        var s = proxyStatus
        s = ProxyStatus(
            activeSessions: s.activeSessions,
            activeKeepalives: s.activeKeepalives,
            totalRequestsForwarded: s.totalRequestsForwarded,
            totalKeepalivesSent: s.totalKeepalivesSent,
            totalKeepalivesFailed: s.totalKeepalivesFailed,
            cacheReads: s.cacheReads,
            cacheWrites: s.cacheWrites,
            estimatedSavings: s.estimatedSavings,
            totalInputTokens: s.totalInputTokens,
            totalOutputTokens: s.totalOutputTokens,
            totalCacheReadInputTokens: s.totalCacheReadInputTokens,
            totalCacheCreationInputTokens: s.totalCacheCreationInputTokens,
            totalEstimatedCostUSD: 0,
            estimatedCostUSDByAPI: [:]
        )
        proxyStatus = s
    }

    /// Set the keepalive mode for a specific session (user-initiated).
    func setSessionKeepaliveMode(_ mode: KeepaliveMode, for sessionID: String) {
        guard ProxySessionID.flavor(for: sessionID)?.supportsKeepalive == true else { return }
        let sessStore = sessionStore
        Task {
            await sessStore.setKeepaliveMode(mode, for: sessionID)
        }
    }

    /// Send a single manual keepalive request for a session.
    func sendManualKeepalive(for sessionID: String) {
        guard !manualKeepaliveInFlight.contains(sessionID) else { return }
        guard let upstreamURL = currentAnthropicUpstreamURL else { return }

        manualKeepaliveInFlight.insert(sessionID)
        manualKeepaliveLastResult.removeValue(forKey: sessionID)

        let sessStore = sessionStore
        let metStore = metricsStore
        let handler = anthropicAPIHandler
        let logger = eventLogger

        Task { [weak self] in
            let result = await Self.performManualKeepalive(
                sessionID: sessionID,
                upstreamBaseURL: upstreamURL,
                sessionStore: sessStore,
                metricsStore: metStore,
                apiHandler: handler,
                eventLogger: logger
            )

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.manualKeepaliveInFlight.remove(sessionID)
                self.manualKeepaliveLastResult[sessionID] = result
            }

            // Clear the result indicator after a brief delay.
            try? await Task.sleep(for: .seconds(2))
            await MainActor.run { [weak self] in
                _ = self?.manualKeepaliveLastResult.removeValue(forKey: sessionID)
            }
        }
    }

    /// Perform a single keepalive request. Returns true on success, false on failure.
    private nonisolated static func performManualKeepalive(
        sessionID: String,
        upstreamBaseURL: String,
        sessionStore: ProxySessionStore,
        metricsStore: ProxyMetricsStore,
        apiHandler: any ProxyAPIHandler,
        eventLogger: ProxyEventLogger?
    ) async -> Bool {
        guard await sessionStore.canSendManualKeepalive(for: sessionID) else { return false }

        guard let keepaliveSource = await sessionStore.keepaliveRequestContext(for: sessionID) else {
            return false
        }
        let lineageBody = keepaliveSource.body
        guard let keepaliveBody = apiHandler.buildKeepaliveBody(from: lineageBody) else {
            return false
        }

        let lineageHeaders = keepaliveSource.headers
        let urlString = upstreamBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            + apiHandler.keepaliveRequestPath
        guard let url = URL(string: urlString) else { return false }

        let model = apiHandler.extractModel(from: lineageBody)
        let requestID = UUID()
        await sessionStore.startRequest(
            id: requestID,
            sessionID: sessionID,
            model: model,
            promptDescriptor: nil,
            isMainAgentShaped: false,
            kind: .keepalive
        )
        await sessionStore.updateRequestBytesSent(id: requestID, totalBytesSent: keepaliveBody.count)
        await sessionStore.markRequestWaiting(id: requestID)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = keepaliveBody
        for header in lineageHeaders {
            let lowered = header.name.lowercased()
            if lowered == "host" || lowered == "content-length" || lowered == "transfer-encoding" {
                continue
            }
            request.addValue(header.value, forHTTPHeaderField: header.name)
        }

        let startedAt = Date()
        let keepaliveID = await eventLogger?.logKeepaliveSent(session: sessionID)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let httpResponse = response as? HTTPURLResponse
            let statusCode = httpResponse?.statusCode ?? 0
            await sessionStore.markRequestReceiving(id: requestID)
            if !data.isEmpty {
                await sessionStore.markFirstDataReceived(id: requestID)
                await sessionStore.updateRequestBytes(id: requestID, additionalBytes: data.count)
            }

            await metricsStore.recordKeepaliveSent()

            if statusCode >= 200 && statusCode < 300 {
                let tokenUsage = apiHandler.parseTokenUsage(from: data, streaming: false)
                let requestCost = ModelPricingTable.pricing(for: model).map { tokenUsage.cost(for: $0) }
                await sessionStore.recordKeepaliveResult(
                    for: sessionID,
                    success: true,
                    tokenUsage: tokenUsage,
                    apiFlavor: .anthropicMessages
                )
                await sessionStore.markRequestDone(
                    id: requestID,
                    errored: false,
                    tokenUsage: tokenUsage,
                    estimatedCost: requestCost
                )
                await eventLogger?.logKeepaliveCompleted(
                    keepaliveID: keepaliveID,
                    session: sessionID,
                    success: true,
                    statusCode: statusCode,
                    durationMs: ProxyHTTPUtils.elapsedMilliseconds(since: startedAt),
                    upstreamRequestID: nil,
                    tokenUsage: tokenUsage,
                    error: nil
                )
                return true
            } else {
                await metricsStore.recordKeepaliveFailed()
                await sessionStore.recordKeepaliveResult(
                    for: sessionID,
                    success: false,
                    tokenUsage: .empty,
                    apiFlavor: .anthropicMessages
                )
                await sessionStore.markRequestDone(id: requestID, errored: true, tokenUsage: nil, estimatedCost: nil)
                await eventLogger?.logKeepaliveCompleted(
                    keepaliveID: keepaliveID,
                    session: sessionID,
                    success: false,
                    statusCode: statusCode,
                    durationMs: ProxyHTTPUtils.elapsedMilliseconds(since: startedAt),
                    upstreamRequestID: nil,
                    tokenUsage: .empty,
                    error: "HTTP \(statusCode)"
                )
                return false
            }
        } catch {
            await metricsStore.recordKeepaliveFailed()
            await sessionStore.recordKeepaliveResult(
                for: sessionID,
                success: false,
                tokenUsage: .empty,
                apiFlavor: .anthropicMessages
            )
            await sessionStore.markRequestDone(id: requestID, errored: true, tokenUsage: nil, estimatedCost: nil)
            await eventLogger?.logKeepaliveCompleted(
                keepaliveID: keepaliveID,
                session: sessionID,
                success: false,
                statusCode: nil,
                durationMs: ProxyHTTPUtils.elapsedMilliseconds(since: startedAt),
                upstreamRequestID: nil,
                tokenUsage: .empty,
                error: error.localizedDescription
            )
            return false
        }
    }

    nonisolated private static func route(
        for path: String,
        anthropicHandler: any ProxyAPIHandler,
        openAIHandler: any ProxyAPIHandler
    ) -> ProxyAPIFlavor? {
        if anthropicHandler.acceptsRequest(method: "POST", path: path) {
            return .anthropicMessages
        }
        if openAIHandler.acceptsRequest(method: "POST", path: path) {
            return .openAIResponses
        }
        return nil
    }

    nonisolated private static func forwarder(
        for flavor: ProxyAPIFlavor?,
        anthropicForwarder: ProxyForwarder?,
        openAIForwarder: ProxyForwarder?
    ) -> ProxyForwarder? {
        switch flavor {
        case .anthropicMessages:
            return anthropicForwarder
        case .openAIResponses:
            return openAIForwarder
        case nil:
            return nil
        }
    }

    nonisolated private static func errorBody(
        forPath path: String?,
        message: String,
        anthropicHandler: any ProxyAPIHandler,
        openAIHandler: any ProxyAPIHandler
    ) -> Data {
        switch route(for: path ?? "", anthropicHandler: anthropicHandler, openAIHandler: openAIHandler) {
        case .openAIResponses:
            return openAIHandler.proxyErrorBody(message: message)
        case .anthropicMessages, nil:
            return anthropicHandler.proxyErrorBody(message: message)
        }
    }

    nonisolated private static var jsonContentType: String { "application/json" }

    /// Refresh session activities immediately in response to a traffic event.
    /// Coalesces rapid calls: the first call schedules a refresh after a short delay;
    /// subsequent calls within that window are absorbed.
    private func scheduleTrafficRefresh() {
        guard !trafficRefreshPending else { return }
        trafficRefreshPending = true
        let sessStore = sessionStore

        trafficRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled, let self else { return }

            let activitySnapshots = await sessStore.snapshotSessionActivities()
            let uploadSize = await sessStore.lastUploadSize()
            let costSnapshot = await sessStore.costSnapshot()
            let activities = Self.visibleSessionActivities(from: activitySnapshots, now: Date())

            self.sessionActivities = activities
            self.lastUploadBytes = uploadSize
            self.proxyStatus = ProxyStatus(
                activeSessions: activities.count,
                activeKeepalives: self.proxyStatus.activeKeepalives,
                totalRequestsForwarded: self.proxyStatus.totalRequestsForwarded,
                totalKeepalivesSent: self.proxyStatus.totalKeepalivesSent,
                totalKeepalivesFailed: self.proxyStatus.totalKeepalivesFailed,
                cacheReads: self.proxyStatus.cacheReads,
                cacheWrites: self.proxyStatus.cacheWrites,
                estimatedSavings: self.proxyStatus.estimatedSavings,
                totalInputTokens: self.proxyStatus.totalInputTokens,
                totalOutputTokens: self.proxyStatus.totalOutputTokens,
                totalCacheReadInputTokens: self.proxyStatus.totalCacheReadInputTokens,
                totalCacheCreationInputTokens: self.proxyStatus.totalCacheCreationInputTokens,
                totalEstimatedCostUSD: costSnapshot.totalEstimatedCostUSD,
                estimatedCostUSDByAPI: costSnapshot.estimatedCostUSDByAPI
            )
            self.trafficRefreshPending = false
        }
    }

    private func startRefreshTask() {
        refreshTask?.cancel()
        let sessStore = sessionStore
        let metStore = metricsStore

        refreshTask = Task { [weak self] in
            var lastSessionExpirationSweep = Date.distantPast
            // Throughput tracking — local to this task to avoid actor hops.
            var prevTransfer = (sent: 0, received: 0)
            var prevTransferDate = Date()

            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(2000))
                guard !Task.isCancelled else { break }

                let now = Date()
                if now.timeIntervalSince(lastSessionExpirationSweep) >= Self.sessionExpirationSweepInterval {
                    lastSessionExpirationSweep = now
                    let expiredSessionIDs = await sessStore.expireSessions(
                        olderThan: now.addingTimeInterval(-Self.sessionRetentionSeconds),
                        otherOlderThan: now.addingTimeInterval(-Self.otherTrafficRetentionSeconds)
                    )
                    if !expiredSessionIDs.isEmpty {
                        let logger = await MainActor.run { self?.eventLogger }
                        for sessionID in expiredSessionIDs {
                            await logger?.logSessionExpired(session: sessionID)
                        }
                    }
                    await sessStore.pruneStaleDoneRequests(
                        olderThan: now.addingTimeInterval(-Self.sideTrafficDoneRetentionSeconds),
                        otherOlderThan: now.addingTimeInterval(-Self.otherTrafficRetentionSeconds)
                    )
                }

                let snapshot = await metStore.snapshot()
                let activitySnapshots = await sessStore.snapshotSessionActivities()
                let uploadSize  = await sessStore.lastUploadSize()
                let bytesRx     = await sessStore.cumulativeBytesReceived()
                let costSnapshot = await sessStore.costSnapshot()

                // Delta-based KB/s from cumulative receive counter.
                let elapsed = now.timeIntervalSince(prevTransferDate)
                let downloadSpeed: Double
                if elapsed > 0 {
                    downloadSpeed = max(0, Double(bytesRx - prevTransfer.received) / elapsed)
                } else {
                    downloadSpeed = 0
                }
                prevTransfer     = (sent: 0, received: bytesRx)
                prevTransferDate = now

                let activities = Self.visibleSessionActivities(from: activitySnapshots, now: now)

                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    self?.sessionActivities   = activities
                    self?.lastUploadBytes     = uploadSize
                    self?.downloadBytesPerSec = downloadSpeed
                    self?.proxyStatus = ProxyStatus(
                        activeSessions: activities.count,
                        activeKeepalives: 0,
                        totalRequestsForwarded: snapshot.totalRequestsForwarded,
                        totalKeepalivesSent: snapshot.totalKeepalivesSent,
                        totalKeepalivesFailed: snapshot.totalKeepalivesFailed,
                        cacheReads: snapshot.totalCacheReads,
                        cacheWrites: snapshot.totalCacheWrites,
                        estimatedSavings: snapshot.estimatedSavingsMultiple,
                        totalInputTokens: snapshot.totalInputTokens,
                        totalOutputTokens: snapshot.totalOutputTokens,
                        totalCacheReadInputTokens: snapshot.totalCacheReadInputTokens,
                        totalCacheCreationInputTokens: snapshot.totalCacheCreationInputTokens,
                        totalEstimatedCostUSD: costSnapshot.totalEstimatedCostUSD,
                        estimatedCostUSDByAPI: costSnapshot.estimatedCostUSDByAPI
                    )
                }
            }
        }
    }

    private static func visibleSessionActivities(
        from snapshots: [ProxySessionStore.SessionSnapshot],
        now: Date
    ) -> [SessionActivity] {
        let sessionCutoff = now.addingTimeInterval(-sessionVisibilitySeconds)
        let otherCutoff = now.addingTimeInterval(-otherTrafficRetentionSeconds)

        return snapshots
            .filter {
                let cutoff = usesShortRetentionWindow(for: $0) ? otherCutoff : sessionCutoff
                return max($0.lastSeenAt, $0.lastKeepaliveAt ?? .distantPast) >= cutoff
                    || !$0.activeRequests.isEmpty
            }
            .map { snap in
                let doneRequests = Self.visibleDoneRequests(from: snap, now: now)
                return SessionActivity(
                    sessionID: snap.sessionID,
                    completedRequests: snap.completedRequestCount,
                    erroredRequests: snap.erroredRequestCount,
                    keepaliveCount: snap.keepaliveTotalCount,
                    activeRequests: snap.activeRequests.sorted { $0.startedAt > $1.startedAt },
                    doneRequests: doneRequests,
                    totalInputTokens: snap.totalInputTokens,
                    totalOutputTokens: snap.totalOutputTokens,
                    totalCacheReadInputTokens: snap.totalCacheReadInputTokens,
                    totalCacheCreationInputTokens: snap.totalCacheCreationInputTokens,
                    estimatedCostUSD: snap.estimatedCostUSD,
                    isKeepaliveDisabled: snap.isKeepaliveDisabled,
                    keepaliveDisabledReason: snap.keepaliveDisabledReason,
                    keepaliveMode: snap.keepaliveMode,
                    lineageReady: snap.lineageEstablished,
                    lastKeepaliveAt: snap.lastKeepaliveAt,
                    lastKeepaliveCacheReadPercent: Self.cacheReadPercent(from: snap.lastKeepaliveTokenUsage),
                    lastKeepaliveOutputTokens: snap.lastKeepaliveTokenUsage?.outputTokens
                )
            }
    }

    private static func visibleDoneRequests(
        from snapshot: ProxySessionStore.SessionSnapshot,
        now: Date
    ) -> [ProxyRequestActivity] {
        var doneRequests = snapshot.doneRequests
        if let lastKeepaliveRequest = snapshot.lastKeepaliveRequest {
            doneRequests.append(lastKeepaliveRequest)
        }

        if usesShortDoneRequestRetentionWindow(for: snapshot) {
            let cutoff = now.addingTimeInterval(-otherTrafficRetentionSeconds)
            doneRequests = doneRequests.filter {
                ($0.completedAt ?? $0.startedAt) >= cutoff
            }
        }

        return doneRequests.sorted {
            ($0.completedAt ?? $0.startedAt) > ($1.completedAt ?? $1.startedAt)
        }
    }

    private static func usesShortRetentionWindow(
        for snapshot: ProxySessionStore.SessionSnapshot
    ) -> Bool {
        ProxySessionID.usesShortRetentionWindow(
            for: snapshot.sessionID,
            lineageEstablished: snapshot.lineageEstablished
        )
    }

    private static func usesShortDoneRequestRetentionWindow(
        for snapshot: ProxySessionStore.SessionSnapshot
    ) -> Bool {
        ProxySessionID.usesShortDoneRequestRetentionWindow(
            for: snapshot.sessionID,
            lineageEstablished: snapshot.lineageEstablished
        )
    }

    /// Compute cache read percentage from a keepalive token usage response.
    private static func cacheReadPercent(from usage: TokenUsage?) -> Double? {
        guard let usage else { return nil }
        let cacheRead = Double(usage.cacheReadInputTokens ?? 0)
        let cacheWrite = Double(usage.cacheCreationInputTokens ?? 0)
        let input = Double(usage.inputTokens ?? 0)
        let total = cacheRead + cacheWrite + input
        guard total > 0 else { return nil }
        return (cacheRead / total) * 100
    }
}
