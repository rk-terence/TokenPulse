import Foundation

@MainActor
final class PollingManager {
    private let providerManager: ProviderManager
    private var timer: Timer?
    private var interval: TimeInterval
    private var backoffInterval: TimeInterval?

    init(providerManager: ProviderManager, interval: TimeInterval = ProviderConfig.defaultPollInterval) {
        self.providerManager = providerManager
        self.interval = max(interval, ProviderConfig.minimumPollInterval)
    }

    func start() {
        // Fire immediately on start
        Task { await providerManager.refreshAll() }
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
            guard let self else { return }
            Task { @MainActor in
                await self.providerManager.refreshAll()
            }
        }
    }
}
