import AppKit
import CoreGraphics

/// The Clawdesk pet icon. The menu-bar face stays a lightweight template image;
/// the Dock uses the bundled multi-resolution icon made from the pet's own
/// silhouette, with a CoreGraphics fallback for package/test runs.
enum RobotIcon {
    /// Menu bar template image matching the pet's neutral face: a filled
    /// circular body with two capsule-shaped eye holes. The transparent eyes
    /// reveal the menu bar behind the template image in either system theme.
    static func menuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let diameter = min(rect.width, rect.height) * 0.76
            let face = CGRect(
                x: rect.midX - diameter / 2,
                y: rect.midY - diameter / 2,
                width: diameter,
                height: diameter
            )

            // The status item is a template image, so the body is the only
            // painted colour. Clearing the eyes makes them read as the
            // paper-coloured eyes of the pet without hard-coding a light or
            // dark menu-bar colour.
            context.setFillColor(NSColor.black.cgColor)
            context.fillEllipse(in: face)

            let eyeWidth = diameter * 0.13
            let eyeHeight = diameter * 0.31
            let eyeOffset = diameter * 0.19
            context.saveGState()
            context.setBlendMode(.clear)
            for side in [-1.0, 1.0] {
                let eyeCenterX = rect.midX + CGFloat(side) * eyeOffset
                let eyeCenterY = rect.midY
                let capsule = BloubPaths.capsule(width: eyeWidth, height: eyeHeight)
                let transform = CGAffineTransform(translationX: eyeCenterX, y: eyeCenterY)
                context.addPath(capsule.transformed(transform))
                context.fillPath()
            }
            context.restoreGState()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Clawdesk"
        return image
    }

    /// Dock / application icon: the pet's own palette and silhouette.
    static func applicationImage() -> NSImage {
        if let iconURL = Bundle.main.url(forResource: "Clawdesk", withExtension: "icns"),
           let bundledIcon = NSImage(contentsOf: iconURL) {
            bundledIcon.accessibilityDescription = "Clawdesk"
            return bundledIcon
        }

        return fallbackApplicationImage()
    }

    /// Package tests and development launches do not have the built app's
    /// Contents/Resources directory. Keep a deterministic fallback that has
    /// the same pet face instead of resurrecting the old antenna icon.
    private static func fallbackApplicationImage() -> NSImage {
        let size = NSSize(width: 512, height: 512)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            drawPetFace(
                in: context,
                bounds: rect,
                bodyColor: NSColor(calibratedRed: 0.095, green: 0.095, blue: 0.12, alpha: 1).cgColor,
                eyeColor: NSColor.white.cgColor
            )
            return true
        }
        image.accessibilityDescription = "Clawdesk"
        return image
    }

    /// One near-circular pet face centred in `bounds`, with the same capsule
    /// eyes used by the bloub renderer. The eyes sit high and to the right,
    /// matching the reference idle pose used for the app icon.
    private static func drawPetFace(
        in context: CGContext,
        bounds: CGRect,
        bodyColor: CGColor,
        eyeColor: CGColor
    ) {
        let unit = min(bounds.width, bounds.height)
        let faceDiameter = unit * 0.68
        let face = CGRect(
            x: bounds.midX - faceDiameter / 2,
            y: bounds.midY - faceDiameter / 2,
            width: faceDiameter,
            height: faceDiameter
        )
        context.setFillColor(bodyColor)
        context.fillEllipse(in: face)

        let eyeWidth = faceDiameter * 0.13
        let eyeHeight = faceDiameter * 0.29
        let eyeCenters: [(x: CGFloat, y: CGFloat)] = [
            (bounds.midX + faceDiameter * 0.11, bounds.midY + faceDiameter * 0.16),
            (bounds.midX + faceDiameter * 0.29, bounds.midY + faceDiameter * 0.22)
        ]
        for eyeCenter in eyeCenters {
            let capsule = BloubPaths.capsule(width: eyeWidth, height: eyeHeight)
            let transform = CGAffineTransform(translationX: eyeCenter.x, y: eyeCenter.y)
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
