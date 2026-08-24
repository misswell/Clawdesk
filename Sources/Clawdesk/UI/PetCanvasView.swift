import AppKit
import Foundation
import ImageIO

@MainActor
public final class PetCanvasView: NSView {
    public var petState: PetState = .idle {
        didSet {
            guard oldValue != petState else { return }
            stateElapsed = 0
            if petState != .idle, petState != .miniIdle {
                pointerOffset = .zero
                pointerKnown = false
            }
            needsDisplay = true
        }
    }

    public var theme: ThemeDefinition = ThemeCatalog.theme(id: "pinch") {
        didSet {
            assetCache.removeAll()
            assetCacheOrder.removeAll()
            assetCacheBytes = 0
            animationClock.reset()
            gazeMorph.reset()
            pointerKnown = false
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
            animationClock.reset()
            needsDisplay = true
        }
    }

    /// A theme-provided visual-only override used for a DND sleep transition.
    /// The logical state remains `collapsing`, so lifecycle and wake semantics
    /// do not depend on an artwork-specific state name.
    public var stateAssetOverride: String? {
        didSet {
            animationClock.reset()
            needsDisplay = true
        }
    }

    public var pointerOffset = CGPoint.zero {
        didSet {
            gazeMorph.setTarget(pointerOffset)
            needsDisplay = true
        }
    }

    public var onDragBegan: ((CGPoint) -> Void)?
    public var onDrag: ((CGPoint) -> Void)?
    public var onDragEnded: (() -> Void)?
    public var onClick: (() -> Void)?
    public var onDoubleTap: (() -> Void)?
    public var onFlail: (() -> Void)?
    public var onContextMenu: ((NSPoint) -> NSMenu?)?
    public var onHoverChanged: ((Bool) -> Void)?

    private var phase: CGFloat = 0
    private var stateElapsed: TimeInterval = 0
    private var animationClock = PetAnimationClock()
    private var gazeMorph = BloubGazeMorph()
    private var pointerKnown = false
    private var assetClock: TimeInterval { animationClock.time }
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
    private var clickTimes: [Date] = []
    private var trackingArea: NSTrackingArea?
    private var mouseDownScreenPoint: CGPoint?
    private var didDragSinceMouseDown = false

    public override var acceptsFirstResponder: Bool { true }

    /// The pet is the entire transparent backing surface. Incremental
    /// AppKit clipping is useful for ordinary views, but it can preserve old
    /// pixels when a new interaction state paints a smaller silhouette.
    public override var wantsDefaultClipping: Bool { false }

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

    public func advanceFrame(at timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let delta = animationClock.advance(to: timestamp)
        phase += CGFloat(delta)
        stateElapsed += delta
        gazeMorph.advance(by: delta)
        if phase > 1_000 { phase = 0 }
        needsDisplay = true
    }

    /// Flush a state transition before a transparent panel is moved or
    /// another interaction event arrives. This keeps stale pixels out of the
    /// window backing surface instead of waiting for AppKit's next run-loop
    /// display pass.
    public func redrawImmediately() {
        needsDisplay = true
        display()
    }

    public func setPointerLocation(_ point: NSPoint) {
        guard theme.supportsEyeTracking, (petState == .idle || petState == .miniIdle) else {
            if pointerOffset != .zero { pointerOffset = .zero }
            return
        }
        let windowPoint = window?.convertFromScreen(NSRect(origin: point, size: .zero)).origin ?? point
        let local = convert(windowPoint, from: nil)
        pointerKnown = true
        pointerOffset = PetPointerMapper.offset(for: local, in: bounds)
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        // This is a transparent, borderless pet window. AppKit does not
        // guarantee that pixels drawn by an earlier state disappear when a
        // later state only paints a smaller shape. Clear the full transparent
        // canvas: the old interaction markers live outside many AppKit dirty
        // rects, so clearing only dirtyRect can leave a horizontal or vertical
        // remnant behind after hover/drag transitions.
        // AppKit may already have installed a dirty-rect clip on the
        // CGContext. Replace it with a clip to the whole pet canvas before
        // clearing so the transparent backing surface is genuinely reset.
        context.resetClip()
        context.clip(to: bounds)
        context.clear(bounds)
        context.setShouldAntialias(true)
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)

