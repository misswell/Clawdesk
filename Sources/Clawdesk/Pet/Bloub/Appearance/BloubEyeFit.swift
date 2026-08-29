import CoreGraphics
import Foundation

/// Where to seat the face on a custom body shape.
///
/// The eyes live on a sphere and `radiusAtAngle` re-seats their CENTRE on the
/// real contour, but an eye has a size: the margin left in front of the edge
/// shrinks by the same factor, so a silhouette narrow in the eye's direction
/// pushes the capsule against the border until the body-mask opens a notch
/// outward. This module solves the problem ONCE, at table-build time, and
/// returns a table of translations.
///
/// Solving inside the render loop would react to everything moving at sixty
/// frames per second — the gaze drift, the pointer, a mid-morph expression.
/// Seven such variants were written upstream and all produced visible motion
/// artefacts. The engine's other inputs are DECLARED and interpolated between
/// with known curves; a tabulated offset fits that mould: between two shape
/// or expression changes it does not move at all, and across a change it goes
/// from one constant to another on that morph's curve. Trembling becomes
/// impossible by construction. Corollary: the solver needs no continuity
/// constraint, since it never runs during animation — it can probe a whole
/// bundle of directions and cover the worst case of the gaze drift.

/// Solver reference radius. Returned offsets are in units of this radius.
private let fitRadius: CGFloat = 100

/// Maximal amplitudes of the rest life, read off `BloubMotion.liveliness`:
/// `loopNoise` is bounded by 1 in absolute value, so these sums are exact
/// bounds. They must be covered, otherwise the correction is right on the
/// nominal pose and wrong one second later.
private let deriveYaw = CGFloat(5.5 + 1.6)
private let derivePitch = CGFloat(4.2 + 1.3)
private let deriveX = CGFloat(0.006)
private let deriveY = CGFloat(0.007)
/// Centre float, absorbed into the capsule radius: cheaper than testing its
/// four corners as extra poses.
private let floatment = (deriveX * deriveX + deriveY * deriveY).squareRoot() * fitRadius

/// The face of a pose: what the solver needs to place the capsules.
private struct Visage {
    var gaze: BloubGaze
    var split: CGFloat
    var eyes: [BloubEyeConfig]
}

/// One capsule ready to be measured: the segment of its axis, plus what it
/// takes to know the radius to clear IN A GIVEN DIRECTION.
///
/// A capsule is exactly a segment thickened by a disc of radius `r`; its
/// image under the tangent matrix is a segment thickened by an ELLIPSE, whose
/// support function in direction u is `r * |A^T u|` over the tangent matrix
/// columns `m`.
private struct Empreinte {
    var x: CGFloat
    var y: CGFloat
    /// Half-vector of the axis.
    var ax: CGFloat
    var ay: CGFloat
    /// Local disc radius, before transformation.
    var r: CGFloat
    /// Tangent matrix columns, for the support function.
    var m: (CGFloat, CGFloat, CGFloat, CGFloat)
}

private func empreintes(
    _ visage: Visage,
    silhouetteRotation: CGFloat,
    radii: [CGFloat]
) -> [Empreinte] {
    let poses = BloubFace.eyePoses(gaze: visage.gaze, scale: fitRadius, split: visage.split)
    var out: [Empreinte] = []
    for (index, pose) in poses.enumerated() {
        guard pose.depth > 0.02, index < visage.eyes.count else { continue }
        let cfg = visage.eyes[index]
        let phi = cfg.tilt * .pi / 180
        let cp = cos(phi)
        let sp = sin(phi)
        let ax = pose.a * cp + pose.c * sp
        let ay = pose.b * cp + pose.d * sp
        let cx = -pose.a * sp + pose.c * cp
        let cy = -pose.b * sp + pose.d * cp

        let hw = max(cfg.width * fitRadius, 0.01) / 2
        let hh = max(cfg.height * fitRadius, 0.01) / 2
        let r = min(hw, hh)
        // The axis is that of the largest dimension.
        let long = hh > hw
        let demi = long ? hh - r : hw - r
        // The local-radius prorata, exactly as the engine does it.
        let fit = RadialProfile(radii: radii).radius(
            atAngle: atan2(pose.y, pose.x) - silhouetteRotation
        )
        out.append(Empreinte(
            x: pose.x * fit,
            y: pose.y * fit,
            ax: (long ? cx : ax) * demi,
            ay: (long ? cy : ay) * demi,
            r: r,
            m: (ax, ay, cx, cy)
        ))
    }
    return out
}

