import CoreGraphics
import Foundation

/// Analytic body shapes offered by the appearance customizer.
///
/// Unlike the animation silhouettes in `BloubProfileFixture` (measured on the
/// reference video), these are constructed analytically — two distinct
/// sources, deliberately: animated states stay faithful to the video, the
/// resting body is a user choice. Every shape is expressed as a
/// `RadialProfile`, so a custom body morphs into every state with the same
/// linear radius interpolation; no shape owns a second animation system.
public enum BloubShapeID: String, CaseIterable, Sendable, Equatable {
    case circle
    case pebble
    case squircle
    case capsule
    case triangle
    case hexagon
    case cloud
    case droplet

    /// Display names stay untranslated, like theme names.
    public var displayName: String {
        switch self {
        case .circle: return "Circle"
        case .pebble: return "Pebble"
        case .squircle: return "Squircle"
        case .capsule: return "Capsule"
        case .triangle: return "Triangle"
        case .hexagon: return "Hexagon"
        case .cloud: return "Cloud"
        case .droplet: return "Droplet"
        }
    }
}

public struct BloubShape: Equatable, Sendable {
    public let id: BloubShapeID
    public let profile: RadialProfile
}

public enum BloubShapeCatalog {
    /// Brings the peak radius to `max` so every shape weighs the same to
    /// the eye.
    private static func normalize(_ radii: [CGFloat], _ max: CGFloat = 1) -> [CGFloat] {
        guard let peak = radii.max(), peak > 0 else { return radii }
        let k = max / peak
        return radii.map { $0 * k }
    }

    /// Superellipse |x/sx|^n + |y/sy|^n = 1. n = 2 is an ellipse, n ~ 4 the
    /// customizer squircle.
    static func superellipseProfile(_ n: CGFloat, sx: CGFloat = 1, sy: CGFloat = 1) -> [CGFloat] {
        (0..<RadialProfile.sampleCount).map { index in
            let theta = CGFloat(index) / CGFloat(RadialProfile.sampleCount) * .pi * 2
            let c = pow(abs(cos(theta) / sx), n)
            let s = pow(abs(sin(theta) / sy), n)
            return pow(c + s, -1 / n)
        }
    }

    /// Radial profile of the UNION of discs: r(theta) is the farthest
    /// ray/circle intersection. Exact while the origin is inside the union —
    /// which is what gives the cloud its bumps without path booleans.
    static func unionOfCirclesProfile(_ circles: [(x: CGFloat, y: CGFloat, r: CGFloat)]) -> [CGFloat] {
        (0..<RadialProfile.sampleCount).map { index in
            let theta = CGFloat(index) / CGFloat(RadialProfile.sampleCount) * .pi * 2
            let dx = cos(theta)
            let dy = sin(theta)
            var best: CGFloat = 0
            for circle in circles {
                let b = dx * circle.x + dy * circle.y
                let disc = b * b - (circle.x * circle.x + circle.y * circle.y - circle.r * circle.r)
                guard disc >= 0 else { continue }
                let t = b + disc.squareRoot()
                if t > best { best = t }
            }
            return best
        }
    }

    /// Polygon with rounded corners, by Minkowski sum with a disc: every edge
    /// is pushed out by `rc`, every vertex becomes an arc of radius `rc`.
    /// Expects a clockwise polygon in screen space (y down).
    private static func roundedPolygon(_ verts: [CGPoint], _ rc: CGFloat, arcSteps: Int = 10) -> [CGPoint] {
        let count = verts.count
        var out: [CGPoint] = []
        func normal(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
            let dx = b.x - a.x
            let dy = b.y - a.y
            let len = max(1, (dx * dx + dy * dy).squareRoot())
            // Clockwise + y down: the outward normal is (dy, -dx).
            return atan2(-dx / len, dy / len)
        }
        for i in 0..<count {
            let prev = verts[(i - 1 + count) % count]
            let cur = verts[i]
            let next = verts[(i + 1) % count]
            let a0 = normal(prev, cur)
            let a1 = normal(cur, next)
            var d = a1 - a0
            while d > .pi { d -= .pi * 2 }
            while d < -.pi { d += .pi * 2 }
            for k in 0...arcSteps {
                let a = a0 + (d * CGFloat(k)) / CGFloat(arcSteps)
                out.append(CGPoint(x: cur.x + cos(a) * rc, y: cur.y + sin(a) * rc))
            }
        }
        return out
    }

