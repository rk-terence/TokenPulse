import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private var pollingManager: PollingManager?
    let providerManager = ProviderManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Register providers
        providerManager.register(ClaudeProvider())
        providerManager.register(ZenMuxProvider())

        // Set up status bar
        statusBarController = StatusBarController(providerManager: providerManager)

        // Wire icon updates
        providerManager.onIconUpdate = { [weak self] label, utilization in
            self?.statusBarController?.updateIcon(label: label, utilization: utilization)
        }

        // Wire right-click to cycle active provider
        statusBarController?.onRightClick = { [weak providerManager] in
            providerManager?.cycleActiveProvider()
        }

        // Wire poll interval changes
        providerManager.onPollIntervalChanged = { [weak self] interval in
            self?.pollingManager?.updateInterval(interval)
        }

        // Start polling
        pollingManager = PollingManager(providerManager: providerManager)
        pollingManager?.start()
    }
}