/// Closest approach between a contour (point cloud) and a segment: the
/// distance AND the vector from the contour towards the segment — the
/// direction that clears room. Both come out of the SAME pass; computing
/// them separately would double the only real cost of this module, the sweep.
private func approche(_ pts: [CGPoint], _ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat)
    -> (d: CGFloat, ux: CGFloat, uy: CGFloat) {
    let sx = x1 - x0
    let sy = y1 - y0
    let len2 = sx * sx + sy * sy
    var best = CGFloat.infinity
    var vx: CGFloat = 0
    var vy: CGFloat = 0
    for p in pts {
        var t = len2 > 0 ? ((p.x - x0) * sx + (p.y - y0) * sy) / len2 : 0
        t = min(1, max(0, t))
        let ex = x0 + t * sx - p.x
        let ey = y0 + t * sy - p.y
        let d2 = ex * ex + ey * ey
        if d2 < best {
            best = d2
            vx = ex
            vy = ey
        }
    }
    let d = best.squareRoot()
    if d > 1e-9 {
        return (d, vx / d, vy / d)
    }
    return (d, 0, 0)
}

/// Tightest capsule margin, and the direction that clears it.
private func pire(_ pts: [CGPoint], _ emps: [Empreinte], _ tx: CGFloat, _ ty: CGFloat)
    -> (marge: CGFloat, ux: CGFloat, uy: CGFloat) {
    var marge = CGFloat.infinity
    var ux: CGFloat = 0
    var uy: CGFloat = 0
    for e in emps {
        let x = e.x + tx
        let y = e.y + ty
        let a = approche(pts, x - e.ax, y - e.ay, x + e.ax, y + e.ay)
        // Support function of the ellipse in the approach direction.
        let radius = e.r * ((e.m.0 * a.ux + e.m.1 * a.uy) * (e.m.0 * a.ux + e.m.1 * a.uy)
            + (e.m.2 * a.ux + e.m.3 * a.uy) * (e.m.2 * a.ux + e.m.3 * a.uy)).squareRoot() + floatment
        if a.d - radius < marge {
            marge = a.d - radius
            ux = a.ux
            uy = a.uy
        }
    }
    return (marge, ux, uy)
}

/// Probed directions and bisection step. Their product is the cost of
/// building the table, the only number to watch here.
private let directions = 12
private let dichotomie = 8

