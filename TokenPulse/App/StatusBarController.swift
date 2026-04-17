import AppKit
import SwiftUI

@MainActor
final class StatusBarController {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    nonisolated(unsafe) private var eventMonitor: Any?
    nonisolated(unsafe) private var localEventMonitor: Any?

    private weak var proxyController: LocalProxyController?
    private var isPinned = false
    private var currentIconModel = StatusBarIconModel(label: "?", utilization: nil, state: .unconfigured)

    // MARK: - Animation tracks

    /// One track per direction. Holds an intensity (0…1) which snaps to 1 on
    /// a traffic event and decays afterwards, plus a hold window during which
    /// intensity remains at 1 even without new events.
    private struct ArrowTrack {
        var intensity: CGFloat = 0
        var holdRemaining: TimeInterval = 0

        var isIdle: Bool { intensity <= 0.001 && holdRemaining <= 0 }
    }

    /// Bar + particle list. The bar's `carrying` value is derived from the
    /// presence of particles; it eases up when a particle is in flight and
    /// eases back down when the list empties.
    private struct BarTrack {
        var particles: [IconAnimation.Particle] = []
        var carrying: CGFloat = 0

        var isIdle: Bool { particles.isEmpty && carrying <= 0.001 }
    }

    /// Percent-digit track. `highlight` pulses on particle absorption,
    /// `settle` pulses when the authoritative value changes on a poll.
    private struct PercentTrack {
        var highlight: CGFloat = 0
        var settle: CGFloat = 0
        var lastUtilization: Double?

        var isIdle: Bool { highlight <= 0.001 && settle <= 0.001 }
    }

    // MARK: - Tuning

    /// Timer frequency for all animation tracks.
    private static let fps: Double = 30
    private static let tickInterval: TimeInterval = 1.0 / fps

    /// Arrow: how long a single traffic event holds the glow at full intensity
    /// before it starts decaying. Kept short so bursts of traffic feel like
    /// continuous glow rather than strobing.
    private static let arrowHoldDuration: TimeInterval = 0.60
    /// Arrow: decay duration once hold expires.
    private static let arrowDecayDuration: TimeInterval = 0.80

    /// Particle travel time across the bar→digits gap.
    private static let particleTravelDuration: TimeInterval = 0.70
    /// Soft cap on concurrent particles before we stop spawning new ones
    /// (keeps visual density legible during bursts).
    private static let particleCap = 5

    /// Bar carrying-state ease rates (per second).
    private static let barEaseUpPerSec: CGFloat   = 3.0
    private static let barEaseDownPerSec: CGFloat = 1.5

    /// Percent-highlight duration (full pulse → zero).
    private static let percentHighlightDuration: TimeInterval = 0.70
    /// Percent-settle duration (full pulse → zero) on poll-value change.
    private static let percentSettleDuration: TimeInterval = 1.10

    // MARK: - State

    nonisolated(unsafe) private var animationTimer: Timer?
    private var upTrack = ArrowTrack()
    private var downTrack = ArrowTrack()
    private var barTrack = BarTrack()
    private var percentTrack = PercentTrack()

    var onRightClick: (() -> Void)?

    init(providerManager: ProviderManager, proxyController: LocalProxyController? = nil) {
        self.proxyController = proxyController
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // Popover content
        let view = PopoverView(
            manager: providerManager,
            proxyController: proxyController,
            onTogglePin: { [weak self] pinned in
                self?.setPinned(pinned)
            },
            onOpenSettings: { [weak self] in
                self?.popover.performClose(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    providerManager.openSettings()
                }
            }
        )
        popover.contentViewController = NSHostingController(rootView: view)
        popover.behavior = .transient

        // Handle both left and right clicks
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Close popover on external clicks (only when not pinned)
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, !self.isPinned, self.popover.isShown else { return }
            self.popover.performClose(nil)
        }

        // Subscribe to proxy traffic events. A nil direction means a UI-refresh
        // event that should not animate the traffic arrows.
        proxyController?.onTrafficEvent = { [weak self] direction in
            guard let direction else { return }
            self?.trafficEventReceived(direction: direction)
        }

        // Subscribe to request-done events. Each spawns a cost-transformation
        // particle on the bar → digits gap.
        proxyController?.onRequestDone = { [weak self] in
            self?.requestDoneReceived()
        }

        // Redraw when the proxy starts or stops so the dim state reflects
        // the toggle immediately, without waiting for the next traffic or
        // poll event.
        proxyController?.onRunningChanged = { [weak self] _ in
            self?.render()
        }

