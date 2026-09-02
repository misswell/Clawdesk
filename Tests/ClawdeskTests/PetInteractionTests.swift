import Foundation
import XCTest
@testable import Clawdesk

final class PetInteractionTests: XCTestCase {
    @MainActor
    func testPointerPollingDropsFurtherInLowPowerMode() {
        XCTAssertEqual(PetTimerScheduler.pointerFrequency(lowPower: false), 30)
        XCTAssertEqual(PetTimerScheduler.pointerFrequency(lowPower: true), 12)
    }

    @MainActor
    func testPetRenderTimerRunsDuringTrackingRunLoopMode() {
        var fireCount = 0
        let timer = PetTimerScheduler.schedule(interval: 0.001, repeats: true) {
            fireCount += 1
        }
        defer { timer.invalidate() }

        let deadline = Date(timeIntervalSinceNow: 0.25)
        while fireCount == 0 && Date() < deadline {
            RunLoop.main.run(mode: .eventTracking, before: Date(timeIntervalSinceNow: 0.01))
        }

        XCTAssertGreaterThan(fireCount, 0)
    }

    func testAnimationClockUsesElapsedTimeInsteadOfFixedFrameSteps() {
        var clock = PetAnimationClock()

        XCTAssertEqual(clock.advance(to: 10), 0, accuracy: 0.0001)
        XCTAssertEqual(clock.advance(to: 10.1), 0.1, accuracy: 0.0001)
        XCTAssertEqual(clock.advance(to: 10.35), 0.25, accuracy: 0.0001)
    }

    func testIdleAnimationCyclePlaysOnceAfterQuietPeriodAndSkipsSelectedRestingFile() {
        let activity = Date(timeIntervalSince1970: 10_000)
        let animations = [
            ThemeIdleAnimation(file: "selected.gif", duration: 1),
            ThemeIdleAnimation(file: "look.gif", duration: 6.5)
        ]
        var cycle = IdleAnimationCycle()

        XCTAssertNil(cycle.choose(
            now: activity.addingTimeInterval(19.9),
            activity: activity,
            animations: animations,
            selectedIdleFile: "selected.gif",
            randomIndex: { _ in 0 }
        ))
        let first = cycle.choose(
            now: activity.addingTimeInterval(20),
            activity: activity,
            animations: animations,
            selectedIdleFile: "selected.gif",
            randomIndex: { _ in 0 }
        )
        XCTAssertEqual(first?.file, "look.gif")
        XCTAssertNil(cycle.choose(
            now: activity.addingTimeInterval(40),
            activity: activity,
            animations: animations,
            selectedIdleFile: "selected.gif",
            randomIndex: { _ in 0 }
        ))

        let nextActivity = activity.addingTimeInterval(41)
        cycle.reset(for: nextActivity)
        XCTAssertEqual(cycle.choose(
            now: nextActivity.addingTimeInterval(20),
            activity: nextActivity,
            animations: animations,
            selectedIdleFile: "selected.gif",
            randomIndex: { _ in 0 }
        )?.file, "look.gif")
    }

    @MainActor
    func testHoverPeekKeepsPointerTracking() throws {
        // Regression: hovering the pet flips it to mini-peek, and the peek
        // used to kill pointer tracking — the eyes snapped to the resting
        // pose until clicked. The peek is a pointer-over state: tracking and
        // the forward gaze must survive it.
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 240),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        let view = PetCanvasView(frame: NSRect(x: 0, y: 0, width: 240, height: 240))
        panel.contentView = view
        view.petState = .miniIdle
        view.theme = ThemeCatalog.theme(id: "pinch")

        view.setPointerLocation(NSPoint(x: 800, y: 800))
        let trackedOffset = view.pointerOffset
        XCTAssertNotEqual(trackedOffset, .zero)

