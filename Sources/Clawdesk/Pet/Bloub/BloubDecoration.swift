import CoreGraphics
import Foundation

/// A plain RGB colour in the 0...1 space used across the bloub engine.
public struct BloubRGB: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public init(hex: UInt32) {
        red = Double((hex >> 16) & 0xff) / 255
        green = Double((hex >> 8) & 0xff) / 255
        blue = Double(hex & 0xff) / 255
    }
}

/// Centralised bloub colours (architecture rule: no scattered hex literals).
///
/// The arc decorations are not flat colours — the reference video shows a full
/// hue wheel at constant lightness with a gradient along each trace
/// (S 45–62 %, L 50–67 %) — so decoration hues come from `BloubDecor.wheel`
/// while body/eye/notification colours live here.
public struct BloubPalette: Equatable, Sendable {
    /// Body fill ("ink" in bloub; its site default is #17203a).
    public var body: BloubRGB
    /// Eye fill / the colour a hole appears to reveal ("paper" in bloub).
    public var eye: BloubRGB
    /// Notification badge blue, measured on the reference (#2496e8).
    public var notification: BloubRGB

    public init(body: BloubRGB, eye: BloubRGB, notification: BloubRGB) {
        self.body = body
        self.eye = eye
        self.notification = notification
    }

    /// Bloub's own defaults.
    public static let bloub = BloubPalette(
        body: BloubRGB(hex: 0x17203a),
        eye: BloubRGB(red: 1, green: 1, blue: 1),
        notification: BloubRGB(hex: 0x2496e8)
    )
}

/// What a state declares for one dot. All geometry stays in ball-radius units;
/// only the engine knows the pixel scale.
public struct BloubDotSpec: Equatable, Sendable {
    public var x: CGFloat
    public var y: CGFloat
    public var r: CGFloat
    public var opacity: CGFloat
    /// Depth haze: 0 = faded into the background, 1 = full body colour.
    /// Blending happens at render time, which alone knows the chosen colours.
    public var depth: CGFloat?
    /// Non-circular shape in radius units centred on the origin (the tilted
    /// "!" dot is a teardrop). When present, `r` is not used for drawing.
    public var drop: [CGPoint]?
    /// Rotation applied to `drop`, in degrees.
    public var dropRotation: CGFloat

    public init(
        x: CGFloat,
        y: CGFloat,
        r: CGFloat,
        opacity: CGFloat,
        depth: CGFloat? = nil,
        drop: [CGPoint]? = nil,
        dropRotation: CGFloat = 0
    ) {
        self.x = x
        self.y = y
        self.r = r
        self.opacity = opacity
        self.depth = depth
        self.drop = drop
        self.dropRotation = dropRotation
    }
}

/// What a state declares for one elliptical orbit arc.
public struct BloubArcRequest: Equatable, Sendable {
    public var id: String
    public var seed: BloubArcSeed
    public var t: CGFloat
    public var opacity: CGFloat

    public init(id: String, seed: BloubArcSeed, t: CGFloat, opacity: CGFloat) {
        self.id = id
        self.seed = seed
        self.t = t
        self.opacity = opacity
    }
}

/// Seed of a 3D elliptical arc, in ball-radius units.
public struct BloubArcSeed: Equatable, Sendable {
    /// Semi-major axis.
    public var a: CGFloat
    /// Flatness b/a: measured <= 0.45 — orbit planes are seen edge on.
    public var k: CGFloat
    /// On-screen inclination of the major axis, radians.
    public var tilt: CGFloat
    /// Revolutions per second.
    public var speed: CGFloat
    public var phase: CGFloat
    /// Fraction of the revolution actually traced.
    public var sweep: CGFloat
    public var hue: CGFloat
    public var hueSpan: CGFloat
    public var width: CGFloat
    public var cx: CGFloat
    public var cy: CGFloat

    public init(
        a: CGFloat, k: CGFloat, tilt: CGFloat, speed: CGFloat, phase: CGFloat,
        sweep: CGFloat, hue: CGFloat, hueSpan: CGFloat, width: CGFloat,
        cx: CGFloat = 0, cy: CGFloat = 0
    ) {
        self.a = a
        self.k = k
        self.tilt = tilt
        self.speed = speed
        self.phase = phase
        self.sweep = sweep
        self.hue = hue
        self.hueSpan = hueSpan
        self.width = width
        self.cx = cx
        self.cy = cy
    }
}

