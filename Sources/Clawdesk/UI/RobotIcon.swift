import AppKit
import CoreGraphics

/// The Clawdesk robot-head icon, drawn programmatically so the status item
/// and the Dock match the pet's own visual language: one rounded head, two
/// capsule eyes (the same stadium shape the bloub engine renders), one
/// antenna. No bitmap asset to keep in sync.
enum RobotIcon {
    /// Menu bar template image: pure black + alpha, ~17 pt tall. At status
    /// bar size a filled head turns into a blob, so this variant draws the
    /// head as an outline with solid eyes and an antenna — the parts that
    /// still read as a robot at 18 pt.
    static func menuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let lineWidth: CGFloat = 1.6

            // Antenna: stem plus a dot.
            let centerX = rect.midX
            let headTop = rect.midY + rect.height * 0.28
            context.setStrokeColor(NSColor.black.cgColor)
            context.setFillColor(NSColor.black.cgColor)
            context.setLineWidth(lineWidth)
            context.setLineCap(.round)
            context.move(to: CGPoint(x: centerX, y: headTop))
            context.addLine(to: CGPoint(x: centerX, y: headTop + 2.6))
            context.strokePath()
            context.fillEllipse(in: CGRect(
                x: centerX - 1.5,
                y: headTop + 2.2,
                width: 3,
                height: 3
            ))

            // Head outline: rounded square.
            let head = CGRect(
                x: rect.midX - 5.6,
                y: rect.midY - 5.2,
                width: 11.2,
                height: 10.4
            )
            context.addPath(CGPath(
                roundedRect: head,
                cornerWidth: 3.4,
                cornerHeight: 3.4,
                transform: nil
            ))
            context.strokePath()

            // Two solid capsule eyes.
            for side in [-1.0, 1.0] {
                let eyeCenterX = centerX + CGFloat(side) * 2.4
                let eyeCenterY = rect.midY + 0.4
                let capsule = BloubPaths.capsule(width: 2.2, height: 3.8)
                let transform = CGAffineTransform(translationX: eyeCenterX, y: eyeCenterY)
                context.addPath(capsule.transformed(transform))
                context.setFillColor(NSColor.black.cgColor)
                context.fillPath()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Clawdesk"
        return image
    }

    /// Dock / application icon: the pet's own palette on a rounded backdrop.
    static func applicationImage() -> NSImage {
        let size = NSSize(width: 512, height: 512)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let backdrop = CGRect(x: 56, y: 56, width: 400, height: 400)
            let backdropPath = CGPath(
                roundedRect: backdrop,
                cornerWidth: 92,
                cornerHeight: 92,
                transform: nil
            )
            context.addPath(backdropPath)
            context.setFillColor(NSColor(calibratedWhite: 0.96, alpha: 1).cgColor)
            context.fillPath()

            drawRobotHead(
                in: context,
                bounds: backdrop.insetBy(dx: 74, dy: 74),
                headColor: NSColor(calibratedRed: 0.07, green: 0.07, blue: 0.08, alpha: 1).cgColor,
                eyeColor: NSColor.white.cgColor,
                antennaColor: NSColor(calibratedRed: 0.98, green: 0.62, blue: 0.18, alpha: 1).cgColor
            )
            return true
        }
        image.accessibilityDescription = "Clawdesk"
        return image
    }

    /// One robot head, centred in `bounds`: antenna on top, rounded-square
    /// head, two capsule eyes — the bloub eye shape, so the icon reads as
    /// the pet itself in miniature.
    private static func drawRobotHead(
        in context: CGContext,
        bounds: CGRect,
        headColor: CGColor,
        eyeColor: CGColor,
        antennaColor: CGColor
    ) {
        let unit = min(bounds.width, bounds.height)
        let centerX = bounds.midX
        let headHeight = unit * 0.62
        let headWidth = unit * 0.78
        let headBottom = bounds.midY - headHeight / 2 + unit * 0.03
        let head = CGRect(
            x: centerX - headWidth / 2,
            y: headBottom,
            width: headWidth,
            height: headHeight
        )
        let headRadius = headHeight * 0.30

        // Antenna: stem plus a lit dot.
        let stemWidth = unit * 0.045
        let stemTop = headBottom + headHeight - headRadius * 0.4
        let stemHeight = unit * 0.14
        context.setFillColor(antennaColor)
        context.fill(CGRect(
            x: centerX - stemWidth / 2,
            y: stemTop,
            width: stemWidth,
            height: stemHeight
        ))
        let antennaDotRadius = unit * 0.062
        let antennaDot = CGRect(
            x: centerX - antennaDotRadius,
            y: stemTop + stemHeight - antennaDotRadius * 0.2,
            width: antennaDotRadius * 2,
            height: antennaDotRadius * 2
        )
        context.fillEllipse(in: antennaDot)

        // Head.
        context.addPath(CGPath(
            roundedRect: head,
            cornerWidth: headRadius,
            cornerHeight: headRadius,
            transform: nil
        ))
        context.setFillColor(headColor)
        context.fillPath()

        // Two capsule eyes, the bloub stadium shape.
        let eyeWidth = unit * 0.105
        let eyeHeight = unit * 0.185
        let eyeOffset = unit * 0.185
        for side in [-1.0, 1.0] {
            let eyeCenterX = centerX + CGFloat(side) * eyeOffset
            let eyeCenterY = headBottom + headHeight * 0.56
            let capsule = BloubPaths.capsule(width: eyeWidth, height: eyeHeight)
            let transform = CGAffineTransform(translationX: eyeCenterX, y: eyeCenterY)
            context.addPath(capsule.transformed(transform))
            context.setFillColor(eyeColor)
            context.fillPath()
        }
    }
}

private extension CGPath {
    func transformed(_ transform: CGAffineTransform) -> CGPath {
        var mutable = transform
        return copy(using: &mutable) ?? self
    }
}
