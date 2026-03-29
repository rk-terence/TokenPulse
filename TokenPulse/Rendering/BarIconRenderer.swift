import AppKit

enum BarIconRenderer {
    // Layout constants
    private static let shellWidth: CGFloat = 26
    private static let shellHeight: CGFloat = 12
    private static let shellLineWidth: CGFloat = 1.0
    private static let labelFontSize: CGFloat = 9
    private static let percentFontSize: CGFloat = 7.5
    private static let labelBarGap: CGFloat = 3

    /// Render: [C][==65%==] — label to the left, remaining % inside the bar.
    @MainActor
    static func renderIcon(_ model: StatusBarIconModel) -> NSImage {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

        // Measure label width
        let labelStr = attributedLabel(model.label, isDark: isDark)
        let labelWidth = ceil(labelStr.size().width)

        let totalWidth = labelWidth + labelBarGap + shellWidth
        let height: CGFloat = 22

        let image = NSImage(size: NSSize(width: totalWidth, height: height), flipped: false) { rect in
            drawIcon(model, isDark: isDark, labelWidth: labelWidth, in: rect)
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: - Drawing

    private static func drawIcon(_ model: StatusBarIconModel, isDark: Bool, labelWidth: CGFloat, in rect: NSRect) {
        let shellColor = shellStrokeColor(for: model.state, isDark: isDark)
        let shellY = (rect.height - shellHeight) / 2

        // Draw provider label to the left
        let labelStr = attributedLabel(model.label, isDark: isDark)
        let labelSize = labelStr.size()
        let labelPoint = NSPoint(
            x: 0,
            y: rect.midY - labelSize.height / 2
        )
        labelStr.draw(at: labelPoint)

        // Bar shell starts after label + gap
        let barX = labelWidth + labelBarGap
        let shellRect = NSRect(x: barX, y: shellY, width: shellWidth, height: shellHeight)
        let shellPath = NSBezierPath(roundedRect: shellRect, xRadius: 2.5, yRadius: 2.5)
        shellColor.withAlphaComponent(0.7).setStroke()
        shellPath.lineWidth = shellLineWidth
        shellPath.stroke()

        if let utilization = model.utilization {
            // Fill bar — inverted: full when usage=0, empty when usage=100
            let remaining = 100.0 - min(max(utilization, 0), 100)
            let inset: CGFloat = shellLineWidth + 0.5
            let fillableWidth = shellWidth - inset * 2
            let fillWidth = fillableWidth * CGFloat(remaining / 100.0)

            if fillWidth > 0 {
                let fillRect = NSRect(
                    x: shellRect.origin.x + inset,
                    y: shellRect.origin.y + inset,
                    width: fillWidth,
                    height: shellRect.height - inset * 2
                )
                let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: 1, yRadius: 1)
                fillColor(for: utilization, state: model.state).setFill()
                fillPath.fill()
            }
        }

        drawCenterText(centerText(for: model), in: shellRect, state: model.state, isDark: isDark)
    }

    private static func attributedLabel(_ text: String, isDark: Bool) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: labelFontSize, weight: .semibold)
        let color: NSColor = isDark ? .white : .black
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color.withAlphaComponent(0.9),
        ]
        return NSAttributedString(string: String(text.prefix(1)), attributes: attrs)
    }

    private static func drawCenterText(_ text: String, in shellRect: NSRect, state: StatusBarIconState, isDark: Bool) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: percentFontSize, weight: .bold)

        let shadow = NSShadow()
        shadow.shadowColor = (isDark ? NSColor.black : NSColor.white).withAlphaComponent(0.9)
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.shadowBlurRadius = 1.5

        let color = centerTextColor(for: state, isDark: isDark)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color.withAlphaComponent(0.95),
            .shadow: shadow,
        ]
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        let size = attrStr.size()
        let drawPoint = NSPoint(
            x: shellRect.midX - size.width / 2,
            y: shellRect.midY - size.height / 2
        )
        attrStr.draw(at: drawPoint)
    }

    // MARK: - State-aware colors

    private static func fillColor(for utilization: Double, state: StatusBarIconState) -> NSColor {
        let baseColor: NSColor
        if utilization <= 50 {
            baseColor = NSColor.systemGreen
        } else if utilization <= 80 {
            baseColor = NSColor.systemOrange
        } else {
            baseColor = NSColor.systemRed
        }

        switch state {
        case .ready:
            return baseColor
        case .refreshing:
            return baseColor.withAlphaComponent(0.55)
        case .stale:
            return NSColor.systemGray
        case .error, .unconfigured:
            return .clear
        }
    }

    private static func shellStrokeColor(for state: StatusBarIconState, isDark: Bool) -> NSColor {
        let base = isDark ? NSColor.white : NSColor.black
        switch state {
        case .ready, .refreshing:
            return base
        case .stale, .unconfigured:
            return NSColor.secondaryLabelColor
        case .error:
            return NSColor.systemRed
        }
    }

    private static func centerTextColor(for state: StatusBarIconState, isDark: Bool) -> NSColor {
        let base = isDark ? NSColor.white : NSColor.black
        switch state {
        case .ready, .refreshing:
            return base
        case .stale, .unconfigured:
            return NSColor.secondaryLabelColor
        case .error:
            return NSColor.systemRed
        }
    }

    private static func centerText(for model: StatusBarIconModel) -> String {
        switch model.state {
        case .unconfigured:
            return "?"
        case .error:
            return "!"
        case .ready, .stale:
            if let utilization = model.utilization {
                return "\(Int(round(100.0 - utilization)))"
            }
            return "?"
        case .refreshing:
            if let utilization = model.utilization {
                return "\(Int(round(100.0 - utilization)))"
            }
            return "~"
        }
    }
}
