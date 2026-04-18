import AppKit

// MARK: - Icon animation state

/// Per-tick animation state passed from `StatusBarController` to the renderer.
/// Each field is a normalized value in [0, 1] driven by the controller's
/// 30 fps tick loop.
struct IconAnimation: Sendable {
    /// Per-arrow state (one instance for upload, one for download).
    struct ArrowState: Sendable {
        /// 0 = labelColor rest, 1 = full-color glowing accent.
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
    /// crossfade between the rest-state labelColor and the warm carrying tint.
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
        /// True when the provider is at 100%. Swaps the warm amber for the
        /// alert red and replaces the digits with "FUL".
        var alert: Bool

        static let idle = PercentState(highlight: 0, settle: 0, alert: false)
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

    /// Appearance-specific accents. These tints are only applied while the
    /// corresponding track is animating; the rest-state color is always
    /// `labelColor(isDarkAppearance:)` so the glyph reads like a stock menu
    /// extra between ticks. Light-mode tints are deeper and more saturated so
    /// they survive wallpaper-tinted bars; dark-mode tints stay airy for the
    /// translucent dark bar.
    private struct Palette {
        let upload: NSColor
        let download: NSColor
        let barCarrying: NSColor
        let percent: NSColor
        let percentAlert: NSColor

        static let dark = Palette(
            upload:       NSColor(srgbRed: 0.310, green: 0.765, blue: 0.969, alpha: 1), // #4FC3F7 sky-300
            download:     NSColor(srgbRed: 0.204, green: 0.827, blue: 0.600, alpha: 1), // #34D399 emerald-400
            barCarrying:  NSColor(srgbRed: 0.984, green: 0.749, blue: 0.141, alpha: 1), // #FBBF24 amber-400
            percent:      NSColor(srgbRed: 0.961, green: 0.620, blue: 0.043, alpha: 1), // #F59E0B amber-500
            percentAlert: NSColor(srgbRed: 0.937, green: 0.267, blue: 0.267, alpha: 1)  // #EF4444 red-500
        )

        // Light-mode accents sit at mid-weight (500–600) rather than the
        // deep 700–800 tones. Idle is effectively black in light mode, so
        // the crossfade target has to carry enough luminance for the
        // animation to be visible — a too-dark accent just reads as the
        // same black glyph pulsing in place. These weights also keep
        // hue-distinct contrast against wallpaper-tinted menu bars.
        static let light = Palette(
            upload:       NSColor(srgbRed: 0.231, green: 0.510, blue: 0.965, alpha: 1), // #3B82F6 blue-500
            download:     NSColor(srgbRed: 0.063, green: 0.725, blue: 0.506, alpha: 1), // #10B981 emerald-500
            barCarrying:  NSColor(srgbRed: 0.961, green: 0.620, blue: 0.043, alpha: 1), // #F59E0B amber-500
            percent:      NSColor(srgbRed: 0.851, green: 0.467, blue: 0.024, alpha: 1), // #D97706 amber-600
            percentAlert: NSColor(srgbRed: 0.863, green: 0.149, blue: 0.149, alpha: 1)  // #DC2626 red-600
        )
    }

