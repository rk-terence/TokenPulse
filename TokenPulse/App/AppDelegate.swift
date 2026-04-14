import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private var pollingManager: PollingManager?
    private var proxyController: LocalProxyController?
    let providerManager = ProviderManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Request notification permission
        NotificationService.shared.requestAuthorization()

        // Register providers
        providerManager.register(ClaudeProvider())
        providerManager.register(CodexProvider())
        providerManager.register(ZenMuxProvider())

        // Start proxy if enabled (before status bar so popover can show status)
        proxyController = LocalProxyController()
        providerManager.proxyController = proxyController

        // Set up status bar
        statusBarController = StatusBarController(providerManager: providerManager, proxyController: proxyController)

        // Wire icon updates
        providerManager.onIconUpdate = { [weak self] model in
            self?.statusBarController?.updateIcon(model)
        }

        // Wire right-click to cycle active provider
        statusBarController?.onRightClick = { [weak providerManager] in
            providerManager?.cycleActiveProvider()
        }

        // Wire poll interval changes
        providerManager.onPollIntervalChanged = { [weak self] interval in
            self?.pollingManager?.updateInterval(interval)
        }

        // Start polling with saved interval
        pollingManager = PollingManager(providerManager: providerManager, interval: ConfigService.shared.pollInterval)
        pollingManager?.start()

        if ConfigService.shared.proxyEnabled {
            proxyController?.start(
                port: ConfigService.shared.proxyPort,
                anthropicUpstreamURL: ConfigService.shared.anthropicUpstreamURL,
                openAIUpstreamURL: ConfigService.shared.openAIUpstreamURL
            )
        }
    }
}
