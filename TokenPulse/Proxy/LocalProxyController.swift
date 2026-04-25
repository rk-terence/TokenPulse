import Foundation

/// Lifecycle owner for the local proxy. `@MainActor` for UI binding only —
/// the server, forwarder, stores all run off main.
@MainActor
@Observable
final class LocalProxyController {
    private static let sessionExpirationSweepInterval: TimeInterval = 10
    private static let sessionRetentionSeconds: TimeInterval = 24 * 60 * 60
    private static let sessionVisibilitySeconds: TimeInterval = 10 * 60
    private static let otherTrafficRetentionSeconds: TimeInterval = 5 * 60
    private static let contentTreePruneRetention: TimeInterval = 24 * 60 * 60
    private static let restartAttempts = 3
    private static let restartStopDelay: Duration = .milliseconds(150)
    private static let restartStartupTimeout: Duration = .milliseconds(900)
    private static let restartPollInterval: Duration = .milliseconds(50)
    private static let lifecycleWaitPollInterval: TimeInterval = 0.01

    // MARK: - Per-session activity snapshot for UI

    struct SessionActivity: Sendable, Identifiable {
        let sessionID: String
        let completedRequests: Int
        let erroredRequests: Int
        let activeRequests: [ProxyRequestActivity]
        let doneRequests: [ProxyRequestActivity]
        let totalInputTokens: Int
        let totalOutputTokens: Int
        let totalCacheReadInputTokens: Int
        let totalCacheCreationInputTokens: Int
        let estimatedCostUSD: Double

        var id: String { sessionID }
        var apiFlavor: ProxyAPIFlavor? { ProxySessionID.flavor(for: sessionID) }
        var displayID: String { ProxySessionID.displayID(for: sessionID) }
        var shortID: String { ProxySessionID.shortDisplayID(for: sessionID) }
        var agentName: String? { apiFlavor?.sessionAgentName }
        var rowTitle: String {
            ProxySessionID.isOther(sessionID) ? displayID : shortID
        }
        var isOtherTraffic: Bool { ProxySessionID.isOther(sessionID) }
    }

    // MARK: - Aggregate metrics snapshot for UI

    struct ProxyStatus: Sendable {
        let activeSessions: Int
        let totalRequestsForwarded: Int
        let totalInputTokens: Int
        let totalOutputTokens: Int
        let totalCacheReadInputTokens: Int
        let totalCacheCreationInputTokens: Int
        let totalEstimatedCostUSD: Double
        let estimatedCostUSDByAPI: [ProxyAPIFlavor: Double]

        static let empty = ProxyStatus(
            activeSessions: 0,
            totalRequestsForwarded: 0,
            totalInputTokens: 0, totalOutputTokens: 0,
            totalCacheReadInputTokens: 0, totalCacheCreationInputTokens: 0,
            totalEstimatedCostUSD: 0,
            estimatedCostUSDByAPI: [:]
        )
    }

    private(set) var isRunning = false {
        didSet {
            if oldValue != isRunning {
                onRunningChanged?(isRunning)
            }
        }
    }
    private(set) var isRestarting = false
    private(set) var listeningPort: Int = 0
    private(set) var proxyStatus: ProxyStatus = .empty
    private(set) var sessionActivities: [SessionActivity] = []
    /// Size of the most recent upstream request body in bytes (one-shot, not rate).
    private(set) var lastUploadBytes: Int = 0
    /// Download throughput in bytes per second, computed from cumulative deltas every refresh tick.
    private(set) var downloadBytesPerSec: Double = 0

    var onTrafficEvent: ((TrafficDirection?) -> Void)?
    var onRequestDone: (() -> Void)?
    var onRunningChanged: ((Bool) -> Void)?

    private var server: ProxyHTTPServer?
    private var serverGeneration: UInt64 = 0
    private let sessionStore = ProxySessionStore()
    private let metricsStore = ProxyMetricsStore()
    private let anthropicAPIHandler: any ProxyAPIHandler = AnthropicProxyAPIHandler()
    private let openAIAPIHandler: any ProxyAPIHandler = OpenAIResponsesProxyAPIHandler()
    private var anthropicForwarder: ProxyForwarder?
    private var openAIForwarder: ProxyForwarder?
    private var eventLogger: ProxyEventLogger?
    private var refreshTask: Task<Void, Never>?
    private var trafficRefreshTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?
    private var trafficRefreshPending = false
    private var currentAnthropicUpstreamURL: String?
    @ObservationIgnored private var hiddenSessions: [String: Date] = [:]

