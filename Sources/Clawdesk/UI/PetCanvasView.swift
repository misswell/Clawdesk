import AppKit
import Foundation
import ImageIO

private extension BloubRGB {
    var cgColor: CGColor {
        CGColor(red: red, green: green, blue: blue, alpha: 1)
    }
}

private extension CGPath {
    func transformed(_ transform: CGAffineTransform) -> CGPath {
        var mutable = transform
        return copy(using: &mutable) ?? self
    }
}

@MainActor
public final class PetCanvasView: NSView {
    /// Ball radius at rest, in points, matching the long-standing 220x220
    /// logical canvas.
    private static let bloubRadius: CGFloat = 74

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureTransparentSurface()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureTransparentSurface()
    }

    public override var isOpaque: Bool { false }

    private func configureTransparentSurface() {
        // A pet is a transparent compositing surface, not a focusable form
        // control. Keep it view-backed: a layer-backed transparent surface can
        // carry old interaction pixels when AppKit moves the panel or redraws
        // only a dirty region. The direct NSView backing is cheap at this
        // canvas size and lets the full-canvas clear below reach the actual
        // window backing store.
        focusRingType = .none
        wantsLayer = false
    }

    public var petState: PetState = .idle {
        didSet {
            guard oldValue != petState else { return }
            syncBloubState()
            // Pointer-interaction states (hover peek, drag) are cursor
            // affordances: the cursor is ON the pet by definition, so the
            // tracking context survives them. Expressive states hand the
            // eyes back to their own pose.
            if petState != .idle, petState != .miniIdle, !petState.isPointerInteraction {
                pointerKnown = false
                updateBloubLook()
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
            // The clock jump must not drag the engine through a phantom
            // transition: rewind it onto the mapped state at the new zero.
            bloubEngine.reset(
                BloubStateMapper.state(for: petState, subagentCount: subagentCount),
                at: 0
            )
            bloubEngine.rewindCustomization(at: 0)
            lookActive = false
            pointerKnown = false
            needsDisplay = true
        }
    }

    /// Bloub appearance chosen in Settings (shape, colour, resting
    /// expression). Appearance is decoupled from the agent state: it changes
    /// what the pet looks like, `petState` decides what it does.
    public var bloubAppearance: BloubAppearance = .standard {
        didSet {
            guard oldValue != bloubAppearance else { return }
            applyAppearance()
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
        didSet {
            syncBloubState()
            needsDisplay = true
        }
    }

    public var idleVisualFile: String? {
        didSet {
            needsDisplay = true
        }
    }

    /// A theme-provided visual-only override used for a DND sleep transition.
    /// The logical state remains `collapsing`, so lifecycle and wake semantics
    /// do not depend on an artwork-specific state name.
    public var stateAssetOverride: String? {
        didSet {
            needsDisplay = true
        }
    }

    public var pointerOffset = CGPoint.zero {
        didSet {
            updateBloubLook()
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

    /// Owns the whole bloub motion language. It never touches a clock: the
    /// canvas feeds it the shared animation time, and all inputs (state
    /// changes, look targets) enter through timestamped setters.
    private var bloubEngine = BloubEngine(radius: PetCanvasView.bloubRadius)
    private var lookActive = false
    private var animationClock = PetAnimationClock()
    private var assetClock: TimeInterval { animationClock.time }
    private var pointerKnown = false
    /// True while the last draw served a multi-frame theme asset: those run
    /// on their own frame timeline and need the full animation frequency.
    private var assetAnimationActive = false
    /// 1 when the cursor rests on the pet's body, 0 when it is elsewhere;
    /// pulls the tracking gaze straight to the viewer across the ball.
    private var pointerForward: CGFloat = 0
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

    private var viewScale: CGFloat {
        min(bounds.width / 220, bounds.height / 220) * (miniMode ? 0.86 : 1)
    }

    /// Keeps the engine's state in step with the mapped pet state. The agent
    /// runtime only ever speaks `PetState`; the bloub vocabulary stays behind
    /// the mapper seam.
    private func syncBloubState() {
        bloubEngine.setState(
            BloubStateMapper.state(for: petState, subagentCount: subagentCount),
            at: assetClock
        )
    }

    /// Pushes the customizer choices into the engine as timestamped inputs:
    /// the shape and the resting expression both glide there on the morph
    /// curve instead of jumping.
    private func applyAppearance() {
        bloubEngine.setShape(bloubAppearance.shape.profile, at: assetClock)
        bloubEngine.setExpression(bloubAppearance.expression, at: assetClock)
    }

    /// Pointer tracking is an idle-state affordance: the engine blends the
    /// absolute look target over the pose's own gaze, so expressive states
    /// simply stop feeding targets and recover theirs.
    private func updateBloubLook() {
        let tracking = theme.supportsEyeTracking
            && (petState == .idle || petState == .miniIdle || petState == .miniPeek)
            && pointerKnown
        if tracking {
            // pointerOffset is the upstream `Aim`: normalized x (right
            // positive) and y (down positive) in -1...1. `targetGaze` turns
            // it into the same absolute head angles as the original. With the
            // cursor on the body, the gaze glides straight to the viewer
            // (yaw and pitch to zero) instead of holding the cone's stance.
            let gaze = BloubMotion.targetGaze(
                normalizedX: Double(pointerOffset.x),
                normalizedY: Double(pointerOffset.y)
            )
            let forward = CGFloat(pointerForward)
            bloubEngine.setLook(
                BloubLook(
                    yaw: CGFloat(gaze.yaw) * (1 - forward),
                    pitch: CGFloat(gaze.pitch) * (1 - forward),
                    mix: 1,
                    spin: 0,
                    wander: 0,
                    roll: 0
                ),
                at: assetClock
            )
            lookActive = true
        } else if lookActive {
            bloubEngine.setLook(nil, at: assetClock)
            lookActive = false
        }
    }

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

    /// Hit testing follows the current morphing silhouette instead of a fixed
    /// rectangle: transparent areas let clicks pass through, and the body —
    /// wherever its edge currently is — stays clickable and draggable.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        let scale = viewScale
        guard scale > 0 else { return nil }
        // View coordinates are y-up; engine coordinates are y-down and centred
        // on the ball.
        let enginePoint = CGPoint(
            x: (point.x - bounds.midX) / scale,
            y: (bounds.midY - point.y) / scale
        )
        let body = bloubEngine.sample(at: assetClock).bodyPath()
        return body.contains(enginePoint) ? self : nil
    }

    public func advanceFrame(at timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        // The engine samples at absolute clock time, so the delta itself needs
        // no further bookkeeping; keeping the clock monotonic is enough.
        animationClock.advance(to: timestamp)
        needsDisplay = true
    }

    /// True when the next frame only differs through the slow rest life
    /// (drift, breath, blink calendar) and no theme asset animation is
    /// playing: the render driver may drop to its idle frequency. The
    /// reference video itself rests at ~10 fps with one-to-two-frame blinks,
    /// so a low idle clock stays faithful to bloub's motion language.
    public var isResting: Bool {
        bloubEngine.isSettled(at: assetClock) && !assetAnimationActive
    }

    /// Flush a state transition before a transparent panel is moved or
    /// another interaction event arrives. This keeps stale pixels out of the
    /// window backing surface instead of waiting for AppKit's next run-loop
    /// display pass.
    public func redrawImmediately() {
        needsDisplay = true
        display()
        window?.displayIfNeeded()
    }

    public func setPointerLocation(_ point: NSPoint) {
        guard theme.supportsEyeTracking,
              (petState == .idle || petState == .miniIdle || petState == .miniPeek) else {
            if pointerOffset != .zero { pointerOffset = .zero }
            return
        }
        guard let window else { return }
        // The rule normalizes against half the screen, not the pet window:
        // the gaze must saturate when the cursor reaches the screen edge,
        // wherever the pet sits (upstream divides by half the browser
        // window). `point` and `convertToScreen` are both AppKit screen
        // coordinates (y grows upward).
        let petRect = window.convertToScreen(bounds)
        let screenFrame = window.screen?.frame
            ?? NSScreen.screens.first(where: { $0.frame.contains(point) })?.frame
            ?? NSScreen.main?.frame
            ?? NSRect(x: 0, y: 0, width: 1, height: 1)
        pointerKnown = true
        let newOffset = PetPointerMapper.gazeOffset(
            petCenter: CGPoint(x: petRect.midX, y: petRect.midY),
            cursor: point,
            screenSize: screenFrame.size
        )
        // The forward zone is the ball itself, not the whole window: cursor
        // on the body makes the eyes rush to the front (look at the viewer).
        let ballRect = petRect.insetBy(
            dx: petRect.width * 0.18,
            dy: petRect.height * 0.18
        )
        let newForward = PetPointerMapper.forwardFactor(petRect: ballRect, cursor: point)
        // A resting cursor must not churn the engine: re-posing the look
        // target every poll would keep the gaze catch-up alive forever and
        // the pet would never settle into its idle cadence.
        guard newOffset != pointerOffset || newForward != pointerForward else { return }
        pointerOffset = newOffset
        pointerForward = newForward
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
        // Replace the complete transparent surface. `sourceOver` can leave
        // old pixels in a buffered transparent window; copy + clear writes
        // transparent pixels over the whole canvas before the next frame.
        context.setBlendMode(.copy)
        context.setFillColor(NSColor.clear.cgColor)
        context.fill(bounds)
        context.setBlendMode(.normal)
        context.setShouldAntialias(true)
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)

        assetAnimationActive = false
        if !petState.isPointerInteraction, drawCustomAsset(in: context) {
            context.restoreGState()
            return
        }

        drawBloubFrame(in: context)
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
        // Multi-frame assets run on their own timeline and need the full
        // animation frequency; a single static frame does not.
        assetAnimationActive = animation.frames.count > 1
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
        context.saveGState()
        context.translateBy(x: bounds.midX, y: bounds.midY)
        context.scaleBy(x: viewScale, y: viewScale)
        context.translateBy(x: -110, y: -110)
        context.interpolationQuality = .none
        context.draw(frame, in: target)
        context.restoreGState()
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

    // MARK: - bloub frame renderer (engine output -> Core Graphics)

    private func drawBloubFrame(in context: CGContext) {
        let frame = bloubEngine.sample(at: assetClock)
        // A customizer colour overrides the theme palette; "theme" defers to it.
        let bodyColor = bloubAppearance.bodyColor ?? BloubRGB(
            red: theme.palette.body.red,
            green: theme.palette.body.green,
            blue: theme.palette.body.blue
        )
        let palette = BloubPalette(
            body: bodyColor,
            eye: BloubRGB(red: 1, green: 1, blue: 1),
            notification: BloubDecor.notifColor
        )
        context.saveGState()
        context.translateBy(x: bounds.midX, y: bounds.midY)
        context.scaleBy(x: viewScale, y: viewScale)
        // After the canvas flip the context is y-down from the top edge — the
        // same handedness the engine speaks — so engine geometry is drawn
        // verbatim with no per-component sign tracking. (Verified against the
        // live display path: the production context CTM is the identity, so
        // the early flip is the only handedness change on this stack.)

        // Orbit depth: back half of every arc first, so the body occludes it.
        for arc in frame.arcs {
            strokeArc(context, arc, polylines: arc.back)
        }

        if frame.dotsBehind {
            drawDots(context, frame.dots, palette: palette)
        }

        // Body with the notification notch subtracted (even-odd), so the
        // badge appears to bite into the silhouette.
        let bodyPath = frame.bodyPath()
        context.setAlpha(frame.body.opacity)
        context.addPath(bodyPath)
        if let notch = frame.notch {
            context.addPath(CGPath(
                ellipseIn: CGRect(
                    x: notch.center.x - notch.radius,
                    y: notch.center.y - notch.radius,
                    width: notch.radius * 2,
                    height: notch.radius * 2
                ),
                transform: nil
            ))
            context.setFillColor(palette.body.cgColor)
            context.fillPath(using: .evenOdd)
        } else {
            context.setFillColor(palette.body.cgColor)
            context.fillPath()
        }
        context.setAlpha(1)

        // Eyes: paper capsules clipped to the body path. Clipping is what
        // trims them automatically when they slide against the silhouette —
        // no extra border logic, matching the masked-hole behaviour upstream.
        if !frame.eyes.isEmpty {
            context.saveGState()
            context.addPath(bodyPath)
            context.clip()
            for eye in frame.eyes {
                let shape = BloubPaths.capsule(
                    width: eye.capsuleWidth,
                    height: eye.capsuleHeight
                ).transformed(eye.transform)
                context.setAlpha(eye.alpha)
                context.setFillColor(palette.eye.cgColor)
                context.addPath(shape)
                context.fillPath()
            }
            context.restoreGState()
        }

        if !frame.dotsBehind {
            drawDots(context, frame.dots, palette: palette)
        }

        if let badge = frame.notification {
            context.setFillColor(palette.notification.cgColor)
            context.fillEllipse(in: CGRect(
                x: badge.center.x - badge.radius,
                y: badge.center.y - badge.radius,
                width: badge.radius * 2,
                height: badge.radius * 2
            ))
        }

        for arc in frame.arcs {
            strokeArc(context, arc, polylines: arc.front)
        }
        context.restoreGState()
    }

    private func drawDots(_ context: CGContext, _ dots: [BloubDot], palette: BloubPalette) {
        for dot in dots {
            // Depth haze fades a particle into the background; on a
            // transparent window that blend is an alpha fade.
            let alpha = dot.opacity * (dot.depth ?? 1)
            guard alpha > 0.004 else { continue }
            context.setAlpha(CGFloat(alpha))
            context.setFillColor(palette.body.cgColor)
            if let drop = dot.drop {
                let transform = CGAffineTransform(
                    translationX: dot.position.x,
                    y: dot.position.y
                ).rotated(by: CGFloat(dot.dropRotation) * .pi / 180)
                let shape = BloubPaths.polygon(drop).transformed(transform)
                context.addPath(shape)
                context.fillPath()
            } else {
                context.fillEllipse(in: CGRect(
                    x: dot.position.x - dot.radius,
                    y: dot.position.y - dot.radius,
                    width: dot.radius * 2,
                    height: dot.radius * 2
                ))
            }
        }
        context.setAlpha(1)
    }

    /// One arc stroke: mask the gradient with the stroked path so each ring
    /// keeps bloub's hue gradient along its trace.
    private func strokeArc(_ context: CGContext, _ arc: BloubArc, polylines: [[CGPoint]]) {
        guard arc.opacity > 0.004 else { return }
        let colors = arc.gradientStops.map { stop in
            CGColor(red: stop.red, green: stop.green, blue: stop.blue, alpha: 1)
        }
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors as CFArray,
            locations: [0, 0.5, 1]
        ) else { return }
        for points in polylines where points.count > 1 {
            context.saveGState()
            context.setAlpha(CGFloat(arc.opacity))
            context.setLineWidth(arc.width)
            context.setLineCap(.round)
            context.addPath(BloubPaths.polyline(points))
            context.replacePathWithStrokedPath()
            context.clip()
            context.drawLinearGradient(
                gradient,
                start: arc.gradientStart,
                end: arc.gradientEnd,
                options: []
            )
            context.restoreGState()
        }
    }
}
