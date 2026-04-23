import AppKit
import SwiftUI

/// Borderless floating panel used in place of `NSPopover` so the popup has
/// no arrow/tip and reads as a plain rounded rectangle. Nonactivating so
/// opening the popup doesn't steal focus from the user's frontmost app.
final class FloatingPopupWindow: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 384, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        // Snap in/out like a native menu — no fade. .utilityWindow was adding
        // a ~150ms fade that made the popup feel slow.
        animationBehavior = .none
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Transparent image view that lets all mouse events pass through to the
/// status item button beneath it. Used to composite the colored overlay on
/// top of the template icon without intercepting clicks.
private final class NonInteractiveImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
final class StatusBarController {
    private static let popupCornerRadius: CGFloat = 10
    private static let popupTopGap: CGFloat = 6

    private let statusItem: NSStatusItem
    private let overlayImageView = NonInteractiveImageView()
    private let popupWindow = FloatingPopupWindow()
    private let hostingController: NSHostingController<PopoverView>
    private var hostingSizeObservation: NSKeyValueObservation?
    nonisolated(unsafe) private var eventMonitor: Any?
    nonisolated(unsafe) private var localEventMonitor: Any?
    nonisolated(unsafe) private var resignKeyObserver: Any?

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
    nonisolated(unsafe) private var appearanceObservation: NSKeyValueObservation?
    private var upTrack = ArrowTrack()
    private var downTrack = ArrowTrack()
    private var barTrack = BarTrack()
    private var percentTrack = PercentTrack()

    var onRightClick: (() -> Void)?

    init(providerManager: ProviderManager, proxyController: LocalProxyController? = nil) {
        self.proxyController = proxyController
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // Build hosting controller first so callbacks can reference a nonnull
        // popupWindow via self.
        let host = NSHostingController(
            rootView: PopoverView(
                manager: providerManager,
                proxyController: proxyController
            )
        )
        host.sizingOptions = [.preferredContentSize]
        self.hostingController = host

        // Host the SwiftUI content inside a rounded NSVisualEffectView so we
        // keep the native popover material + shadow but drop the arrow.
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = Self.popupCornerRadius
        background.layer?.masksToBounds = true

        host.view.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: background.topAnchor),
            host.view.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            host.view.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        popupWindow.contentView = background

        // Rewire the pin / settings callbacks now that self exists.
        host.rootView = PopoverView(
            manager: providerManager,
            proxyController: proxyController,
            onTogglePin: { [weak self] pinned in
                self?.setPinned(pinned)
            },
            onOpenSettings: { [weak self] in
                self?.hidePopup()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    providerManager.openSettings()
                }
            }
        )

        // Track SwiftUI's preferred content size so the window follows content
        // growth/shrinkage (e.g., new sessions arriving) while staying anchored
        // to its top-left corner.
        hostingSizeObservation = host.observe(\.preferredContentSize, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.applyPreferredContentSize()
            }
        }

        // Warm up SwiftUI so the first click doesn't pay a cold-render cost.
        // Give the content view a real frame, force a synchronous layout pass,
        // then size the window to the SwiftUI preferred size.
        background.frame = NSRect(x: 0, y: 0, width: 384, height: 600)
        host.view.layoutSubtreeIfNeeded()
        applyPreferredContentSize(preservingAnchor: false)

        // Handle both left and right clicks
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone

            // Overlay: non-interactive image view pinned over the button for
            // the colored accent layer. Clicks fall through via hitTest = nil.
            overlayImageView.imageScaling = .scaleNone
            overlayImageView.imageAlignment = .alignCenter
            overlayImageView.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(overlayImageView)
            NSLayoutConstraint.activate([
                overlayImageView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                overlayImageView.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                overlayImageView.topAnchor.constraint(equalTo: button.topAnchor),
                overlayImageView.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            ])
        }

        // Close popup on external clicks (only when not pinned)
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isPinned, self.popupWindow.isVisible else { return }
                self.hidePopup()
            }
        }

        // Close popup when it resigns key (e.g. user switches apps via Cmd-Tab).
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: popupWindow,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isPinned, self.popupWindow.isVisible else { return }
                self.hidePopup()
            }
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

        // Re-render on system appearance changes so the icon palette tracks
        // the light/dark menu bar. KVO on NSApp.effectiveAppearance fires on
        // both manual theme changes and Auto-switch sunset/sunrise.
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.render() }
        }

        // Initial render
        render()
    }

    deinit {
        animationTimer?.invalidate()
        appearanceObservation?.invalidate()
        hostingSizeObservation?.invalidate()
        if let eventMonitor    { NSEvent.removeMonitor(eventMonitor) }
        if let localEventMonitor { NSEvent.removeMonitor(localEventMonitor) }
        if let resignKeyObserver { NotificationCenter.default.removeObserver(resignKeyObserver) }
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
                settle: percentTrack.settle
            ),
            proxyEnabled: proxyController?.isRunning ?? false
        )
        // Read from NSApp directly: that's what the KVO observes, and the
        // button's effectiveAppearance can lag by a tick on theme switches,
        // causing the first render after a toggle to pick the stale palette.
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua

        let result = BarIconRenderer.renderIcon(
            currentIconModel,
            animation: animation,
            isDarkAppearance: isDark
        )
        statusItem.button?.image = result.template
        overlayImageView.image = result.overlay
        statusItem.length = result.size.width
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
        if popupWindow.isVisible {
            hidePopup()
        } else {
            showPopup()
        }
    }

    private func showPopup() {
        guard let button = statusItem.button,
              let buttonWindow = button.window else { return }

        // Make sure the window has a sensible size before the first show.
        applyPreferredContentSize(preservingAnchor: false)

        let buttonFrameInScreen = buttonWindow.convertToScreen(
            button.convert(button.bounds, to: nil)
        )
        let screenFrame = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let size = popupWindow.frame.size

        let desiredX = buttonFrameInScreen.midX - size.width / 2
        let clampedX = max(
            screenFrame.minX + 4,
            min(desiredX, screenFrame.maxX - size.width - 4)
        )
        let originY = buttonFrameInScreen.minY - Self.popupTopGap - size.height

        popupWindow.setFrameOrigin(NSPoint(x: clampedX, y: originY))
        popupWindow.makeKeyAndOrderFront(nil)
    }

    private func hidePopup() {
        popupWindow.orderOut(nil)
    }

    /// Resize the popup window to match the SwiftUI content's preferred size.
    /// Keeps the top-left corner anchored so content growth expands downward.
    private func applyPreferredContentSize(preservingAnchor: Bool = true) {
        var size = hostingController.preferredContentSize
        if size.width <= 1 || size.height <= 1 {
            // Fall back to the host view's fitting size during the first
            // measurement pass, before SwiftUI has reported a preferred size.
            size = hostingController.view.fittingSize
        }
        guard size.width > 1, size.height > 1 else { return }

        if preservingAnchor, popupWindow.isVisible {
            let current = popupWindow.frame
            let topLeft = NSPoint(x: current.minX, y: current.maxY)
            let newOrigin = NSPoint(x: topLeft.x, y: topLeft.y - size.height)
            popupWindow.setFrame(NSRect(origin: newOrigin, size: size), display: true, animate: false)
        } else {
            popupWindow.setContentSize(size)
        }
    }
}
