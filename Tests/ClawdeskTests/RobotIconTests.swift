import AppKit
import XCTest
@testable import Clawdesk

final class RobotIconTests: XCTestCase {
    func testMenuBarImageIsARoundPetFaceWithTwoEyeHoles() throws {
        let image = RobotIcon.menuBarImage()

        XCTAssertEqual(image.size.width, 18, accuracy: 0.001)
        XCTAssertEqual(image.size.height, 18, accuracy: 0.001)
        XCTAssertTrue(image.isTemplate)

        let rendered = try render(image)
        XCTAssertGreaterThan(alpha(at: (9, 9), in: rendered), 0.9)
        XCTAssertGreaterThan(alpha(at: (3, 9), in: rendered), 0.9)
        XCTAssertLessThan(alpha(at: (1, 9), in: rendered), 0.1)
        XCTAssertLessThan(alpha(at: (3, 3), in: rendered), 0.1)

        // The centre of each vertical capsule is transparent, while the
        // space between the eyes remains part of the circular body.
        XCTAssertLessThan(alpha(at: (6, 9), in: rendered), 0.1)
        XCTAssertLessThan(alpha(at: (11, 9), in: rendered), 0.1)
        XCTAssertGreaterThan(alpha(at: (9, 9), in: rendered), 0.9)
    }

    private func render(_ image: NSImage) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 18,
            pixelsHigh: 18,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(
            in: NSRect(x: 0, y: 0, width: 18, height: 18),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }

    private func alpha(at point: (x: Int, y: Int), in image: NSBitmapImageRep) -> CGFloat {
        image.colorAt(x: point.x, y: point.y)?.alphaComponent ?? 0
    }
}