    /// At-rest color for every part. Matches `NSColor.labelColor` for the
    /// given appearance so the idle glyph blends in with Wi-Fi, Battery,
    /// and other stock menu bar icons.
    private static func labelColor(isDarkAppearance: Bool) -> NSColor {
        isDarkAppearance
            ? NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.85)
            : NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.85)
    }

    // MARK: Public entry point

    @MainActor
    static func renderIcon(
        _ model: StatusBarIconModel,
        animation: IconAnimation = .idle,
        isDarkAppearance: Bool = true
    ) -> NSImage {
        let palette: Palette = isDarkAppearance ? .dark : .light
        let labelC = labelColor(isDarkAppearance: isDarkAppearance)
        // Compute total icon width. The digits slot is fixed at `digitSlotChars`
        // monospaced chars wide so the menu bar icon does not jitter as the
        // percentage changes. "FUL" intentionally renders at the same width.
        let digitFont = NSFont.monospacedSystemFont(ofSize: digitFontSize, weight: .bold)
        let digitSlot = monospacedSlotWidth(for: digitFont, charCount: digitSlotChars)

        let totalWidth = padLeading
            + arrowWidth + gapArrowToArrow + arrowWidth
            + gapArrowToBar + barWidth + gapBarToDigits
            + digitSlot
            + padTrailing

        let size = NSSize(width: ceil(totalWidth), height: iconHeight)

        let image = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return true }

            let resolved = resolvePercent(
                model: model,
                animation: animation,
                palette: palette,
                labelColor: labelC
            )

            // Positions
            let upX  = padLeading
            let dnX  = upX + arrowWidth + gapArrowToArrow
            let barX = dnX + arrowWidth + gapArrowToBar
            let digitsX = barX + barWidth + gapBarToDigits

            // Arrow vertical placement: with a triangular head + rectangular
            // stem, each arrow's visual center of mass is offset from its
            // bounding-box midpoint. Shift each arrow so the CoM lands on the
            // icon's vertical centerline; the up-arrow and down-arrow get
            // mirrored offsets and so end up optically aligned with each other.
            let baseArrowY = (iconHeight - arrowHeight) / 2
            let comShift   = arrowCenterOfMassYOffset
            let upArrowY   = baseArrowY - comShift
            let dnArrowY   = baseArrowY + comShift
            let barY   = (iconHeight - barHeight) / 2

            // 1) Arrows. Proxy-off pulls the left half of the icon (arrows +
            //    bar) back to a faint trace so the user can tell at a glance
            //    that traffic is paused. The digit slot stays at full opacity
            //    because the percentage still reflects provider polls.
            let dim: CGFloat = animation.proxyEnabled ? 1.0 : 0.35
            drawArrow(in: ctx,
                      x: upX, y: upArrowY,
                      intensity: animation.up.intensity,
                      dim: dim,
                      idle: labelC,
                      accent: palette.upload,
                      pointsUp: true)
            drawArrow(in: ctx,
                      x: dnX, y: dnArrowY,
                      intensity: animation.down.intensity,
                      dim: dim,
                      idle: labelC,
                      accent: palette.download,
                      pointsUp: false)

            // 2) Bar + particles + trail
            drawBar(in: ctx,
                    x: barX, y: barY,
                    carrying: animation.bar.carrying,
                    dim: dim,
                    idle: labelC,
                    carryingColor: palette.barCarrying)

            drawParticles(in: ctx,
                          bar: (x: barX, y: barY),
                          digitsX: digitsX,
                          gap: gapBarToDigits,
                          particles: animation.particles,
                          opacity: dim,
                          palette: palette)

            // 3) Digits — independent of `dim`. Their own opacity already
            //    reflects refreshing / stale / errored states via
            //    `resolved.opacity`.
            drawDigits(in: ctx,
                       x: digitsX,
                       slotWidth: digitSlot,
                       font: digitFont,
                       text: resolved.text,
                       baseColor: resolved.baseColor,
                       pulseTarget: resolved.pulseTarget,
                       baseOpacity: resolved.opacity,
                       percent: animation.percent)
            _ = rect
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: Percent resolution (digits text + color)

    /// `baseColor` is the color the digits sit at when no pulse is active.
    /// `pulseTarget`, when non-nil, is the palette accent the digits fade
    /// toward during a `highlight` or `settle` pulse — that is the only
    /// time color appears. Alert (≥100%) is the exception: it stays red
    /// steady-state so the over-quota signal does not hide between ticks.
    private struct ResolvedPercent {
        let text: String
        let baseColor: NSColor
        let pulseTarget: NSColor?
        let opacity: CGFloat
    }

    private static func resolvePercent(
        model: StatusBarIconModel,
        animation: IconAnimation,
        palette: Palette,
        labelColor: NSColor
    ) -> ResolvedPercent {
        // A placeholder (?, !, ~, ---) always sits at labelColor and does
        // not flash — nothing to predict, nothing to settle.
        func placeholder(_ text: String, opacity: CGFloat) -> ResolvedPercent {
            ResolvedPercent(text: text, baseColor: labelColor, pulseTarget: nil, opacity: opacity)
        }

        // A real percentage reads as labelColor at rest and crossfades to
        // the palette accent while a pulse is active. Alert short-circuits
        // that — we want to see the red even with no pulse in flight.
        func numeric(_ text: String, opacity: CGFloat) -> ResolvedPercent {
            if animation.percent.alert {
                return ResolvedPercent(
                    text: text,
                    baseColor: palette.percentAlert,
                    pulseTarget: nil,
                    opacity: opacity
                )
            }
            return ResolvedPercent(
                text: text,
                baseColor: labelColor,
                pulseTarget: palette.percent,
                opacity: opacity
            )
        }

        switch model.state {
        case .unconfigured:
            // Dim right half: the provider can't tell us anything.
            return placeholder(" ? ", opacity: 0.55)
        case .error:
            // Dim right half on errored usage, matching the stale treatment.
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

    // MARK: Arrow drawing

    /// Vertical offset of the up-arrow's center of mass from its bounding-box
    /// midpoint. The down-arrow offset is the negative of this. Used to
    /// optically align the two arrows on a common horizontal line even though
    /// the head+stem shape is not symmetric about its own midpoint.
    private static var arrowCenterOfMassYOffset: CGFloat {
        let headH = arrowHeight * arrowHeadFraction
        let stemH = arrowHeight - headH
        let stemW = arrowWidth * arrowStemFraction
        let aHead = 0.5 * arrowWidth * headH       // triangle area
        let aStem = stemW * stemH                  // rectangle area
        // Centroids, in the up-arrow's local frame (origin bottom-left).
        // Head triangle peaks at y=arrowHeight with base at y=arrowHeight-headH.
        // Its centroid sits one-third of its height above the base.
        let yHead = arrowHeight - (2.0 / 3.0) * headH
        let yStem = stemH / 2
        let comY  = (aHead * yHead + aStem * yStem) / (aHead + aStem)
        return comY - arrowHeight / 2
    }

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

    private static func drawArrow(
        in ctx: CGContext,
        x: CGFloat, y: CGFloat,
        intensity: CGFloat,
        dim: CGFloat,
        idle: NSColor,
        accent: NSColor,
        pointsUp: Bool
    ) {
        let path = arrowPath(pointsUp: pointsUp, width: arrowWidth, height: arrowHeight)

        ctx.saveGState()
        ctx.translateBy(x: x, y: y)

        // Crossfade the fill color from labelColor (rest) to the palette
        // accent (full animation). `idle` already carries 85% alpha, so the
        // rest-state glyph matches Wi-Fi, Battery, and other stock icons;
        // at full intensity we reach the accent's native alpha. `dim`
        // multiplies the resulting alpha so proxy-off visibly recedes.
        let color = blend(from: idle, to: accent, t: intensity)
        let finalAlpha = color.alphaComponent * dim
        let effectiveIntensity = intensity * dim

        // Soft glow halo while animating.
        if effectiveIntensity > 0.02 {
            ctx.saveGState()
            ctx.setShadow(
                offset: .zero,
                blur: 3.0 * effectiveIntensity,
                color: accent.withAlphaComponent(0.75 * effectiveIntensity).cgColor
            )
            ctx.setFillColor(color.withAlphaComponent(finalAlpha).cgColor)
            ctx.addPath(path)
            ctx.fillPath()
            ctx.restoreGState()
        } else {
            ctx.setFillColor(color.withAlphaComponent(finalAlpha).cgColor)
            ctx.addPath(path)
            ctx.fillPath()
        }

        ctx.restoreGState()
    }

    // MARK: Bar drawing

    private static func drawBar(
        in ctx: CGContext,
        x: CGFloat, y: CGFloat,
        carrying: CGFloat,
        dim: CGFloat,
        idle: NSColor,
        carryingColor: NSColor
    ) {
        let rect = CGRect(x: x, y: y, width: barWidth, height: barHeight)

        // Same story as the arrows: rest-state = labelColor, carrying-state =
        // palette accent, crossfade between them on `carrying`.
        let color = blend(from: idle, to: carryingColor, t: carrying)
        let finalAlpha = color.alphaComponent * dim
        let effectiveCarrying = carrying * dim

        if effectiveCarrying > 0.02 {
            ctx.saveGState()
            ctx.setShadow(
                offset: .zero,
                blur: 2.5 * effectiveCarrying,
                color: carryingColor.withAlphaComponent(0.6 * effectiveCarrying).cgColor
            )
            ctx.setFillColor(color.withAlphaComponent(finalAlpha).cgColor)
            let path = CGPath(roundedRect: rect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil)
            ctx.addPath(path)
            ctx.fillPath()
            ctx.restoreGState()
        } else {
            ctx.setFillColor(color.withAlphaComponent(finalAlpha).cgColor)
            let path = CGPath(roundedRect: rect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil)
            ctx.addPath(path)
            ctx.fillPath()
        }
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

    // MARK: Digits

    private static func drawDigits(
        in ctx: CGContext,
        x: CGFloat,
        slotWidth: CGFloat,
        font: NSFont,
        text: String,
        baseColor: NSColor,
        pulseTarget: NSColor?,
        baseOpacity: CGFloat,
        percent: IconAnimation.PercentState
    ) {
        // The settling animation briefly dips the opacity at mid-transition
        // and recovers — simulated here as a subtle additional fade.
        let settleDip = 0.5 * percent.settle
        let settledOpacity = max(0.15, baseOpacity - settleDip * baseOpacity)

        // Crossfade to the palette accent while a pulse is in flight. At
        // rest (no highlight, no settle) the digits stay at labelColor and
        // read like a stock menu extra — color only blooms on tick events.
        let pulse = max(percent.highlight, percent.settle)
        let color: NSColor
        if let target = pulseTarget {
            color = blend(from: baseColor, to: target, t: pulse)
        } else {
            color = baseColor
        }

        // Multiply opacity through so labelColor's built-in 85% alpha
        // survives instead of being silently replaced.
        let finalAlpha = color.alphaComponent * settledOpacity
        let finalColor = color.withAlphaComponent(finalAlpha)

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: finalColor,
            .paragraphStyle: paragraph,
        ]
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        let textSize = attrStr.size()
        let textY = (iconHeight - textSize.height) / 2 + 0.5   // optical nudge

        // Highlight pulse — glow only makes sense when there's a pulse target
        // to glow toward (i.e. the digits carry an animatable accent).
        if let target = pulseTarget, percent.highlight > 0.02 {
            ctx.saveGState()
            ctx.setShadow(
                offset: .zero,
                blur: 3.5 * percent.highlight,
                color: target.withAlphaComponent(0.85 * percent.highlight).cgColor
            )
            attrStr.draw(in: CGRect(x: x, y: textY, width: slotWidth, height: textSize.height))
            ctx.restoreGState()
        }

        attrStr.draw(in: CGRect(x: x, y: textY, width: slotWidth, height: textSize.height))
    }

    // MARK: Color blending

    private static func blend(from: NSColor, to: NSColor, t: CGFloat) -> NSColor {
        let tt = max(0, min(1, t))
        let f = from.usingColorSpace(.sRGB) ?? from
        let o = to.usingColorSpace(.sRGB) ?? to
        var fr: CGFloat = 0, fg: CGFloat = 0, fb: CGFloat = 0, fa: CGFloat = 0
        var tr: CGFloat = 0, tg: CGFloat = 0, tb: CGFloat = 0, ta: CGFloat = 0
        f.getRed(&fr, green: &fg, blue: &fb, alpha: &fa)
        o.getRed(&tr, green: &tg, blue: &tb, alpha: &ta)
        return NSColor(
            srgbRed: fr + (tr - fr) * tt,
            green:   fg + (tg - fg) * tt,
            blue:    fb + (tb - fb) * tt,
            alpha:   fa + (ta - fa) * tt
        )
    }
}