    /// Regular polygon with rounded corners, inscribed in `radius`.
    static func regularPolygonProfile(
        _ sides: Int,
        _ radius: CGFloat,
        _ rc: CGFloat,
        rotationDeg: CGFloat = 0
    ) -> RadialProfile {
        let rot = rotationDeg * .pi / 180
        let verts = (0..<sides).map { index -> CGPoint in
            // Clockwise on screen: theta grows with y down.
            let a = rot + (CGFloat(index) / CGFloat(sides)) * .pi * 2
            return CGPoint(x: cos(a) * (radius - rc), y: sin(a) * (radius - rc))
        }
        return BloubShapeFactory.profile(fromPolygon: roundedPolygon(verts, rc), center: .zero)
    }

    public static let shapes: [BloubShape] = {
        // Pebble: a circle deformed by two low harmonics — irregular but smooth.
        let pebble = normalize(
            (0..<RadialProfile.sampleCount).map { index in
                let a = CGFloat(index) / CGFloat(RadialProfile.sampleCount) * .pi * 2
                return 1 + 0.075 * cos(2 * a + 0.5) + 0.035 * cos(3 * a + 2.1)
            },
            1.02
        )
        // Cloud: union of bumps, wide at the bottom, two lobes on top.
        let cloud = normalize(
            unionOfCirclesProfile([
                (x: -0.44, y: 0.2, r: 0.54),
                (x: 0.46, y: 0.2, r: 0.5),
                (x: 0.02, y: 0.3, r: 0.6),
                (x: -0.24, y: -0.3, r: 0.48),
                (x: 0.3, y: -0.24, r: 0.44)
            ]),
            1.02
        )
        // Droplet: a big disc at the bottom, a thin tip on top.
        let droplet = normalize(
            BloubShapeFactory.profile(
                fromPolygon: BloubShapeFactory.hullOfCircles(0, 0.28, 0.66, 0, -0.96, 0.05),
                center: .zero
            ).radii,
            1.04
        )
        // Lying capsule: hull of two side-by-side discs.
        let capsule = BloubShapeFactory.profile(
            fromPolygon: BloubShapeFactory.hullOfCircles(-0.42, 0, 0.62, 0.42, 0, 0.62),
            center: .zero
        )
        return [
            BloubShape(id: .circle, profile: .circle(1)),
            BloubShape(id: .pebble, profile: RadialProfile(radii: pebble)),
            // 1.15 and not 1.02: on a superellipse the maximal radius is the
            // diagonal, so normalising on it keeps the squircle from looking
            // smaller than the circle.
            BloubShape(id: .squircle, profile: RadialProfile(radii: normalize(superellipseProfile(4.2), 1.15))),
            BloubShape(id: .capsule, profile: capsule),
            // -90°: one vertex towards the top of the screen (y points down).
            BloubShape(id: .triangle, profile: regularPolygonProfile(3, 1.12, 0.34, rotationDeg: -90)),
            // 0°: vertices left and right, so flat edges on top and bottom.
            BloubShape(id: .hexagon, profile: regularPolygonProfile(6, 1.04, 0.26, rotationDeg: 0)),
            BloubShape(id: .cloud, profile: RadialProfile(radii: cloud)),
            BloubShape(id: .droplet, profile: RadialProfile(radii: droplet))
        ]
    }()

    public static func shape(_ id: BloubShapeID) -> BloubShape {
        shapes.first { $0.id == id } ?? shapes[0]
    }
}

/// Body colour identifiers of the appearance customizer.
public enum BloubColorID: String, CaseIterable, Sendable, Equatable {
    case ink
    case brown
    case red
    case orange
    case amber
    case green
    case teal
    case blue
    case violet
    case pink
    case gray
    case cream
    /// Keeps following the active theme palette; the customizer default.
    case theme

    public var hex: UInt32? {
        switch self {
        case .ink: return 0x0a0a0c
        case .brown: return 0x8b5e3c
        case .red: return 0xe8483f
        case .orange: return 0xf08a24
        case .amber: return 0xf0b429
        case .green: return 0x3ecf8e
        case .teal: return 0x2fbfa0
        case .blue: return 0x3b93f0
        case .violet: return 0x8b5cf6
        case .pink: return 0xe152b0
        case .gray: return 0xa3a3a3
        case .cream: return 0xf1efe9
        case .theme: return nil
        }
    }

    /// Display names stay untranslated, like theme names.
    public var displayName: String {
        switch self {
        case .ink: return "Ink"
        case .brown: return "Brown"
        case .red: return "Red"
        case .orange: return "Orange"
        case .amber: return "Amber"
        case .green: return "Green"
        case .teal: return "Teal"
        case .blue: return "Blue"
        case .violet: return "Violet"
        case .pink: return "Pink"
        case .gray: return "Gray"
        case .cream: return "Cream"
        case .theme: return "Theme"
        }
    }
}
