import AppKit
import Foundation
import ImageIO

@MainActor
public final class PetCanvasView: NSView {
    public var petState: PetState = .idle {
        didSet {
            if oldValue != petState { needsDisplay = true }
        }
    }

    public var theme: ThemeDefinition = ThemeCatalog.theme(id: "pinch") {
        didSet {
            assetCache.removeAll()
            assetCacheOrder.removeAll()
            assetCacheBytes = 0
            assetClock = 0
            needsDisplay = true
        }
    }

    public var miniMode = false {
        didSet { needsDisplay = true }
    }

    /// Live subagent count selects the visual tier for the juggling state.
    /// Zero is used for the two-session working tier and intentionally falls
    /// back to the single-subagent visual.
    public var subagentCount = 0 {
        didSet { needsDisplay = true }
    }

    public var idleVisualFile: String? {
        didSet {
            assetClock = 0
            needsDisplay = true
        }
    }

    public var pointerOffset = CGPoint.zero {
        didSet { needsDisplay = true }
    }

    public var onDragBegan: (() -> Void)?
    public var onDrag: ((CGSize) -> Void)?
    public var onDragEnded: (() -> Void)?
    public var onDoubleTap: (() -> Void)?
    public var onFlail: (() -> Void)?
    public var onContextMenu: ((NSPoint) -> NSMenu?)?
    public var onHoverChanged: ((Bool) -> Void)?

    private var phase: CGFloat = 0
    private var assetClock: TimeInterval = 0
    private static let maxAssetDimension = 512
    private static let maxAnimationBytes = 64 * 1024 * 1024
    private static let maxAssetCacheBytes = 96 * 1024 * 1024
    private struct AssetFrames {
        let frames: [CGImage]
        let durations: [TimeInterval]
        let bytes: Int
    }
    private var assetCache: [String: AssetFrames] = [:]
    private var assetCacheOrder: [String] = []
    private var assetCacheBytes = 0
    private var mouseDownPoint: NSPoint?
    private var lastDragPoint: NSPoint?
    private var clickTimes: [Date] = []
    private var trackingArea: NSTrackingArea?

    public override var acceptsFirstResponder: Bool { true }