        view.petState = .miniPeek
        view.setPointerLocation(NSPoint(x: 900, y: 700))
        XCTAssertNotEqual(view.pointerOffset, trackedOffset, "peek must keep updating the gaze")
    }

    func testForwardFactorPeaksAtBallCentreAndFallsToZeroAtTheEdge() {
        let ball = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertEqual(
            PetPointerMapper.forwardFactor(petRect: ball, cursor: CGPoint(x: 50, y: 50)),
            1, accuracy: 0.001
        )
        // Halfway to the edge: half of the pull to the front.
        XCTAssertEqual(
            PetPointerMapper.forwardFactor(petRect: ball, cursor: CGPoint(x: 75, y: 50)),
            0.5, accuracy: 0.001
        )
        XCTAssertEqual(
            PetPointerMapper.forwardFactor(petRect: ball, cursor: CGPoint(x: 50, y: 100)),
            0, accuracy: 0.001
        )
        // Beyond the edge clamps at zero — pure tracking out there.
        XCTAssertEqual(
            PetPointerMapper.forwardFactor(petRect: ball, cursor: CGPoint(x: 250, y: -150)),
            0, accuracy: 0.001
        )
    }

    @MainActor
    func testScreenPointerLocationMovesIdleEyesThroughWindowCoordinates() {
        let viewFrame = NSRect(x: 0, y: 0, width: 240, height: 240)
        let view = PetCanvasView(frame: viewFrame)
        let panel = NSPanel(
            contentRect: viewFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.setFrameOrigin(NSPoint(x: 500, y: 300))
        panel.contentView = view
        view.petState = .idle
        view.theme = ThemeCatalog.theme(id: "pinch")

        // Screen point below-right of the window centre (AppKit y grows up).
        view.setPointerLocation(NSPoint(x: 720, y: 320))

        XCTAssertGreaterThan(view.pointerOffset.x, 0)
        XCTAssertGreaterThan(view.pointerOffset.y, 0)
        XCTAssertLessThanOrEqual(view.pointerOffset.x, 1)
        XCTAssertLessThanOrEqual(view.pointerOffset.y, 1)
    }

    @MainActor
    func testCursorCircleTriggersDizzyOnlyForDefaultFullIdle() {
        let frame = NSRect(x: 0, y: 0, width: 240, height: 240)
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.setFrameOrigin(NSPoint(x: 500, y: 300))
        let view = PetCanvasView(frame: frame)
        panel.contentView = view
        view.petState = .idle

        var triggerCount = 0
        view.onDizzy = { triggerCount += 1 }
        let screenRect = panel.convertToScreen(view.bounds)
        let center = CGPoint(x: screenRect.midX, y: screenRect.midY)
        for index in 0...32 {
            let angle = CGFloat(index) * (.pi * 4 / 32)
            view.setPointerLocation(
                NSPoint(x: center.x + cos(angle) * 80, y: center.y + sin(angle) * 80),
                at: Double(index) * 0.05
            )
        }

        XCTAssertEqual(triggerCount, 1)

        // The same gesture shape is ignored by an active state and by mini
        // mode; returning to idle does not inherit the previous turn.
        view.petState = .typing
        for index in 0...32 {
            let angle = CGFloat(index) * (.pi * 4 / 32)
            view.setPointerLocation(
                NSPoint(x: center.x + cos(angle) * 80, y: center.y + sin(angle) * 80),
                at: 2 + Double(index) * 0.05
            )
        }
        view.petState = .idle
        view.miniMode = true
        for index in 0...32 {
            let angle = CGFloat(index) * (.pi * 4 / 32)
            view.setPointerLocation(
                NSPoint(x: center.x + cos(angle) * 80, y: center.y + sin(angle) * 80),
                at: 4 + Double(index) * 0.05
            )
        }
        XCTAssertEqual(triggerCount, 1)
    }

    @MainActor
    func testCursorCircleIsDisabledForNonDefaultIdleArtwork() {
        let frame = NSRect(x: 0, y: 0, width: 240, height: 240)
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.setFrameOrigin(NSPoint(x: 500, y: 300))
        let view = PetCanvasView(frame: frame)
        panel.contentView = view
        view.theme = ThemeDefinition(
            id: "idle-choice",
            displayName: "Idle Choice",
            palette: ThemeCatalog.theme(id: "pinch").palette,
            idleVisualFiles: ["idle-follow.png", "idle-reading.png"]
        )
        view.idleVisualFile = "idle-reading.png"
        var triggerCount = 0
        view.onDizzy = { triggerCount += 1 }
        let screenRect = panel.convertToScreen(view.bounds)
        let center = CGPoint(x: screenRect.midX, y: screenRect.midY)
        for index in 0...32 {
            let angle = CGFloat(index) * (.pi * 4 / 32)
            view.setPointerLocation(
                NSPoint(x: center.x + cos(angle) * 80, y: center.y + sin(angle) * 80),
                at: Double(index) * 0.05
            )
        }
        XCTAssertEqual(triggerCount, 0)
    }

    func testDragAnchorUsesStableScreenDelta() {
        let anchor = PetDragAnchor(
            windowOrigin: CGPoint(x: 100, y: 200),
            pointerOrigin: CGPoint(x: 120, y: 240)
        )

        XCTAssertEqual(anchor.windowOrigin(for: CGPoint(x: 120, y: 240)), CGPoint(x: 100, y: 200))
        XCTAssertEqual(anchor.windowOrigin(for: CGPoint(x: 180, y: 300)), CGPoint(x: 160, y: 260))
    }

    func testGazeOffsetNormalizesAgainstHalfTheScreen() {
        // Upstream rule: the offset divides by half the screen extents and
        // clamps, saturating exactly at the screen edge. Screen coords grow
        // upward; the returned offset is screen-convention (y down positive).
        let center = CGPoint(x: 756, y: 495)
        let size = CGSize(width: 1512, height: 982)

        XCTAssertEqual(
            PetPointerMapper.gazeOffset(petCenter: center, cursor: center, screenSize: size),
            .zero
        )

        // Cursor below-right of the pet: positive on both axes.
        let belowRight = PetPointerMapper.gazeOffset(
            petCenter: center,
            cursor: CGPoint(x: center.x + size.width / 2, y: center.y - size.height / 2),
            screenSize: size
        )
        XCTAssertEqual(belowRight.x, 1, accuracy: 0.001)
        XCTAssertEqual(belowRight.y, 1, accuracy: 0.001)

        // Cursor above-left: negative on both axes.
        let aboveLeft = PetPointerMapper.gazeOffset(
            petCenter: center,
            cursor: CGPoint(x: center.x - size.width / 2, y: center.y + size.height / 2),
            screenSize: size
        )
        XCTAssertEqual(aboveLeft.x, -1, accuracy: 0.001)
        XCTAssertEqual(aboveLeft.y, -1, accuracy: 0.001)

        // Far beyond the screen clamps instead of extrapolating.
        let clamped = PetPointerMapper.gazeOffset(
            petCenter: center,
            cursor: CGPoint(x: center.x + size.width * 10, y: center.y),
            screenSize: size
        )
        XCTAssertEqual(clamped.x, 1, accuracy: 0.001)
        XCTAssertEqual(clamped.y, 0, accuracy: 0.001)
    }

    func testBuiltInThemesExposeDistinctBloubBodyColors() {
        let themes = ThemeCatalog.builtIn
        let bodyColors = Set(themes.map {
            "\($0.palette.body.red),\($0.palette.body.green),\($0.palette.body.blue)"
        })

        XCTAssertGreaterThanOrEqual(themes.count, 7)
        XCTAssertGreaterThanOrEqual(bodyColors.count, 6)
        XCTAssertEqual(
            ThemeCatalog.theme(id: "pinch").palette.body,
            RGBColor(red: 0.07, green: 0.07, blue: 0.08)
        )
        XCTAssertNotEqual(
            ThemeCatalog.theme(id: "rose").palette.body,
            ThemeCatalog.theme(id: "mint").palette.body
        )
    }

    @MainActor
    func testHoverAndDraggingStatesDoNotDrawLegacyCornerBars() {
        let frame = NSRect(x: 0, y: 0, width: 220, height: 220)
        let theme = ThemeCatalog.theme(id: "pinch")
        let view = PetCanvasView(frame: frame)
        view.theme = theme

        view.petState = .miniPeek
        let peek = render(view)
        XCTAssertFalse(
            isHighlightPixel(in: peek, x: 185, y: 72, theme: theme),
            "Mini-mode hover must not draw the legacy upper-right bar"
        )

        view.petState = .dragging
        let dragging = render(view)
        XCTAssertFalse(
            isHighlightPixel(in: dragging, x: 44, y: 65, theme: theme),
            "Dragging must not draw the legacy upper-left bar"
        )
    }

    @MainActor
    func testInteractionStatesDoNotRenderThemeInteractionAssets() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clawdesk-interaction-assets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let asset = makeBitmap(width: 16, height: 16)
        paintCornerAsset(in: asset, theme: ThemeCatalog.theme(id: "pinch"))
        let assetURL = directory.appendingPathComponent("interaction.png")
        try XCTUnwrap(asset.representation(using: .png, properties: [:])).write(to: assetURL)

        let baseTheme = ThemeCatalog.theme(id: "pinch")
        let theme = ThemeDefinition(
            id: "interaction-asset-test",
            displayName: "Interaction asset test",
            palette: baseTheme.palette,
            assetDirectory: directory,
            stateFiles: [
                "mini-peek": "interaction.png",
                "dragging": "interaction.png"
            ]
        )
        let view = PetCanvasView(frame: NSRect(x: 0, y: 0, width: 220, height: 220))
        view.theme = theme

        XCTAssertNil(
            theme.assetURL(for: .miniPeek),
            "Pointer hover must never resolve a theme interaction asset"
        )
        XCTAssertNil(
            theme.assetURL(for: .dragging),
            "Pointer dragging must never resolve a theme interaction asset"
        )

        view.petState = .miniPeek
        XCTAssertFalse(hasOpaqueCornerPixel(in: render(view)), "Hover must not load a corner-mark asset")

        view.petState = .dragging
        XCTAssertFalse(hasOpaqueCornerPixel(in: render(view)), "Dragging must not load a corner-mark asset")
    }

    @MainActor
    func testStateTransitionRedrawClearsPreviousDecorations() {
        let frame = NSRect(x: 0, y: 0, width: 220, height: 220)
        let view = PetCanvasView(frame: frame)
        view.theme = ThemeCatalog.theme(id: "pinch")
        // Prime the animation clock (the first advance only anchors it), then
        // take the resting reference.
        view.advanceFrame(at: 0)
        view.advanceFrame(at: 1.0)
        let idleReference = render(view)
        let image = makeBitmap(width: 220, height: 220)

        // Waking maps to the swirl transition: its rings paint beyond the
        // resting silhouette.
        view.petState = .waking
        view.advanceFrame(at: 1.1)
        render(view, into: image)
        XCTAssertTrue(
            paintsBeyondReference(image, reference: idleReference),
            "The wake transition must actually draw its rings"
        )

        // Back to rest, past the cross-fade: every pixel the resting pet
        // leaves transparent must be transparent again — anywhere on the
        // canvas, not just inside the AppKit dirty rect. A 3 px tolerance
        // around the reference absorbs the breathing/drifting edge.
        view.petState = .idle
        view.advanceFrame(at: 2.0)
        render(view, into: image)
        var retained: [String] = []
        for y in stride(from: 0, to: 220, by: 2) {
            for x in stride(from: 0, to: 220, by: 2) {
                if isTransparent(in: idleReference, x: x, y: y, margin: 3),
                   (image.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                    retained.append("(\(x), \(y))")
                }
            }
        }
        XCTAssertTrue(
            retained.isEmpty,
            "A transparent pet canvas must not retain previous-state pixels: \(retained.prefix(8))"
        )
    }

    @MainActor
    func testWorkingPetKeepsItsActionAfterTheFirstOrbitPass() {
        let view = PetCanvasView(frame: NSRect(x: 0, y: 0, width: 220, height: 220))
        view.petState = .thinking
        view.advanceFrame(at: 0)
        for timestamp in stride(from: 0.25, through: 5, by: 0.25) {
            view.advanceFrame(at: timestamp)
        }

        XCTAssertFalse(
            view.isResting,
            "an active work state must keep animating after the first orbit pass"
        )
    }

    /// True when the pixel and a `margin` neighbourhood around it are all
    /// transparent in the reference, i.e. truly outside the resting pet.
    @MainActor
    private func isTransparent(
        in image: NSBitmapImageRep,
        x: Int,
        y: Int,
        margin: Int
    ) -> Bool {
        for dy in -margin...margin {
            for dx in -margin...margin {
                let px = min(max(x + dx, 0), 219)
                let py = min(max(y + dy, 0), 219)
                if (image.colorAt(x: px, y: py)?.alphaComponent ?? 0) > 0.1 {
                    return false
                }
            }
        }
        return true
    }

    @MainActor
    func testPartialRedrawClearsInteractionCornersOutsideDirtyRect() {
        let frame = NSRect(x: 0, y: 0, width: 220, height: 220)
        let theme = ThemeCatalog.theme(id: "pinch")
        let view = PetCanvasView(frame: frame)
        view.theme = theme
        let image = makeBitmap(width: 220, height: 220)

        paintLegacyCornerMarks(in: image, theme: theme)
        XCTAssertGreaterThan(image.colorAt(x: 44, y: 65)?.alphaComponent ?? 0, 0.9)
        XCTAssertGreaterThan(image.colorAt(x: 185, y: 75)?.alphaComponent ?? 0, 0.9)
        view.petState = .idle
        render(view, dirtyRect: NSRect(x: 96, y: 96, width: 28, height: 28), into: image)

        XCTAssertFalse(
            (image.colorAt(x: 44, y: 65)?.alphaComponent ?? 0) > 0.1,
            "A partial redraw must clear the former upper-left drag marker"
        )
        XCTAssertFalse(
            (image.colorAt(x: 185, y: 75)?.alphaComponent ?? 0) > 0.1,
            "A partial redraw must clear the former upper-right hover marker"
        )
    }

    @MainActor
    func testPetCanvasDoesNotExposeSystemFocusDecoration() {
        let view = PetCanvasView(frame: NSRect(x: 0, y: 0, width: 220, height: 220))
        let panel = NSPanel(
            contentRect: view.bounds,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.contentView = view

        XCTAssertFalse(view.isOpaque)
        XCTAssertEqual(view.focusRingType, .none)
        XCTAssertFalse(panel.styleMask.contains(.resizable))
        XCTAssertFalse(view.wantsLayer && (view.layer?.isOpaque ?? true))
    }

    @MainActor
    func testPetCanvasUsesDirectTransparentBacking() {
        let view = PetCanvasView(frame: NSRect(x: 0, y: 0, width: 220, height: 220))

        XCTAssertFalse(
            view.wantsLayer,
            "A transparent pet must not retain interaction pixels in a layer-backed contents buffer"
        )
        XCTAssertFalse(view.isOpaque)
        XCTAssertEqual(view.focusRingType, .none)
    }

    @MainActor
    private func render(_ view: PetCanvasView) -> NSBitmapImageRep {
        let image = makeBitmap(width: 220, height: 220)
        render(view, into: image)
        return image
    }

    @MainActor
    private func render(_ view: PetCanvasView, into image: NSBitmapImageRep) {
        render(view, dirtyRect: view.bounds, into: image)
    }

    @MainActor
    private func render(_ view: PetCanvasView, dirtyRect: NSRect, into image: NSBitmapImageRep) {
        let graphicsContext = NSGraphicsContext(bitmapImageRep: image)!
        // AppKit clips an NSView's drawing context to the invalidated region.
        // Keep the bitmap harness faithful to that behavior so stale pixels
        // outside dirtyRect cannot be hidden by an unrestricted test context.
        graphicsContext.cgContext.clip(to: dirtyRect)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        view.draw(dirtyRect)
        graphicsContext.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
    }

    @MainActor
    private func paintLegacyCornerMarks(in image: NSBitmapImageRep, theme: ThemeDefinition) {
        guard let data = image.bitmapData else { return }
        let red = UInt8((theme.palette.highlight.red * 255).rounded())
        let green = UInt8((theme.palette.highlight.green * 255).rounded())
        let blue = UInt8((theme.palette.highlight.blue * 255).rounded())
        for (x, y) in [(44, 65), (185, 75)] {
            let offset = y * image.bytesPerRow + x * 4
            data[offset] = red
            data[offset + 1] = green
            data[offset + 2] = blue
            data[offset + 3] = 255
        }
    }

    private func paintCornerAsset(in image: NSBitmapImageRep, theme: ThemeDefinition) {
        guard let data = image.bitmapData else { return }
        let red = UInt8((theme.palette.highlight.red * 255).rounded())
        let green = UInt8((theme.palette.highlight.green * 255).rounded())
        let blue = UInt8((theme.palette.highlight.blue * 255).rounded())
        for y in 0..<16 {
            for x in 0..<16 {
                let offset = y * image.bytesPerRow + x * 4
                data[offset] = red
                data[offset + 1] = green
                data[offset + 2] = blue
                data[offset + 3] = 255
            }
        }
    }

    private func hasOpaqueCornerPixel(in image: NSBitmapImageRep) -> Bool {
        for y in 10..<45 {
            for x in 10..<45 {
                if (image.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.8 {
                    return true
                }
            }
        }
        return false
    }

    /// True when `image` paints an opaque pixel the reference leaves
    /// transparent, i.e. decoration reaches beyond the resting silhouette.
    @MainActor
    private func paintsBeyondReference(_ image: NSBitmapImageRep, reference: NSBitmapImageRep) -> Bool {
        for y in stride(from: 0, to: 220, by: 2) {
            for x in stride(from: 0, to: 220, by: 2) {
                let referenceAlpha = reference.colorAt(x: x, y: y)?.alphaComponent ?? 0
                let alpha = image.colorAt(x: x, y: y)?.alphaComponent ?? 0
                if referenceAlpha <= 0.1, alpha > 0.1 {
                    return true
                }
            }
        }
        return false
    }

    private func makeBitmap(width: Int, height: Int) -> NSBitmapImageRep {
        NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
    }

    private func isHighlightPixel(
        in image: NSBitmapImageRep,
        x: Int,
        y: Int,
        theme: ThemeDefinition
    ) -> Bool {
        guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
            return false
        }
        let expected = theme.palette.highlight
        let expectedColor = NSColor(
            calibratedRed: expected.red,
            green: expected.green,
            blue: expected.blue,
            alpha: 1
        ).usingColorSpace(.deviceRGB)
        guard let expectedColor else { return false }
        return color.alphaComponent > 0.9
            && abs(color.redComponent - expectedColor.redComponent) < 0.03
            && abs(color.greenComponent - expectedColor.greenComponent) < 0.03
            && abs(color.blueComponent - expectedColor.blueComponent) < 0.03
    }
}
