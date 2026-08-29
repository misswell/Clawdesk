import CoreGraphics
import Foundation

/// Where the bot looks when something external drives it — the pointer today.
///
/// `yaw` and `pitch` are ABSOLUTE directions that replace the pose's own gaze
/// as `mix` rises. The engine must do this blending (not the caller) because
/// only it knows the pose at that instant; and it must be absolute on both
/// axes, otherwise the eyes would drop suddenly on the first mood change.
/// `spin` is a full turn to travel on the way in, in degrees, melted towards
/// zero on arrival. `wander` is what remains of automatic drift; it dies while
/// the pointer is tracked and survives when there is no pointer at all.
public struct BloubLook: Equatable, Sendable {
    public var yaw: CGFloat
    public var pitch: CGFloat
    public var mix: CGFloat
    public var spin: CGFloat
    public var wander: CGFloat

    public init(yaw: CGFloat, pitch: CGFloat, mix: CGFloat, spin: CGFloat, wander: CGFloat) {
        self.yaw = yaw
        self.pitch = pitch
        self.mix = mix
        self.spin = spin
        self.wander = wander
    }

    /// No external pilot: the state's own gaze rules.
    public static let none = BloubLook(yaw: 0, pitch: 0, mix: 0, spin: 0, wander: 1)
}

public struct BloubRenderedEye: Equatable, Sendable {
    /// Capsule size in points, before transform.
    public var capsuleWidth: CGFloat
    public var capsuleHeight: CGFloat
    /// Affine matrix (a, b, c, d, tx, ty) with the blink squash baked into the
    /// y outputs and the fit-corrected position in the translation.
    public var transform: CGAffineTransform
    public var alpha: CGFloat

    public init(
        capsuleWidth: CGFloat,
        capsuleHeight: CGFloat,
        transform: CGAffineTransform,
        alpha: CGFloat
    ) {
        self.capsuleWidth = capsuleWidth
        self.capsuleHeight = capsuleHeight
        self.transform = transform
        self.alpha = alpha
    }
}

public struct BloubBadge: Equatable, Sendable {
    public var center: CGPoint
    public var radius: CGFloat

    public init(center: CGPoint, radius: CGFloat) {
        self.center = center
        self.radius = radius
    }
}

/// One deterministic sample of the bot: everything the renderer needs, in
/// screen points, y-down, centred on the ball origin.
public struct BloubFrame: Equatable, Sendable {
    public var body: BloubBody
    public var bodyPoints: [CGPoint]
    public var eyes: [BloubRenderedEye]
    public var dots: [BloubDot]
    /// True when the dots pass behind the body (burst particles).
    public var dotsBehind: Bool
    public var arcs: [BloubArc]
    public var notification: BloubBadge?
    /// Concentric disc subtracted from the body under the badge.
    public var notch: BloubBadge?

    public init(
        body: BloubBody,
        bodyPoints: [CGPoint],
        eyes: [BloubRenderedEye],
        dots: [BloubDot],
        dotsBehind: Bool,
        arcs: [BloubArc],
        notification: BloubBadge?,
        notch: BloubBadge?
    ) {
        self.body = body
        self.bodyPoints = bodyPoints
        self.eyes = eyes
        self.dots = dots
        self.dotsBehind = dotsBehind
        self.arcs = arcs
        self.notification = notification
        self.notch = notch
    }

    /// The exact current silhouette, for hit testing and clipping.
    public func bodyPath() -> CGPath {
        BloubPaths.closed(points: bodyPoints)
    }
}

/// Clock-less engine: `sample(at:)` is a pure function of time.
///
/// Practical consequence: pause, resume, slow motion and seeking to an
/// arbitrary date give exactly the same image, and rendering is testable
/// without a window. External inputs (state changes, look targets) enter only
/// through timestamped setters, never through variables read during sampling.
public final class BloubEngine {
    /// Ball radius at rest, in points.
    public let radius: CGFloat

    /// Duration of the gaze catch-up towards a target. Shorter than the shape
    /// morph: a following gaze must look attentive, not syrupy. Because the
    /// target is re-posed at every pointer move, this duration gives the
    /// tracking its inertia — the gaze never quite reaches a moving cursor.
    public static let lookMorphDuration: TimeInterval = 0.24

