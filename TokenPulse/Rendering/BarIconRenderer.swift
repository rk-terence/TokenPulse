import AppKit

// MARK: - Icon animation state

/// Per-tick animation state passed from `StatusBarController` to the renderer.
/// Each field is a normalized value in [0, 1] driven by the controller's
/// 30 fps tick loop.
struct IconAnimation: Sendable {
    /// Per-arrow state (one instance for upload, one for download).
    struct ArrowState: Sendable {
        /// 0 = template rest, 1 = full-color glowing accent on overlay.
        var intensity: CGFloat

        static let idle = ArrowState(intensity: 0)
    }

    /// A single cost-transformation particle traversing the bar→digit gap.
    struct Particle: Sendable {
        /// 0 = just left the bar, 1 = arrived at the digits.
        var progress: CGFloat
    }

    /// Bar state. `carrying` is driven to 1 while any particle is in flight
    /// and decays back to 0 when the bar is idle, producing a smooth color
    /// crossfade on the overlay between transparent and the warm carrying tint.
    struct BarState: Sendable {
        var carrying: CGFloat

        static let idle = BarState(carrying: 0)
    }

    /// Percent-digit state. Tracks two overlapping effects:
    ///   `highlight` pulses up when a particle is absorbed (predicted accrual).
    ///   `settle` pulses up when the authoritative % changes on a poll tick.
    struct PercentState: Sendable {
        var highlight: CGFloat
        var settle: CGFloat

        static let idle = PercentState(highlight: 0, settle: 0)
    }

    var up: ArrowState
    var down: ArrowState
    var bar: BarState
    var particles: [Particle]
    var percent: PercentState
    /// Global dimmer applied to the arrows and bar when the proxy is off.
    /// The percentage is unaffected because it continues to reflect provider polls.
    var proxyEnabled: Bool

    static let idle = IconAnimation(
        up: .idle,
        down: .idle,
        bar: .idle,
        particles: [],
        percent: .idle,
        proxyEnabled: true
    )
}

// MARK: - Renderer

enum BarIconRenderer {

    // MARK: Layout constants (native pt)

    private static let iconHeight: CGFloat  = 22

    // Arrow geometry
    private static let arrowWidth: CGFloat  = 7
    private static let arrowHeight: CGFloat = 13
    private static let arrowHeadFraction: CGFloat = 0.54  // head takes 54% of arrow height
    private static let arrowStemFraction: CGFloat = 0.36  // stem is 36% of arrow width
    private static let downArrowDrop: CGFloat = 1         // down-arrow vertical nudge (pts, AppKit)

    // Bar geometry
    private static let barWidth: CGFloat    = 1.6
    private static let barHeight: CGFloat   = 14

    // Digits
    private static let digitFontSize: CGFloat = 11
    private static let digitSlotChars: Int    = 3

    // Horizontal spacing
    private static let padLeading: CGFloat   = 0.5
    private static let padTrailing: CGFloat  = 0.5
    private static let gapArrowToArrow: CGFloat = 2.5
    private static let gapArrowToBar: CGFloat   = 4
    private static let gapBarToDigits: CGFloat  = 4

    // MARK: Palette

    /// Appearance-specific accents. These tints are only applied on the overlay
    /// layer while the corresponding track is animating. The template layer
    /// always draws in black so macOS can tint it to match the real menu bar
    /// background (factoring in wallpaper luminance and transparency settings).
    /// `rimColor` is the crisp stroke wrapped around the fill while animating
    /// so the silhouette has a clear boundary against the menu bar.
    private struct Palette {
        let upload: NSColor
        let download: NSColor
        let barCarrying: NSColor
        let percent: NSColor
        let rimColor: NSColor

        static let dark = Palette(
            upload:       NSColor(srgbRed: 0.310, green: 0.765, blue: 0.969, alpha: 1), // #4FC3F7 sky-300
            download:     NSColor(srgbRed: 0.204, green: 0.827, blue: 0.600, alpha: 1), // #34D399 emerald-400
            barCarrying:  NSColor(srgbRed: 0.984, green: 0.749, blue: 0.141, alpha: 1), // #FBBF24 amber-400
            percent:      NSColor(srgbRed: 0.961, green: 0.620, blue: 0.043, alpha: 1), // #F59E0B amber-500
            rimColor:     NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        )

