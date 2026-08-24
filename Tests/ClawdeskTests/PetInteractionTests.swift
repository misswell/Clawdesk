import Foundation
import XCTest
@testable import Clawdesk

final class PetInteractionTests: XCTestCase {
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
