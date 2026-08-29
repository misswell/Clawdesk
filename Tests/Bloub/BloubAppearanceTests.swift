import CoreGraphics
import Foundation
import XCTest
@testable import Clawdesk

/// Appearance customizer fixtures and behaviour. Shape radii, expression
/// tables and eye-fit offsets were captured from the upstream TypeScript
/// engine (jeremy-prt/bloub @ b4bb3c1) and lock the Swift port to the same
/// output.
final class BloubAppearanceTests: XCTestCase {
    // MARK: - shapes

    /// Upstream analytic shapes, sampled at four angles.
    func testShapeRadiiFixtures() {
        let fixtures: [BloubShapeID: [(Int, CGFloat)]] = [
            .circle: [(0, 1), (16, 1), (32, 1), (48, 1)],
            .pebble: [(0, 0.976537), (16, 0.898504), (32, 1.009462), (48, 0.842208)],
            .squircle: [(0, 0.959084), (16, 0.959084), (32, 0.959084), (48, 0.959084)],
            .capsule: [(0, 1.04), (16, 0.62), (32, 1.04), (48, 0.62)],
            .triangle: [(0, 0.842931), (16, 0.73), (32, 0.842931), (48, 1.12)],
            .hexagon: [(0, 1.04), (16, 0.9355), (32, 1.04), (48, 0.9355)],
            .cloud: [(0, 0.915748), (16, 0.897208), (32, 0.939025), (48, 0.713737)],
            .droplet: [(0, 0.615104), (16, 0.967921), (32, 0.615104), (48, 1.04)]
        ]
        XCTAssertEqual(Set(fixtures.keys), Set(BloubShapeID.allCases))
        for (id, samples) in fixtures {
            let radii = BloubShapeCatalog.shape(id).profile.radii
            XCTAssertEqual(radii.count, RadialProfile.sampleCount, id.rawValue)
            for (index, expected) in samples {
                XCTAssertEqual(
                    radii[index], expected, accuracy: 1e-5,
                    "\(id.rawValue) sample \(index)"
                )
            }
        }
    }

    func testCustomShapesStayWithinTheirVisualWeight() {
        for shape in BloubShapeCatalog.shapes {
            let peak = shape.profile.radii.max() ?? 0
            XCTAssertLessThanOrEqual(peak, 1.16, "\(shape.id.rawValue) dwarfs the ball")
            XCTAssertGreaterThanOrEqual(shape.profile.radii.min() ?? 0, 0.05)
        }
    }

    // MARK: - expressions