    /// Duration of the morph when the body shape or the resting expression
    /// changes. All shapes share one sample structure, so the change is a
    /// simple radius interpolation — no jump.
    public static let shapeMorphDuration: TimeInterval = 0.45

    private var current: BloubState
    private var previous: BloubState?
    /// Starting pose FROZEN only when a state change arrives while a fade is
    /// already in flight (see `setState`).
    private var frozenOrigin: BloubPose?
    private var tCurrent: TimeInterval = 0
    private var tPrevious: TimeInterval = 0
    private var blinkAt: TimeInterval = -10

    /// Resting body shape chosen in the customizer. It replaces the body only
    /// on rest states (`baseBody`): elsewhere the silhouette IS the animation.
    private var shape: RadialProfile?
    private var shapePrevious: RadialProfile?
    private var shapeAt: TimeInterval = -10
    /// Resting expression chosen in the customizer. Like the shape, it glides
    /// to the new value instead of jumping.
    private var expression: BloubExpression?
    private var expressionPrevious: BloubExpression?
    private var expressionAt: TimeInterval = -10

    private var look: BloubLook = .none
    private var lookPrevious: BloubLook = .none
    private var lookAt: TimeInterval = -10
    private var lookMorph: TimeInterval = BloubEngine.lookMorphDuration

    public init(radius: CGFloat = 100, initial: BloubState = .idle) {
        self.radius = radius
        self.current = initial
    }

    public var state: BloubState { current }

    /// Body shape chosen in the customizer. It only replaces the body on rest
    /// states (`baseBody`); elsewhere the silhouette IS the animation and must
    /// not be overridden. The change happens as a morph, not a jump: all
    /// shapes are sampled at the same angles, so interpolating radii is all
    /// it takes.
    public func setShape(_ newShape: RadialProfile?, at now: TimeInterval) {
        if newShape == shape { return }
        shapePrevious = shape
        shape = newShape
        shapeAt = now
    }

    /// Resting expression chosen in the customizer. Like the shape, it glides
    /// to the new value instead of jumping.
    public func setExpression(_ newExpression: BloubExpression?, at now: TimeInterval) {
        if newExpression == expression { return }
        expressionPrevious = expression
        expression = newExpression
        expressionAt = now
    }

    /// Shape in effect at `now`, morph included.
    ///
    /// Does NOT clear `shapePrevious` at the end of the morph: `sample` must
    /// stay a pure function of time, so re-reading a past date must give back
    /// the intermediate image.
    private func shapeAtTime(_ now: TimeInterval) -> RadialProfile? {
        let to = shape
        let from = shapePrevious
        guard let to, let from else { return to }
        let k = (now - shapeAt) / Self.shapeMorphDuration
        if k >= 1 { return to }
        let t = BloubEase.easeOutQuint(BloubEase.clamp01(k))
        var radii = to.radii
        for index in 0..<radii.count {
            radii[index] = BloubEase.lerp(from.radii[index], radii[index], t)
        }
        return RadialProfile(radii: radii)
    }

    /// Expression in effect at `now`, morph included.
    private func expressionAtTime(_ now: TimeInterval) -> BloubExpression? {
        let to = expression
        let from = expressionPrevious
        guard let to, let from else { return to }
        let k = (now - expressionAt) / Self.shapeMorphDuration
        if k >= 1 { return to }
        return BloubExpression.blend(from, to, BloubEase.easeOutQuint(BloubEase.clamp01(k)))
    }

    /// Catalogue identifier of a stored shape, for eye-fit table lookups.
    /// The interpolated profile of a running morph matches no entry by design:
    /// the table is queried on the morph BOUNDS only.
    private func shapeID(of profile: RadialProfile?) -> BloubShapeID? {
        guard let profile else { return nil }
        return BloubShapeCatalog.shapes.first { $0.profile == profile }?.id
    }

