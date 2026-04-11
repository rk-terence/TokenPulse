import Foundation

/// Lifecycle owner for the local proxy. `@MainActor` for UI binding only —
/// the server, forwarder, stores all run off main.
@MainActor
@Observable
final class LocalProxyController {
    private(set) var isRunning = false
    private(set) var listeningPort: Int = 0

    private var server: ProxyHTTPServer?
    private let sessionStore = ProxySessionStore()
    private let metricsStore = ProxyMetricsStore()
    private var forwarder: AnthropicForwarder?
    private var keepaliveManager: KeepaliveManager?

    /// Start the proxy server on the given port, forwarding to the upstream URL.
    func start(port: Int, upstreamURL: String) {
        guard !isRunning else { return }

        let fwd = AnthropicForwarder(upstreamBaseURL: upstreamURL)
        self.forwarder = fwd

        // Read keepalive config from ConfigService (both are @MainActor, safe here).
        let config = ConfigService.shared
        var kaManager: KeepaliveManager?
        if config.keepaliveEnabled {
            kaManager = KeepaliveManager(
                intervalSeconds: config.keepaliveIntervalSeconds,
                inactivityTimeoutSeconds: config.proxyInactivityTimeoutSeconds,
                upstreamBaseURL: upstreamURL,
                sessionStore: sessionStore,
                metricsStore: metricsStore
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
        } catch {
            ProxyLogger.log("Failed to start proxy server: \(error)")
        }
    }

    /// Stop the proxy server.
    func stop() {
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

        isRunning = false
        listeningPort = 0
        ProxyLogger.log("Proxy controller stopped")
    }
}
