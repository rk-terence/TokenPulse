import Foundation

@MainActor
final class PollingManager {
    private let providerManager: ProviderManager
    private var timer: Timer?
    private var interval: TimeInterval

    init(providerManager: ProviderManager, interval: TimeInterval = ProviderConfig.defaultPollInterval) {
        self.providerManager = providerManager
        self.interval = max(interval, ProviderConfig.minimumPollInterval)
    }

    func start() {
        providerManager.requestRefresh(.automatic)
        scheduleTimer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func updateInterval(_ newInterval: TimeInterval) {
        interval = max(newInterval, ProviderConfig.minimumPollInterval)
        if timer != nil {
            stop()
            scheduleTimer()
        }
    }

    private func scheduleTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.providerManager.requestRefresh(.automatic)
            }
        }
    }
}
