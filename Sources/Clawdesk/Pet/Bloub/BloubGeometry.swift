import CoreGraphics
import Foundation

/// Easing curves measured on the bloub reference video.
///
/// Body transitions are exponential ease-outs without overshoot; the only
/// local "springs" (notification pop, eye opening) are written directly into
/// the state that owns them. Do not add a general spring here: keeping bloub's
/// visual language matters more than matching AppKit habits.
public enum BloubEase {
    public static func clamp01(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }

    public static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
        a + (b - a) * t
    }

    public static func easeOutCubic(_ t: CGFloat) -> CGFloat {
        let c = clamp01(t)
        return 1 - pow(1 - c, 3)
    }

    public static func easeInOutCubic(_ t: CGFloat) -> CGFloat {
        let c = clamp01(t)
        return c < 0.5 ? 4 * c * c * c : 1 - pow(-2 * c + 2, 3) / 2
    }

    public static func easeOutQuint(_ t: CGFloat) -> CGFloat {
        let c = clamp01(t)
        return 1 - pow(1 - c, 5)
    }
}

/// Deterministic PRNG (mulberry32) ported from bloub's `createRng`.
///
/// Decoration tables (orbit rings, particles, comet ribbons) are pre-drawn
/// from fixed seeds, so identical seeds must reproduce the upstream sequence
/// exactly. All arithmetic stays in UInt32 to match JavaScript's `Math.imul`
/// semantics bit for bit.
public struct BloubRandom {
    private var state: UInt32

    public init(seed: UInt32) {
        state = seed
    }

    public mutating func next() -> Double {
        state &+= 0x6d2b79f5
        var value = (state ^ (state >> 15)) &* (state | 1)
        value = (value &+ ((value ^ (value >> 7)) &* (value | 61))) ^ value
        return Double(value ^ (value >> 14)) / 4_294_967_296
    }
}

/// A radial silhouette sampled at a fixed number of angles.
///
/// Every bloub shape is expressed as `r(theta)` over the same sample angles,
/// so any two shapes correspond point for point and morphing reduces to a
/// linear interpolation of radii — no path-morphing library needed. This is
/// the geometry seam that keeps every state morphable with every other one.
public struct RadialProfile: Equatable, Sendable {
    public static let sampleCount = 64

    public var radii: [CGFloat]

    public init(radii: [CGFloat]) {
        precondition(radii.count == Self.sampleCount, "profiles share one sample count")
        self.radii = radii
    }

    /// Perfect circle: the neutral base for dots, bubbles and fade targets.
    public static func circle(_ radius: CGFloat) -> RadialProfile {
        RadialProfile(radii: [CGFloat](repeating: radius, count: sampleCount))
    }

    /// Linear interpolation of two profiles. Endpoints are exact, so a finished
    /// morph never leaves residue behind.
    public static func interpolate(
        from: RadialProfile,
        to: RadialProfile,
        progress: CGFloat
    ) -> RadialProfile {
        let t = BloubEase.clamp01(progress)
        var radii = [CGFloat](repeating: 0, count: sampleCount)
        for index in 0..<sampleCount {
            radii[index] = BloubEase.lerp(from.radii[index], to.radii[index], t)
        }
        return RadialProfile(radii: radii)
    }

    /// Radius in an arbitrary direction, interpolated between the two
    /// neighbouring samples. Used to re-seat features that sit "on" the body
    /// (eyes, the notification badge) when the silhouette is not a circle.
    public func radius(atAngle angle: CGFloat) -> CGFloat {
        let count = CGFloat(radii.count)
        let t = angle.truncatingRemainder(dividingBy: .pi * 2)
        let normalized = ((t < 0 ? t + .pi * 2 : t) / (.pi * 2)) * count
        let index = Int(normalized)
        let fraction = normalized - CGFloat(index)
        return BloubEase.lerp(
            radii[index % radii.count],
            radii[(index + 1) % radii.count],
            fraction
        )
    }
}

/// The bloub body: a radial profile plus its pose.
public struct BloubBody: Equatable, Sendable {
    public var profile: RadialProfile
    /// Profile rotation, in radians.
    public var rotation: CGFloat
    /// Center offset in ball-radius units.
    public var center: CGPoint
    /// Squash & stretch applied in screen space (after rotation).
    public var scale: CGSize
    public var opacity: CGFloat

    public init(
        profile: RadialProfile,
        rotation: CGFloat = 0,
        center: CGPoint = .zero,
        scale: CGSize = CGSize(width: 1, height: 1),
        opacity: CGFloat = 1
    ) {
        self.profile = profile
        self.rotation = rotation
        self.center = center
        self.scale = scale
        self.opacity = opacity
    }