        let scale = min(bounds.width / 220, bounds.height / 220) * (miniMode ? 0.86 : 1.0)
        let bob: CGFloat
        switch petState {
        case .attention, .miniHappy: bob = sin(phase * 6) * 5
        case .error, .reactFlail: bob = sin(phase * 12) * 3
        case .idle, .miniIdle, .yawning, .dozing, .collapsing, .sleeping, .wakingFromDoze: bob = 0
        default: bob = sin(phase * 2) * 1.7
        }
        context.translateBy(x: bounds.midX, y: bounds.midY + bob)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -110, y: -110)

        if !petState.isPointerInteraction, drawCustomAsset(in: context) {
            context.restoreGState()
            return
        }

        drawBloub(in: context)
        drawStateOverlay(in: context)
        context.restoreGState()
    }

    private func drawCustomAsset(in context: CGContext) -> Bool {
        let idleFile = petState == .idle ? idleVisualFile : nil
        guard let url = theme.assetURL(
            for: petState,
            idleVisualFile: idleFile,
            stateOverrideFile: stateAssetOverride
        ),
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
        let screenPoint = window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        mouseDownScreenPoint = screenPoint
        didDragSinceMouseDown = false
        onDragBegan?(screenPoint)
    }

    public override func mouseDragged(with event: NSEvent) {
        let screenPoint = window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        if let start = mouseDownScreenPoint {
            let dx = screenPoint.x - start.x
            let dy = screenPoint.y - start.y
            didDragSinceMouseDown = didDragSinceMouseDown || (dx * dx + dy * dy) >= 16
        }
        onDrag?(screenPoint)
    }

    public override func mouseUp(with event: NSEvent) {
        onDragEnded?()
        if !didDragSinceMouseDown, event.clickCount == 1 {
            onClick?()
        }
        mouseDownScreenPoint = nil
        didDragSinceMouseDown = false
    }

    public override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let menu = onContextMenu?(point) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }

    private func fillRoundedRect(_ context: CGContext, _ rect: CGRect, radius: CGFloat, _ color: CGColor) {
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        context.addPath(path)
        context.setFillColor(color)
        context.fillPath()
    }

    // MARK: - bloub pet (MIT, jeremy-prt/bloub; ported from its radial/eye model)

    private struct BloubEyePose {
        let x: Double
        let y: Double
        let a: Double
        let b: Double
        let c: Double
        let d: Double
        let depth: Double
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
            return BloubEyePose(
                x: ef.0 * scale,
                y: ef.1 * scale,
                a: er.0,
                b: er.1,
                c: down.0,
                d: down.1,
                depth: ef.2
            )
        }
        return [build(-1), build(1)]
    }

    private func drawBloub(in context: CGContext) {
        let radius: CGFloat = 74
        let bodyColor = theme.palette.body.cgColor()
        let eyeColor = NSColor.white.cgColor
        let dozing = petState == .dozing
        let sleeping = petState == .sleeping
        let yawning = petState == .yawning
        let collapsing = petState == .collapsing
        let wakingFromDoze = petState == .wakingFromDoze
        let idleLike = petState == .idle || petState == .miniIdle
        let yawnProgress = yawning
            ? min(1, max(0, stateElapsed / max(0.25, theme.timings.yawnDuration)))
            : 0
        let collapseDuration = stateAssetOverride != nil
            ? max(0.25, theme.timings.dndCollapseDuration)
            : max(0.25, theme.timings.collapseDuration)
        let collapseProgress = collapsing
            ? min(1, max(0, stateElapsed / collapseDuration))
            : 0
        let sleepPose = dozing || sleeping || collapsing
        let life = BloubMotion.liveliness(
            at: assetClock,
            wander: idleLike && pointerKnown ? 0 : (sleepPose || yawning ? 0 : 1),
            blink: !sleepPose && !wakingFromDoze,
            float: !sleepPose && !yawning && !wakingFromDoze
        )
        let yawnWave = sin(yawnProgress * .pi)
        let bodyScaleX = 1 + yawnWave * 0.05 + collapseProgress * 0.26
        let bodyScaleY = 1 + yawnWave * 0.10 - collapseProgress * 0.34
        let sleepBreath = (dozing || sleeping)
            ? 1 + sin((stateElapsed / 4) * .pi * 2) * 0.018
            : 1
        let center = CGPoint(
            x: 110 + CGFloat(life.driftX) * radius,
            y: 108 - CGFloat(life.driftY) * radius - collapseProgress * 6 + yawnProgress * 1.5
        )
        let shift: CGFloat = (dozing || sleeping ? -14 : 0) - collapseProgress * 2

        context.saveGState()
        context.translateBy(x: 0, y: shift)

        // The bloub rest silhouette is round; sleep transitions deliberately
        // squash or stretch that same shape instead of swapping in a heavy
        // animation timeline.
        let breath = CGFloat(life.breath * sleepBreath)
        let bodyRect = CGRect(
            x: center.x - radius * CGFloat(bodyScaleX),
            y: center.y - radius * CGFloat(bodyScaleY) * breath,
            width: radius * 2 * CGFloat(bodyScaleX),
            height: radius * 2 * CGFloat(bodyScaleY) * breath
        )
        fillEllipse(context, rect: bodyRect, color: bodyColor)

        // Eyes: two white capsules placed by the spherical head model.
        let baseGaze = idleLike && pointerKnown
            ? BloubMotion.targetGaze(forPointerOffset: gazeMorph.value)
            : BloubMotion.restGaze
        let gaze = BloubGaze(
            yaw: baseGaze.yaw + life.dYaw,
            pitch: baseGaze.pitch + life.dPitch,
            roll: baseGaze.roll + life.dRoll
        )
        let poses = Self.bloubEyePoses(gaze: gaze, scale: Double(radius))
        let closeProgress: Double
        if wakingFromDoze {
            closeProgress = max(0, 1 - min(1, stateElapsed / 0.35))
        } else if yawning {
            closeProgress = min(1, max(0, (yawnProgress - 0.18) / 0.28))
        } else {
            closeProgress = sleepPose ? 1 : 0
        }
        let lid = min(1, max(0, life.lid * (1 - closeProgress)))
        let eyeWidth = 0.186 * Double(radius)
        let eyeHeight = closeProgress >= 0.999
            ? 0
            : 0.412 * Double(radius) * (0.06 + 0.94 * lid)

        for pose in poses {
            guard pose.depth > 0.02 else { continue }
            let eyeX = center.x + CGFloat(pose.x)
            let eyeY = center.y - CGFloat(pose.y)
            let visibility = min(1, max(0, pose.depth / 0.12))
            context.saveGState()
            context.setAlpha(CGFloat(visibility))
            if eyeHeight < 1.2 {
                // Closed eye: rounded horizontal line.
                fillRoundedRect(
                    context,
                    CGRect(x: eyeX - CGFloat(eyeWidth) * 0.85, y: eyeY - 2.5, width: CGFloat(eyeWidth) * 1.7, height: 5),
                    radius: 2.5,
                    eyeColor
                )
                context.restoreGState()
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
            context.restoreGState()
        }

        if yawning {
            let mouthProgress = sin(min(1, max(0, (yawnProgress - 0.18) / 0.62)) * .pi)
            if mouthProgress > 0 {
                let mouthWidth = 7 + CGFloat(mouthProgress) * 7
                let mouthHeight = 3 + CGFloat(mouthProgress) * 10
                fillEllipse(
                    context,
                    rect: CGRect(
                        x: center.x - mouthWidth / 2,
                        y: center.y - 31 - CGFloat(mouthProgress) * 2,
                        width: mouthWidth,
                        height: mouthHeight
                    ),
                    color: theme.palette.shadow.cgColor()
                )
            }
        }
        context.restoreGState()
    }

    private func drawStateOverlay(in context: CGContext) {
        guard !petState.isPointerInteraction else { return }
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
        case .sleeping:
            drawSleepMarks(in: context)
        case .collapsing:
            let duration = stateAssetOverride != nil
                ? max(0.25, theme.timings.dndCollapseDuration)
                : max(0.25, theme.timings.collapseDuration)
            let progress = min(1, max(0, stateElapsed / duration))
            drawSleepMarks(in: context, alpha: CGFloat(progress))
        case .yawning, .dozing, .wakingFromDoze:
            break
        case .waking:
            drawSparkle(in: context)
        case .dragging, .miniPeek:
            // Dragging and mini-hover are interaction states, not decorations.
            // In particular, do not resurrect the old corner bar markers here.
            break
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

    private func drawSleepMarks(in context: CGContext, alpha: CGFloat = 1) {
        context.saveGState()
        context.setAlpha(alpha)
        let color = theme.palette.shadow.cgColor()
        fillRect(context, CGRect(x: 156, y: 24, width: 16, height: 4), color)
        fillRect(context, CGRect(x: 168, y: 28, width: 4, height: 12), color)
        fillRect(context, CGRect(x: 168, y: 36, width: 14, height: 4), color)
        fillRect(context, CGRect(x: 177, y: 44, width: 12, height: 4), color)
        fillRect(context, CGRect(x: 185, y: 48, width: 4, height: 10), color)
        fillRect(context, CGRect(x: 177, y: 54, width: 12, height: 4), color)
        context.restoreGState()
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