/// A rendered arc: front/back polylines (each may contain several strokes,
/// the trace crosses the silhouette plane more than once) plus its gradient.
public struct BloubArc: Equatable, Sendable {
    public var id: String
    /// Portions in front of the body.
    public var front: [[CGPoint]]
    /// Portions behind the body (drawn first, so the body occludes them).
    public var back: [[CGPoint]]
    public var width: CGFloat
    public var opacity: CGFloat
    public var gradientStart: CGPoint
    public var gradientEnd: CGPoint
    public var gradientStops: [BloubRGB]

    public init(
        id: String,
        front: [[CGPoint]],
        back: [[CGPoint]],
        width: CGFloat,
        opacity: CGFloat,
        gradientStart: CGPoint,
        gradientEnd: CGPoint,
        gradientStops: [BloubRGB]
    ) {
        self.id = id
        self.front = front
        self.back = back
        self.width = width
        self.opacity = opacity
        self.gradientStart = gradientStart
        self.gradientEnd = gradientEnd
        self.gradientStops = gradientStops
    }
}

/// A rendered dot in screen points.
public struct BloubDot: Equatable, Sendable {
    public var position: CGPoint
    public var radius: CGFloat
    public var opacity: CGFloat
    public var depth: CGFloat?
    public var drop: [CGPoint]?
    public var dropRotation: CGFloat

    public init(spec: BloubDotSpec, scale: CGFloat) {
        position = CGPoint(x: spec.x * scale, y: spec.y * scale)
        radius = spec.r * scale
        opacity = spec.opacity
        depth = spec.depth
        // Drop shapes are declared in radius units like everything else; the
        // engine is the only one that knows the point scale, so it scales the
        // polygon once here and the renderer only translates/rotates it.
        drop = spec.drop?.map { CGPoint(x: $0.x * scale, y: $0.y * scale) }
        dropRotation = spec.dropRotation
    }

    public init(
        position: CGPoint,
        radius: CGFloat,
        opacity: CGFloat,
        depth: CGFloat? = nil,
        drop: [CGPoint]? = nil,
        dropRotation: CGFloat = 0
    ) {
        self.position = position
        self.radius = radius
        self.opacity = opacity
        self.depth = depth
        self.drop = drop
        self.dropRotation = dropRotation
    }
}

/// The notification badge and the concentric notch subtracted from the body.
public struct BloubNotification: Equatable, Sendable {
    public var x: CGFloat
    public var y: CGFloat
    public var r: CGFloat
    public var notch: CGFloat

    public init(x: CGFloat, y: CGFloat, r: CGFloat, notch: CGFloat) {
        self.x = x
        self.y = y
        self.r = r
        self.notch = notch
    }
}

