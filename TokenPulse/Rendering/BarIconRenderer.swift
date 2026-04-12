import AppKit

// MARK: - Slash animation state

/// Flow direction for the diagonal slash animation.
enum SlashFlow: Sendable {
    case idle        // solid line, no animation
    case upstream    // sending request — pulse travels up-right
    case downstream  // receiving response — pulse travels down-left
}

/// Controls the diagonal slash animation in the menu bar icon.
struct SlashAnimation: Sendable {
    static let idle = SlashAnimation(flow: .idle, phase: 0, transition: 0)

    let flow: SlashFlow
    let phase: CGFloat       // advanced by caller each timer tick
    let transition: CGFloat  // 0 = idle (full-width gray), 1 = active (short glowing segment)
}

// MARK: - Renderer

enum BarIconRenderer {
    // Layout
    private static let usageFontSize: CGFloat    = 9.5   // same size for both 5h and weekly
    private static let slashInset: CGFloat       = 1.5   // inset for the diagonal slash line

    /// Render the menu bar icon.
    ///   Diagonal cell: 5h upper-left, weekly lower-right, slash between.
    ///   When streaming, a bright pulse travels along the slash.
    @MainActor
    static func renderIcon(
        _ model: StatusBarIconModel,
        slash: SlashAnimation = .idle
    ) -> NSImage {
        let (topStr, botStr) = usageStrings(model)
        let topSize = topStr.size()
        let botSize = botStr.size()

        // Cell width: at least wide enough for `minDisplayChars` digits.
        let font = NSFont.monospacedSystemFont(ofSize: usageFontSize, weight: .semibold)
        let refStr = NSAttributedString(
            string: String(repeating: "0", count: minDisplayChars),
            attributes: [.font: font]
        )
        let cellW = max(ceil(refStr.size().width), ceil(topSize.width), ceil(botSize.width))
        let totalWidth = botStr.length > 0
            ? cellW * 2 + slashInset * 2
            : ceil(topSize.width)
        let height: CGFloat = 22

        let image = NSImage(size: NSSize(width: totalWidth, height: height), flipped: false) { rect in
            if botStr.length > 0 {
                // 5h number — upper-left, right-aligned within left cell
                topStr.draw(at: NSPoint(x: cellW - ceil(topSize.width),
                                        y: rect.height - ceil(topSize.height) - 1))

                // Weekly number — lower-right, left-aligned within right cell
                botStr.draw(at: NSPoint(x: totalWidth - cellW,
                                        y: 1))

                // Diagonal separator / streaming chevrons.
                guard let ctx = NSGraphicsContext.current?.cgContext else { return true }
                ctx.saveGState()

                let inset = slashInset
                // Slash endpoints: upper-right → lower-left.
                let p0 = CGPoint(x: totalWidth - inset, y: rect.height - inset - 1)
                let p1 = CGPoint(x: inset, y: inset + 1)

                drawSlash(in: ctx, p0: p0, p1: p1,
                          phase: slash.phase, transition: slash.transition)

                ctx.restoreGState()
            } else {
                // Single number centred vertically.
                topStr.draw(at: NSPoint(x: 0, y: rect.midY - topSize.height / 2))
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: - Left cell (diagonal split)

    /// Returns (top, bottom) attributed strings for the diagonal cell.
    /// Top = 5h usage (upper-left), Bottom = weekly usage (lower-right).
    /// When the secondary window is absent, render `NaN` so the slash still draws.
    /// Minimum display width in characters for each number cell.
    private static let minDisplayChars = 3

    private static func usageStrings(
        _ model: StatusBarIconModel
    ) -> (NSAttributedString, NSAttributedString) {
        let font = NSFont.monospacedSystemFont(ofSize: usageFontSize, weight: .semibold)

        let topText  = padded(numberText(for: model, utilization: model.utilization))
        let topColor = primaryColor(for: model)
        let topStr   = NSAttributedString(
            string: topText,
            attributes: [.font: font, .foregroundColor: topColor]
        )

        let botText  = secondaryNumberText(for: model)
        let botColor = secondaryColor(for: model)
        let botStr   = NSAttributedString(
            string: botText,
            attributes: [.font: font, .foregroundColor: botColor]
        )

        return (topStr, botStr)
    }

    /// Right-align text within a fixed-width field of at least `minDisplayChars` characters.
    private static func padded(_ text: String) -> String {
        let pad = max(0, minDisplayChars - text.count)
        return String(repeating: " ", count: pad) + text
    }

    private static func numberText(for model: StatusBarIconModel, utilization: Double?) -> String {
        switch model.state {
        case .unconfigured: return "?"
        case .error:        return "!"
        case .refreshing:
            return utilization.map { "\(Int(round($0)))" } ?? "~"
        case .ready, .stale:
            return utilization.map { "\(Int(round($0)))" } ?? "?"
        }
    }

    private static func secondaryNumberText(for model: StatusBarIconModel) -> String {
        if let utilization = model.sevenDayUtilization {
            return numberText(for: model, utilization: utilization)
        }

        switch model.state {
        case .ready, .refreshing, .stale:
            return "--"
        case .unconfigured:
            return "?"
        case .error:
            return "!"
        }
    }

    /// Color for the primary (5h) number — monochrome to match system menu bar style.
    private static func primaryColor(for model: StatusBarIconModel) -> NSColor {
        switch model.state {
        case .unconfigured, .stale: return .secondaryLabelColor
        case .error:                return .secondaryLabelColor
        case .refreshing:           return .labelColor.withAlphaComponent(0.5)
        case .ready:                return .labelColor
        }
    }

    /// Color for the secondary (weekly) number — same as primary.
    private static func secondaryColor(for model: StatusBarIconModel) -> NSColor {
        primaryColor(for: model)
    }

    // MARK: - Unified slash drawing

    /// Fraction of the slash length occupied by the runner at full transition.
    private static let runnerFraction: CGFloat = 0.50

    /// Draw the diagonal slash, morphing between full-width gray (idle) and
    /// a short glowing orange segment (active) based on `transition` (0…1).
    private static func drawSlash(
        in ctx: CGContext,
        p0: CGPoint,
        p1: CGPoint,
        phase: CGFloat,
        transition: CGFloat
    ) {
        let dx = p1.x - p0.x
        let dy = p1.y - p0.y
        let length = hypot(dx, dy)
        guard length > 0 else { return }

        // --- Segment bounds ---
        // Lerp center: 0.5 (middle) → ping-pong position.
        // Lerp half-width: 0.5 (full slash) → halfRunner.
        let halfRunner = runnerFraction / 2
        // Phase is pre-normalized [0, 2): 0→1 forward, 1→2 backward.
        let raw = phase.truncatingRemainder(dividingBy: 2.0)
        let pingPong = raw <= 1.0 ? raw : 2.0 - raw

        let center    = 0.5 + transition * (pingPong - 0.5)
        let halfWidth = 0.5 - transition * (0.5 - halfRunner)

        let segStart = max(center - halfWidth, 0)
        let segEnd   = min(center + halfWidth, 1.0)

        let startPt = CGPoint(x: p0.x + dx * segStart, y: p0.y + dy * segStart)
        let endPt   = CGPoint(x: p0.x + dx * segEnd,   y: p0.y + dy * segEnd)

        // --- Color: lerp gray → orange ---
        let gray  = NSColor.secondaryLabelColor
        let orange = NSColor.systemOrange

        // Glow (only visible when transitioning toward active).
        if transition > 0.01 {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 2.5,
                           color: orange.withAlphaComponent(0.6 * transition).cgColor)
            ctx.setStrokeColor(orange.withAlphaComponent(0.5 * transition).cgColor)
            ctx.setLineWidth(1.0 + 1.5 * transition)
            ctx.setLineCap(.round)
            ctx.move(to: startPt)
            ctx.addLine(to: endPt)
            ctx.strokePath()
            ctx.restoreGState()
        }

        // Core line: blend gray → orange.
        let blended = blendColor(from: gray, to: orange, t: transition)
        let lineWidth = 1.5 - 0.5 * transition  // 1.5 idle → 1.0 active
        ctx.setStrokeColor(blended.cgColor)
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)
        ctx.move(to: startPt)
        ctx.addLine(to: endPt)
        ctx.strokePath()
    }

    /// Simple linear blend between two NSColors in sRGB space.
    private static func blendColor(from: NSColor, to: NSColor, t: CGFloat) -> NSColor {
        let f = from.usingColorSpace(.sRGB) ?? from
        let o = to.usingColorSpace(.sRGB) ?? to
        var fr: CGFloat = 0, fg: CGFloat = 0, fb: CGFloat = 0, fa: CGFloat = 0
        var tr: CGFloat = 0, tg: CGFloat = 0, tb: CGFloat = 0, ta: CGFloat = 0
        f.getRed(&fr, green: &fg, blue: &fb, alpha: &fa)
        o.getRed(&tr, green: &tg, blue: &tb, alpha: &ta)
        return NSColor(
            srgbRed:   fr + (tr - fr) * t,
            green: fg + (tg - fg) * t,
            blue:  fb + (tb - fb) * t,
            alpha: fa + (ta - fa) * t
        )
    }
}
