import CoreGraphics
import Foundation

/// One projected eye on the sphere: position plus the 2x2 tangent matrix
/// (SVG matrix(a,b,c,d) convention) and the facing depth.
public struct BloubEyePose: Equatable, Sendable {
    public var x: CGFloat
    public var y: CGFloat
    public var a: CGFloat
    public var b: CGFloat
    public var c: CGFloat
    public var d: CGFloat
    /// z component of the normal: > 0 means front-facing.
    public var depth: CGFloat

    public init(x: CGFloat, y: CGFloat, a: CGFloat, b: CGFloat, c: CGFloat, d: CGFloat, depth: CGFloat) {
        self.x = x
        self.y = y
        self.a = a
        self.b = b
        self.c = c
        self.d = d
        self.depth = depth
    }
}

/// Per-eye capsule configuration in ball-radius units.
public struct BloubEyeConfig: Equatable, Sendable {
    /// Local width (short axis of the capsule).
    public var width: CGFloat
    /// Local height (long axis).
    public var height: CGFloat
    /// 1 = open, 0 = closed.
    public var openness: CGFloat
    /// Own capsule tilt in degrees, positive = top leans right. Applied after
    /// the sphere tangent frame; mirror-image tilts (anger, sadness) are
    /// impossible with head roll alone.
    public var tilt: CGFloat

    public init(width: CGFloat, height: CGFloat, openness: CGFloat = 1, tilt: CGFloat = 0) {
        self.width = width
        self.height = height
        self.openness = openness
        self.tilt = tilt
    }

    public static func pair(_ width: CGFloat, _ height: CGFloat) -> [BloubEyeConfig] {
        [BloubEyeConfig(width: width, height: height), BloubEyeConfig(width: width, height: height)]
    }
}

extension Array where Element == BloubEyeConfig {
    /// Two identical eyes.
    public static func pair(_ width: CGFloat, _ height: CGFloat) -> [BloubEyeConfig] {
        BloubEyeConfig.pair(width, height)
    }

    /// Two identical eyes with mirrored own-tilts and shared openness.
    public static func mirrored(
        _ width: CGFloat,
        _ height: CGFloat,
        _ tilt: CGFloat = 0,
        _ openness: CGFloat = 1
    ) -> [BloubEyeConfig] {
        [
            BloubEyeConfig(width: width, height: height, openness: openness, tilt: tilt),
            BloubEyeConfig(width: width, height: height, openness: openness, tilt: -tilt)
        ]
    }
}

/// The eyes are painted on a sphere, not laid flat.
///
/// Measured on the reference video: the edge-nearest eye is 0.69x the width of
/// the other and its area 0.663x — exactly the depth factor (z = 0.669) of a
/// sphere point at that distance. So a true head orientation is modelled and
/// each eye receives the sphere tangent frame, projected orthographically; the
/// compression and inclination follow by themselves. That is what gives the
/// volume. The constants come from a model fit against frame-by-frame
/// measurements (residual ~1 px at radius 190), not hand tuning.
public enum BloubFace {
    /// Half-separation of the eyes on the sphere, degrees (~31° total).
    public static let eyeSplit: CGFloat = 15.46
    /// Rest eye size, ball-radius units.
    public static let eyeWidth: CGFloat = 0.186
    public static let eyeHeight: CGFloat = 0.412

    private static func degrees(_ value: CGFloat) -> CGFloat {
        value * .pi / 180
    }

    /// Rotates two vectors of an orthonormal basis within their common plane.
    private static func spin(
        _ u: (CGFloat, CGFloat, CGFloat),
        _ v: (CGFloat, CGFloat, CGFloat),
        _ angle: CGFloat
    ) -> ((CGFloat, CGFloat, CGFloat), (CGFloat, CGFloat, CGFloat)) {
        let c = cos(angle)
        let s = sin(angle)
        return (
            (u.0 * c + v.0 * s, u.1 * c + v.1 * s, u.2 * c + v.2 * s),
            (v.0 * c - u.0 * s, v.1 * c - u.1 * s, v.2 * c - u.2 * s)
        )
    }

    /// Head basis then the two eyes.
    ///
    /// Screen basis: x right, y down, z towards the viewer. Index 0 is the
    /// inner eye, index 1 the outer one.
    public static func eyePoses(
        gaze: BloubGaze,
        scale: CGFloat,
        split: CGFloat = BloubFace.eyeSplit
    ) -> [BloubEyePose] {
        var f: (CGFloat, CGFloat, CGFloat) = (0, 0, 1)
        var right: (CGFloat, CGFloat, CGFloat) = (1, 0, 0)
        var down: (CGFloat, CGFloat, CGFloat) = (0, 1, 0)

        // Yaw: forward tilts towards right.
        (f, right) = spin(f, right, degrees(gaze.yaw))
        // Pitch: forward tilts upward (opposite of down).
        (down, f) = spin(down, f, degrees(gaze.pitch))
        // Roll: the head tilts in its own plane.
        (right, down) = spin(right, down, degrees(gaze.roll))

        func build(_ side: CGFloat) -> BloubEyePose {
            let (ef, er) = spin(f, right, degrees(split * side))
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

    /// The blink is a vertical squash in screen space around the eye centre
    /// (bbox width conserved, height falls to ~0.35), not a shrink along the
    /// capsule's own tilted axis. It composes after the tangent frame, which
    /// is why it only scales the y outputs.
    public static func blinkScale(_ lid: CGFloat) -> CGFloat {
        0.06 + 0.94 * BloubEase.clamp01(lid)
    }
}
