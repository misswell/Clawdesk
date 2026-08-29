import CoreGraphics
import Foundation
import XCTest
@testable import Clawdesk

/// Radial geometry contracts and pixel-measured profile fixtures. The fixture
/// numbers were captured by running the upstream TypeScript engine
/// (jeremy-prt/bloub) and must not drift.
final class BloubShapeTests: XCTestCase {
    func testAllProfilesShareOneSampleCount() {
        XCTAssertEqual(RadialProfile.sampleCount, 64)
        for profile in [BloubProfileFixture.egg, BloubProfileFixture.hexagon, BloubProfileFixture.triangle] {
            XCTAssertEqual(profile.radii.count, RadialProfile.sampleCount)
        }
    }

    func testCircleProfileIsConstant() {
        let profile = RadialProfile.circle(1)
        XCTAssertEqual(profile.radii, [CGFloat](repeating: 1, count: 64))
        XCTAssertEqual(profile.radius(atAngle: 0), 1, accuracy: 1e-12)
        XCTAssertEqual(profile.radius(atAngle: 2.4), 1, accuracy: 1e-12)
    }

    /// Measured profiles, first and last samples.
    func testProfileFixtures() {
        XCTAssertEqual(BloubProfileFixture.egg.radii.first ?? 0, CGFloat(0.8369), accuracy: 1e-9)
        XCTAssertEqual(BloubProfileFixture.egg.radii.last ?? 0, CGFloat(0.8326), accuracy: 1e-9)
        XCTAssertEqual(BloubProfileFixture.hexagon.radii.first ?? 0, CGFloat(0.9210), accuracy: 1e-9)
        XCTAssertEqual(BloubProfileFixture.hexagon.radii.last ?? 0, CGFloat(0.9232), accuracy: 1e-9)
        XCTAssertEqual(BloubProfileFixture.triangle.radii.first ?? 0, CGFloat(0.7819), accuracy: 1e-9)
        XCTAssertEqual(BloubProfileFixture.triangle.radii.last ?? 0, CGFloat(0.7528), accuracy: 1e-9)
        // The egg is narrower than tall: radii near the horizontal axis sit
        // below 0.84 while the vertical extremes reach ~1.05.
        XCTAssertLessThan(BloubProfileFixture.egg.radii[0], 0.85)
        XCTAssertGreaterThan(BloubProfileFixture.egg.radii[47], 1.02)
    }

    /// Upstream fixture: radiusAtAngle on the egg profile.
    func testRadiusAtAngleInterpolatesBetweenNeighbouringSamples() {
        let egg = BloubProfileFixture.egg
        XCTAssertEqual(egg.radius(atAngle: 0), 0.8369, accuracy: 1e-6)
        XCTAssertEqual(egg.radius(atAngle: .pi), 0.8137, accuracy: 1e-6)
        XCTAssertEqual(egg.radius(atAngle: 0.03), 0.838581, accuracy: 1e-5)
        // Wraps below the circle: just under theta 0 the radius comes from the
        // last sample lerping towards the first one.
        XCTAssertEqual(egg.radius(atAngle: -0.03), 0.835586, accuracy: 1e-4)
    }

    func testProfileInterpolationEndpointsAreExact() {
        let from = RadialProfile.circle(1)
        let to = BloubProfileFixture.hexagon
        XCTAssertEqual(
            RadialProfile.interpolate(from: from, to: to, progress: 0).radii,
            from.radii
        )
        XCTAssertEqual(
            RadialProfile.interpolate(from: from, to: to, progress: 1).radii,
            to.radii
        )
        let half = RadialProfile.interpolate(from: from, to: to, progress: 0.5)
        XCTAssertEqual(half.radii[0], (1 + to.radii[0]) / 2, accuracy: 1e-12)
        // Out-of-range progress is clamped, never extrapolated.
        XCTAssertEqual(
            RadialProfile.interpolate(from: from, to: to, progress: -3).radii,
            from.radii
        )
    }

    /// Upstream fixture: a posed circle projected at scale 100.
    func testBodyPointProjection() {
        let body = BloubBody(
            profile: .circle(1),
            rotation: 0.5,
            center: CGPoint(x: 0.2, y: -0.1),
            scale: CGSize(width: 1.1, height: 0.9)
        )
        let points = body.points(scale: 100)
        XCTAssertEqual(points.count, 64)
        let expected: [(CGFloat, CGFloat)] = [
            (116.534082, 33.148298),
            (110.900133, 40.68216),
            (104.390765, 47.727924),
            (97.068669, 54.217737)
        ]
        for (index, expectation) in expected.enumerated() {
            XCTAssertEqual(points[index].x, expectation.0, accuracy: 1e-4, "point \(index) x")
            XCTAssertEqual(points[index].y, expectation.1, accuracy: 1e-4, "point \(index) y")
        }
    }

    func testBodyBlendRotatesAlongShortestPath() {
        let a = BloubBody(profile: .circle(1), rotation: 3.0)
        let b = BloubBody(profile: .circle(1), rotation: -3.0)
        let mid = BloubBody.blend(a, b, 0.5)
        // From +3 rad the short way to -3 rad wraps through pi (0.283 rad of
        // travel), not through the long 6 rad road (which would land on 0).
        XCTAssertEqual(mid.rotation, .pi, accuracy: 1e-9)
    }

    func testClosedPathContainsCentreAndStaysSmooth() {
        let points = BloubBody(profile: .circle(1)).points(scale: 100)
        let path = BloubPaths.closed(points: points)
        XCTAssertTrue(path.contains(CGPoint(x: 5, y: -5)))
        XCTAssertFalse(path.contains(CGPoint(x: 150, y: 0)))
        XCTAssertEqual(points.count, 64)
    }

    func testCapsulePathMatchesRequestedStadium() {
        let capsule = BloubPaths.capsule(width: 40, height: 100)
        // Long axis reaches the extremes; short axis half-way.
        XCTAssertTrue(capsule.contains(.zero))
        XCTAssertTrue(capsule.contains(CGPoint(x: 0, y: 49)))
        XCTAssertFalse(capsule.contains(CGPoint(x: 0, y: 51)))
        XCTAssertTrue(capsule.contains(CGPoint(x: 19, y: 0)))
        XCTAssertFalse(capsule.contains(CGPoint(x: 21, y: 0)))
    }

    func testPolygonProfileRayCastsASquare() {
        let square = [
            CGPoint(x: 1, y: 1), CGPoint(x: -1, y: 1),
            CGPoint(x: -1, y: -1), CGPoint(x: 1, y: -1)
        ]
        let profile = BloubShapeFactory.profile(fromPolygon: square, center: .zero)
        XCTAssertEqual(profile.radius(atAngle: 0), 1, accuracy: 1e-6)
        XCTAssertEqual(profile.radius(atAngle: .pi / 4), 1 / cos(.pi / 4), accuracy: 1e-4)
    }

    func testHullOfCirclesProducesTheTaperedBar() {
        let hull = BloubShapeFactory.hullOfCircles(0, -0.505, 0.132, 0, 0.13, 0.075)
        // In the profile's y-down space the bar spans from the top circle's
        // outer edge (-0.505 - 0.132) to the bottom circle's outer edge
        // (0.13 + 0.075).
        let maxY = hull.map { $0.y }.max() ?? 0
        let minY = hull.map { $0.y }.min() ?? 0
        XCTAssertEqual(minY, -0.637, accuracy: 1e-6)
        XCTAssertEqual(maxY, 0.205, accuracy: 1e-6)
    }
}
