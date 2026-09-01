import AppKit

/// Small, license-safe native agent marks for the HUD and quota ring. The
/// upstream uses downloaded agent artwork; the native port keeps identity
/// recognizable without bundling third-party logos or making network requests
/// from a floating panel.
enum AgentIconRenderer {
    static func draw(
        _ descriptor: AgentIconDescriptor,
        in rect: CGRect,
        context: CGContext
    ) {
        let side = min(rect.width, rect.height)
        guard side > 0 else { return }
        let iconRect = CGRect(
            x: rect.midX - side / 2,
            y: rect.midY - side / 2,
            width: side,
            height: side
        )
        let radius = side * 0.22
        let path = CGPath(
            roundedRect: iconRect,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )

        context.saveGState()
        context.addPath(path)
        context.setFillColor(background(for: descriptor.kind).cgColor)
        context.fillPath()
        context.restoreGState()

        if descriptor.kind == .codex {
            drawCodexMark(in: iconRect, context: context)
        } else {
            drawGlyph(descriptor.glyph, in: iconRect, context: context)
        }
    }

    private static func drawGlyph(_ glyph: String, in rect: CGRect, context: CGContext) {
        let fontSize = glyph.count > 1 ? rect.height * 0.42 : rect.height * 0.60
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: foreground(for: glyph)
        ]
        let measured = (glyph as NSString).size(withAttributes: attributes)
        (glyph as NSString).draw(
            at: NSPoint(
                x: rect.midX - measured.width / 2,
                y: rect.midY - measured.height / 2 + rect.height * 0.03
            ),
            withAttributes: attributes
        )
        _ = context
    }

    private static func drawCodexMark(in rect: CGRect, context: CGContext) {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = rect.width * 0.22
        context.saveGState()
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(max(1.1, rect.width * 0.075))
        context.setLineCap(.round)
        for index in 0..<3 {
            let start = CGFloat(index) * 2 * .pi / 3 - .pi / 3
            let path = CGMutablePath()
            path.addArc(
                center: center,
                radius: radius,
                startAngle: start,
                endAngle: start + .pi * 1.35,
                clockwise: false
            )
            context.addPath(path)
        }
        context.strokePath()
        context.restoreGState()
    }

    private static func background(for kind: AgentIconKind) -> NSColor {
        switch kind {
        case .claude:
            return NSColor(calibratedWhite: 0.96, alpha: 1)
        case .codex:
            return NSColor(calibratedRed: 0.12, green: 0.17, blue: 0.25, alpha: 1)
        case .deepSeek:
            return NSColor(calibratedRed: 0.12, green: 0.27, blue: 0.55, alpha: 1)
        case .copilot:
            return NSColor(calibratedRed: 0.18, green: 0.21, blue: 0.34, alpha: 1)
        case .gemini, .antigravity:
            return NSColor(calibratedRed: 0.20, green: 0.28, blue: 0.52, alpha: 1)
        case .cursor:
            return NSColor(calibratedWhite: 0.18, alpha: 1)
        case .kimi:
            return NSColor(calibratedRed: 0.12, green: 0.39, blue: 0.78, alpha: 1)
        case .qwen:
            return NSColor(calibratedRed: 0.30, green: 0.18, blue: 0.60, alpha: 1)
        case .zcode, .openCode:
            return NSColor(calibratedRed: 0.24, green: 0.25, blue: 0.32, alpha: 1)
        case .pi, .generic:
            return NSColor(calibratedRed: 0.28, green: 0.29, blue: 0.34, alpha: 1)
        }
    }

    private static func foreground(for glyph: String) -> NSColor {
        glyph == "✳" ? NSColor(calibratedRed: 0.90, green: 0.38, blue: 0.16, alpha: 1) : .white
    }
}
