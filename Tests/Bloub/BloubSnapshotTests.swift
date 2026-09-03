import AppKit
import XCTest
@testable import Clawdesk

/// Snapshot regression for the engine-driven renderer (architecture §37/§38:
/// geometry fixtures are the compatibility contract; snapshots complement
/// them by catching draw-order, clipping and paint regressions that pure
/// numbers cannot see).
///
/// Frames are rendered off-screen through the real `PetCanvasView.draw(_:)`
/// with a pinned state, time and appearance. The off-screen harness shares the
/// production draw path but mirrors the production surface vertically (the
/// layer-backed context handed to `draw` on screen is flipped) — the snapshot
/// pins the harness output, which is deterministic and changes whenever the
/// rendered geometry does.
///
/// Regenerate goldens with `CLAWDESK_UPDATE_BLOUB_SNAPSHOTS=1 swift test`.
final class BloubSnapshotTests: XCTestCase {
    private var snapshotsDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("__Snapshots__", isDirectory: true)
    }

    @MainActor
    private func renderFrame(
        petState: PetState,
        at time: TimeInterval,
        appearance: BloubAppearance = .standard
    ) -> NSBitmapImageRep {
        let view = PetCanvasView(frame: NSRect(x: 0, y: 0, width: 220, height: 220))
        view.theme = ThemeCatalog.theme(id: "pinch")
        view.advanceFrame(at: 0)
        view.bloubAppearance = appearance
        view.petState = petState
        view.advanceFrame(at: time)
        let image = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 220, pixelsHigh: 220,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bitmapFormat: [], bytesPerRow: 0, bitsPerPixel: 0
        )!
        let context = NSGraphicsContext(bitmapImageRep: image)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        view.draw(view.bounds)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return image
    }

    @MainActor
    func testPinnedFramesMatchSnapshots() throws {
        let capsule = BloubAppearance(
            shapeID: BloubShapeID.capsule.rawValue,
            colorID: BloubColorID.green.rawValue,
            expressionID: BloubExpressionID.scared.rawValue
        )
        let cases: [(String, PetState, TimeInterval, BloubAppearance)] = [
            ("idle", .idle, 1.0, .standard),
            ("thinking", .thinking, 1.1, .standard),
            ("working", .typing, 1.0, .standard),
            ("alert", .error, 0.8, .standard),
            ("notify", .notification, 0.9, .standard),
            ("sleep", .sleeping, 0.45, .standard),
            ("orbit", .juggling, 1.2, .standard),
            ("burst", .attention, 0.45, .standard),
            ("capsule-scared", .idle, 2.0, capsule)
        ]
        try FileManager.default.createDirectory(at: snapshotsDirectory, withIntermediateDirectories: true)
        let update = ProcessInfo.processInfo.environment["CLAWDESK_UPDATE_BLOUB_SNAPSHOTS"] == "1"

        for (name, petState, time, appearance) in cases {
            let rendered = renderFrame(petState: petState, at: time, appearance: appearance)
            let goldenURL = snapshotsDirectory.appendingPathComponent("\(name).png")
            if update {
                let data = try XCTUnwrap(rendered.representation(using: .png, properties: [:]))
                try data.write(to: goldenURL)
                continue
            }
            let data = try Data(contentsOf: goldenURL)
            let golden = try XCTUnwrap(NSBitmapImageRep(data: data), name)
            try assertClose(rendered, golden, name)
        }
    }

    /// Pixel comparison with a small per-channel tolerance and a tight budget
    /// of differing pixels: antialiasing jitter on a future OS passes, any
    /// real geometry, draw-order or colour change fails.
    ///
    /// Raw stored components are compared on purpose: a PNG-decoded rep
    /// reports NSCalibratedRGBColorSpace while the in-memory render reports
    /// NSDeviceRGBColorSpace, so a colorspace conversion would shift identical
    /// samples. The raw bytes are the stable contract.
    @MainActor
    private func assertClose(
        _ rendered: NSBitmapImageRep,
        _ golden: NSBitmapImageRep,
        _ name: String
    ) throws {
        XCTAssertEqual(rendered.pixelsWide, golden.pixelsWide, name)
        XCTAssertEqual(rendered.pixelsHigh, golden.pixelsHigh, name)
        let channelEpsilon: CGFloat = 3 / 255
        var differing = 0
        let total = rendered.pixelsWide * rendered.pixelsHigh
        for y in 0..<rendered.pixelsHigh {
            for x in 0..<rendered.pixelsWide {
                let a = rendered.colorAt(x: x, y: y)
                let b = golden.colorAt(x: x, y: y)
                if abs((a?.alphaComponent ?? 0) - (b?.alphaComponent ?? 0)) > 0.02 {
                    differing += 1
                    continue
                }
                if abs((a?.redComponent ?? 0) - (b?.redComponent ?? 0)) > channelEpsilon
                    || abs((a?.greenComponent ?? 0) - (b?.greenComponent ?? 0)) > channelEpsilon
                    || abs((a?.blueComponent ?? 0) - (b?.blueComponent ?? 0)) > channelEpsilon {
                    differing += 1
                }
            }
        }
        let budget = total * 5 / 1000
        XCTAssertLessThanOrEqual(
            differing, budget,
            "\(name): \(differing) of \(total) pixels differ from the snapshot"
        )
    }
}