    /// Eye offset at `now` for a given state, in ball-radius units.
    ///
    /// Read from a table and interpolated, never re-solved. Both morph axes
    /// (shape and expression) are queried on their BOUNDS and interpolated
    /// with exactly the curve and duration of the silhouette morph — same
    /// cause, same movement. The interpolated in-flight values have no table
    /// identity; feeding those to the table is what made earlier versions
    /// tremble.
    private func eyeOffset(state: BloubState, at now: TimeInterval) -> CGPoint {
        func surAxe(_ debut: TimeInterval, _ duree: TimeInterval, _ a: CGPoint, _ b: CGPoint) -> CGPoint {
            if a == b { return b }
            let k = (now - debut) / duree
            if k >= 1 { return b }
            let t = BloubEase.easeOutQuint(BloubEase.clamp01(k))
            return CGPoint(x: BloubEase.lerp(a.x, b.x, t), y: BloubEase.lerp(a.y, b.y, t))
        }

        func lookup(_ radii: RadialProfile?, _ expression: BloubExpression?) -> CGPoint {
            BloubEyeFit.offset(
                shape: shapeID(of: radii),
                state: state,
                expression: expression?.id
            )
        }

        // Expression axis, for each of the two shapes in presence.
        func parForme(_ radii: RadialProfile?) -> CGPoint {
            surAxe(
                expressionAt,
                Self.shapeMorphDuration,
                lookup(radii, expressionPrevious),
                lookup(radii, expression)
            )
        }

        // Then the shape axis.
        return surAxe(shapeAt, Self.shapeMorphDuration, parForme(shapePrevious), parForme(shape))
    }

    /// Moves to a new state, timestamped.
    ///
    /// The engine keeps a single history slot, so a change landing during a
    /// fade used to replace the blend origin with the FULL pose of the state
    /// being left, instead of the partially blended image on screen (measured
    /// upstream on `idle -> wide -> idle` at 100 ms: a 35.9 px jump against a
    /// normal 8.0 px movement). The current composite pose is therefore frozen
    /// and the next fade starts from it — continuous by construction, whatever
    /// number of changes are chained.
    ///
    /// And ONLY in that case: freezing at every change would stop the
    /// outgoing state's own animation dead for the whole fade — the alert "!"
    /// would freeze mid-run — while outside a morph there is nothing to
    /// correct: the outgoing state is already exactly the displayed image.
    public func setState(_ id: BloubState, at now: TimeInterval) {
        guard id != current else { return }
        let morph = BloubStates.catalog[current]?.morph ?? 0.45
        let midMorph = previous != nil && now - tCurrent < morph
        frozenOrigin = midMorph ? composedPose(at: now) : nil
        previous = current
        tPrevious = tCurrent
        current = id
        tCurrent = now
        // On the reference video every body-shape change is masked by a blink.
        if BloubStates.catalog[id]?.blinkIn == true {
            blinkAt = now
        }
    }

    /// Restarts on `id` with NO previous state, like a fresh engine dropped on
    /// that state. This is what "rewind" means for this engine.
    public func reset(_ id: BloubState, at now: TimeInterval) {
        current = id
        previous = nil
        frozenOrigin = nil
        tCurrent = now
        tPrevious = now
        blinkAt = -10
    }

    /// Re-anchors the customizer morph timeline after a clock jump (theme
    /// switch rewinds the animation clock): the current shape and expression
    /// become the settled values at `now`, with no phantom morph.
    public func rewindCustomization(at now: TimeInterval) {
        shapePrevious = nil
        shapeAt = now
        expressionPrevious = nil
        expressionAt = now
    }

    /// New gaze target, `nil` to return to the state's own.
    ///
    /// It starts from the CURRENT value, not the previous target: called at
    /// every pointer move, restarting from the old target would step the gaze
    /// backwards once per move — the tracking would tremble instead of glide.
    ///
    /// A non-finite target is refused and the last one is kept: a NaN posed
    /// once would propagate to every frame and the bot would never settle.
    public func setLook(_ newLook: BloubLook?, at now: TimeInterval, morph: TimeInterval? = nil) {
        if let newLook {
            let sum = newLook.yaw + newLook.pitch + newLook.mix + newLook.spin + newLook.wander
            guard sum.isFinite else { return }
        }
        lookPrevious = lookValue(at: now)
        look = newLook ?? .none
        lookAt = now
        lookMorph = max(0.001, morph ?? Self.lookMorphDuration)
    }