    func testExpressionCatalogFixtures() {
        let fixtures: [BloubExpressionID: (BloubGaze, CGFloat, CGFloat, CGFloat, CGFloat?)] = [
            .neutral: (BloubGaze(yaw: 28.49, pitch: 28.62, roll: -13), 15.46, 0.186, 0.412, nil),
            .attentive: (BloubGaze(yaw: 4, pitch: 5, roll: -4), 16, 0.21, 0.44, nil),
            .surprised: (BloubGaze(yaw: 3, pitch: -3, roll: 0), 19, 0.45, 0.47, nil),
            .excited: (BloubGaze(yaw: 6, pitch: -14, roll: 0), 19.5, 0.4, 0.56, -10),
            .happy: (BloubGaze(yaw: 5, pitch: 9, roll: 0), 17, 0.27, 0.17, 14),
            .gleeful: (BloubGaze(yaw: 4, pitch: 14, roll: 0), 18, 0.34, 0.13, 20),
            .angry: (BloubGaze(yaw: 3, pitch: 7, roll: 0), 17, 0.34, 0.15, 30),
            .sad: (BloubGaze(yaw: 3, pitch: -13, roll: 0), 16, 0.22, 0.4, -28),
            .scared: (BloubGaze(yaw: 2, pitch: -20, roll: 0), 20.5, 0.4, 0.6, nil),
            .suspicious: (BloubGaze(yaw: 12, pitch: 6, roll: -6), 16, 0.21, 0.4, nil),
            .confused: (BloubGaze(yaw: -14, pitch: 3, roll: 8), 16.5, 0.2, 0.44, -18),
            .curious: (BloubGaze(yaw: 16, pitch: -9, roll: -15), 16.5, 0.24, 0.46, -8),
            .proud: (BloubGaze(yaw: 5, pitch: 17, roll: 0), 17, 0.3, 0.15, 18),
            .shy: (BloubGaze(yaw: -19, pitch: -14, roll: -7), 14, 0.17, 0.3, nil),
            .unimpressed: (BloubGaze(yaw: -22, pitch: 2, roll: 0), 16, 0.3, 0.12, nil),
            .sleepy: (BloubGaze(yaw: 6, pitch: -9, roll: -3), 16, 0.2, 0.42, nil)
        ]
        XCTAssertEqual(Set(fixtures.keys), Set(BloubExpressionID.allCases))
        for (id, expectation) in fixtures {
            let expression = BloubExpression.expression(id)
            XCTAssertEqual(expression.gaze.yaw, expectation.0.yaw, accuracy: 1e-9, id.rawValue)
            XCTAssertEqual(expression.gaze.pitch, expectation.0.pitch, accuracy: 1e-9, id.rawValue)
            XCTAssertEqual(expression.gaze.roll, expectation.0.roll, accuracy: 1e-9, id.rawValue)
            XCTAssertEqual(expression.split, expectation.1, accuracy: 1e-9, id.rawValue)
            XCTAssertEqual(expression.eyes[0].width, expectation.2, accuracy: 1e-9, id.rawValue)
            XCTAssertEqual(expression.eyes[0].height, expectation.3, accuracy: 1e-9, id.rawValue)
            if let tilt = expectation.4, id != .confused, id != .curious {
                // Mirrored tilts on the pair (confused/curious are
                // deliberately asymmetric and checked verbatim below).
                XCTAssertEqual(expression.eyes[0].tilt, tilt, accuracy: 1e-9, id.rawValue)
                XCTAssertEqual(expression.eyes[1].tilt, -tilt, accuracy: 1e-9, id.rawValue)
            }
        }
        // Asymmetric eyes survive verbatim: suspicious (one droopy eye) and
        // confused (mismatched sizes and tilts).
        let suspicious = BloubExpression.expression(.suspicious)
        XCTAssertEqual(suspicious.eyes[1].width, 0.22, accuracy: 1e-9)
        XCTAssertEqual(suspicious.eyes[1].height, 0.15, accuracy: 1e-9)
        let confused = BloubExpression.expression(.confused)
        XCTAssertEqual(confused.eyes[1].width, 0.28, accuracy: 1e-9)
        XCTAssertEqual(confused.eyes[1].tilt, 14, accuracy: 1e-9)
        // Sleepy keeps half-closed lids through `open`, like the blink.
        XCTAssertEqual(
            BloubExpression.expression(.sleepy).eyes[0].openness, 0.42, accuracy: 1e-9
        )
    }

    func testExpressionBlendGlidesBetweenConstants() {
        let a = BloubExpression.expression(.neutral)
        let b = BloubExpression.expression(.angry)
        XCTAssertEqual(BloubExpression.blend(a, b, 0).gaze.yaw, a.gaze.yaw, accuracy: 1e-9)
        XCTAssertEqual(BloubExpression.blend(a, b, 1).gaze.yaw, b.gaze.yaw, accuracy: 1e-9)
        let half = BloubExpression.blend(a, b, 0.5)
        XCTAssertEqual(half.gaze.yaw, (a.gaze.yaw + b.gaze.yaw) / 2, accuracy: 1e-9)
        XCTAssertEqual(half.eyes[0].tilt, 15, accuracy: 1e-9)
    }

    // MARK: - eye fit