/// The translation to put on BOTH eyes for this shape, state and expression.
///
/// One TRANSLATION common to the two eyes — an isometry: separation, sizes
/// and tilts are preserved to the pixel. The face is only seated a little
/// lower on a body without room up top. Variants that bounded each eye
/// separately widened the pair; ones that scaled the face shrank the eyes —
/// visibly.
///
/// The targeted margin is the one of the ORIGINAL profile, not a strict
/// clearance: on the circle the outer eye already grazes the edge (17.3
/// units for a ball of radius 100) and that is wanted — it is what gives the
/// volume. The demand is capped by what the shape offers at its centre,
/// otherwise it is untenable on a flat body.
///
/// DIRECTIONAL search, not descent: we want the smallest-norm translation
/// that fits, so a crown of directions is probed and the distance
/// bisected along each. A gradient descent was written first and did not
/// converge — clearing the pair from one border brings it closer to the
/// other, so it dithered. Here the result depends on no convergence: every
/// direction is solved exactly, to the bisection step.
private func resous(_ epreuves: [(empreintes: [Empreinte], reference: [Empreinte], contour: [CGPoint], calContour: [CGPoint])])
    -> CGPoint {
    guard !epreuves.isEmpty else { return .zero }

    func marge(_ tx: CGFloat, _ ty: CGFloat) -> CGFloat {
        var m = CGFloat.infinity
        for ep in epreuves {
            m = min(m, pire(ep.contour, ep.empreintes, tx, ty).marge)
        }
        return m
    }

    // Required margin: the tightest the original profile tolerates, across
    // all trials. Then capped by the most clearance the shape can offer the
    // pair at all — its centre.
    var requis = CGFloat.infinity
    for ep in epreuves {
        requis = min(requis, pire(ep.calContour, ep.reference, 0, 0).marge)
    }

    // The run must be able to reach the body centre: `wide` has 87-unit
    // capsules, and on a triangle they only fit towards the middle, some
    // fifty units from their nominal place. A fixed run would leave them out.
    var mx: CGFloat = 0
    var my: CGFloat = 0
    let emps = epreuves[0].empreintes
    if !emps.isEmpty {
        for e in emps {
            mx -= e.x / CGFloat(emps.count)
            my -= e.y / CGFloat(emps.count)
        }
    }
    let course = max(0.35 * fitRadius, (mx * mx + my * my).squareRoot() * 1.25)

    // Cap of the demand: what the shape offers at its centre, always reachable.
    requis = min(requis, marge(mx, my))

    // Already good: the circle, and any shape wide enough. The capsule must
    // FIT IN and be no tighter than on the original profile — without that
    // second condition, a shape where nothing fits satisfies the first
    // degenerately.
    let depart = marge(0, 0)
    if depart >= requis && depart >= 0 { return .zero }
    let cible = max(requis, 0)

    var meilleurX: CGFloat = 0
    var meilleurY: CGFloat = 0
    var meilleureNorme = CGFloat.infinity
    // Fallback when nothing fits: the translation that clears the most,
    // probed along the way.
    var secoursX: CGFloat = 0
    var secoursY: CGFloat = 0
    var secours = depart

    for d in 0..<directions {
        let a = (CGFloat(d) / CGFloat(directions)) * .pi * 2
        let ux = cos(a)
        let uy = sin(a)
        if marge(ux * course, uy * course) < cible {
            // This direction leads nowhere; still keep the best clearance.
            for k in [CGFloat(0.3), 0.6, 1] {
                let m = marge(ux * course * k, uy * course * k)
                if m > secours {
                    secours = m
                    secoursX = ux * course * k
                    secoursY = uy * course * k
                }
            }
            continue
        }
        // Shortest distance that fits, along this direction.
        var bas: CGFloat = 0
        var haut = course
        for _ in 0..<dichotomie {
            let mid = (bas + haut) / 2
            if marge(ux * mid, uy * mid) >= cible {
                haut = mid
            } else {
                bas = mid
            }
        }
        if haut < meilleureNorme {
            meilleureNorme = haut
            meilleurX = ux * haut
            meilleurY = uy * haut
        }
    }

    let x = meilleureNorme == .infinity ? secoursX : meilleurX
    let y = meilleureNorme == .infinity ? secoursY : meilleurY
    // Returned in BALL-RADIUS units; the engine puts it back on its scale.
    return CGPoint(x: (x / fitRadius), y: (y / fitRadius))
}

/// The face to cover: the expression's when the state accepts one, its own
/// otherwise.
private func visageDe(_ definition: BloubStateDefinition, _ pose: BloubPose, _ expr: BloubExpression?)
    -> Visage {
    if definition.baseFace, let expr {
        return Visage(gaze: expr.gaze, split: expr.split, eyes: expr.eyes)
    }
    return Visage(gaze: pose.gaze, split: pose.split, eyes: pose.eyes)
}

/// The dates to sample in a state: a single one when its pose does not move.
private func dates(_ definition: BloubStateDefinition) -> [CGFloat] {
    func signature(_ p: BloubPose) -> [CGFloat] {
        [p.gaze.yaw, p.gaze.pitch, p.gaze.roll, p.split,
         p.body.rotation, p.body.center.x, p.body.center.y,
         p.body.scale.width, p.body.scale.height]
    }
    if signature(definition.pose(0)) == signature(definition.pose(CGFloat(definition.duration))) {
        return [0]
    }
    let n = 3
    return (0..<n).map { CGFloat($0) / CGFloat(n - 1) * CGFloat(definition.duration) }
}