    /// Gaze in effect at `now`, catch-up included.
    private func lookValue(at now: TimeInterval) -> BloubLook {
        let k = (now - lookAt) / lookMorph
        guard k < 1 else { return look }
        return Self.blendLook(lookPrevious, look, BloubEase.easeOutQuint(BloubEase.clamp01(k)))
    }

    private static func blendLook(_ a: BloubLook, _ b: BloubLook, _ t: CGFloat) -> BloubLook {
        BloubLook(
            yaw: BloubEase.lerp(a.yaw, b.yaw, t),
            pitch: BloubEase.lerp(a.pitch, b.pitch, t),
            mix: BloubEase.lerp(a.mix, b.mix, t),
            spin: BloubEase.lerp(a.spin, b.spin, t),
            wander: BloubEase.lerp(a.wander, b.wander, t)
        )
    }

    /// Origin of the fade in flight: the frozen pose when one exists, else the
    /// outgoing state evaluated at its own elapsed time — still animating,
    /// which is intended.
    private func originPose(at now: TimeInterval) -> BloubPose? {
        if let frozenOrigin { return frozenOrigin }
        guard let previous, let definition = BloubStates.catalog[previous] else { return nil }
        return posed(definition, max(0, now - tPrevious), now: now)
    }

    /// Composite pose at `now`, fade included: exactly what `sample` blends,
    /// before the rest-life and gaze layers. Extracted so `setState` can
    /// freeze it.
    private func composedPose(at now: TimeInterval) -> BloubPose {
        guard let definition = BloubStates.catalog[current] else { return BloubPose() }
        let pose = posed(definition, max(0, now - tCurrent), now: now)
        let since = now - tCurrent
        guard since < definition.morph, let origin = originPose(at: now) else { return pose }
        return Self.blend(origin, pose, BloubEase.easeOutQuint(BloubEase.clamp01(since / definition.morph)))
    }

    /// A state's pose with the customizer layers applied: the chosen shape
    /// only on rest-body states, the chosen expression only on rest-face
    /// states.
    private func posed(
        _ definition: BloubStateDefinition,
        _ t: CGFloat,
        now: TimeInterval
    ) -> BloubPose {
        var pose = definition.pose(t)
        if definition.baseBody, let shape = shapeAtTime(now) {
            // Keep the pose (rotation, offset, squash) and swap only the profile.
            pose.body.profile = shape
        }
        if definition.baseFace, let expression = expressionAtTime(now) {
            pose.gaze = expression.gaze
            pose.split = expression.split
            pose.eyes = expression.eyes
        }
        return pose
    }

    private static func blendEyeConfig(
        _ a: BloubEyeConfig,
        _ b: BloubEyeConfig,
        _ t: CGFloat
    ) -> BloubEyeConfig {
        BloubEyeConfig(
            width: BloubEase.lerp(a.width, b.width, t),
            height: BloubEase.lerp(a.height, b.height, t),
            openness: BloubEase.lerp(a.openness, b.openness, t),
            tilt: BloubEase.lerp(a.tilt, b.tilt, t)
        )
    }