    /// Upstream solver output for sampled (shape, state, expression) keys.
    func testEyeFitFixtures() {
        let fixtures: [(BloubShapeID, BloubState, BloubExpressionID?, CGFloat, CGFloat)] = [
            (.circle, .idle, nil, 0, 0),
            (.circle, .idle, .angry, 0, 0),
            (.circle, .wide, nil, 0, 0),
            (.pebble, .idle, nil, -0.0118, 0.0205),
            (.pebble, .idle, .angry, 0, 0),
            (.pebble, .idle, .scared, 0, -0.0642),
            (.pebble, .wide, nil, -0.0174, -0.0301),
            (.pebble, .notify, nil, 0.0101, -0.0058),
            (.pebble, .swirl, .sleepy, 0, -0.21),
            (.squircle, .wide, nil, -0.0167, -0.0289),
            (.squircle, .notify, nil, 0.0107, -0.0062),
            (.capsule, .idle, nil, -0.0448, 0.0775),
            (.capsule, .idle, .angry, 0, 0),
            (.capsule, .idle, .scared, 0, -0.2491),
            (.capsule, .wide, nil, -0.3287, -0.1898),
            (.capsule, .notify, nil, 0.0468, 0),
            (.capsule, .swirl, .sleepy, -0.0616, -0.0355),
            (.triangle, .idle, nil, -0.003, 0.0052),
            (.triangle, .wide, nil, -0.1473, -0.2552),
            (.triangle, .notify, nil, 0.1972, 0),
            (.hexagon, .wide, nil, 0, 0),
            (.hexagon, .notify, nil, 0.0136, -0.0235),
            (.cloud, .idle, nil, -0.0171, 0.0296),
            (.cloud, .wide, nil, -0.1447, -0.2506),
            (.droplet, .idle, nil, -0.0171, 0.0296),
            (.droplet, .wide, nil, -0.127, -0.0733),
            (.droplet, .notify, nil, 0.041, 0.0711)
        ]
        for (shape, state, expression, x, y) in fixtures {
            let offset = BloubEyeFit.offset(shape: shape, state: state, expression: expression)
            XCTAssertEqual(offset.x, x, accuracy: 1e-4, "\(shape.rawValue)|\(state.rawValue)|\(String(describing: expression))")
            XCTAssertEqual(offset.y, y, accuracy: 1e-4, "\(shape.rawValue)|\(state.rawValue)|\(String(describing: expression))")
        }
    }

    func testEyeFitUnknownShapeReturnsZero() {
        XCTAssertEqual(
            BloubEyeFit.offset(shape: nil, state: .idle, expression: nil),
            .zero
        )
        XCTAssertEqual(
            BloubEyeFit.offset(shape: .circle, state: .wink, expression: .happy),
            .zero
        )
    }

    // MARK: - engine integration

    func testCustomShapeMorphsTheBodyOnRestStatesOnly() {
        let engine = BloubEngine(radius: 100, initial: .idle)
        // Boot onto the circle first (as the canvas does), then morph.
        engine.setShape(RadialProfile.circle(1), at: 0)
        let capsule = BloubShapeCatalog.shape(.capsule).profile
        engine.setShape(capsule, at: 0)
        // Mid morph the radii sit on the ease-out curve between the two.
        let mid = engine.sample(at: 0.2)
        let midProgress = BloubMotion.easeOutQuint(0.2 / 0.45)
        XCTAssertEqual(mid.body.profile.radii[0], BloubEase.lerp(1, 1.04, CGFloat(midProgress)), accuracy: 1e-6)
        // Settled: the body is the capsule.
        let settled = engine.sample(at: 2.0)
        XCTAssertEqual(settled.body.profile.radii[0], 1.04, accuracy: 1e-6)
        XCTAssertEqual(settled.body.profile.radii[16], 0.62, accuracy: 1e-6)

        // The alert bar draws its own body: a custom shape must not touch it.
        engine.setState(.alert, at: 3.0)
        let alert = engine.sample(at: 4.0)
        XCTAssertEqual(
            alert.body.profile.radii[0],
            BloubStates.catalog[.alert]!.pose(1).body.profile.radii[0],
            accuracy: 1e-9
        )
    }