/// The offset of one shape on one state and expression, drift included.
private func decalagePour(
    _ definition: BloubStateDefinition,
    _ radii: [CGFloat],
    _ expr: BloubExpression?
) -> CGPoint {
    var epreuves: [([Empreinte], [Empreinte], [CGPoint], [CGPoint])] = []
    for t in dates(definition) {
        let pose = definition.pose(t)
        var posedRadii = pose.body.profile
        posedRadii.radii = radii
        var posedBody = pose.body
        posedBody.profile = posedRadii
        let contour = posedBody.points(scale: fitRadius)
        let calContour = pose.body.points(scale: fitRadius)
        let visage = visageDe(definition, pose, expr)
        // The four corners of the drift bound the nominal pose, which is
        // their centre: testing it too would change no margin and cost one
        // trial in five.
        var coins: [Visage] = []
        for dy in [-deriveYaw, deriveYaw] {
            for dp in [-derivePitch, derivePitch] {
                coins.append(Visage(
                    gaze: BloubGaze(yaw: visage.gaze.yaw + dy, pitch: visage.gaze.pitch + dp, roll: visage.gaze.roll),
                    split: visage.split,
                    eyes: visage.eyes
                ))
            }
        }
        for coin in coins {
            epreuves.append((
                empreintes(coin, silhouetteRotation: pose.body.rotation, radii: radii),
                empreintes(coin, silhouetteRotation: pose.body.rotation, radii: pose.body.profile.radii),
                contour,
                calContour
            ))
        }
    }
    return resous(epreuves)
}

/// The offset table, built once on first use: one entry per (shape, rest-body
/// state, expression). Only `idle` and `swirl` wear the resting face, so only
/// they decline per expression — the other rest-body states have a face
/// measured on the video and a single entry.
private enum BloubEyeFitTable {
    static let offsets: [BloubShapeID: [BloubEyeFit.Key: CGPoint]] = {
        var table: [BloubShapeID: [BloubEyeFit.Key: CGPoint]] = [:]
        for shape in BloubShapeCatalog.shapes {
            var par: [BloubEyeFit.Key: CGPoint] = [:]
            for (state, definition) in BloubStates.catalog where definition.baseBody {
                if definition.baseFace {
                    par[BloubEyeFit.Key(state: state, expression: nil)] = decalagePour(
                        definition, shape.profile.radii, nil
                    )
                    for expression in BloubExpressionID.allCases {
                        par[BloubEyeFit.Key(state: state, expression: expression)] = decalagePour(
                            definition, shape.profile.radii, BloubExpression.expression(expression)
                        )
                    }
                } else {
                    par[BloubEyeFit.Key(state: state, expression: nil)] = decalagePour(
                        definition, shape.profile.radii, nil
                    )
                }
            }
            table[shape.id] = par
        }
        return table
    }()
}

public enum BloubEyeFit {
    public struct Key: Hashable, Sendable {
        var state: BloubState
        var expression: BloubExpressionID?

        init(state: BloubState, expression: BloubExpressionID?) {
            self.state = state
            self.expression = expression
        }
    }

    /// Translation to apply to both eyes for this shape on this state, in
    /// ball-radius units — the engine puts it back on its scale.
    ///
    /// Zero as soon as the shape is the circle (both profiles are the same,
    /// so the margin already equals the demand) or unknown: the measured
    /// shapes never move, with no special case.
    public static func offset(
        shape: BloubShapeID?,
        state: BloubState,
        expression: BloubExpressionID?
    ) -> CGPoint {
        guard let shape, shape != .circle else { return .zero }
        let par = BloubEyeFitTable.offsets[shape]
        // A state without a resting face has one entry whatever the expression.
        return par?[Key(state: state, expression: expression)]
            ?? par?[Key(state: state, expression: nil)]
            ?? .zero
    }
}