        // Light-mode accents are bright + saturated (400-tier). The black
        // `rimColor` wraps the bright fill in a crisp boundary so it doesn't
        // melt into the near-white bar.
        static let light = Palette(
            upload:       NSColor(srgbRed: 0.376, green: 0.647, blue: 0.980, alpha: 1), // #60A5FA blue-400
            download:     NSColor(srgbRed: 0.204, green: 0.827, blue: 0.600, alpha: 1), // #34D399 emerald-400
            barCarrying:  NSColor(srgbRed: 0.984, green: 0.749, blue: 0.141, alpha: 1), // #FBBF24 amber-400
            percent:      NSColor(srgbRed: 0.851, green: 0.467, blue: 0.024, alpha: 1), // #D97706 amber-600
            rimColor:     NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        )
    }

    /// Total stroke width for rim. Because stroke is centered on the path,
    /// only half (rimWidth / 2) is visible outside the shape; the inside
    /// half is overpainted by the fill. 1.0 pt → ~0.5 pt crisp rim.
    private static let rimWidth: CGFloat = 1.0

    // MARK: Public entry point

    /// Render the menu bar icon as two stacked images with identical size.
    ///
    /// - `template`: `isTemplate = true`. Drawn in black; macOS auto-tints it
    ///   to match the real menu bar background (wallpaper luminance, tinted
    ///   mode, reduce-transparency). Contains arrows, bar, and digits.
    ///   Fully opaque at rest; no color, no glow.
    ///
    /// - `overlay`: `isTemplate = false`. Contains only the COLORED deltas —
    ///   accent fills during animation, rim strokes, particles + trails, digit
    ///   pulse fill + highlight glow. Fully transparent when idle. Pinned over
    ///   `statusItem.button` via a non-interactive NSImageView subview so that
    ///   at rest the template tint shows through cleanly; during a pulse the
    ///   overlay fades in and covers the template with palette accents.
    ///
    /// - `size`: Common NSSize for both images.
    @MainActor
    static func renderIcon(
        _ model: StatusBarIconModel,
        animation: IconAnimation = .idle,
        isDarkAppearance: Bool = true
    ) -> (template: NSImage, overlay: NSImage, size: NSSize) {
        let palette: Palette = isDarkAppearance ? .dark : .light

        // Compute geometry once; both passes share it.
        let digitFont = NSFont.monospacedSystemFont(ofSize: digitFontSize, weight: .bold)
        let digitSlot = monospacedSlotWidth(for: digitFont, charCount: digitSlotChars)

        let totalWidth = padLeading
            + arrowWidth + gapArrowToArrow + arrowWidth
            + gapArrowToBar + barWidth + gapBarToDigits
            + digitSlot
            + padTrailing

        let size = NSSize(width: ceil(totalWidth), height: iconHeight)

        let resolved = resolvePercent(model: model, animation: animation, palette: palette)

        // Positions
        let upX     = padLeading
        let dnX     = upX + arrowWidth + gapArrowToArrow
        let barX    = dnX + arrowWidth + gapArrowToBar
        let digitsX = barX + barWidth + gapBarToDigits

        // Arrow vertical placement. The up-arrow centers in the icon;
        // the down-arrow gets a small downward nudge (AppKit coords:
        // smaller y = lower) so its head lands below the up-arrow's
        // head and the pair doesn't look top-heavy.
        let baseArrowY = (iconHeight - arrowHeight) / 2
        let upArrowY   = baseArrowY
        let dnArrowY   = baseArrowY - downArrowDrop
        let barY       = (iconHeight - barHeight) / 2

        // Proxy-off pulls the arrows + bar back to a faint trace.
        // The digit slot stays at full opacity because the percentage
        // still reflects provider polls.
        let dim: CGFloat = animation.proxyEnabled ? 1.0 : 0.35

        // ── Template pass ────────────────────────────────────────────────
        // All paths drawn in black with per-pixel alpha. isTemplate = true
        // so macOS re-tints to match the actual menu bar background.
        let template = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return true }

