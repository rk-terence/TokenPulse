import Foundation

/// Lifecycle owner for the local proxy. `@MainActor` for UI binding only —
/// the server, forwarder, stores all run off main.
@MainActor
@Observable
final class LocalProxyController {

    // MARK: - Metrics snapshot for UI

    struct ProxyStatus: Sendable {
        let activeSessions: Int
        let activeKeepalives: Int
        let totalRequestsForwarded: Int
        let totalKeepalivesSent: Int
        let totalKeepalivesFailed: Int
        let cacheReads: Int
        let cacheWrites: Int

        static let empty = ProxyStatus(
            activeSessions: 0, activeKeepalives: 0,
            totalRequestsForwarded: 0, totalKeepalivesSent: 0,
            totalKeepalivesFailed: 0, cacheReads: 0, cacheWrites: 0
        )
    }

    private(set) var isRunning = false
    private(set) var listeningPort: Int = 0
    private(set) var proxyStatus: ProxyStatus = .empty

    private var server: ProxyHTTPServer?
    private let sessionStore = ProxySessionStore()
    private let metricsStore = ProxyMetricsStore()
    private var forwarder: AnthropicForwarder?
    private var keepaliveManager: KeepaliveManager?
    private var eventLogger: ProxyEventLogger?
    private var refreshTask: Task<Void, Never>?

    /// Start the proxy server on the given port, forwarding to the upstream URL.
    func start(port: Int, upstreamURL: String) {
        guard !isRunning else { return }

        // Read config from ConfigService (both are @MainActor, safe here).
        let config = ConfigService.shared

        let logger = ProxyEventLogger(enabled: config.saveProxyEventLog)
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

        // Capture actor-isolated stores for the handler closure.
        let sessStore = sessionStore
        let metStore = metricsStore

        do {
            let httpServer = try ProxyHTTPServer(port: UInt16(clamping: port)) {
                @Sendable request in
                await fwd.forward(
                    request: request,
                    sessionStore: sessStore,
                    metrics: metStore,
                    keepaliveManager: kaManager
                )
            }
            httpServer.start()
            self.server = httpServer
            self.listeningPort = Int(httpServer.actualPort ?? UInt16(clamping: port))
            self.isRunning = true
            ProxyLogger.log("Proxy controller started on port \(listeningPort)")

            let actualPort = listeningPort
            Task {
                await logger.logProxyStarted(port: actualPort)
            }

            // Launch periodic metrics refresh for UI.
            let kaRef = keepaliveManager
            refreshTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { break }
                    let sessions = await sessStore.recentSessionCount(within: 600)
                    let keepalives = await kaRef?.activeCount() ?? 0
                    let snapshot = await metStore.snapshot()
                    await MainActor.run {
                        guard !Task.isCancelled else { return }
                        self?.proxyStatus = ProxyStatus(
                            activeSessions: sessions,
                            activeKeepalives: keepalives,
                            totalRequestsForwarded: snapshot.totalRequestsForwarded,
                            totalKeepalivesSent: snapshot.totalKeepalivesSent,
                            totalKeepalivesFailed: snapshot.totalKeepalivesFailed,
                            cacheReads: snapshot.totalCacheReads,
                            cacheWrites: snapshot.totalCacheWrites
                        )
                    }
                }
            }
        } catch {
            ProxyLogger.log("Failed to start proxy server: \(error)")
        }
    }

    /// Stop the proxy server.
    func stop() {
        refreshTask?.cancel()
        refreshTask = nil

        server?.stop()
        server = nil
        forwarder = nil

        if let km = keepaliveManager {
            let manager = km
            Task {
                await manager.stopAll()
            }
        }
        keepaliveManager = nil

        if let logger = eventLogger {
            let metStore = metricsStore
            Task {
                await logger.logProxyStopped()
                let snapshot = await metStore.snapshot()
                await logger.writeStatusSnapshot(
                    enabled: false,
                    port: 0,
                    activeSessions: 0,
                    activeKeepalives: 0,
                    metrics: snapshot
                )
                await logger.close()
            }
        }
        eventLogger = nil

        isRunning = false
        listeningPort = 0
        proxyStatus = .empty
        ProxyLogger.log("Proxy controller stopped")
    }
}
