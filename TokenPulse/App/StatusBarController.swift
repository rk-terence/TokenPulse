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
    private var currentIconModel = StatusBarIconModel(label: "?", utilization: nil, sevenDayUtilization: nil, state: .unconfigured)

    // MARK: - Slash animation state machine

    private enum AnimationState {
        case idle              // full-width gray slash
        case starting          // shrinking to glowing segment (morph 0→1)
        case bouncing          // glowing segment ping-pongs; countdown ticks
        case waitingForCenter  // countdown expired, coasting to center
        case stopping          // expanding back to full-width (morph 1→0)
    }

    /// 30 fps animation timer — only runs while animation is active.
    nonisolated(unsafe) private var animationTimer: Timer?
    private var slashState: AnimationState = .idle
    /// Normalized phase [0, 2) — one full ping-pong cycle.
    private var animationPhase: CGFloat = 0.5
    /// Current morph value (0 = idle full-width gray, 1 = active orange segment).
    private var morphTransition: CGFloat = 0
    /// Seconds of bounce time remaining (only decremented in `.bouncing`).
    private var bounceTimeRemaining: TimeInterval = 0

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

        // Subscribe to proxy traffic events.
        proxyController?.onTrafficEvent = { [weak self] in
            self?.trafficEventReceived()
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

    /// Called by ProviderManager whenever provider status changes.
    func updateIcon(_ model: StatusBarIconModel) {
        currentIconModel = model
        render()
    }

    private func setPinned(_ pinned: Bool) {
        isPinned = pinned
        popover.behavior = pinned ? .applicationDefined : .transient
    }

    // MARK: - Event-driven animation

    /// How long the glowing segment bounces before winding down.
    private static let bounceDuration: TimeInterval = 2.0
    /// Morph speed per tick (0→1 in ~0.4s at 30fps: 1.0 / 12 ≈ 0.083).
    private static let morphSpeed: CGFloat = 0.083
    /// Normalized phase increment per tick (~1.7s full ping-pong at 30fps).
    private static let phaseStep: CGFloat = 0.04
    /// How close the ping-pong position must be to 0.5 to count as "at center".
    private static let centerEpsilon: CGFloat = 0.05

    /// Called by the proxy's traffic event callback.
    private func trafficEventReceived() {
        switch slashState {
        case .idle:
            slashState = .starting
            morphTransition = 0
            animationPhase = 0.5   // center — shrinks symmetrically
            startAnimationTimer()

        case .starting:
            break  // already heading toward active

        case .bouncing:
            bounceTimeRemaining = Self.bounceDuration

        case .waitingForCenter:
            slashState = .bouncing
            bounceTimeRemaining = Self.bounceDuration

        case .stopping:
            // Reverse from current morph progress back toward active.
            slashState = .starting
        }
    }

    private func startAnimationTimer() {
        guard animationTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
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
        let dt: TimeInterval = 1.0 / 30.0

        switch slashState {
        case .idle:
            stopAnimationTimer()
            return

        case .starting:
            // Morph toward active (0→1); phase stays at center.
            morphTransition = min(morphTransition + Self.morphSpeed, 1.0)
            if morphTransition >= 1.0 {
                slashState = .bouncing
                bounceTimeRemaining = Self.bounceDuration
                // Random initial direction from center.
                animationPhase = Bool.random() ? 0.5 : 1.5
            }

        case .bouncing:
            animationPhase = (animationPhase + Self.phaseStep)
                .truncatingRemainder(dividingBy: 2.0)
            bounceTimeRemaining -= dt
            if bounceTimeRemaining <= 0 {
                slashState = .waitingForCenter
            }

        case .waitingForCenter:
            animationPhase = (animationPhase + Self.phaseStep)
                .truncatingRemainder(dividingBy: 2.0)
            let raw = animationPhase.truncatingRemainder(dividingBy: 2.0)
            let pingPong = raw <= 1.0 ? raw : 2.0 - raw
            if abs(pingPong - 0.5) < Self.centerEpsilon {
                animationPhase = 0.5   // snap to center
                slashState = .stopping
            }

        case .stopping:
            // Morph toward idle (1→0); phase stays at center.
            morphTransition = max(morphTransition - Self.morphSpeed, 0.0)
            if morphTransition <= 0 {
                slashState = .idle
                render(transition: 0)
                stopAnimationTimer()
                return
            }
        }

        render(transition: morphTransition)
    }

    // MARK: - Rendering

    private func render(transition: CGFloat = 0) {
        let flow: SlashFlow = transition > 0 ? .downstream : .idle
        let slash = SlashAnimation(flow: flow, phase: animationPhase, transition: transition)
        let image = BarIconRenderer.renderIcon(currentIconModel, slash: slash)
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
