import Foundation
import SwiftUI

struct ProviderEntry: Sendable {
    let id: String
    let displayName: String
    let shortLabel: String
    let status: ProviderStatus
}

@Observable
@MainActor
final class ProviderManager {
    private(set) var providerEntries: [ProviderEntry] = []
    private(set) var lastUpdated: Date?
    private(set) var isRefreshing = false
    private(set) var activeProviderIndex: Int = 0

    private var providers: [any UsageProvider] = []
    private var statuses: [String: ProviderStatus] = [:]
    private var settingsWindow: NSWindow?

    var onIconUpdate: ((_ label: String, _ utilization: Double) -> Void)?
    var onPollIntervalChanged: ((_ interval: TimeInterval) -> Void)?

    func requestRefresh() {
        guard !isRefreshing else { return }
        Task { await refreshAll() }
    }

    func openSettings() {
        NSApp.activate(ignoringOtherApps: true)

        if let window = settingsWindow, window.isVisible {
            window.orderFrontRegardless()
            return
        }
        let view = SettingsView(manager: self)
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
        statuses[provider.id] = .idle
        rebuildEntries()
    }

    func refreshAll() async {
        isRefreshing = true
        for provider in providers {
            statuses[provider.id] = .loading
        }
        rebuildEntries()

        await withTaskGroup(of: (String, ProviderStatus).self) { group in
            for provider in providers {
                group.addTask { [provider] in
                    do {
                        let data = try await provider.fetchUsage()
                        return (provider.id, .ready(data))
                    } catch {
                        return (provider.id, .error(error.localizedDescription))
                    }
                }
            }
            for await (id, status) in group {
                statuses[id] = status
            }
        }

        lastUpdated = .now
        isRefreshing = false
        rebuildEntries()
        UsageExporter.write(entries: providerEntries)
        notifyIconUpdate()
    }

    private func rebuildEntries() {
        providerEntries = providers.map { p in
            ProviderEntry(
                id: p.id,
                displayName: p.displayName,
                shortLabel: p.shortLabel,
                status: statuses[p.id] ?? .idle
            )
        }
    }

    /// Cycle to the next provider and update the icon.
    func cycleActiveProvider() {
        guard !providers.isEmpty else { return }
        activeProviderIndex = (activeProviderIndex + 1) % providers.count
        notifyIconUpdate()
    }

    private func notifyIconUpdate() {
        guard !providers.isEmpty else { return }
        let index = min(activeProviderIndex, providers.count - 1)
        let p = providers[index]
        let label = p.shortLabel
        let utilization: Double
        if case .ready(let data) = statuses[p.id],
           let util = data.fiveHour?.utilization {
            utilization = util
        } else {
            utilization = 0
        }
        onIconUpdate?(label, utilization)
    }

}