    /// Interpolation of two poses. The decor crosses in opacity, not geometry.
    private static func blend(_ a: BloubPose, _ b: BloubPose, _ t: CGFloat) -> BloubPose {
        let out = 1 - t
        return BloubPose(
            body: BloubBody.blend(a.body, b.body, t),
            offset: CGPoint(
                x: BloubEase.lerp(a.offset.x, b.offset.x, t),
                y: BloubEase.lerp(a.offset.y, b.offset.y, t)
            ),
            gaze: BloubGaze(
                yaw: BloubEase.lerp(a.gaze.yaw, b.gaze.yaw, t),
                pitch: BloubEase.lerp(a.gaze.pitch, b.gaze.pitch, t),
                roll: BloubEase.lerp(a.gaze.roll, b.gaze.roll, t)
            ),
            split: BloubEase.lerp(a.split, b.split, t),
            eyes: [
                blendEyeConfig(a.eyes[0], b.eyes[0], t),
                blendEyeConfig(a.eyes[1], b.eyes[1], t)
            ],
            eyeOpacity: BloubEase.lerp(a.eyeOpacity, b.eyeOpacity, t),
            bodyOpacity: BloubEase.lerp(a.bodyOpacity, b.bodyOpacity, t),
            dots: a.dots.map { var d = $0; d.opacity *= out; return d }
                + b.dots.map { var d = $0; d.opacity *= t; return d },
            arcs: a.arcs.map { BloubArcRequest(id: "a" + $0.id, seed: $0.seed, t: $0.t, opacity: $0.opacity * out) }
                + b.arcs.map { BloubArcRequest(id: "b" + $0.id, seed: $0.seed, t: $0.t, opacity: $0.opacity * t) },
            // The badge belongs to one of the two states, it does not mix.
            notification: t < 0.5 ? a.notification : b.notification,
            dotsBehind: t < 0.5 ? a.dotsBehind : b.dotsBehind
        )
    }