    /// Interpolation of two bodies. Rotation takes the shortest path so a
    /// spinning profile never winds the long way around.
    public static func blend(_ a: BloubBody, _ b: BloubBody, _ t: CGFloat) -> BloubBody {
        var dRot = b.rotation - a.rotation
        while dRot > .pi { dRot -= .pi * 2 }
        while dRot < -.pi { dRot += .pi * 2 }
        return BloubBody(
            profile: .interpolate(from: a.profile, to: b.profile, progress: t),
            rotation: a.rotation + dRot * t,
            center: CGPoint(
                x: BloubEase.lerp(a.center.x, b.center.x, t),
                y: BloubEase.lerp(a.center.y, b.center.y, t)
            ),
            scale: CGSize(
                width: BloubEase.lerp(a.scale.width, b.scale.width, t),
                height: BloubEase.lerp(a.scale.height, b.scale.height, t)
            ),
            opacity: BloubEase.lerp(a.opacity, b.opacity, t)
        )
    }

    /// Projects the silhouette into screen points.
    ///
    /// Coordinates are y-down (theta = 0 points right, theta grows clockwise),
    /// centered on the ball origin; `scale` converts radius units to points.
    /// The renderer consumes these points directly.
    public func points(scale: CGFloat) -> [CGPoint] {
        let count = profile.radii.count
        var output = [CGPoint](repeating: .zero, count: count)
        let cosR = cos(rotation)
        let sinR = sin(rotation)
        for index in 0..<count {
            let theta = CGFloat(index) / CGFloat(count) * .pi * 2
            let r = profile.radii[index]
            let x = r * cos(theta)
            let y = r * sin(theta)
            let rx = x * cosR - y * sinR
            let ry = x * sinR + y * cosR
            output[index] = CGPoint(
                x: (rx * self.scale.width + center.x) * scale,
                y: (ry * self.scale.height + center.y) * scale
            )
        }
        return output
    }
}

/// Profile fixtures measured pixel by pixel on the bloub reference video.
///
/// Ported verbatim from `bloub/src/bot/profiles.ts`; do not "clean up" the
/// numbers — they are the compatibility contract with upstream (see
/// `Upstream/MAPPING.md`).
public enum BloubProfileFixture {
    public static let egg = RadialProfile(radii: [
        0.8369, 0.8424, 0.8497, 0.8585, 0.8674, 0.8775, 0.8878, 0.8983,
        0.9089, 0.9185, 0.9288, 0.9374, 0.9445, 0.9504, 0.9543, 0.9559,
        0.9555, 0.9519, 0.9466, 0.9389, 0.9302, 0.9193, 0.9085, 0.8969,
        0.8852, 0.8734, 0.8625, 0.8513, 0.8411, 0.8325, 0.8243, 0.8179,
        0.8137, 0.8112, 0.8102, 0.8128, 0.8178, 0.8262, 0.8374, 0.8518,
        0.8702, 0.8922, 0.9169, 0.9446, 0.9741, 1.0023, 1.0267, 1.0433,
        1.0481, 1.0393, 1.0216, 0.9970, 0.9697, 0.9418, 0.9169, 0.8949,
        0.8760, 0.8604, 0.8490, 0.8394, 0.8337, 0.8314, 0.8305, 0.8326
    ])

    public static let hexagon = RadialProfile(radii: [
        0.9210, 0.9282, 0.9441, 0.9706, 0.9984, 1.0059, 0.9896, 0.9562,
        0.9290, 0.9124, 0.9047, 0.9058, 0.9157, 0.9349, 0.9642, 0.9873,
        0.9882, 0.9665, 0.9336, 0.9105, 0.8968, 0.8918, 0.8955, 0.9080,
        0.9293, 0.9611, 0.9820, 0.9812, 0.9590, 0.9282, 0.9089, 0.8978,
        0.8964, 0.9026, 0.9189, 0.9439, 0.9778, 0.9990, 0.9964, 0.9713,
        0.9439, 0.9274, 0.9196, 0.9206, 0.9308, 0.9502, 0.9799, 1.0121,
        1.0226, 1.0071, 0.9752, 0.9510, 0.9366, 0.9316, 0.9351, 0.9485,
        0.9711, 1.0026, 1.0213, 1.0155, 0.9863, 0.9547, 0.9347, 0.9232
    ])

    public static let triangle = RadialProfile(radii: [
        0.7819, 0.8211, 0.8747, 0.9440, 1.0223, 1.0960, 1.1401, 1.1340,
        1.0808, 1.0047, 0.9265, 0.8603, 0.8104, 0.7730, 0.7450, 0.7273,
        0.7151, 0.7118, 0.7148, 0.7245, 0.7427, 0.7680, 0.8037, 0.8518,
        0.9148, 0.9876, 1.0583, 1.1073, 1.1109, 1.0667, 0.9940, 0.9164,
        0.8482, 0.7948, 0.7555, 0.7261, 0.7056, 0.6925, 0.6859, 0.6869,
        0.6938, 0.7084, 0.7305, 0.7615, 0.8040, 0.8595, 0.9311, 1.0092,
        1.0791, 1.1171, 1.1054, 1.0501, 0.9779, 0.9050, 0.8450, 0.7990,
        0.7656, 0.7413, 0.7258, 0.7160, 0.7146, 0.7204, 0.7330, 0.7528
    ])
}

