import Foundation
import SwiftUI

struct ProviderEntry: Sendable {
    let id: String
    let displayName: String
    let shortLabel: String
    let status: ProviderStatus
    let lastAttemptAt: Date?
    let lastSuccessAt: Date?
}

struct StatusBarIconModel: Sendable {
    let label: String
    let utilization: Double?
    let state: StatusBarIconState
}

enum StatusBarIconState: Sendable {
    case unconfigured
    case ready
    case refreshing
    case stale
    case error
}

enum RefreshTrigger: Sendable {
    case automatic
    case manual
}

private struct ProviderState: Sendable {
    var status: ProviderStatus
    var lastAttemptAt: Date?
    var lastSuccessAt: Date?
    var refreshGeneration: Int = 0
}

private enum RefreshTimeoutError: LocalizedError {
    case timeout

    var errorDescription: String? {
        switch self {
        case .timeout:
            return String(localized: "Request timed out")
        }
    }
}

@Observable
@MainActor
final class ProviderManager {
    private static let requestTimeout: TimeInterval = 30

    private(set) var providerEntries: [ProviderEntry] = []
    private(set) var lastUpdated: Date?
    private(set) var isRefreshing = false
    private(set) var activeProviderID: String?

    private var providers: [any UsageProvider] = []
    private var states: [String: ProviderState] = [:]
    private var inFlightRefreshes: [String: Task<Void, Never>] = [:]
    private var settingsWindow: NSWindow?

    var onIconUpdate: ((StatusBarIconModel) -> Void)?
    var onPollIntervalChanged: ((_ interval: TimeInterval) -> Void)?

    var configuredProviderCount: Int {
        providerEntries.filter { $0.status.isConfigured }.count
    }