    public func sample(at now: TimeInterval) -> BloubFrame {
        guard let definition = BloubStates.catalog[current] else {
            return emptyFrame()
        }
        var pose = posed(definition, max(0, now - tCurrent), now: now)
        var eyeOffset = self.eyeOffset(state: current, at: now)

        // --- transition -----------------------------------------------------
        // The previous state is never purged: `since < morph` is enough to
        // ignore it once the fade has passed, and forgetting it would make the
        // engine non-replayable — reading a date before the end of the fade
        // would not find it again. The optimisation that looks innocent and
        // breaks everything.
        let since = now - tCurrent
        if since < definition.morph, let origin = originPose(at: now) {
            // Exponential ease-out: the curve measured on the video. The body
            // never overshoots (only the badge and eye opening do). The ratio
            // is clamped: reading a date EARLIER than the state change would
            // give a negative ratio that ease-out extrapolates — the
            // silhouette would then fly thirty times too far.
            let ratio = BloubEase.easeOutQuint(BloubEase.clamp01(since / definition.morph))
            pose = Self.blend(origin, pose, ratio)
            // The eye offset follows the SAME curve as the silhouette that
            // motivates it: it comes from the outgoing state.
            if let outgoing = previous {
                let avant = self.eyeOffset(state: outgoing, at: now)
                eyeOffset = CGPoint(
                    x: BloubEase.lerp(avant.x, eyeOffset.x, ratio),
                    y: BloubEase.lerp(avant.y, eyeOffset.y, ratio)
                )
            }
        }

        // --- rest life --------------------------------------------------------
        let alive = pose.eyeOpacity > 0.01
        let activeLook = lookValue(at: now)
        let life = BloubMotion.liveliness(
            at: now,
            wander: Double(alive ? activeLook.wander : 0),
            blink: alive
        )

        let gaze = BloubGaze(
            // The two aims REPLACE the pose's own (see `BloubLook`), and the
            // spin is subtracted along the way. The drift adds AFTER the blend,
            // otherwise the target would cancel it together with the pose —
            // the drift must survive a turned head without a pointer.
            yaw: BloubEase.lerp(pose.gaze.yaw, activeLook.yaw, activeLook.mix)
                + CGFloat(life.dYaw) - activeLook.spin,
            pitch: BloubEase.lerp(pose.gaze.pitch, activeLook.pitch, activeLook.mix)
                + CGFloat(life.dPitch),
            // Roll follows nothing: the bot's head is tilted -13° on the video,
            // and rolling it with the cursor breaks that signature.
            roll: pose.gaze.roll + CGFloat(life.dRoll)
        )

        // Blink triggered by the state change, in addition to the calendar.
        let forced = BloubEase.clamp01((now - blinkAt) / 0.2)
        let forcedLid = forced < 1 ? abs(forced * 2 - 1) : 1
        let lid = min(life.lid, forcedLid)

        let offX = pose.offset.x + CGFloat(life.driftX)
        let offY = pose.offset.y + CGFloat(life.driftY)

        // --- body -------------------------------------------------------------
        var body = pose.body
        body.center = CGPoint(x: body.center.x + offX, y: body.center.y + offY)
        body.scale = CGSize(
            width: body.scale.width,
            height: body.scale.height * CGFloat(life.breath)
        )
        body.opacity = pose.bodyOpacity
        let bodyPoints = body.points(scale: radius)

        // The eyes live on a sphere of radius 1; as soon as the silhouette is
        // not a circle they are re-seated proportionally to the real radius in
        // their direction, otherwise they overflow and the mask cuts them.
        func bodyRadius(x: CGFloat, y: CGFloat) -> CGFloat {
            pose.body.profile.radius(atAngle: atan2(y, x) - pose.body.rotation)
        }

        // --- eyes -------------------------------------------------------------
        var eyes: [BloubRenderedEye] = []
        if pose.eyeOpacity > 0.01 {
            let poses = BloubFace.eyePoses(gaze: gaze, scale: radius, split: pose.split)
            for (index, eyePose) in poses.enumerated() {
                guard eyePose.depth > 0.02, index < pose.eyes.count else { continue }
                let config = pose.eyes[index]
                let fit = bodyRadius(x: eyePose.x, y: eyePose.y)
                // Own eye tilt: the tangent frame composes with a rotation in
                // the eye plane (basis x rotation). That is what allows
                // mirror-image tilts between the two eyes.
                let phi = config.tilt * .pi / 180
                let cp = cos(phi)
                let sp = sin(phi)
                let ax = eyePose.a * cp + eyePose.c * sp
                let ay = eyePose.b * cp + eyePose.d * sp
                let cx2 = -eyePose.a * sp + eyePose.c * cp
                let cy2 = -eyePose.b * sp + eyePose.d * cp
                // The blink applies after all that: a vertical squash on
                // screen, not along the capsule's own axis.
                let k = BloubFace.blinkScale(min(lid, config.openness))
                eyes.append(BloubRenderedEye(
                    capsuleWidth: config.width * radius,
                    capsuleHeight: config.height * radius,
                    transform: CGAffineTransform(
                        a: ax,
                        b: ay * k,
                        c: cx2,
                        d: cy2 * k,
                        tx: eyePose.x * fit + (offX + eyeOffset.x) * radius,
                        ty: eyePose.y * fit + (offY + eyeOffset.y) * radius
                    ),
                    alpha: pose.eyeOpacity * BloubEase.clamp01(eyePose.depth / 0.12)
                ))
            }
        }

        // --- decor ------------------------------------------------------------
        let dots = pose.dots
            .filter { $0.opacity > 0.01 && $0.r > 0.0005 }
            .map { spec -> BloubDot in
                var dot = BloubDot(spec: spec, scale: radius)
                dot.position.x += offX * radius
                dot.position.y += offY * radius
                return dot
            }

        // The badge sits on the contour: it follows the shape too.
        var notification: BloubBadge?
        var notch: BloubBadge?
        if let target = pose.notification {
            let fit = bodyRadius(x: target.x, y: target.y)
            let nx = (target.x * fit + offX) * radius
            let ny = (target.y * fit + offY) * radius
            notification = BloubBadge(center: CGPoint(x: nx, y: ny), radius: target.r * radius)
            notch = BloubBadge(center: CGPoint(x: nx, y: ny), radius: target.notch * radius)
        }

        // States declare arcs in ball-radius units; the engine is the only one
        // that knows the point scale, so it is the one that traces them.
        let arcs = pose.arcs
            .filter { $0.opacity > 0.01 }
            .map { BloubDecor.arcRender($0.seed, t: $0.t, scale: radius, id: $0.id, opacity: $0.opacity) }

        return BloubFrame(
            body: body,
            bodyPoints: bodyPoints,
            eyes: eyes,
            dots: dots,
            dotsBehind: pose.dotsBehind,
            arcs: arcs,
            notification: notification,
            notch: notch
        )
    }

    private func emptyFrame() -> BloubFrame {
        let body = BloubBody(profile: .circle(1))
        return BloubFrame(
            body: body,
            bodyPoints: body.points(scale: radius),
            eyes: [],
            dots: [],
            dotsBehind: false,
            arcs: [],
            notification: nil,
            notch: nil
        )
    }
}