    public override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    public override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    public override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        let center = NSPoint(x: bounds.midX, y: bounds.midY + bounds.height * 0.04)
        let radiusX = max(1, bounds.width * (miniMode ? 0.24 : 0.38))
        let radiusY = max(1, bounds.height * (miniMode ? 0.30 : 0.40))
        let x = (point.x - center.x) / radiusX
        let y = (point.y - center.y) / radiusY
        return x * x + y * y <= 1.08 ? self : nil
    }

    public func advanceFrame() {
        phase += 0.075
        if phase > 1_000 { phase = 0 }
        assetClock += 0.075
        if assetClock > 86_400 { assetClock = 0 }
        needsDisplay = true
    }

    public func setPointerLocation(_ point: NSPoint) {
        guard theme.supportsEyeTracking, petState == .idle || petState == .miniIdle else {
            if pointerOffset != .zero { pointerOffset = .zero }
            return
        }
        let windowPoint = window?.convertFromScreen(NSRect(origin: point, size: .zero)).origin ?? point
        let local = convert(windowPoint, from: nil)
        let dx = (local.x - bounds.midX) / max(1, bounds.width * 0.20)
        let dy = (local.y - bounds.midY) / max(1, bounds.height * 0.25)
        pointerOffset = CGPoint(x: max(-5, min(5, dx * 5)), y: max(-4, min(4, dy * 4)))
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.setShouldAntialias(true)
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)

        let scale = min(bounds.width / 220, bounds.height / 220) * (miniMode ? 0.86 : 1.0)
        let bob: CGFloat
        switch petState {
        case .sleeping: bob = 0
        case .attention, .miniHappy: bob = sin(phase * 6) * 5
        case .error, .reactFlail: bob = sin(phase * 12) * 3
        default: bob = sin(phase * 2) * 1.7
        }
        context.translateBy(x: bounds.midX, y: bounds.midY + bob)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -110, y: -110)

        if drawCustomAsset(in: context) {
            context.restoreGState()
            return
        }

        drawShadow(in: context)
        drawBloub(in: context)
        drawStateOverlay(in: context)
        context.restoreGState()
    }

    private func drawCustomAsset(in context: CGContext) -> Bool {
        let idleFile = petState == .idle ? idleVisualFile : nil
        guard let url = theme.assetURL(for: petState, idleVisualFile: idleFile),
              let animation = loadAsset(at: url),
              !animation.frames.isEmpty else { return false }
        let frame = currentFrame(in: animation)
        let width = CGFloat(frame.width)
        let height = CGFloat(frame.height)
        guard width > 0, height > 0 else { return false }
        let ratio = min(190.0 / width, 190.0 / height)
        let target = CGRect(
            x: 110 - width * ratio / 2,
            y: 110 - height * ratio / 2,
            width: width * ratio,
            height: height * ratio
        )
        context.interpolationQuality = .none
        context.draw(frame, in: target)
        return true
    }

    private func loadAsset(at url: URL) -> AssetFrames? {
        if let cached = assetCache[url.path] { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = min(CGImageSourceGetCount(source), 180)
        guard count > 0 else { return nil }
        var frames: [CGImage] = []
        var durations: [TimeInterval] = []
        var bytes = 0
        for index in 0..<count {
            // Downsample every raster frame to a bounded canvas instead of
            // caching full-resolution images; a pet animation only ever draws
            // inside a 220x220 logical area.
            guard let image = Self.boundedFrame(source: source, index: index) else { continue }
            frames.append(image)
            durations.append(Self.frameDuration(source: source, index: index))
            bytes += image.width * image.height * 4
        }
        if frames.isEmpty {
            // ImageIO intentionally has no animated SVG timeline. For a
            // vector theme state, rasterize one bounded frame through
            // AppKit; the render loop still draws only the cached CGImage.
            return loadStaticAppKitAsset(at: url)
        }
        if bytes > Self.maxAnimationBytes {
            // Keep the total memory of any single animation bounded. Falling
            // back to the first frame is a deliberate low-memory policy for
            // oversized theme packs rather than caching hundreds of MB.
            frames = [frames[0]]
            durations = [durations[0]]
            bytes = frames[0].width * frames[0].height * 4
        }
        let animation = AssetFrames(frames: frames, durations: durations, bytes: bytes)
        cache(animation, for: url.path)
        return animation
    }

    private static func boundedFrame(source: CGImageSource, index: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxAssetDimension
        ]
        if let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) {
            return thumbnail
        }
        return CGImageSourceCreateImageAtIndex(source, index, nil)
    }

    private func cache(_ animation: AssetFrames, for key: String) {
        assetCache[key] = animation
        if let existing = assetCacheOrder.firstIndex(of: key) {
            assetCacheOrder.remove(at: existing)
        }
        assetCacheOrder.append(key)
        assetCacheBytes += animation.bytes
        while assetCacheBytes > Self.maxAssetCacheBytes, let oldest = assetCacheOrder.first {
            assetCacheOrder.removeFirst()
            if let removed = assetCache.removeValue(forKey: oldest) {
                assetCacheBytes -= removed.bytes
            }
        }
    }

    private func loadStaticAppKitAsset(at url: URL) -> AssetFrames? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        var proposedRect = NSRect(x: 0, y: 0, width: 220, height: 220)
        guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            return nil
        }
        let animation = AssetFrames(frames: [cgImage], durations: [0.08], bytes: cgImage.width * cgImage.height * 4)
        cache(animation, for: url.path)
        return animation
    }

    private func currentFrame(in animation: AssetFrames) -> CGImage {
        guard animation.frames.count > 1 else { return animation.frames[0] }
        let total = animation.durations.reduce(0, +)
        guard total > 0 else { return animation.frames[Int(assetClock * 12) % animation.frames.count] }
        var remaining = assetClock.truncatingRemainder(dividingBy: total)
        for (index, duration) in animation.durations.enumerated() {
            if remaining < duration { return animation.frames[index] }
            remaining -= duration
        }
        return animation.frames.last ?? animation.frames[0]
    }

    private static func frameDuration(source: CGImageSource, index: Int) -> TimeInterval {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else { return 0.08 }
        let dictionaries = [
            properties[kCGImagePropertyGIFDictionary] as? [CFString: Any],
            properties[kCGImagePropertyPNGDictionary] as? [CFString: Any]
        ].compactMap { $0 }
        for dictionary in dictionaries {
            let value = dictionary[kCGImagePropertyGIFUnclampedDelayTime] ?? dictionary[kCGImagePropertyGIFDelayTime]
            if let seconds = value as? NSNumber, seconds.doubleValue > 0 {
                return min(2, max(0.04, seconds.doubleValue))
            }
        }
        return 0.08
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let now = Date.now
        clickTimes.append(now)
        clickTimes.removeAll { now.timeIntervalSince($0) > 0.9 }
        if clickTimes.count >= 4 {
            clickTimes.removeAll()
            onFlail?()
        } else if event.clickCount == 2 {
            clickTimes.removeAll()
            onDoubleTap?()
        }
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        lastDragPoint = mouseDownPoint
        onDragBegan?()
    }

    public override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let lastDragPoint else { return }
        let delta = CGSize(width: point.x - lastDragPoint.x, height: point.y - lastDragPoint.y)
        self.lastDragPoint = point
        onDrag?(delta)
    }

    public override func mouseUp(with event: NSEvent) {
        mouseDownPoint = nil
        lastDragPoint = nil
        onDragEnded?()
    }

    public override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let menu = onContextMenu?(point) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }

    private func drawShadow(in context: CGContext) {
        fillEllipse(context, rect: CGRect(x: 40, y: 174, width: 140, height: 18), color: NSColor.black.withAlphaComponent(0.18).cgColor)
    }

    private func drawCrab(in context: CGContext) {
        let p = theme.palette
        let body = cgColor(p.body)
        let accent = cgColor(p.accent)
        let shadow = cgColor(p.shadow)
        let highlight = cgColor(p.highlight)
        let outline = shadow
        let yShift: CGFloat = petState == .sleeping ? -14 : 0
        context.saveGState()
        context.translateBy(x: 0, y: yShift)

        // Legs behind the shell.
        drawCrabLegs(context, x: 48, body: body, outline: outline)
        drawCrabLegs(context, x: 172, body: body, outline: outline)

        // Rounded shell with a cartoon outline and soft belly.
        fillEllipseStroke(context, CGRect(x: 52, y: 56, width: 116, height: 102), fill: body, outline: outline, width: 5)
        fillEllipse(context, rect: CGRect(x: 72, y: 78, width: 76, height: 70), color: accent.copy(alpha: 0.35)!)
        fillRoundedRect(context, CGRect(x: 78, y: 86, width: 38, height: 7), radius: 3.5, highlight.copy(alpha: 0.75)!)

        // Antennae with ball tips.
        drawAntenna(context, baseX: 90, body: body, outline: outline, direction: -1)
        drawAntenna(context, baseX: 130, body: body, outline: outline, direction: 1)

        // Pincer claws.
        drawCrabClaw(context, side: -1, body: body, accent: accent, highlight: highlight, outline: outline)
        drawCrabClaw(context, side: 1, body: body, accent: accent, highlight: highlight, outline: outline)

        drawCuteFace(
            in: context,
            leftEye: CGRect(x: 76, y: 96, width: 28, height: 36),
            rightEye: CGRect(x: 116, y: 96, width: 28, height: 36),
            mouthY: 140,
            outline: outline,
            pupil: shadow,
            highlight: highlight,
            accent: accent
        )
        context.restoreGState()
    }

    private func drawCat(in context: CGContext) {
        let p = theme.palette
        let body = cgColor(p.body)
        let accent = cgColor(p.accent)
        let shadow = cgColor(p.shadow)
        let highlight = cgColor(p.highlight)
        let outline = shadow
        let shift: CGFloat = petState == .sleeping ? -12 : 0
        context.saveGState()
        context.translateBy(x: 0, y: shift)

        // Blunt outlined ears with accent inner ears.
        drawBluntEar(context, base: CGPoint(x: 72, y: 150), tip: CGPoint(x: 66, y: 194), body: body, outline: outline)
        drawBluntEar(context, base: CGPoint(x: 148, y: 150), tip: CGPoint(x: 154, y: 194), body: body, outline: outline)
        fillRoundedRect(context, CGRect(x: 84, y: 156, width: 22, height: 22), radius: 11, accent)
        fillRoundedRect(context, CGRect(x: 114, y: 156, width: 22, height: 22), radius: 11, accent)

        // Compact body with two little outlined paws.
        fillEllipseStroke(context, CGRect(x: 62, y: 30, width: 96, height: 52), fill: body, outline: outline, width: 4)
        fillEllipseStroke(context, CGRect(x: 74, y: 14, width: 24, height: 26), fill: body, outline: outline, width: 4)
        fillEllipseStroke(context, CGRect(x: 122, y: 14, width: 24, height: 26), fill: body, outline: outline, width: 4)

        // Big round outlined head with a calico patch.
        fillEllipseStroke(context, CGRect(x: 46, y: 62, width: 128, height: 120), fill: body, outline: outline, width: 5)
        fillEllipse(context, rect: CGRect(x: 64, y: 68, width: 48, height: 44), color: accent)
        fillRoundedRect(context, CGRect(x: 96, y: 94, width: 40, height: 7), radius: 3.5, highlight.copy(alpha: 0.75)!)

        drawWhiskers(context, leftEye: CGRect(x: 72, y: 100, width: 28, height: 36), rightEye: CGRect(x: 120, y: 100, width: 28, height: 36), mouthY: 148, outline: outline)

        drawCuteFace(
            in: context,
            leftEye: CGRect(x: 74, y: 100, width: 28, height: 36),
            rightEye: CGRect(x: 118, y: 100, width: 28, height: 36),
            mouthY: 148,
            outline: outline,
            pupil: shadow,
            highlight: highlight,
            accent: accent
        )
        context.restoreGState()
    }

    private func drawCloudling(in context: CGContext) {
        let p = theme.palette
        let body = cgColor(p.body)
        let accent = cgColor(p.accent)
        let shadow = cgColor(p.shadow)
        let highlight = cgColor(p.highlight)
        let outline = shadow
        let shift: CGFloat = petState == .sleeping ? -10 : 0
        context.saveGState()
        context.translateBy(x: 0, y: shift)

        // Puffy cloud body as one outlined silhouette (lobes share one stroke).
        fillEllipsesStroke(
            context,
            [
                CGRect(x: 46, y: 76, width: 66, height: 66),
                CGRect(x: 108, y: 60, width: 74, height: 82),
                CGRect(x: 58, y: 54, width: 100, height: 100),
                CGRect(x: 62, y: 104, width: 96, height: 56)
            ],
            fill: body,
            outline: outline,
            width: 5
        )
        fillEllipse(context, rect: CGRect(x: 70, y: 74, width: 34, height: 20), color: accent.copy(alpha: 0.5)!)
        fillEllipse(context, rect: CGRect(x: 110, y: 68, width: 40, height: 20), color: accent.copy(alpha: 0.5)!)

        // Two little outlined cloud feet.
        fillEllipseStroke(context, CGRect(x: 78, y: 40, width: 26, height: 22), fill: body, outline: outline, width: 4)
        fillEllipseStroke(context, CGRect(x: 118, y: 40, width: 26, height: 22), fill: body, outline: outline, width: 4)

        drawCuteFace(
            in: context,
            leftEye: CGRect(x: 80, y: 96, width: 26, height: 34),
            rightEye: CGRect(x: 116, y: 96, width: 26, height: 34),
            mouthY: 138,
            outline: outline,
            pupil: shadow,
            highlight: highlight,
            accent: accent
        )
        context.restoreGState()
    }

    private func fillRoundedRect(_ context: CGContext, _ rect: CGRect, radius: CGFloat, _ color: CGColor) {
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        context.addPath(path)
        context.setFillColor(color)
        context.fillPath()
    }

    private func fillEllipseStroke(_ context: CGContext, _ rect: CGRect, fill: CGColor, outline: CGColor, width: CGFloat) {
        let path = CGPath(ellipseIn: rect, transform: nil)
        context.addPath(path)
        context.setFillColor(fill)
        context.fillPath()
        context.addPath(path)
        context.setStrokeColor(outline)
        context.setLineWidth(width)
        context.setLineJoin(.round)
        context.strokePath()
    }

    private func fillRoundedRectStroke(_ context: CGContext, _ rect: CGRect, radius: CGFloat, fill: CGColor, outline: CGColor, width: CGFloat) {
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        context.addPath(path)
        context.setFillColor(fill)
        context.fillPath()
        context.addPath(path)
        context.setStrokeColor(outline)
        context.setLineWidth(width)
        context.setLineJoin(.round)
        context.strokePath()
    }

    private func fillEllipsesStroke(_ context: CGContext, _ rects: [CGRect], fill: CGColor, outline: CGColor, width: CGFloat) {
        let path = CGMutablePath()
        for rect in rects { path.addEllipse(in: rect) }
        context.addPath(path)
        context.setFillColor(fill)
        context.fillPath()
        context.addPath(path)
        context.setStrokeColor(outline)
        context.setLineWidth(width)
        context.setLineJoin(.round)
        context.strokePath()
    }

    /// Big white cartoon eyes with dark pupils that track the pointer,
    /// catchlights, blush cheeks, and a tiny mouth. Eyes become rounded
    /// closed lines when asleep.
    private func drawCuteFace(
        in context: CGContext,
        leftEye: CGRect,
        rightEye: CGRect,
        mouthY: CGFloat,
        outline: CGColor,
        pupil: CGColor,
        highlight: CGColor,
        accent: CGColor
    ) {
        let offset = CGPoint(x: pointerOffset.x, y: pointerOffset.y)
        for rect in [leftEye, rightEye] {
            if petState == .sleeping || petState == .dozing {
                fillRoundedRect(context, CGRect(x: rect.minX, y: rect.midY - 3, width: rect.width, height: 7), radius: 3.5, outline)
                continue
            }
            fillEllipseStroke(context, rect, fill: NSColor.white.cgColor, outline: outline, width: 4)
            let pupilWidth = rect.width * 0.34
            let pupilHeight = rect.height * 0.52
            let pupilRect = CGRect(
                x: rect.midX - pupilWidth / 2 + offset.x * 0.4,
                y: rect.midY - pupilHeight / 2 + offset.y * 0.4,
                width: pupilWidth,
                height: pupilHeight
            )
            fillEllipse(context, rect: pupilRect, color: pupil)
            let glow = pupilWidth * 0.34
            fillEllipse(context, rect: CGRect(x: pupilRect.minX + pupilWidth * 0.16, y: pupilRect.maxY - pupilHeight * 0.52, width: glow, height: glow), color: highlight)
        }
        fillEllipse(context, rect: CGRect(x: leftEye.minX - 14, y: leftEye.minY - 4, width: 14, height: 9), color: accent.copy(alpha: 0.8)!)
        fillEllipse(context, rect: CGRect(x: rightEye.maxX, y: rightEye.minY - 4, width: 14, height: 9), color: accent.copy(alpha: 0.8)!)
        fillRoundedRect(context, CGRect(x: 107, y: mouthY, width: 6, height: 6), radius: 3, outline)
    }

    private func drawAntenna(_ context: CGContext, baseX: CGFloat, body: CGColor, outline: CGColor, direction: CGFloat) {
        let tipX = baseX + direction * 10
        let tipY: CGFloat = 194
        let stalk = CGMutablePath()
        stalk.move(to: CGPoint(x: baseX, y: 158))
        stalk.addLine(to: CGPoint(x: tipX, y: tipY - 10))
        context.addPath(stalk)
        context.setStrokeColor(outline)
        context.setLineWidth(7)
        context.setLineCap(.round)
        context.strokePath()
        fillEllipseStroke(context, CGRect(x: tipX - 8, y: tipY - 8, width: 16, height: 16), fill: body, outline: outline, width: 4)
    }

    private func drawWhiskers(_ context: CGContext, leftEye: CGRect, rightEye: CGRect, mouthY: CGFloat, outline: CGColor) {
        let y = mouthY + 4
        context.setStrokeColor(outline)
        context.setLineWidth(3)
        context.setLineCap(.round)
        for index in 0..<3 {
            let yOffset = CGFloat(index - 1) * 8
            let left = CGMutablePath()
            left.move(to: CGPoint(x: leftEye.minX - 4, y: y + yOffset))
            left.addLine(to: CGPoint(x: leftEye.minX - 30, y: y + yOffset + 4))
            context.addPath(left)
            context.strokePath()
            let right = CGMutablePath()
            right.move(to: CGPoint(x: rightEye.maxX + 4, y: y + yOffset))
            right.addLine(to: CGPoint(x: rightEye.maxX + 30, y: y + yOffset + 4))
            context.addPath(right)
            context.strokePath()
        }
    }

    private func drawCrabLegs(_ context: CGContext, x: CGFloat, body: CGColor, outline: CGColor) {
        let direction: CGFloat = x < 110 ? -1 : 1
        for (dy, length) in [(24.0, 28.0), (46.0, 24.0), (66.0, 26.0)] as [(CGFloat, CGFloat)] {
            let y = 64 + dy
            let start = x + direction * length * 0.15
            fillRoundedRectStroke(context, CGRect(x: min(start, start + direction * length), y: y, width: length, height: 15), radius: 7.5, fill: body, outline: outline, width: 4)
        }
    }

    private func drawCrabClaw(_ context: CGContext, side: CGFloat, body: CGColor, accent: CGColor, highlight: CGColor, outline: CGColor) {
        let centerY: CGFloat = 112
        let anchorX: CGFloat = side < 0 ? 54 : 166
        fillRoundedRectStroke(context, CGRect(x: side < 0 ? anchorX - 22 : anchorX, y: centerY, width: 22, height: 18), radius: 9, fill: body, outline: outline, width: 4)
        let clawX = side < 0 ? anchorX - 32 : anchorX + 32
        fillEllipseStroke(context, CGRect(x: clawX - 16, y: centerY + 8, width: 32, height: 30), fill: accent, outline: outline, width: 4)
        fillEllipseStroke(context, CGRect(x: clawX - 12, y: centerY - 6, width: 24, height: 22), fill: accent, outline: outline, width: 4)
        fillEllipse(context, rect: CGRect(x: clawX - 8, y: centerY + 24, width: 10, height: 8), color: highlight.copy(alpha: 0.85)!)
    }

    private func drawBluntEar(_ context: CGContext, base: CGPoint, tip: CGPoint, body: CGColor, outline: CGColor) {
        let path = CGMutablePath()
        path.move(to: base)
        path.addLine(to: tip)
        path.addLine(to: CGPoint(x: base.x + 22, y: base.y + 4))
        path.closeSubpath()
        context.addPath(path)
        context.setFillColor(body)
        context.fillPath()
        context.addPath(path)
        context.setStrokeColor(outline)
        context.setLineWidth(4)
        context.setLineJoin(.round)
        context.strokePath()
        fillEllipseStroke(context, CGRect(x: tip.x - 7, y: tip.y - 7, width: 14, height: 14), fill: body, outline: outline, width: 4)
    }

    // MARK: - bloub pet (MIT, jeremy-prt/bloub; ported from its radial/eye model)

    private struct BloubEyePose {
        let x: Double
        let y: Double
        let a: Double
        let b: Double
        let c: Double
        let d: Double
    }

    private struct BloubGaze {
        let yaw: Double
        let pitch: Double
        let roll: Double
    }

    private static func bloubEyePoses(gaze: BloubGaze, scale: Double) -> [BloubEyePose] {
        func spin(_ u: (Double, Double, Double), _ v: (Double, Double, Double), _ angle: Double) -> ((Double, Double, Double), (Double, Double, Double)) {
            let c = cos(angle)
            let s = sin(angle)
            return (
                (u.0 * c + v.0 * s, u.1 * c + v.1 * s, u.2 * c + v.2 * s),
                (v.0 * c - u.0 * s, v.1 * c - u.1 * s, v.2 * c - u.2 * s)
            )
        }
        func deg(_ d: Double) -> Double { d * .pi / 180 }
        var f: (Double, Double, Double) = (0, 0, 1)
        var right: (Double, Double, Double) = (1, 0, 0)
        var down: (Double, Double, Double) = (0, 1, 0)
        (f, right) = spin(f, right, deg(gaze.yaw))
        (down, f) = spin(down, f, deg(gaze.pitch))
        (right, down) = spin(right, down, deg(gaze.roll))
        func build(_ side: Double) -> BloubEyePose {
            let (ef, er) = spin(f, right, deg(15.46 * side))
            return BloubEyePose(x: ef.0 * scale, y: ef.1 * scale, a: er.0, b: er.1, c: down.0, d: down.1)
        }
        return [build(-1), build(1)]
    }

    private static func bloubLid(time: TimeInterval) -> Double {
        let cycle = time.truncatingRemainder(dividingBy: 4.4)
        guard cycle < 0.18 else { return 1 }
        if cycle < 0.08 { return max(0, 1 - cycle / 0.08) }
        return min(1, (cycle - 0.08) / 0.10)
    }

    private func drawBloub(in context: CGContext) {
        let center = CGPoint(x: 110, y: 108)
        let radius: CGFloat = 74
        let bodyColor = NSColor(white: 0.07, alpha: 1).cgColor
        let eyeColor = NSColor.white.cgColor
        let sleeping = petState == .sleeping || petState == .dozing
        let shift: CGFloat = sleeping ? -14 : 0

        context.saveGState()
        context.translateBy(x: 0, y: shift)

        // Body: a perfect circle (the bloub rest silhouette), breathing faintly.
        let breath: CGFloat = petState == .idle ? 1 + CGFloat(sin(assetClock * 1.8) * 0.006) : 1
        let bodyRect = CGRect(
            x: center.x - radius,
            y: center.y - radius * breath,
            width: radius * 2,
            height: radius * 2 * breath
        )
        fillEllipse(context, rect: bodyRect, color: bodyColor)

        // Eyes: two white capsules placed by the spherical head model.
        let baseGaze = BloubGaze(yaw: 28.49, pitch: 28.62, roll: -13)
        let gaze = BloubGaze(
            yaw: baseGaze.yaw + Double(pointerOffset.x) * 2.5,
            pitch: baseGaze.pitch + Double(pointerOffset.y) * 2.5,
            roll: baseGaze.roll
        )
        let poses = Self.bloubEyePoses(gaze: gaze, scale: Double(radius))
        let lid = sleeping ? 0.0 : Self.bloubLid(time: assetClock)
        let eyeWidth = 0.186 * Double(radius)
        let eyeHeight = 0.412 * Double(radius) * (0.06 + 0.94 * lid)

        for pose in poses {
            let eyeX = center.x + CGFloat(pose.x)
            let eyeY = center.y - CGFloat(pose.y)
            if eyeHeight < 1.2 {
                // Closed eye: rounded horizontal line.
                fillRoundedRect(
                    context,
                    CGRect(x: eyeX - CGFloat(eyeWidth) * 0.85, y: eyeY - 2.5, width: CGFloat(eyeWidth) * 1.7, height: 5),
                    radius: 2.5,
                    eyeColor
                )
                continue
            }
            // Tangent frame, y-flipped into CoreGraphics' bottom-left space.
            var transform = CGAffineTransform(
                a: pose.a * eyeWidth,
                b: -pose.b * eyeWidth,
                c: pose.c * eyeHeight,
                d: -pose.d * eyeHeight,
                tx: eyeX,
                ty: eyeY
            )
            let path = CGPath(ellipseIn: CGRect(x: -0.5, y: -0.5, width: 1, height: 1), transform: &transform)
            context.addPath(path)
            context.setFillColor(eyeColor)
            context.fillPath()
        }
        context.restoreGState()
    }

    private func drawStateOverlay(in context: CGContext) {
        switch petState {
        case .thinking:
            drawThoughtBubble(in: context)
        case .typing:
            fillRect(context, CGRect(x: 78, y: 45, width: 64, height: 22), NSColor(white: 0.12, alpha: 1).cgColor)
            for index in 0..<5 {
                fillRect(context, CGRect(x: 84 + CGFloat(index) * 10, y: 51, width: 6, height: 5), NSColor.white.cgColor)
            }
        case .building:
            fillRect(context, CGRect(x: 168, y: 42, width: 24, height: 24), theme.palette.highlight.cgColor())
            fillRect(context, CGRect(x: 176, y: 48, width: 8, height: 12), theme.palette.shadow.cgColor())
        case .juggling:
            drawJugglingOverlay(in: context)
        case .error, .reactFlail:
            fillRect(context, CGRect(x: 76, y: 36, width: 42, height: 7), NSColor.systemRed.cgColor)
            fillRect(context, CGRect(x: 94, y: 18, width: 7, height: 43), NSColor.systemRed.cgColor)
        case .attention, .miniHappy:
            for x in stride(from: 35, through: 180, by: 29) {
                let y = 30 + CGFloat((Int(x) / 29) % 3) * 13
                fillRect(context, CGRect(x: CGFloat(x), y: y, width: 7, height: 7), theme.palette.highlight.cgColor())
            }
        case .notification, .miniAlert:
            fillEllipse(context, rect: CGRect(x: 145, y: 18, width: 46, height: 39), color: NSColor.white.cgColor)
            fillRect(context, CGRect(x: 166, y: 26, width: 6, height: 17), NSColor.systemRed.cgColor)
            fillRect(context, CGRect(x: 166, y: 47, width: 6, height: 5), NSColor.systemRed.cgColor)
        case .sweeping:
            fillRect(context, CGRect(x: 154, y: 46, width: 8, height: 80), theme.palette.shadow.cgColor())
            fillRect(context, CGRect(x: 148, y: 40, width: 28, height: 10), theme.palette.highlight.cgColor())
        case .carrying:
            fillRect(context, CGRect(x: 145, y: 102, width: 43, height: 37), theme.palette.accent.cgColor())
            fillRect(context, CGRect(x: 164, y: 102, width: 5, height: 37), theme.palette.shadow.cgColor())
            fillRect(context, CGRect(x: 145, y: 119, width: 43, height: 5), theme.palette.shadow.cgColor())
        case .sleeping, .dozing:
            drawSleepMarks(in: context)
        case .waking:
            drawSparkle(in: context)
        case .dragging:
            fillEllipse(context, rect: CGRect(x: 36, y: 34, width: 16, height: 16), color: theme.palette.highlight.cgColor())
            fillRect(context, CGRect(x: 40, y: 50, width: 8, height: 35), theme.palette.highlight.cgColor())
        case .miniPeek:
            fillRect(context, CGRect(x: 173, y: 72, width: 25, height: 7), theme.palette.highlight.cgColor())
        default:
            break
        }
    }

    private func drawThoughtBubble(in context: CGContext) {
        fillEllipse(context, rect: CGRect(x: 146, y: 16, width: 52, height: 40), color: NSColor.white.cgColor)
        fillEllipse(context, rect: CGRect(x: 134, y: 50, width: 12, height: 12), color: NSColor.white.cgColor)
        fillEllipse(context, rect: CGRect(x: 124, y: 62, width: 8, height: 8), color: NSColor.white.cgColor)
        for index in 0..<3 {
            fillRect(context, CGRect(x: 158 + CGFloat(index) * 10, y: 31, width: 5, height: 5), theme.palette.accent.cgColor())
        }
    }

    private func drawJugglingOverlay(in context: CGContext) {
        let isTierTwo = subagentCount >= 2
        if theme.id != "pinch", isTierTwo {
            // Calico and Cloudling use the conducting pose for 2+ live
            // subagents, while Clawd uses the three-ball tier below.
            fillRect(context, CGRect(x: 104, y: 22, width: 6, height: 56), theme.palette.shadow.cgColor())
            fillRect(context, CGRect(x: 92, y: 20, width: 30, height: 6), theme.palette.highlight.cgColor())
            fillEllipse(context, rect: CGRect(x: 60, y: 35, width: 14, height: 14), color: theme.palette.accent.cgColor())
            fillEllipse(context, rect: CGRect(x: 151, y: 35, width: 14, height: 14), color: theme.palette.accent.cgColor())
            return
        }
        if isTierTwo {
            for (index, position) in [(0, CGPoint(x: 55, y: 42)), (1, CGPoint(x: 107, y: 28)), (2, CGPoint(x: 160, y: 42))] {
                let color = index == 1 ? theme.palette.highlight.cgColor() : theme.palette.accent.cgColor()
                fillEllipse(context, rect: CGRect(x: position.x, y: position.y, width: 14, height: 14), color: color)
            }
        } else {
            // The one-subagent / two-session tier is a compact headphones
            // cue, visually distinct from the 2+ juggling tier.
            context.setStrokeColor(theme.palette.accent.cgColor())
            context.setLineWidth(6)
            context.addArc(center: CGPoint(x: 110, y: 43), radius: 28, startAngle: .pi, endAngle: 0, clockwise: false)
            context.strokePath()
            fillRect(context, CGRect(x: 77, y: 42, width: 8, height: 20), theme.palette.accent.cgColor())
            fillRect(context, CGRect(x: 135, y: 42, width: 8, height: 20), theme.palette.accent.cgColor())
        }
    }

    private func drawSleepMarks(in context: CGContext) {
        let color = theme.palette.shadow.cgColor()
        fillRect(context, CGRect(x: 156, y: 24, width: 16, height: 4), color)
        fillRect(context, CGRect(x: 168, y: 28, width: 4, height: 12), color)
        fillRect(context, CGRect(x: 168, y: 36, width: 14, height: 4), color)
        fillRect(context, CGRect(x: 177, y: 44, width: 12, height: 4), color)
        fillRect(context, CGRect(x: 185, y: 48, width: 4, height: 10), color)
        fillRect(context, CGRect(x: 177, y: 54, width: 12, height: 4), color)
    }

    private func drawSparkle(in context: CGContext) {
        let color = theme.palette.highlight.cgColor()
        fillRect(context, CGRect(x: 36, y: 42, width: 5, height: 24), color)
        fillRect(context, CGRect(x: 27, y: 51, width: 23, height: 5), color)
        fillRect(context, CGRect(x: 177, y: 64, width: 5, height: 22), color)
        fillRect(context, CGRect(x: 168, y: 73, width: 23, height: 5), color)
    }

    private func cgColor(_ color: RGBColor) -> CGColor {
        NSColor(calibratedRed: color.red, green: color.green, blue: color.blue, alpha: 1).cgColor
    }

    private func fillRect(_ context: CGContext, _ rect: CGRect, _ color: CGColor) {
        context.setFillColor(color)
        context.fill(rect)
    }

    private func fillEllipse(_ context: CGContext, rect: CGRect, color: CGColor) {
        context.setFillColor(color)
        context.fillEllipse(in: rect)
    }
}

private extension RGBColor {
    func cgColor() -> CGColor {
        NSColor(calibratedRed: red, green: green, blue: blue, alpha: 1).cgColor
    }
}