/// Decoration catalogue ported from `bloub/src/bot/decor.ts`.
///
/// Seed values and RNG call order reproduce upstream exactly: the rings,
/// particles and comet ribbons must draw the same shapes as the source.
public enum BloubDecor {
    /// Full hue wheel at constant S/L — the arc colour language. Output is
    /// quantised to 8 bits per channel, exactly like upstream's hex strings,
    /// so fixture comparisons stay exact.
    public static func wheel(hue: Double, s: Double = 0.55, l: Double = 0.62) -> BloubRGB {
        let h = hue.truncatingRemainder(dividingBy: 360)
        let normalized = h < 0 ? h + 360 : h
        let c = (1 - abs(2 * l - 1)) * s
        let x = c * (1 - abs((normalized / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = l - c / 2
        let rgb: (Double, Double, Double)
        switch normalized {
        case ..<60: rgb = (c, x, 0)
        case ..<120: rgb = (x, c, 0)
        case ..<180: rgb = (0, c, x)
        case ..<240: rgb = (0, x, c)
        case ..<300: rgb = (x, 0, c)
        default: rgb = (c, 0, x)
        }
        func quantized(_ v: Double) -> Double {
            ((v + m) * 255).rounded() / 255
        }
        return BloubRGB(
            red: quantized(rgb.0),
            green: quantized(rgb.1),
            blue: quantized(rgb.2)
        )
    }

    /// Projects a tilted 3D circle orthographically and splits the trace into
    /// front (z >= 0) and back (z < 0) polylines. The back half is drawn
    /// before the body so real depth occlusion — not a flat drawing — is what
    /// makes the rings read as orbits.
    public static func arcRender(
        _ seed: BloubArcSeed,
        t: CGFloat,
        scale: CGFloat,
        id: String,
        opacity: CGFloat
    ) -> BloubArc {
        let spin = seed.phase + t * seed.speed * .pi * 2
        let cu = cos(seed.tilt)
        let su = sin(seed.tilt)
        let kz = max(0, 1 - seed.k * seed.k).squareRoot()

        let segments = 64
        let span = seed.sweep * .pi * 2
        var front: [[CGPoint]] = []
        var back: [[CGPoint]] = []
        var currentFront: [CGPoint] = []
        var currentBack: [CGPoint] = []
        var previousBehind: Bool?
        var previousPoint: CGPoint?
        var previousZ: CGFloat?

        func finish(_ run: inout [CGPoint], into output: inout [[CGPoint]]) {
            guard run.count > 1 else {
                run.removeAll(keepingCapacity: true)
                return
            }
            output.append(run)
            run.removeAll(keepingCapacity: true)
        }

        for i in 0...segments {
            let theta = spin + (CGFloat(i) / CGFloat(segments)) * span
            let ct = cos(theta)
            let st = sin(theta)
            let x = seed.a * (ct * cu + st * -su * seed.k) + seed.cx
            let y = seed.a * (ct * su + st * cu * seed.k) + seed.cy
            let z = seed.a * st * kz
            let behind = z < 0
            let point = CGPoint(x: x * scale, y: y * scale)
            if let previousBehind, previousBehind != behind,
               let previousPoint, let previousZ {
                // Split exactly at z = 0. Sharing that crossing point between
                // the two runs prevents a one-sample gap (or a diagonal cap)
                // when an orbit crosses the body's silhouette plane.
                let denominator = previousZ - z
                let ratio = abs(denominator) > 0.000001 ? previousZ / denominator : 0.5
                let crossing = CGPoint(
                    x: previousPoint.x + (point.x - previousPoint.x) * ratio,
                    y: previousPoint.y + (point.y - previousPoint.y) * ratio
                )
                if previousBehind {
                    currentBack.append(crossing)
                    finish(&currentBack, into: &back)
                    currentFront = [crossing, point]
                } else {
                    currentFront.append(crossing)
                    finish(&currentFront, into: &front)
                    currentBack = [crossing, point]
                }
            } else if behind {
                currentBack.append(point)
            } else {
                currentFront.append(point)
            }
            previousBehind = behind
            previousPoint = point
            previousZ = z
        }
        finish(&currentFront, into: &front)
        finish(&currentBack, into: &back)

        let gx = cos(seed.tilt) * seed.a * scale
        let gy = sin(seed.tilt) * seed.a * scale
        return BloubArc(
            id: id,
            front: front,
            back: back,
            width: seed.width * scale,
            opacity: opacity,
            gradientStart: CGPoint(x: seed.cx * scale - gx, y: seed.cy * scale - gy),
            gradientEnd: CGPoint(x: seed.cx * scale + gx, y: seed.cy * scale + gy),
            gradientStops: [
                wheel(hue: seed.hue),
                wheel(hue: seed.hue + seed.hueSpan * 0.5),
                wheel(hue: seed.hue + seed.hueSpan)
            ]
        )
    }

    /// Six orbit rings, semi-major axis 1.30–1.40 (clearly larger than the
    /// ball), flatness <= 0.45, ~3.3 revolutions per second.
    public static let rings: [BloubArcSeed] = {
        var random = BloubRandom(seed: 0xa11ce)
        return (0..<6).map { index in
            BloubArcSeed(
                a: 1.3 + random.next() * 0.1,
                k: 0.05 + random.next() * 0.4,
                tilt: (CGFloat(index) / 6) * .pi + random.next() * 0.5,
                speed: 3 + random.next() * 0.7,
                phase: random.next() * .pi * 2,
                sweep: 0.6 + random.next() * 0.25,
                hue: (CGFloat(index) * 360) / 6 + random.next() * 30,
                hueSpan: 60 + random.next() * 60,
                width: 0.05 + random.next() * 0.012,
                cx: 0,
                cy: 0.1
            )
        }
    }()

    /// Nested arc bouquet sweeping across the triangle just before orbit.
    public static let swoosh: [BloubArcSeed] = {
        (0..<4).map { index in
            BloubArcSeed(
                a: 0.78 + CGFloat(index) * 0.2,
                k: 0.05 + CGFloat(index) * 0.02,
                tilt: -0.62 + CGFloat(index) * 0.05,
                speed: 0.3,
                phase: 0.06 * CGFloat(index),
                sweep: 0.4,
                hue: 95 + CGFloat(index) * 62,
                hueSpan: 100,
                width: 0.05,
                cx: 0,
                cy: -0.12
            )
        }
    }()

    /// Three-dot x positions measured on the reference: -0.557 / -0.013 / +0.532.
    public static let dotX: [CGFloat] = [-0.557, -0.013, 0.532]
    public static let dotR: CGFloat = 0.165
    public static let dotPeak: CGFloat = 1.25

    /// Burst particles: they do not fly straight — they spiral towards the
    /// centre (radius ×0.75 per unit, angle +100°/s) while growing, and pass
    /// behind the core, where they are swallowed.
    public static func burstParticles(at t: CGFloat) -> [BloubDotSpec] {
        var output: [BloubDotSpec] = []
        for particle in particleTable {
            let u = t - particle.birth
            if u < 0 || u > 0.62 { continue }
            let rho = particle.rho * pow(CGFloat(0.75), u * 10)
            let a = particle.angle + (u * 100 * .pi) / 180
            output.append(BloubDotSpec(
                x: cos(a) * rho,
                y: sin(a) * rho,
                r: 0.04 + 0.028 * BloubEase.clamp01(u / 0.55),
                opacity: BloubEase.clamp01(u / 0.06) * BloubEase.clamp01((0.62 - u) / 0.08),
                depth: BloubEase.clamp01(1 - rho / 0.8)
            ))
        }
        return output
    }

    private static let particleTable: [(birth: CGFloat, angle: CGFloat, rho: CGFloat)] = {
        var random = BloubRandom(seed: 0xbeef)
        return (0..<5).map { index in
            (
                birth: CGFloat(index) * 0.2,
                angle: random.next() * .pi * 2,
                rho: 0.58 + random.next() * 0.18
            )
        }
    }()

    /// Comet: the dot stays centred while its trail orbits it. Ellipse
    /// a = 0.85, b = 0.15, major axis inclined +34°, four ribbons, ~210°/s.
    public static let cometRibbons: [BloubArcSeed] = {
        var random = BloubRandom(seed: 0xc0e7)
        return (0..<4).map { index in
            let d = CGFloat(index) - 1.5
            return BloubArcSeed(
                a: 0.85 * (1 + d * 0.03),
                k: (0.15 / 0.85) * (1 + d * 0.16),
                tilt: (34 * .pi) / 180 + d * 0.035,
                speed: 210 / 360,
                phase: -CGFloat(index) * 0.045 + random.next() * 0.012,
                sweep: 0.34,
                hue: CGFloat(index) * 85 + random.next() * 20,
                hueSpan: 80,
                width: 0.095,
                cx: 0,
                cy: 0
            )
        }
    }()

    /// Comet dot radius, measured at 0.129.
    public static let cometDot: CGFloat = 0.129

    /// Notification badge blue, measured pixel by pixel.
    public static let notifColor = BloubRGB(hex: 0x2496e8)
    /// The badge sits exactly on the circumference, at -42°.
    public static let notifAngle: CGFloat = -42
    public static let notifDist: CGFloat = 1.003
    /// Radius at rest; the pop peaks 14 % above.
    public static let notifR: CGFloat = 0.15
    public static let notifPop: CGFloat = 1.14
    /// The notch is a concentric disc subtracted from the body; the margin is
    /// constant (0.054 R) and follows the body scale.
    public static let notifMargin: CGFloat = 0.054
}