public enum BloubShapeFactory {
    /// Arbitrary polygon -> radial profile by ray casting from `center`.
    ///
    /// Builds the shapes that do not express naturally as r(theta) (the
    /// tapered "!" bar). Computed once at load, never inside the render loop.
    public static func profile(fromPolygon polygon: [CGPoint], center: CGPoint) -> RadialProfile {
        var radii = [CGFloat](repeating: 0, count: RadialProfile.sampleCount)
        let count = polygon.count
        for k in 0..<RadialProfile.sampleCount {
            let theta = CGFloat(k) / CGFloat(RadialProfile.sampleCount) * .pi * 2
            let dx = cos(theta)
            let dy = sin(theta)
            var best: CGFloat = 0
            for i in 0..<count {
                let a = polygon[i]
                let b = polygon[(i + 1) % count]
                let ex = b.x - a.x
                let ey = b.y - a.y
                let den = dx * ey - dy * ex
                if abs(den) < 1e-9 { continue }
                let px = a.x - center.x
                let py = a.y - center.y
                let t = (px * ey - py * ex) / den
                let u = (px * dy - py * dx) / den
                if t > best && u >= 0 && u <= 1 { best = t }
            }
            radii[k] = best
        }
        return RadialProfile(radii: radii)
    }

    /// Convex hull of two circles: the tapered bar of the upright "!".
    public static func hullOfCircles(
        _ x1: CGFloat, _ y1: CGFloat, _ r1: CGFloat,
        _ x2: CGFloat, _ y2: CGFloat, _ r2: CGFloat,
        steps: Int = 96
    ) -> [CGPoint] {
        let dx = x2 - x1
        let dy = y2 - y1
        let dist = max(1e-6, (dx * dx + dy * dy).squareRoot())
        let base = atan2(dy, dx)
        let ratio = min(1, max(-1, (r1 - r2) / dist))
        let spread = acos(ratio)
        var points: [CGPoint] = []
        let half = steps / 2
        for i in 0...half {
            let a = base + spread + ((.pi * 2 - 2 * spread) * CGFloat(i)) / CGFloat(half)
            points.append(CGPoint(x: x1 + cos(a) * r1, y: y1 + sin(a) * r1))
        }
        for i in 0...half {
            let a = base - spread + ((2 * spread) * CGFloat(i)) / CGFloat(half)
            points.append(CGPoint(x: x2 + cos(a) * r2, y: y2 + sin(a) * r2))
        }
        return points
    }
}

/// Path builders shared by the engine output and the renderer.
public enum BloubPaths {
    /// Closed polyline -> Catmull-Rom cubics.
    ///
    /// With 64 samples, centred tangents are smooth to the pixel even when the
    /// pet window is displayed large; the chain stays short and cheap.
    public static func closed(points: [CGPoint], tension: CGFloat = 1 / 6) -> CGPath {
        let path = CGMutablePath()
        let count = points.count
        guard count >= 3 else {
            path.move(to: points.first ?? .zero)
            path.closeSubpath()
            return path
        }
        path.move(to: points[0])
        for i in 0..<count {
            let p0 = points[(i - 1 + count) % count]
            let p1 = points[i]
            let p2 = points[(i + 1) % count]
            let p3 = points[(i + 2) % count]
            let c1 = CGPoint(
                x: p1.x + (p2.x - p0.x) * tension,
                y: p1.y + (p2.y - p0.y) * tension
            )
            let c2 = CGPoint(
                x: p2.x - (p3.x - p1.x) * tension,
                y: p2.y - (p3.y - p1.y) * tension
            )
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        path.closeSubpath()
        return path
    }

    /// Capsule (stadium) centred on the origin: the exact eye shape.
    /// A rounded rect whose corner radius equals half the shorter side is a
    /// capsule; with equal sides it degenerates to a circle.
    public static func capsule(width: CGFloat, height: CGFloat) -> CGPath {
        let hw = max(width, 0.01) / 2
        let hh = max(height, 0.01) / 2
        let r = min(hw, hh)
        return CGPath(
            roundedRect: CGRect(x: -hw, y: -hh, width: hw * 2, height: hh * 2),
            cornerWidth: r,
            cornerHeight: r,
            transform: nil
        )
    }

    /// Open polyline (exact segments): rendered orbit arc traces.
    public static func polyline(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        return path
    }

    /// Closed polyline (exact segments, no smoothing): dot drop shapes.
    public static func polygon(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }
}