    /// Hide the given session from the popup until new activity arrives.
    func hideSession(_ sessionID: String) {
        hiddenSessions[sessionID] = Date()
        sessionActivities.removeAll { $0.sessionID == sessionID }
    }

    /// Start the proxy server on the given port, serving both supported API routes.
    func start(port: Int, anthropicUpstreamURL: String, openAIUpstreamURL: String) {
        waitForInFlightShutdownIfNeeded()
        guard server == nil else { return }

        let config = ConfigService.shared
        currentAnthropicUpstreamURL = anthropicUpstreamURL

        let logger = ProxyEventLogger(enabled: config.saveProxyEventLog)
        self.eventLogger = logger
        let upstreamHTTPSProxySetting = config.effectiveUpstreamProxySetting
        let contentBlocklistEntries = config.contentBlocklistEntries

        let anthropicForwarder = ProxyForwarder(
            upstreamBaseURL: anthropicUpstreamURL,
            apiFlavor: .anthropicMessages,
            apiHandler: anthropicAPIHandler,
            upstreamHTTPSProxySetting: upstreamHTTPSProxySetting,
            contentBlocklistEntries: contentBlocklistEntries,
            eventLogger: logger,
            proxyPort: port
        )
        let openAIForwarder = ProxyForwarder(
            upstreamBaseURL: openAIUpstreamURL,
            apiFlavor: .openAIResponses,
            apiHandler: openAIAPIHandler,
            upstreamHTTPSProxySetting: upstreamHTTPSProxySetting,
            contentBlocklistEntries: contentBlocklistEntries,
            eventLogger: logger,
            proxyPort: port
        )
        self.anthropicForwarder = anthropicForwarder
        self.openAIForwarder = openAIForwarder

        Task { [weak self] in
            guard let self else { return }
            let store = self.sessionStore
            await store.setTrafficCallback { [weak self] direction in
                Task { @MainActor [weak self] in
                    self?.onTrafficEvent?(direction)
                    self?.scheduleTrafficRefresh()
                }
            }
            await store.setRequestDoneCallback { [weak self] in
                Task { @MainActor [weak self] in
                    self?.onRequestDone?()
                }
            }
        }

        let sessStore = sessionStore
        let metStore = metricsStore
        let anthropicHandler = anthropicAPIHandler
        let openAIHandler = openAIAPIHandler

        do {
            serverGeneration &+= 1
            let thisGeneration = serverGeneration
            let httpServer = try ProxyHTTPServer(
                port: UInt16(clamping: port),
                requestValidator: { method, path in
                    if anthropicHandler.acceptsRequest(method: method, path: path)
                        || openAIHandler.acceptsRequest(method: method, path: path) {
                        return .accepted
                    }
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
                        guard let self, self.serverGeneration == thisGeneration, self.server != nil else { return }
                        self.listeningPort = Int(actualPort)
                        self.isRunning = true
                        ProxyLogger.log("Proxy controller started on port \(self.listeningPort)")
                        self.startRefreshTask()
                        await logger.logProxyStarted(port: self.listeningPort)
                    }
                },
                onFailure: { [weak self] errorMessage in
                    Task { @MainActor [weak self] in
                        guard let self, self.serverGeneration == thisGeneration else { return }
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
            httpServer.start()
            self.server = httpServer
        } catch {
            currentAnthropicUpstreamURL = nil
            ProxyLogger.log("Failed to start proxy server: \(error)")
        }
    }

    func stop() {
        _ = beginShutdown(cancelRestartTask: true)
    }

    func stopAndWait() async {
        if let shutdownTask = beginShutdown(cancelRestartTask: true) {
            await shutdownTask.value
        }
    }

    func restart(port: Int, anthropicUpstreamURL: String, openAIUpstreamURL: String) {
        restartTask?.cancel()
        restartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performRestart(
                port: port,
                anthropicUpstreamURL: anthropicUpstreamURL,
                openAIUpstreamURL: openAIUpstreamURL
            )
        }
    }

    private func beginShutdown(cancelRestartTask: Bool) -> Task<Void, Never>? {
        if cancelRestartTask {
            restartTask?.cancel()
            restartTask = nil
            isRestarting = false
        }

        if let shutdownTask {
            return shutdownTask
        }

        refreshTask?.cancel()
        refreshTask = nil
        trafficRefreshTask?.cancel()
        trafficRefreshTask = nil
        trafficRefreshPending = false

        server?.stop()
        server = nil
        serverGeneration &+= 1
        anthropicForwarder = nil
        openAIForwarder = nil

        let logger = eventLogger
        let metStore = metricsStore
        eventLogger = nil

        isRunning = false
        listeningPort = 0
        proxyStatus = .empty
        sessionActivities = []
        lastUploadBytes = 0
        downloadBytesPerSec = 0
        currentAnthropicUpstreamURL = nil

        let shutdownTask = Task { [weak self] in
            if let logger {
                await logger.logProxyStopped()
                let snapshot = await metStore.snapshot()
                await logger.writeStatusSnapshot(
                    enabled: false,
                    port: 0,
                    activeSessions: 0,
                    metrics: snapshot,
                    force: true
                )
                await logger.close()
            }

            await MainActor.run {
                self?.shutdownTask = nil
            }
            ProxyLogger.log("Proxy controller stopped")
        }
        self.shutdownTask = shutdownTask
        return shutdownTask
    }

    private func performRestart(port: Int, anthropicUpstreamURL: String, openAIUpstreamURL: String) async {
        guard !isRestarting else { return }
        isRestarting = true
        defer {
            isRestarting = false
            restartTask = nil
        }

        for attempt in 1...Self.restartAttempts {
            if let shutdownTask = beginShutdown(cancelRestartTask: false) {
                await shutdownTask.value
            }
            guard !Task.isCancelled else { return }

            try? await Task.sleep(for: Self.restartStopDelay)
            guard !Task.isCancelled else { return }

            start(
                port: port,
                anthropicUpstreamURL: anthropicUpstreamURL,
                openAIUpstreamURL: openAIUpstreamURL
            )

            if await waitForRunning(timeout: Self.restartStartupTimeout) {
                ProxyLogger.log("Proxy restart succeeded on attempt \(attempt)")
                return
            }

            ProxyLogger.log("Proxy restart attempt \(attempt) did not reach running state")
        }

        ProxyLogger.log("Proxy restart failed after \(Self.restartAttempts) attempts")
    }

    private func waitForRunning(timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let start = clock.now

        while clock.now - start < timeout {
            if isRunning { return true }
            if server == nil { return false }
            guard !Task.isCancelled else { return false }
            try? await Task.sleep(for: Self.restartPollInterval)
        }

        return isRunning
    }

    private func waitForInFlightShutdownIfNeeded() {
        guard let shutdownTask else { return }

        let waitGroup = DispatchGroup()
        waitGroup.enter()

        Task {
            await shutdownTask.value
            waitGroup.leave()
        }

        while waitGroup.wait(timeout: .now()) != .success {
            _ = RunLoop.current.run(
                mode: .default,
                before: Date(timeIntervalSinceNow: Self.lifecycleWaitPollInterval)
            )
        }
    }

    /// Reset the cumulative proxy cost estimate to zero.
    func resetCost() async {
        await sessionStore.resetCost()
        let s = proxyStatus
        proxyStatus = ProxyStatus(
            activeSessions: s.activeSessions,
            totalRequestsForwarded: s.totalRequestsForwarded,
            totalInputTokens: s.totalInputTokens,
            totalOutputTokens: s.totalOutputTokens,
            totalCacheReadInputTokens: s.totalCacheReadInputTokens,
            totalCacheCreationInputTokens: s.totalCacheCreationInputTokens,
            totalEstimatedCostUSD: 0,
            estimatedCostUSDByAPI: [:]
        )
    }

    // MARK: - Route helpers

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

    // MARK: - Refresh

    private func scheduleTrafficRefresh() {
        guard !trafficRefreshPending else { return }
        trafficRefreshPending = true
        let sessStore = sessionStore

        trafficRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled, let self else { return }

            let capturedHidden = self.hiddenSessions
            let activitySnapshots = await sessStore.snapshotSessionActivities()
            let uploadSize = await sessStore.lastUploadSize()
            let costSnapshot = await sessStore.costSnapshot()
            let (activities, activeSessionCount, stalledHideIDs) = Self.visibleSessionActivities(
                from: activitySnapshots,
                now: Date(),
                hiddenSessions: capturedHidden
            )

            for id in stalledHideIDs { self.hiddenSessions.removeValue(forKey: id) }
            self.sessionActivities = activities
            self.lastUploadBytes = uploadSize
            self.proxyStatus = ProxyStatus(
                activeSessions: activeSessionCount,
                totalRequestsForwarded: self.proxyStatus.totalRequestsForwarded,
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
                        await MainActor.run {
                            for id in expiredSessionIDs { self?.hiddenSessions.removeValue(forKey: id) }
                        }
                    }
                    await sessStore.pruneStaleDoneRequests(
                        otherOlderThan: now.addingTimeInterval(-Self.otherTrafficRetentionSeconds)
                    )
                    let pruneResult = await sessStore.pruneContentTree(
                        retention: Self.contentTreePruneRetention
                    )
                    if !pruneResult.removedConversationIDs.isEmpty || !pruneResult.removedNodeIDs.isEmpty {
                        let logger = await MainActor.run { self?.eventLogger }
                        await logger?.pruneLineageMirror(
                            conversationIDs: pruneResult.removedConversationIDs,
                            nodeIDs: pruneResult.removedNodeIDs
                        )
                    }
                }

                let capturedHidden = await MainActor.run { self?.hiddenSessions ?? [:] }
                let snapshot = await metStore.snapshot()
                let activitySnapshots = await sessStore.snapshotSessionActivities()
                let uploadSize  = await sessStore.lastUploadSize()
                let bytesRx     = await sessStore.cumulativeBytesReceived()
                let costSnapshot = await sessStore.costSnapshot()

                let elapsed = now.timeIntervalSince(prevTransferDate)
                let downloadSpeed: Double
                if elapsed > 0 {
                    downloadSpeed = max(0, Double(bytesRx - prevTransfer.received) / elapsed)
                } else {
                    downloadSpeed = 0
                }
                prevTransfer     = (sent: 0, received: bytesRx)
                prevTransferDate = now

                let (activities, activeSessionCount, stalledHideIDs) = Self.visibleSessionActivities(
                    from: activitySnapshots,
                    now: now,
                    hiddenSessions: capturedHidden
                )

                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    for id in stalledHideIDs { self?.hiddenSessions.removeValue(forKey: id) }
                    self?.sessionActivities   = activities
                    self?.lastUploadBytes     = uploadSize
                    self?.downloadBytesPerSec = downloadSpeed
                    self?.proxyStatus = ProxyStatus(
                        activeSessions: activeSessionCount,
                        totalRequestsForwarded: snapshot.totalRequestsForwarded,
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
        now: Date,
        hiddenSessions: [String: Date]
    ) -> (activities: [SessionActivity], activeSessionCount: Int, stalledHideIDs: [String]) {
        let identifiedCutoff = now.addingTimeInterval(-sessionVisibilitySeconds)
        let otherCutoff = now.addingTimeInterval(-otherTrafficRetentionSeconds)

        var result: [SessionActivity] = []
        var activeSessionCount = 0
        var stalledHideIDs: [String] = []

        for snap in snapshots {
            let sortedActive = snap.activeRequests.sorted { $0.startedAt > $1.startedAt }
            let sortedDone = snap.doneRequests.sorted {
                ($0.completedAt ?? $0.startedAt) > ($1.completedAt ?? $1.startedAt)
            }

            // Check if this session is hidden, and if so whether new activity resurfaces it.
            if let hideDate = hiddenSessions[snap.sessionID] {
                let hasNewActive = sortedActive.contains { $0.startedAt > hideDate }
                let hasNewDone = sortedDone.contains { $0.startedAt > hideDate }
                if !hasNewActive && !hasNewDone {
                    // Still hidden — skip.
                    continue
                }
                // New activity arrived after the hide — resurface and clean up.
                stalledHideIDs.append(snap.sessionID)
            }

            let visibleActive: [ProxyRequestActivity]
            let visibleDone: [ProxyRequestActivity]

            if ProxySessionID.usesShortRetentionWindow(for: snap.sessionID) {
                // Other group: filter done rows by age; active rows always render.
                // Drop the whole row when nothing is left to show.
                visibleActive = sortedActive
                visibleDone = sortedDone.filter {
                    ($0.completedAt ?? $0.startedAt) >= otherCutoff
                }
                if visibleActive.isEmpty && visibleDone.isEmpty { continue }
            } else {
                // Identified: visible while in-flight, or while the most
                // recent request finished within the visibility window.
                let lastDone = snap.lastRequestDoneAt ?? .distantPast
                let isLive = !sortedActive.isEmpty || lastDone >= identifiedCutoff
                guard isLive else { continue }
                visibleActive = sortedActive
                visibleDone = sortedDone
            }

            activeSessionCount += 1

            result.append(SessionActivity(
                sessionID: snap.sessionID,
                completedRequests: snap.completedRequestCount,
                erroredRequests: snap.erroredRequestCount,
                activeRequests: visibleActive,
                doneRequests: visibleDone,
                totalInputTokens: snap.totalInputTokens,
                totalOutputTokens: snap.totalOutputTokens,
                totalCacheReadInputTokens: snap.totalCacheReadInputTokens,
                totalCacheCreationInputTokens: snap.totalCacheCreationInputTokens,
                estimatedCostUSD: snap.estimatedCostUSD
            ))
        }
        return (activities: result, activeSessionCount: activeSessionCount, stalledHideIDs: stalledHideIDs)
    }
}