        // Initial render
        render()
    }

    deinit {
        animationTimer?.invalidate()
        if let eventMonitor    { NSEvent.removeMonitor(eventMonitor) }
        if let localEventMonitor { NSEvent.removeMonitor(localEventMonitor) }
    }

    // MARK: - Public

    /// Called by `ProviderManager` whenever provider status changes.
    func updateIcon(_ model: StatusBarIconModel) {
        let previous = currentIconModel
        currentIconModel = model

        // Detect an authoritative value change to trigger the settle animation.
        // We use the utilization in rounded-integer space so that noisy
        // sub-percent fluctuations don't constantly re-trigger the fade.
        let before = previous.utilization.map { Int($0.rounded()) }
        let after  = model.utilization.map { Int($0.rounded()) }
        if before != nil, after != nil, before != after {
            percentTrack.settle = 1.0
            percentTrack.lastUtilization = model.utilization
            startAnimationTimer()
        }
        render()
    }

    private func setPinned(_ pinned: Bool) {
        isPinned = pinned
        popover.behavior = pinned ? .applicationDefined : .transient
    }

    // MARK: - Event ingest

    private func trafficEventReceived(direction: TrafficDirection) {
        switch direction {
        case .upload:
            upTrack.intensity = 1.0
            upTrack.holdRemaining = Self.arrowHoldDuration
        case .download:
            downTrack.intensity = 1.0
            downTrack.holdRemaining = Self.arrowHoldDuration
        }
        startAnimationTimer()
    }

    private func requestDoneReceived() {
        // Soft cap to keep the icon legible under bursts; excess events
        // still fire (silently) until the next spawn has room.
        guard barTrack.particles.count < Self.particleCap else { return }
        barTrack.particles.append(IconAnimation.Particle(progress: 0))
        startAnimationTimer()
    }

    // MARK: - Tick loop

    private func startAnimationTimer() {
        guard animationTimer == nil else { return }
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.onAnimationTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    private func stopAnimationTimer() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    private func onAnimationTick() {
        let dt = Self.tickInterval

        advanceArrow(&upTrack,   dt: dt)
        advanceArrow(&downTrack, dt: dt)
        advanceBarAndParticles(dt: dt)
        advancePercent(dt: dt)

        render()

        if upTrack.isIdle && downTrack.isIdle && barTrack.isIdle && percentTrack.isIdle {
            stopAnimationTimer()
        }
    }

    private func advanceArrow(_ t: inout ArrowTrack, dt: TimeInterval) {
        if t.holdRemaining > 0 {
            // Full intensity during the hold window; arrow does not decay.
            t.intensity = 1
            t.holdRemaining -= dt
            if t.holdRemaining < 0 { t.holdRemaining = 0 }
            return
        }
        if t.intensity > 0 {
            // Linear fade-out over arrowDecayDuration.
            let step = CGFloat(dt / Self.arrowDecayDuration)
            t.intensity = max(0, t.intensity - step)
        }
    }

    private func advanceBarAndParticles(dt: TimeInterval) {
        // Advance each particle's progress; drop the ones that arrived and
        // fire a percent-highlight pulse for each arrival.
        let progressStep = CGFloat(dt / Self.particleTravelDuration)
        var arrivedCount = 0
        var next: [IconAnimation.Particle] = []
        next.reserveCapacity(barTrack.particles.count)
        for var p in barTrack.particles {
            p.progress += progressStep
            if p.progress >= 1.0 {
                arrivedCount += 1
            } else {
                next.append(p)
            }
        }
        barTrack.particles = next

        if arrivedCount > 0 {
            percentTrack.highlight = 1.0
        }

        // Bar carrying eases up while particles are present, down otherwise.
        let targetCarrying: CGFloat = barTrack.particles.isEmpty ? 0 : 1
        let rate = barTrack.particles.isEmpty ? Self.barEaseDownPerSec : Self.barEaseUpPerSec
        let step = rate * CGFloat(dt)
        if barTrack.carrying < targetCarrying {
            barTrack.carrying = min(targetCarrying, barTrack.carrying + step)
        } else if barTrack.carrying > targetCarrying {
            barTrack.carrying = max(targetCarrying, barTrack.carrying - step)
        }
    }

    private func advancePercent(dt: TimeInterval) {
        if percentTrack.highlight > 0 {
            let step = CGFloat(dt / Self.percentHighlightDuration)
            percentTrack.highlight = max(0, percentTrack.highlight - step)
        }
        if percentTrack.settle > 0 {
            let step = CGFloat(dt / Self.percentSettleDuration)
            percentTrack.settle = max(0, percentTrack.settle - step)
        }
    }

    // MARK: - Rendering

    private func render() {
        let animation = IconAnimation(
            up: .init(intensity: upTrack.intensity),
            down: .init(intensity: downTrack.intensity),
            bar: .init(carrying: barTrack.carrying),
            particles: barTrack.particles,
            percent: .init(
                highlight: percentTrack.highlight,
                settle: percentTrack.settle,
                alert: currentIconModel.utilization.map { $0 >= 100 } ?? false
            ),
            proxyEnabled: proxyController?.isRunning ?? false
        )
        let image = BarIconRenderer.renderIcon(currentIconModel, animation: animation)
        statusItem.button?.image = image
        statusItem.length = image.size.width
    }

    // MARK: - Click handling

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
