import Foundation
import XCTest
@testable import Clawdesk

final class PetInteractionTests: XCTestCase {
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

        view.setPointerLocation(NSPoint(x: 720, y: 520))

        XCTAssertGreaterThan(view.pointerOffset.x, 0)
        XCTAssertGreaterThan(view.pointerOffset.y, 0)
    }

    func testDragAnchorUsesStableScreenDelta() {
        let anchor = PetDragAnchor(
            windowOrigin: CGPoint(x: 100, y: 200),
            pointerOrigin: CGPoint(x: 120, y: 240)
        )

        XCTAssertEqual(anchor.windowOrigin(for: CGPoint(x: 120, y: 240)), CGPoint(x: 100, y: 200))
        XCTAssertEqual(anchor.windowOrigin(for: CGPoint(x: 180, y: 300)), CGPoint(x: 160, y: 260))
    }

    func testPointerOffsetFollowsCursorAndClampsAtPetEdges() {
        let bounds = CGRect(x: 0, y: 0, width: 240, height: 240)

        XCTAssertEqual(PetPointerMapper.offset(for: CGPoint(x: 120, y: 120), in: bounds), .zero)

        let rightAndAbove = PetPointerMapper.offset(for: CGPoint(x: 240, y: 240), in: bounds)
        XCTAssertEqual(rightAndAbove.x, 5, accuracy: 0.001)
        XCTAssertEqual(rightAndAbove.y, 4, accuracy: 0.001)

        let leftAndBelow = PetPointerMapper.offset(for: CGPoint(x: 0, y: 0), in: bounds)
        XCTAssertEqual(leftAndBelow.x, -5, accuracy: 0.001)
        XCTAssertEqual(leftAndBelow.y, -4, accuracy: 0.001)
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
}
