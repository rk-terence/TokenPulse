import AppKit
import SwiftUI

@MainActor
final class StatusBarController {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    nonisolated(unsafe) private var eventMonitor: Any?
    nonisolated(unsafe) private var localEventMonitor: Any?

    var onRightClick: (() -> Void)?

    init(providerManager: ProviderManager) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // Placeholder icon
        updateIcon(StatusBarIconModel(label: "?", utilization: nil, state: .unconfigured))

        // Popover content
        let view = PopoverView(manager: providerManager) { [weak self] in
            self?.popover.performClose(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                providerManager.openSettings()
            }
        }
        popover.contentViewController = NSHostingController(rootView: view)
        popover.behavior = .transient

        // Handle both left and right clicks
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Monitor clicks outside the popover to close it
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.popover.isShown else { return }
            self.popover.performClose(nil)
        }
    }

    deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
        }
    }

    func updateIcon(_ model: StatusBarIconModel) {
        let image = BarIconRenderer.renderIcon(model)
        statusItem.button?.image = image
        statusItem.length = image.size.width
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            onRightClick?()
        } else {
            togglePopover(sender)
        }
    }

    private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}