    func openSettings() {
        NSApp.activate(ignoringOtherApps: true)

        if let window = settingsWindow, window.isVisible {
            window.orderFrontRegardless()
            return
        }
        let view = SettingsView(manager: self, config: ConfigService.shared)
        let hostingController = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "TokenPulse Settings"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 400, height: 300))
        window.center()
        window.level = .floating
        window.orderFrontRegardless()
        settingsWindow = window
    }

    func register(_ provider: any UsageProvider) {
        providers.append(provider)
        states[provider.id] = ProviderState(
            status: provider.isConfigured() ? .pendingFirstLoad : .unconfigured
        )
        rebuildEntries()
        syncActiveProviderSelection()
    }

    func requestRefresh(_ trigger: RefreshTrigger = .manual) {
        for provider in providers {
            refresh(provider, trigger: trigger)
        }

        rebuildEntries()
        syncActiveProviderSelection()
        notifyIconUpdate()
    }

    // MARK: - Per-provider refresh

    private func refresh(_ provider: any UsageProvider, trigger: RefreshTrigger) {
        guard var state = states[provider.id] else { return }

        guard provider.isConfigured() else {
            if let existing = inFlightRefreshes[provider.id] {
                state.refreshGeneration += 1
                existing.cancel()
                inFlightRefreshes[provider.id] = nil
            }

            state.status = .unconfigured
            states[provider.id] = state
            updateRefreshingFlag()
            return
        }

        // Don't stack refreshes for the same provider
        if inFlightRefreshes[provider.id] != nil { return }

        let lastData = state.status.displayData
        let attemptAt = Date()
        state.refreshGeneration += 1
        let generation = state.refreshGeneration
        state.lastAttemptAt = attemptAt
        state.status = .refreshing(lastData: lastData)
        states[provider.id] = state
        updateRefreshingFlag()

        let task = Task { [weak self, provider] in
            let result = await Self.fetchUsage(for: provider, timeout: Self.requestTimeout)
            await self?.applyRefreshResult(result, for: provider, generation: generation, attemptAt: attemptAt)
        }

        inFlightRefreshes[provider.id] = task
    }

    private func applyRefreshResult(
        _ result: Result<UsageData, Error>,
        for provider: any UsageProvider,
        generation: Int,
        attemptAt: Date
    ) {
        guard var state = states[provider.id], state.refreshGeneration == generation else { return }

        inFlightRefreshes[provider.id] = nil

        switch result {
        case .success(let data):
            state.status = .ready(data)
            state.lastSuccessAt = data.fetchedAt
            lastUpdated = data.fetchedAt

        case .failure(let error):
            if error is CancellationError {
                updateRefreshingFlag()
                rebuildEntries()
                syncActiveProviderSelection()
                notifyIconUpdate()
                return
            }

            let lastData = state.status.displayData
            let disposition: FailureDisposition

            if error is RefreshTimeoutError {
                disposition = .transient(String(localized: "Request timed out. Showing last successful data."))
            } else {
                disposition = provider.classifyError(error)
            }

            switch disposition {
            case .unconfigured:
                state.status = .unconfigured

            case .transient(let message):
                if let lastData {
                    state.status = .stale(lastData, reason: .transient, message: message)
                } else {
                    state.status = .error(message)
                }

            case .auth(let message):
                if let lastData {
                    state.status = .stale(lastData, reason: .auth, message: message)
                } else {
                    state.status = .error(message)
                }

            case .persistent(let message):
                state.status = .error(message)
            }

            lastUpdated = attemptAt
        }

        states[provider.id] = state
        updateRefreshingFlag()
        rebuildEntries()
        syncActiveProviderSelection()
        NotificationService.shared.evaluate(entries: providerEntries)
        UsageExporter.write(entries: providerEntries)
        notifyIconUpdate()
    }

    // MARK: - Fetch with timeout

    private static func fetchUsage(
        for provider: any UsageProvider,
        timeout: TimeInterval
    ) async -> Result<UsageData, Error> {
        do {
            let data = try await withThrowingTaskGroup(of: UsageData.self) { group in
                group.addTask {
                    try await provider.fetchUsage()
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    throw RefreshTimeoutError.timeout
                }

                let result = try await group.next()!
                group.cancelAll()
                return result
            }
            return .success(data)
        } catch {
            return .failure(error)
        }
    }

    // MARK: - State management

    private func rebuildEntries() {
        providerEntries = providers.map { p in
            let state = states[p.id]
            ProviderEntry(
                id: p.id,
                displayName: p.displayName,
                shortLabel: p.shortLabel,
                status: state?.status ?? .unconfigured,
                lastAttemptAt: state?.lastAttemptAt,
                lastSuccessAt: state?.lastSuccessAt
            )
        }
    }

    private func updateRefreshingFlag() {
        isRefreshing = !inFlightRefreshes.isEmpty
    }

    private func configuredProviderIDs() -> [String] {
        providers.compactMap { provider in
            guard states[provider.id]?.status.isConfigured == true else { return nil }
            return provider.id
        }
    }

    private func syncActiveProviderSelection() {
        let preferredIDs = providers.compactMap { provider in
            guard states[provider.id]?.status.canDrivePrimaryUI == true else { return nil }
            return provider.id
        }
        let configuredIDs = configuredProviderIDs()

        if let activeProviderID {
            if preferredIDs.contains(activeProviderID) { return }
            if preferredIDs.isEmpty, configuredIDs.contains(activeProviderID) { return }
        }

        activeProviderID = preferredIDs.first ?? configuredIDs.first
    }

    /// Cycle to the next provider and update the icon.
    func cycleActiveProvider() {
        let configuredIDs = configuredProviderIDs()
        guard !configuredIDs.isEmpty else {
            activeProviderID = nil
            notifyIconUpdate()
            return
        }

        guard configuredIDs.count > 1 else {
            activeProviderID = configuredIDs[0]
            notifyIconUpdate()
            return
        }

        let currentIndex = activeProviderID.flatMap { configuredIDs.firstIndex(of: $0) } ?? -1
        activeProviderID = configuredIDs[(currentIndex + 1) % configuredIDs.count]
        notifyIconUpdate()
    }

    private func notifyIconUpdate() {
        guard
            let activeProviderID,
            let provider = providers.first(where: { $0.id == activeProviderID }),
            let status = states[activeProviderID]?.status
        else {
            onIconUpdate?(StatusBarIconModel(label: "?", utilization: nil, state: .unconfigured))
            return
        }

        let utilization = status.displayData?.fiveHour?.utilization
        let iconState: StatusBarIconState

        switch status {
        case .unconfigured:
            iconState = .unconfigured
        case .pendingFirstLoad, .refreshing:
            iconState = .refreshing
        case .ready:
            iconState = .ready
        case .stale:
            iconState = .stale
        case .error:
            iconState = .error
        }

        onIconUpdate?(StatusBarIconModel(label: provider.shortLabel, utilization: utilization, state: iconState))
    }
}