    func testCustomExpressionAppliesToRestFaceStatesOnly() {
        let engine = BloubEngine(radius: 100, initial: .idle)
        engine.setExpression(BloubExpression.expression(.angry), at: 0)
        let settled = engine.sample(at: 2.0)
        XCTAssertEqual(settled.body.profile.radii[0], 1, accuracy: 1e-9)
        // The angry gaze replaced the resting gaze absolutely; the rest life
        // (angular drift + float) still rides on top.
        let life = BloubMotion.liveliness(at: 2.0)
        // Angry's own roll is 0: the -13 resting head tilt belongs to the
        // neutral face the expression just replaced.
        let expected = BloubFace.eyePoses(
            gaze: BloubGaze(
                yaw: 3 + life.dYaw,
                pitch: 7 + life.dPitch,
                roll: 0 + life.dRoll
            ),
            scale: 100,
            split: 17
        )
        XCTAssertEqual(
            settled.eyes[0].transform.tx,
            expected[0].x + CGFloat(life.driftX) * 100,
            accuracy: 1e-4
        )

        // wide keeps its measured face even with an expression chosen.
        engine.setState(.wide, at: 3.0)
        let wide = engine.sample(at: 4.0)
        XCTAssertEqual(wide.eyes[0].capsuleHeight, 0.875 * 100, accuracy: 1e-6)
    }

    func testEyeFitKeepsCapsulesInsideNarrowBodies() {
        // The actual property the table exists for: with a narrow shape and a
        // demanding state, both capsule tips stay inside the body contour.
        for shape in [BloubShapeID.capsule, .triangle, .droplet] {
            for state in [BloubState.idle, .wide, .notify] {
                let engine = BloubEngine(radius: 100, initial: state)
                engine.setShape(BloubShapeCatalog.shape(shape).profile, at: 0)
                engine.setExpression(BloubExpression.expression(.scared), at: 0)
                let frame = engine.sample(at: 2.0)
                let body = frame.bodyPath()
                for eye in frame.eyes {
                    // Capsule axis runs along local y; render both tips.
                    let top = CGPoint(x: 0, y: -eye.capsuleHeight / 2)
                        .applying(eye.transform)
                    let bottom = CGPoint(x: 0, y: eye.capsuleHeight / 2)
                        .applying(eye.transform)
                    XCTAssertTrue(body.contains(top), "\(shape.rawValue)/\(state.rawValue) top tip out")
                    XCTAssertTrue(body.contains(bottom), "\(shape.rawValue)/\(state.rawValue) bottom tip out")
                }
            }
        }
    }

    func testAppearanceResolutionDegradesGracefully() {
        let standard = BloubAppearance.standard
        XCTAssertEqual(standard.shape.id, .circle)
        XCTAssertNil(standard.bodyColor)
        XCTAssertNil(standard.expression)

        let junk = BloubAppearance(shapeID: "blob", colorID: "rainbow", expressionID: "smug")
        XCTAssertEqual(junk.shape.id, .circle, "unknown shape falls back to the circle")
        XCTAssertNil(junk.bodyColor, "unknown colour defers to the theme")
        XCTAssertNil(junk.expression, "unknown expression falls back to neutral")

        let chosen = BloubAppearance(
            shapeID: BloubShapeID.droplet.rawValue,
            colorID: BloubColorID.green.rawValue,
            expressionID: BloubExpressionID.sleepy.rawValue
        )
        XCTAssertEqual(chosen.shape.id, .droplet)
        XCTAssertEqual(chosen.bodyColor?.green ?? 0, 0xcf / 255.0, accuracy: 1e-9)
        XCTAssertEqual(chosen.expression?.id, .sleepy)
    }

    func testAppearanceCodableRoundTrip() throws {
        let appearance = BloubAppearance(
            shapeID: BloubShapeID.cloud.rawValue,
            colorID: BloubColorID.violet.rawValue,
            expressionID: BloubExpressionID.curious.rawValue
        )
        let data = try JSONEncoder().encode(appearance)
        let decoded = try JSONDecoder().decode(BloubAppearance.self, from: data)
        XCTAssertEqual(decoded, appearance)
    }
}
