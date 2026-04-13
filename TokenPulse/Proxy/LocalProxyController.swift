import Foundation

/// Lifecycle owner for the local proxy. `@MainActor` for UI binding only —
/// the server, forwarder, stores all run off main.
@MainActor
@Observable
final class LocalProxyController {
    private static let sessionExpirationSweepInterval: TimeInterval = 60
    private static let sessionRetentionSeconds: TimeInterval = 24 * 60 * 60

    // MARK: - Per-session activity snapshot for UI

    struct SessionActivity: Sendable, Identifiable {
        let sessionID: String
        let completedRequests: Int
        let erroredRequests: Int
        let keepaliveRequests: Int
        let activeRequests: [ProxyRequestActivity]
        let doneRequests: [ProxyRequestActivity]
        let totalInputTokens: Int
        let totalOutputTokens: Int
        let totalCacheReadInputTokens: Int
        let totalCacheCreationInputTokens: Int
        let estimatedCostUSD: Double

        var id: String { sessionID }
        /// First 8 characters of the session ID — enough to distinguish sessions in the UI.
        var shortID: String { String(sessionID.prefix(8)) }
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

        static let empty = ProxyStatus(
            activeSessions: 0, activeKeepalives: 0,
            totalRequestsForwarded: 0, totalKeepalivesSent: 0,
            totalKeepalivesFailed: 0, cacheReads: 0, cacheWrites: 0,
            estimatedSavings: 0,
            totalInputTokens: 0, totalOutputTokens: 0,
            totalCacheReadInputTokens: 0, totalCacheCreationInputTokens: 0,
            totalEstimatedCostUSD: 0
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
    private var forwarder: AnthropicForwarder?
    private var keepaliveManager: KeepaliveManager?
    private var eventLogger: ProxyEventLogger?
    private var refreshTask: Task<Void, Never>?
    private var trafficRefreshTask: Task<Void, Never>?
    private var trafficRefreshPending = false
    private var currentUpstreamURL: String?

    /// Start the proxy server on the given port, forwarding to the upstream URL.
    func start(port: Int, upstreamURL: String) {
        guard server == nil else { return }

        // Read config from ConfigService (both are @MainActor, safe here).
        let config = ConfigService.shared
        currentUpstreamURL = upstreamURL

        let logger = ProxyEventLogger(
            enabled: config.saveProxyEventLog || config.saveProxyPayloads,
            capturesContent: config.saveProxyPayloads
        )
        self.eventLogger = logger

        let fwd = AnthropicForwarder(upstreamBaseURL: upstreamURL, eventLogger: logger, proxyPort: port)
        self.forwarder = fwd

        var kaManager: KeepaliveManager?
        if config.keepaliveEnabled {
            kaManager = KeepaliveManager(
                intervalSeconds: config.keepaliveIntervalSeconds,
                inactivityTimeoutSeconds: config.proxyInactivityTimeoutSeconds,
                upstreamBaseURL: upstreamURL,
                sessionStore: sessionStore,
                metricsStore: metricsStore,
                eventLogger: logger,
                proxyPort: port
            )
        }
        self.keepaliveManager = kaManager

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

        do {
            var startedServer: ProxyHTTPServer?
            let httpServer = try ProxyHTTPServer(
                port: UInt16(clamping: port),
                handler: { @Sendable [weak self] request in
                    let controller = self
                    let keepaliveManager = await MainActor.run { controller?.keepaliveManager }
                    await fwd.forward(
                        request: request,
                        sessionStore: sessStore,
                        metrics: metStore,
                        keepaliveManager: keepaliveManager
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
                        self.forwarder = nil
                        self.keepaliveManager = nil
                        self.eventLogger = nil
                        self.currentUpstreamURL = nil
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
            currentUpstreamURL = nil
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
        forwarder = nil

        let manager = keepaliveManager
        keepaliveManager = nil
        let logger = eventLogger
        let metStore = metricsStore

        Task {
            await manager?.shutdown()
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
        currentUpstreamURL = nil
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
            totalEstimatedCostUSD: 0
        )
        proxyStatus = s
    }

    /// Apply keepalive changes immediately for a running proxy without a full restart.
    func updateKeepaliveConfiguration(enabled: Bool, intervalSeconds: Int, inactivityTimeoutSeconds: Int) {
        guard isRunning, let upstreamURL = currentUpstreamURL else { return }

        if enabled {
            if let manager = keepaliveManager {
                Task {
                    await manager.reconfigure(
                        intervalSeconds: intervalSeconds,
                        inactivityTimeoutSeconds: inactivityTimeoutSeconds,
                        upstreamBaseURL: upstreamURL
                    )
                }
            } else {
                let manager = KeepaliveManager(
                    intervalSeconds: intervalSeconds,
                    inactivityTimeoutSeconds: inactivityTimeoutSeconds,
                    upstreamBaseURL: upstreamURL,
                    sessionStore: sessionStore,
                    metricsStore: metricsStore,
                    eventLogger: eventLogger,
                    proxyPort: listeningPort
                )
                keepaliveManager = manager

                let sessStore = sessionStore
                Task {
                    let existingSessions = await sessStore.keepaliveBootstrapSessions()
                    for session in existingSessions {
                        await manager.startOrReset(sessionID: session.sessionID, headers: session.headers)
                    }
                }
            }
        } else if let manager = keepaliveManager {
            keepaliveManager = nil
            let logger = eventLogger
            let metStore = metricsStore
            let sessStore = sessionStore
            let port = listeningPort
            Task {
                await manager.shutdown()
                guard let logger else { return }
                let snapshot = await metStore.snapshot()
                let activeSessions = await sessStore.activeSessions().count
                await logger.writeStatusSnapshot(
                    enabled: true,
                    port: port,
                    activeSessions: activeSessions,
                    activeKeepalives: 0,
                    metrics: snapshot,
                    force: true
                )
            }
        }
    }

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
            let totalCost = await sessStore.totalEstimatedCostUSD()
            let now = Date()
            let recentCutoff = now.addingTimeInterval(-600)

            let activities = activitySnapshots
                .filter {
                    max($0.lastSeenAt, $0.lastKeepaliveAt ?? .distantPast) >= recentCutoff
                        || !$0.activeRequests.isEmpty
                        || !$0.doneRequests.isEmpty
                }
                .map { snap in
                    SessionActivity(
                        sessionID: snap.sessionID,
                        completedRequests: snap.completedRequestCount,
                        erroredRequests: snap.erroredRequestCount,
                        keepaliveRequests: snap.keepaliveTotalCount,
                        activeRequests: snap.activeRequests.sorted { $0.startedAt > $1.startedAt },
                        doneRequests: snap.doneRequests.sorted {
                            ($0.completedAt ?? $0.startedAt) > ($1.completedAt ?? $1.startedAt)
                        },
                        totalInputTokens: snap.totalInputTokens,
                        totalOutputTokens: snap.totalOutputTokens,
                        totalCacheReadInputTokens: snap.totalCacheReadInputTokens,
                        totalCacheCreationInputTokens: snap.totalCacheCreationInputTokens,
                        estimatedCostUSD: snap.estimatedCostUSD
                    )
                }

            self.sessionActivities = activities
            self.lastUploadBytes = uploadSize
            self.proxyStatus = ProxyStatus(
                activeSessions: self.proxyStatus.activeSessions,
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
                totalEstimatedCostUSD: totalCost
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
                        olderThan: now.addingTimeInterval(-Self.sessionRetentionSeconds)
                    )
                    if !expiredSessionIDs.isEmpty {
                        let logger = await MainActor.run { self?.eventLogger }
                        for sessionID in expiredSessionIDs {
                            await logger?.logSessionExpired(session: sessionID)
                        }
                    }
                }

                let sessions = await sessStore.recentSessionCount(within: 600)
                let keepaliveManager = await MainActor.run { self?.keepaliveManager }
                let keepalives = await keepaliveManager?.activeCount() ?? 0
                let snapshot = await metStore.snapshot()
                let activitySnapshots = await sessStore.snapshotSessionActivities()
                let uploadSize  = await sessStore.lastUploadSize()
                let bytesRx     = await sessStore.cumulativeBytesReceived()
                let totalCost   = await sessStore.totalEstimatedCostUSD()

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

                // Keep sessions visible while recent real traffic or keepalive activity exists.
                let recentCutoff = now.addingTimeInterval(-600)
                let activities = activitySnapshots
                    .filter {
                        max($0.lastSeenAt, $0.lastKeepaliveAt ?? .distantPast) >= recentCutoff
                            || !$0.activeRequests.isEmpty
                            || !$0.doneRequests.isEmpty
                    }
                    .map { snap in
                        SessionActivity(
                            sessionID: snap.sessionID,
                            completedRequests: snap.completedRequestCount,
                            erroredRequests: snap.erroredRequestCount,
                            keepaliveRequests: snap.keepaliveTotalCount,
                            activeRequests: snap.activeRequests
                                .sorted { $0.startedAt > $1.startedAt },
                            doneRequests: snap.doneRequests
                                .sorted { ($0.completedAt ?? $0.startedAt) > ($1.completedAt ?? $1.startedAt) },
                            totalInputTokens: snap.totalInputTokens,
                            totalOutputTokens: snap.totalOutputTokens,
                            totalCacheReadInputTokens: snap.totalCacheReadInputTokens,
                            totalCacheCreationInputTokens: snap.totalCacheCreationInputTokens,
                            estimatedCostUSD: snap.estimatedCostUSD
                        )
                    }

                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    self?.sessionActivities   = activities
                    self?.lastUploadBytes     = uploadSize
                    self?.downloadBytesPerSec = downloadSpeed
                    self?.proxyStatus = ProxyStatus(
                        activeSessions: sessions,
                        activeKeepalives: keepalives,
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
                        totalEstimatedCostUSD: totalCost
                    )
                }
            }
        }
    }
}