            drawArrowTemplate(in: ctx, x: upX, y: upArrowY, dim: dim, pointsUp: true)
            drawArrowTemplate(in: ctx, x: dnX, y: dnArrowY, dim: dim, pointsUp: false)
            drawBarTemplate(in: ctx, x: barX, y: barY, dim: dim)
            drawDigitsTemplate(in: ctx,
                               x: digitsX,
                               slotWidth: digitSlot,
                               font: digitFont,
                               text: resolved.text,
                               baseOpacity: resolved.opacity,
                               percent: animation.percent)
            return true
        }
        template.isTemplate = true

        // ── Overlay pass ─────────────────────────────────────────────────
        // Colored deltas only. Fully transparent when all tracks are idle.
        // isTemplate = false (default) so macOS does not re-tint these pixels.
        let overlay = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return true }

            let upEffective   = animation.up.intensity   * dim
            let downEffective = animation.down.intensity * dim
            let carryEff      = animation.bar.carrying   * dim

            if upEffective > 0.02 {
                drawArrowOverlay(in: ctx, x: upX, y: upArrowY,
                                 effectiveIntensity: upEffective,
                                 accent: palette.upload, rim: palette.rimColor,
                                 pointsUp: true)
            }
            if downEffective > 0.02 {
                drawArrowOverlay(in: ctx, x: dnX, y: dnArrowY,
                                 effectiveIntensity: downEffective,
                                 accent: palette.download, rim: palette.rimColor,
                                 pointsUp: false)
            }
            if carryEff > 0.02 {
                drawBarOverlay(in: ctx, x: barX, y: barY,
                               effectiveCarrying: carryEff,
                               carryingColor: palette.barCarrying, rim: palette.rimColor)
            }

            drawParticles(in: ctx,
                          bar: (x: barX, y: barY),
                          digitsX: digitsX,
                          gap: gapBarToDigits,
                          particles: animation.particles,
                          opacity: dim,
                          palette: palette)

            drawDigitsOverlay(in: ctx,
                              x: digitsX,
                              slotWidth: digitSlot,
                              font: digitFont,
                              text: resolved.text,
                              pulseTarget: resolved.pulseTarget,
                              baseOpacity: resolved.opacity,
                              percent: animation.percent)
            return true
        }
        overlay.isTemplate = false

        return (template: template, overlay: overlay, size: size)
    }

    // MARK: Percent resolution (digits text + color)

    /// `pulseTarget`, when non-nil, is the palette accent the digits fade
    /// toward during a `highlight` or `settle` pulse — the only time color
    /// appears on the overlay. A placeholder (?, !, ~, ---) has no pulse target.
    private struct ResolvedPercent {
        let text: String
        let pulseTarget: NSColor?
        let opacity: CGFloat
    }

    private static func resolvePercent(
        model: StatusBarIconModel,
        animation: IconAnimation,
        palette: Palette
    ) -> ResolvedPercent {
        // A placeholder (?, !, ~, ---) does not flash — nothing to predict,
        // nothing to settle.
        func placeholder(_ text: String, opacity: CGFloat) -> ResolvedPercent {
            ResolvedPercent(text: text, pulseTarget: nil, opacity: opacity)
        }

        // A real percentage crossfades to the palette accent while a pulse
        // is active; between pulses the template tint handles the rest state.
        func numeric(_ text: String, opacity: CGFloat) -> ResolvedPercent {
            ResolvedPercent(text: text, pulseTarget: palette.percent, opacity: opacity)
        }

        switch model.state {
        case .unconfigured:
            return placeholder(" ? ", opacity: 0.55)
        case .error:
            return placeholder(" ! ", opacity: 0.55)
        case .refreshing:
            if let u = model.utilization {
                return numeric(percentText(for: u), opacity: 0.55)
            } else {
                return placeholder(" ~ ", opacity: 0.55)
            }
        case .ready:
            if let u = model.utilization {
                return numeric(percentText(for: u), opacity: 1)
            } else {
                return placeholder(" ? ", opacity: 1)
            }
        case .stale:
            if let u = model.utilization {
                return numeric(percentText(for: u), opacity: 0.55)
            } else {
                return placeholder("---", opacity: 0.55)
            }
        }
    }

    /// "FUL" at 100%, otherwise "NN%" padded to 3 chars.
    private static func percentText(for utilization: Double) -> String {
        let clamped = max(0, min(100, utilization))
        let rounded = Int(clamped.rounded())
        if rounded >= 100 { return "FUL" }
        if rounded >= 10  { return "\(rounded)%" }
        return " \(rounded)%"
    }

    /// Monospaced slot width for exactly `charCount` glyphs.
    private static func monospacedSlotWidth(for font: NSFont, charCount: Int) -> CGFloat {
        let ref = NSAttributedString(
            string: String(repeating: "0", count: charCount),
            attributes: [.font: font]
        )
        return ceil(ref.size().width)
    }

    // MARK: Arrow path

    /// Arrow shape: triangular head, narrow stem.
    /// NSImage(flipped: false) uses AppKit coordinates — y=0 is at the BOTTOM,
    /// y=height is at the TOP. Paths are authored in that convention.
    private static func arrowPath(pointsUp: Bool, width: CGFloat, height: CGFloat) -> CGPath {
        let headHeight = height * arrowHeadFraction
        let stemWidth  = width * arrowStemFraction
        let stemLeftX  = (width - stemWidth) / 2
        let stemRightX = stemLeftX + stemWidth

        let path = CGMutablePath()
        if pointsUp {
            // Tip at top (high y), stem hangs below.
            path.move(to: CGPoint(x: width / 2, y: height))
            path.addLine(to: CGPoint(x: width,      y: height - headHeight))
            path.addLine(to: CGPoint(x: stemRightX, y: height - headHeight))
            path.addLine(to: CGPoint(x: stemRightX, y: 0))
            path.addLine(to: CGPoint(x: stemLeftX,  y: 0))
            path.addLine(to: CGPoint(x: stemLeftX,  y: height - headHeight))
            path.addLine(to: CGPoint(x: 0,          y: height - headHeight))
            path.closeSubpath()
        } else {
            // Tip at bottom (low y), stem rises above.
            path.move(to: CGPoint(x: width / 2, y: 0))
            path.addLine(to: CGPoint(x: width,      y: headHeight))
            path.addLine(to: CGPoint(x: stemRightX, y: headHeight))
            path.addLine(to: CGPoint(x: stemRightX, y: height))
            path.addLine(to: CGPoint(x: stemLeftX,  y: height))
            path.addLine(to: CGPoint(x: stemLeftX,  y: headHeight))
            path.addLine(to: CGPoint(x: 0,          y: headHeight))
            path.closeSubpath()
        }
        return path
    }

    // MARK: Arrow drawing — template pass

    /// Template pass: fill the arrow in black at 85% * dim alpha. No rim,
    /// no accent — macOS will re-tint the black pixels to match the menu bar.
    private static func drawArrowTemplate(
        in ctx: CGContext,
        x: CGFloat, y: CGFloat,
        dim: CGFloat,
        pointsUp: Bool
    ) {
        let path = arrowPath(pointsUp: pointsUp, width: arrowWidth, height: arrowHeight)
        ctx.saveGState()
        ctx.translateBy(x: x, y: y)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.85 * dim).cgColor)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.restoreGState()
    }

    // MARK: Arrow drawing — overlay pass

    /// Overlay pass: rim stroke + accent fill at `effectiveIntensity` alpha.
    /// Alpha-composites on top of the template so the palette color replaces
    /// the system tint at full intensity and fades back to transparent at rest.
    private static func drawArrowOverlay(
        in ctx: CGContext,
        x: CGFloat, y: CGFloat,
        effectiveIntensity: CGFloat,
        accent: NSColor,
        rim: NSColor,
        pointsUp: Bool
    ) {
        let path = arrowPath(pointsUp: pointsUp, width: arrowWidth, height: arrowHeight)
        ctx.saveGState()
        ctx.translateBy(x: x, y: y)
        ctx.setStrokeColor(rim.withAlphaComponent(min(1, effectiveIntensity)).cgColor)
        ctx.setLineWidth(rimWidth)
        ctx.addPath(path)
        ctx.strokePath()
        ctx.setFillColor(accent.withAlphaComponent(accent.alphaComponent * effectiveIntensity).cgColor)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.restoreGState()
    }

    // MARK: Bar drawing — template pass

    /// Template pass: fill the bar in black at 85% * dim alpha.
    private static func drawBarTemplate(
        in ctx: CGContext,
        x: CGFloat, y: CGFloat,
        dim: CGFloat
    ) {
        let rect = CGRect(x: x, y: y, width: barWidth, height: barHeight)
        let path = CGPath(roundedRect: rect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.85 * dim).cgColor)
        ctx.addPath(path)
        ctx.fillPath()
    }

    // MARK: Bar drawing — overlay pass

    /// Overlay pass: rim stroke + carrying-color fill at `effectiveCarrying` alpha.
    private static func drawBarOverlay(
        in ctx: CGContext,
        x: CGFloat, y: CGFloat,
        effectiveCarrying: CGFloat,
        carryingColor: NSColor,
        rim: NSColor
    ) {
        let rect = CGRect(x: x, y: y, width: barWidth, height: barHeight)
        let path = CGPath(roundedRect: rect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil)
        ctx.setStrokeColor(rim.withAlphaComponent(min(1, effectiveCarrying)).cgColor)
        ctx.setLineWidth(rimWidth)
        ctx.addPath(path)
        ctx.strokePath()
        ctx.setFillColor(carryingColor.withAlphaComponent(carryingColor.alphaComponent * effectiveCarrying).cgColor)
        ctx.addPath(path)
        ctx.fillPath()
    }

    // MARK: Particles

    /// Draw each particle as a bright dot with a short fading trail, positioned
    /// along the bar→digits gap according to its progress value.
    private static func drawParticles(
        in ctx: CGContext,
        bar: (x: CGFloat, y: CGFloat),
        digitsX: CGFloat,
        gap: CGFloat,
        particles: [IconAnimation.Particle],
        opacity: CGFloat,
        palette: Palette
    ) {
        guard !particles.isEmpty, opacity > 0.01 else { return }

        let yCenter = (iconHeight) / 2
        let travelStart = bar.x + barWidth + 0.5
        let travelEnd   = digitsX - 0.5

        for p in particles {
            let progress = max(0, min(1, p.progress))
            let px = travelStart + (travelEnd - travelStart) * progress

            ctx.saveGState()
            // Trail: short horizontal streak behind the particle.
            let trailLength: CGFloat = 4.0
            let trailStart = max(travelStart, px - trailLength)
            drawParticleTrail(
                in: ctx,
                from: CGPoint(x: trailStart, y: yCenter),
                to: CGPoint(x: px, y: yCenter),
                opacity: 0.85 * opacity,
                palette: palette
            )

            // Particle dot with glow.
            ctx.setShadow(
                offset: .zero,
                blur: 2.5,
                color: palette.barCarrying.withAlphaComponent(0.9 * opacity).cgColor
            )
            ctx.setFillColor(palette.barCarrying.withAlphaComponent(1.0 * opacity).cgColor)
            let dotDiameter: CGFloat = 2.4
            let dot = CGRect(
                x: px - dotDiameter / 2,
                y: yCenter - dotDiameter / 2,
                width: dotDiameter,
                height: dotDiameter
            )
            ctx.fillEllipse(in: dot)
            ctx.restoreGState()
        }
        _ = gap
    }

    private static func drawParticleTrail(
        in ctx: CGContext,
        from: CGPoint,
        to: CGPoint,
        opacity: CGFloat,
        palette: Palette
    ) {
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineWidth(1.2)
        ctx.setStrokeColor(palette.barCarrying.withAlphaComponent(opacity).cgColor)
        ctx.move(to: from)
        ctx.addLine(to: to)
        ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: Digits drawing — template pass

    /// Template pass: draw the percent text in black.
    /// `settledOpacity` mirrors the settle-dip the overlay also uses so both
    /// layers animate in sync during a value change.
    private static func drawDigitsTemplate(
        in ctx: CGContext,
        x: CGFloat,
        slotWidth: CGFloat,
        font: NSFont,
        text: String,
        baseOpacity: CGFloat,
        percent: IconAnimation.PercentState
    ) {
        // Settle-dip: briefly fade at mid-transition, then recover.
        let settledOpacity = max(0.15, baseOpacity - 0.5 * percent.settle * baseOpacity)

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black.withAlphaComponent(settledOpacity),
            .paragraphStyle: paragraph,
        ]
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        let textSize = attrStr.size()
        let textY = (iconHeight - textSize.height) / 2 + 0.5   // optical nudge
        attrStr.draw(in: CGRect(x: x, y: textY, width: slotWidth, height: textSize.height))
    }

    // MARK: Digits drawing — overlay pass

    /// Overlay pass: accent fill + optional highlight glow, composited on top
    /// of the template digits. Only draws when a pulse is in flight.
    private static func drawDigitsOverlay(
        in ctx: CGContext,
        x: CGFloat,
        slotWidth: CGFloat,
        font: NSFont,
        text: String,
        pulseTarget: NSColor?,
        baseOpacity: CGFloat,
        percent: IconAnimation.PercentState
    ) {
        guard let target = pulseTarget else { return }
        let pulse = max(percent.highlight, percent.settle)
        guard pulse > 0.02 else { return }

        // Settle-dip mirrors the template pass.
        let settledOpacity = max(0.15, baseOpacity - 0.5 * percent.settle * baseOpacity)
        let finalAlpha = target.alphaComponent * pulse * settledOpacity

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: target.withAlphaComponent(finalAlpha),
            .paragraphStyle: paragraph,
        ]
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        let textSize = attrStr.size()
        let textY = (iconHeight - textSize.height) / 2 + 0.5   // optical nudge
        let drawRect = CGRect(x: x, y: textY, width: slotWidth, height: textSize.height)

        // Highlight pulse — glow blooms only on predicted accrual events.
        if percent.highlight > 0.02 {
            ctx.saveGState()
            ctx.setShadow(
                offset: .zero,
                blur: 3.5 * percent.highlight,
                color: target.withAlphaComponent(0.85 * percent.highlight).cgColor
            )
            attrStr.draw(in: drawRect)
            ctx.restoreGState()
        }

        attrStr.draw(in: drawRect)
    }
}
