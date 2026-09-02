import CoreGraphics
import Foundation

/// The bloub state catalogue: one shape morphing through the measured states
/// plus the runtime `dizzy` reaction and `swirl`, an interface-only
/// transition.
///
/// Every pose below is a pure function of local state time: identical state +
/// parameters + time always produce an identical pose, which is what keeps
/// pause/resume/seek/preview/testable rendering possible.
public enum BloubState: String, CaseIterable, Sendable, Equatable {
    case idle
    case roam
    case thinking
    case wink
    case wide
    case alert
    case notify
    case exclaim
    case sleep
    /// Clawdesk's full idle-sleep sequence. The upstream bloub catalogue has
    /// one sleeping-dot state; these native overlays preserve the agent
    /// runtime's yawn/doze/collapse/wake phases when no theme asset exists.
    case yawning
    case dozing
    case collapsing
    case sleeping
    case waking
    case wakingFromDoze
    /// Continuous lifecycle actions. These are separate from the original
    /// sequence's one-shot hexagon/egg/comet showcase states so a long-lived
    /// agent never freezes on a settled pose.
    case building
    case carrying
    case sweeping
    case egg
    case hexagon
    case play
    case orbit
    case burst
    case comet
    case miniIdle
    case miniPeek
    case miniAlert
    case miniHappy
    case miniWorking
    case miniCrabwalk
    case miniEnter
    case miniEnterSleep
    case miniSleep
    /// Runtime reaction shown after the cursor circles the pet twice.
    case dizzy
    /// Interface transition, not a catalogue animation (excluded from
    /// `sequence`, like upstream).
    case swirl
}

/// Local time at which each state reads best; used by tests and previews as a
/// deterministic "cover shot" per state. The type forces coverage of every new
/// state.
public enum BloubPoseBook {
    public static let time: [BloubState: TimeInterval] = [
        .idle: 1,
        .roam: 0.55,
        .thinking: 1.1,
        .wink: 0.8,
        .wide: 0.8,
        .alert: 0.75,
        .notify: 0.9,
        .exclaim: 0.8,
        .sleep: 0.45,
        .yawning: 0.7,
        .dozing: 0.65,
        .collapsing: 0.7,
        .sleeping: 0.45,
        .waking: 0.75,
        .wakingFromDoze: 0.35,
        .building: 0.9,
        .carrying: 0.8,
        .sweeping: 1.1,
        .egg: 0.8,
        .hexagon: 0.8,
        .play: 0.9,
        .orbit: 1.2,
        .swirl: 0.5,
        .burst: 0.45,
        .comet: 1.15,
        .dizzy: 1.2,
        .miniIdle: 0.8,
        .miniPeek: 0.8,
        .miniAlert: 0.7,
        .miniHappy: 0.8,
        .miniWorking: 0.8,
        .miniCrabwalk: 0.45,
        .miniEnter: 0.6,
        .miniEnterSleep: 0.6,
        .miniSleep: 0.35
    ]
}

/// One state's behaviour: hold duration when a full sequence is played, the
/// entry morph duration, whether the entry is masked by a blink, and the pose
/// function itself.
public struct BloubStateDefinition: Sendable {
    public let id: BloubState
    /// Hold duration when the complete sequence is played.
    public let duration: TimeInterval
    /// Duration below which the animation is cut before resolving. Read from
    /// the pose constants, never chosen: the "!" does not come back, the body
    /// stays burst. Absent = the state ignores time or loops.
    public let minDuration: TimeInterval?
    /// Entry morph duration.
    public let morph: TimeInterval
    /// True when the entry is masked by a blink, as in the reference video.
    public let blinkIn: Bool
    /// True when the body is the "at rest" silhouette (replaceable by a
    /// customizer shape). States that draw their own body (the "!", the dots,
    /// the egg, the triangle...) are false: that shape IS the animation.
    public let baseBody: Bool
    /// True when the state wears the resting face (replaceable by a
    /// customizer expression). Only `idle` and `swirl`.
    public let baseFace: Bool
    /// Local time after which the state's own animation is visually done and
    /// only the rest life (drift, breath, blink calendar) remains. The render
    /// driver uses this to drop to a low idle frequency (architecture rule:
    /// idle never means a permanent 60 FPS clock). `nil` = the state loops
    /// forever and never settles.
    public let settlesAt: TimeInterval?
    public let pose: @Sendable (CGFloat) -> BloubPose

    public init(
        id: BloubState,
        duration: TimeInterval,
        minDuration: TimeInterval? = nil,
        morph: TimeInterval,
        blinkIn: Bool,
        baseBody: Bool,
        baseFace: Bool,
        settlesAt: TimeInterval? = nil,
        pose: @escaping @Sendable (CGFloat) -> BloubPose
    ) {
        self.id = id
        self.duration = duration
        self.minDuration = minDuration
        self.morph = morph
        self.blinkIn = blinkIn
        self.baseBody = baseBody
        self.baseFace = baseFace
        self.settlesAt = settlesAt
        self.pose = pose
    }
}

/// The pose a state produces: silhouette, body/eye offsets, gaze, eye
/// configuration and decoration requests. All geometry is in ball-radius
/// units, y-down, centred on the ball origin.
public struct BloubPose: Equatable, Sendable {
    public var body: BloubBody
    /// Global offset of the body AND the eyes, radius units.
    public var offset: CGPoint
    public var gaze: BloubGaze
    /// Half-separation of the eyes on the sphere, degrees.
    public var split: CGFloat
    /// [inner eye, outer eye].
    public var eyes: [BloubEyeConfig]
    public var eyeOpacity: CGFloat
    public var bodyOpacity: CGFloat
    public var dots: [BloubDotSpec]
    public var arcs: [BloubArcRequest]
    public var notification: BloubNotification?
    /// True when the decor passes behind the body (burst particles).
    public var dotsBehind: Bool

    public init(
        body: BloubBody = BloubBody(profile: .circle(1)),
        offset: CGPoint = .zero,
        gaze: BloubGaze = BloubMotion.restGaze,
        split: CGFloat = BloubFace.eyeSplit,
        eyes: [BloubEyeConfig] = .pair(BloubFace.eyeWidth, BloubFace.eyeHeight),
        eyeOpacity: CGFloat = 1,
        bodyOpacity: CGFloat = 1,
        dots: [BloubDotSpec] = [],
        arcs: [BloubArcRequest] = [],
        notification: BloubNotification? = nil,
        dotsBehind: Bool = false
    ) {
        self.body = body
        self.offset = offset
        self.gaze = gaze
        self.split = split
        self.eyes = eyes
        self.eyeOpacity = eyeOpacity
        self.bodyOpacity = bodyOpacity
        self.dots = dots
        self.arcs = arcs
        self.notification = notification
        self.dotsBehind = dotsBehind
    }
}

public enum BloubStates {
    /// Reading order of the original bloub sequence. Clawdesk's lifecycle
    /// sleep overlays, mini states and reactions are runtime additions and
    /// intentionally stay out of this montage order.
    public static let sequence: [BloubState] = [
        .idle, .thinking, .wink, .wide, .alert, .notify, .exclaim, .sleep,
        .egg, .hexagon, .play, .orbit, .burst, .comet
    ]

    /// The upright "!" bar: convex hull of two circles.
    /// Measured: top circle (0, -0.505) r 0.132, bottom circle (0, +0.130)
    /// r 0.075, straight flanks — a tapered cone (top/bottom ratio 1.76).
    private static let barUprightCenterY: CGFloat = -0.1875
    private static let barUpright = BloubShapeFactory.profile(
        fromPolygon: BloubShapeFactory.hullOfCircles(0, -0.505, 0.132, 0, 0.13, 0.075),
        center: CGPoint(x: 0, y: barUprightCenterY)
    )

    /// The tilted "!" bar: a pure capsule (constant width 0.269, length 0.776).
    private static let barItalic = BloubShapeFactory.profile(
        fromPolygon: BloubShapeFactory.hullOfCircles(0, -0.2535, 0.1345, 0, 0.2535, 0.1345),
        center: .zero
    )

    /// The tilted "!" dot is not a disc: it is a teardrop with a round end
    /// (r 0.118) on the bar side and a pointed tip opposite, length 0.300
    /// along the glyph axis, centred on the round end's barycentre.
    private static let tear = BloubShapeFactory.hullOfCircles(0, 0, 0.118, 0, 0.172, 0.012)

    /// The triangle does not spin on its own axis: its centre describes a
    /// circle of radius 0.213 around the origin (measured). That offset is
    /// what makes it appear to tumble instead of pirouette.
    private static let triangleOrbit: CGFloat = 0.213

    private static func spinningTriangle(_ rotation: CGFloat) -> BloubBody {
        BloubBody(
            profile: BloubProfileFixture.triangle,
            rotation: rotation,
            center: CGPoint(
                x: -triangleOrbit * sin(rotation),
                y: triangleOrbit * cos(rotation)
            )
        )
    }

    /// Pulse wave travelling left-to-right across the three thinking dots.
    private static func dotPulse(_ t: CGFloat, _ index: Int) -> CGFloat {
        var p = (t - CGFloat(index) * 0.5) / 1.5
        p = p.truncatingRemainder(dividingBy: 1)
        if p < 0 { p += 1 }
        let k = p < 0.5 ? 0.5 - 0.5 * cos(p * .pi * 2) : 0
        return BloubEase.clamp01(k * 2)
    }

    /// Wrap a looping state without putting mutable clock state in the
    /// renderer. The first and last frames of the continuous work cycles are
    /// authored to meet, so a long-running hook never freezes on a one-shot's
    /// final frame.
    private static func loopTime(_ t: CGFloat, period: CGFloat) -> CGFloat {
        guard period > 0 else { return 0 }
        let wrapped = t.truncatingRemainder(dividingBy: period)
        return wrapped < 0 ? wrapped + period : wrapped
    }

    /// Native counterparts for clawd-on-desk's mini-mode assets. The native
    /// renderer does not copy the upstream SVG files, but keeping these as
    /// real catalogue states means a custom theme can still replace them and
    /// the built-in renderer never falls back to an unrelated full-size pose.
    private static func miniRestPose() -> BloubPose {
        var pose = BloubPose()
        pose.gaze = BloubMotion.restGaze
        return pose
    }

    private static func miniAlertPose(at t: CGFloat) -> BloubPose {
        let p = BloubEase.clamp01(t / 0.45)
        let pop = 1 + (BloubDecor.notifPop - 1) * sin(p * .pi) * (1 - p * 0.35)
        let r = BloubDecor.notifR * (p < 1 ? pop : 1)
        let angle = BloubDecor.notifAngle * .pi / 180
        var pose = BloubPose()
        pose.gaze = BloubGaze(yaw: -18, pitch: -5, roll: -8)
        pose.notification = BloubNotification(
            x: cos(angle) * BloubDecor.notifDist,
            y: sin(angle) * BloubDecor.notifDist,
            r: r,
            notch: r + BloubDecor.notifMargin
        )
        return pose
    }

    private static func miniHappyPose(at t: CGFloat) -> BloubPose {
        let collapse = 1 - 0.72 * BloubEase.easeOutQuint(BloubEase.clamp01(t / 0.45))
        let regrow = BloubEase.easeOutQuint(BloubEase.clamp01((t - 0.9) / 0.65))
        var pose = BloubPose()
        pose.body = BloubBody(profile: .circle(collapse + (1 - collapse) * regrow))
        pose.eyeOpacity = BloubEase.clamp01((t - 1.05) / 0.3)
        pose.dots = BloubDecor.burstParticles(at: t)
        pose.dotsBehind = true
        return pose
    }

    public static let catalog: [BloubState: BloubStateDefinition] = [
        .idle: BloubStateDefinition(
            id: .idle,
            duration: 2.4,
            morph: 0.45,
            blinkIn: false,
            baseBody: true,
            baseFace: true,
            settlesAt: 0  // static pose
        ) { _ in BloubPose() },

        .roam: BloubStateDefinition(
            id: .roam,
            duration: 1.2,
            morph: 0.35,
            blinkIn: false,
            baseBody: true,
            baseFace: false,
            settlesAt: nil
        ) { t in
            let phase = BloubStates.loopTime(t, period: 0.8)
            let stride = sin(phase * .pi * 2)
            var pose = BloubPose()
            pose.body = BloubBody(
                profile: .circle(1),
                rotation: stride * 0.045,
                center: CGPoint(x: stride * 0.025, y: abs(stride) * 0.07),
                scale: CGSize(width: 1 + abs(stride) * 0.025, height: 1 - abs(stride) * 0.025)
            )
            pose.gaze = BloubGaze(yaw: 10, pitch: -4, roll: -2)
            return pose
        },

        .thinking: BloubStateDefinition(
            id: .thinking,
            duration: 2.6,
            morph: 0.4,
            blinkIn: true,
            baseBody: false,
            baseFace: false,
            settlesAt: nil  // pulse loops forever
        ) { t in
            let mid = dotPulse(t, 1)
            // The side dots emerge from the ball's flanks: on the video they
            // stay fused with it for 1-2 frames before detaching.
            let emerge = 0.3 + 0.7 * BloubEase.easeOutCubic(BloubEase.clamp01(t / 0.3))
            var pose = BloubPose()
            // The ball BECOMES the middle dot: the morph stays continuous.
            pose.body = BloubBody(
                profile: .circle(BloubDecor.dotR * (1 + (BloubDecor.dotPeak - 1) * mid)),
                center: CGPoint(x: BloubDecor.dotX[1], y: 0)
            )
            pose.eyeOpacity = 0
            pose.dots = [0, 2].map { index in
                let k = dotPulse(t, index)
                return BloubDotSpec(
                    x: BloubDecor.dotX[index] * emerge,
                    y: 0,
                    r: BloubDecor.dotR * (1 + (BloubDecor.dotPeak - 1) * k),
                    opacity: 0.55 + 0.45 * k
                )
            }
            return pose
        },

        .wink: BloubStateDefinition(
            id: .wink,
            duration: 1.6,
            morph: 0.3,
            blinkIn: true,
            baseBody: true,
            baseFace: false,
            settlesAt: 0  // static pose
        ) { _ in
            var pose = BloubPose()
            pose.gaze = BloubGaze(yaw: -5.37, pitch: 4.55, roll: 6.7)
            pose.split = 16.25
            // The closed eye is not the open eye squashed: it is a horizontal
            // dash WIDER than the open eye (0.447 against 0.236).
            pose.eyes = [
                BloubEyeConfig(width: 0.236, height: 0.464),
                BloubEyeConfig(width: 0.447, height: 0.089)
            ]
            return pose
        },

        .wide: BloubStateDefinition(
            id: .wide,
            duration: 1.8,
            morph: 0.55,
            blinkIn: true,
            baseBody: true,
            baseFace: false,
            settlesAt: 0  // static pose
        ) { _ in
            var pose = BloubPose()
            pose.gaze = BloubGaze(yaw: 6.92, pitch: -21.96, roll: 11.6)
            pose.split = 18.43
            pose.eyes = .pair(0.356, 0.875)
            return pose
        },

        .alert: BloubStateDefinition(
            id: .alert,
            duration: 2.4,
            minDuration: 2,
            morph: 0.45,
            blinkIn: false,
            baseBody: false,
            baseFace: false,
            settlesAt: 2.1  // the ! is back in place; the 0.005R buzz is sub-pixel
        ) { t in
            // Measured run: -0.087 -> +0.732 in 1.5 s, ease-in-out,
            // micro-overshoot; the "!" is back in place at 1.6 + 0.4.
            let p = BloubEase.clamp01(t / 1.5)
            let travel = BloubEase.easeInOutCubic(p) * 0.82 - 0.087
            let back = t > 1.6 ? BloubEase.clamp01((t - 1.6) / 0.4) : 0
            let x = travel * (1 - back) + 0.1 * back
            // Secondary vibration at 2.5 Hz, bar and dot out of phase.
            let buzz = sin(t * 2.5 * .pi * 2) * 0.005
            let tilt = 17.7 * .pi / 180
            var pose = BloubPose()
            pose.body = BloubBody(
                profile: barItalic,
                rotation: tilt,
                center: CGPoint(x: x, y: -0.325 - buzz)
            )
            pose.eyeOpacity = 0
            pose.dots = [
                BloubDotSpec(
                    // The dot follows the glyph axis, 0.580 from the bar centre.
                    x: x - sin(tilt) * 0.58,
                    y: -0.325 + cos(tilt) * 0.58 + buzz * 2.8,
                    r: 0.118,
                    opacity: 1,
                    drop: tear,
                    dropRotation: tilt * 180 / .pi
                )
            ]
            return pose
        },

        .notify: BloubStateDefinition(
            id: .notify,
            duration: 2.2,
            morph: 0.5,
            blinkIn: true,
            baseBody: true,
            baseFace: false,
            settlesAt: 0.5  // badge pop settled
        ) { t in
            // Blue badge pop: peaks at +14 % around 0.3 s then stabilises.
            let p = BloubEase.clamp01(t / 0.45)
            let pop = 1 + (BloubDecor.notifPop - 1) * sin(p * .pi) * (1 - p * 0.35)
            let r = BloubDecor.notifR * (p < 1 ? pop : 1)
            let angle = BloubDecor.notifAngle * .pi / 180
            var pose = BloubPose()
            // The gaze turns away from the badge.
            pose.gaze = BloubGaze(yaw: -21.94, pitch: -5.82, roll: -12.2)
            pose.split = 18.89
            pose.eyes = .pair(0.505, 0.498)
            pose.notification = BloubNotification(
                x: cos(angle) * BloubDecor.notifDist,
                y: sin(angle) * BloubDecor.notifDist,
                r: r,
                notch: r + BloubDecor.notifMargin
            )
            return pose
        },

        .exclaim: BloubStateDefinition(
            id: .exclaim,
            duration: 2,
            morph: 0.45,
            blinkIn: false,
            baseBody: false,
            baseFace: false,
            settlesAt: 0  // static pose
        ) { _ in
            var pose = BloubPose()
            pose.body = BloubBody(
                profile: barUpright,
                center: CGPoint(x: 0, y: barUprightCenterY)
            )
            pose.eyeOpacity = 0
            pose.dots = [BloubDotSpec(x: -0.012, y: 0.526, r: 0.113, opacity: 1)]
            return pose
        },

        .sleep: BloubStateDefinition(
            id: .sleep,
            duration: 2.4,
            morph: 0.5,
            blinkIn: false,
            baseBody: false,
            baseFace: false,
            settlesAt: nil  // bounce loops forever
        ) { t in
            var pose = BloubPose()
            // Measured vertical bounce: ±0.19 around +0.11, period 0.6 s.
            pose.body = BloubBody(
                profile: .circle(0.1585),
                center: CGPoint(x: 0, y: 0.11 + sin(t * (.pi * 2 / 0.6)) * 0.19)
            )
            pose.eyeOpacity = 0
            return pose
        },

        // The following six states are Clawdesk lifecycle overlays. They
        // retain the same low-detail native language as bloub while keeping
        // the original clawd-on-desk sleep sequence observable when a theme
        // does not provide its own SVG for the phase.
        .yawning: BloubStateDefinition(
            id: .yawning,
            duration: 3.0,
            morph: 0.45,
            blinkIn: true,
            baseBody: true,
            baseFace: false,
            settlesAt: nil
        ) { t in
            let phase = BloubStates.loopTime(t, period: 3.0)
            let mouth = sin(phase * .pi / 3)
            var pose = BloubPose()
            pose.body = BloubBody(
                profile: .circle(1),
                center: CGPoint(x: 0, y: abs(mouth) * 0.025),
                scale: CGSize(width: 1 + abs(mouth) * 0.015, height: 1 - abs(mouth) * 0.03)
            )
            pose.gaze = BloubGaze(yaw: -4, pitch: 9 + mouth * 6, roll: 0)
            pose.eyes = .mirrored(0.19, 0.28, 0, 0.9 - abs(mouth) * 0.55)
            return pose
        },

        .dozing: BloubStateDefinition(
            id: .dozing,
            duration: 2.4,
            morph: 0.4,
            blinkIn: false,
            baseBody: true,
            baseFace: false,
            settlesAt: 0.8
        ) { t in
            let phase = BloubStates.loopTime(t, period: 2.4)
            let breath = sin(phase * .pi * 2 / 2.4)
            var pose = BloubPose()
            pose.body = BloubBody(
                profile: .circle(1),
                center: CGPoint(x: 0, y: 0.015 + breath * 0.012),
                scale: CGSize(width: 1.01, height: 0.985)
            )
            pose.gaze = BloubGaze(yaw: 0, pitch: 11, roll: 0)
            pose.eyes = .mirrored(0.19, 0.24, 0, 0.28)
            return pose
        },

        .collapsing: BloubStateDefinition(
            id: .collapsing,
            duration: 1.0,
            morph: 0.35,
            blinkIn: false,
            baseBody: false,
            baseFace: false,
            settlesAt: 1.0
        ) { t in
            let progress = BloubEase.easeInOutCubic(BloubEase.clamp01(t / 1.0))
            var pose = BloubPose()
            pose.body = BloubBody(
                profile: .circle(BloubEase.lerp(1, BloubDecor.cometDot, progress)),
                center: CGPoint(x: 0, y: BloubEase.lerp(0, 0.11, progress))
            )
            pose.eyeOpacity = 1 - BloubEase.clamp01((progress - 0.55) / 0.45)
            return pose
        },

        .sleeping: BloubStateDefinition(
            id: .sleeping,
            duration: 2.4,
            morph: 0.35,
            blinkIn: false,
            baseBody: false,
            baseFace: false,
            settlesAt: nil
        ) { t in
            var pose = BloubPose()
            pose.body = BloubBody(
                profile: .circle(BloubDecor.cometDot),
                center: CGPoint(x: 0, y: 0.11 + sin(t * (.pi * 2 / 0.6)) * 0.19)
            )
            pose.eyeOpacity = 0
            return pose
        },

        .waking: BloubStateDefinition(
            id: .waking,
            duration: 1.3,
            morph: 0.3,
            blinkIn: true,
            baseBody: false,
            baseFace: false,
            settlesAt: 1.3
        ) { t in
            let progress = BloubEase.easeOutCubic(BloubEase.clamp01(t / 1.3))
            var pose = BloubPose()
            pose.body = BloubBody(
                profile: .circle(BloubEase.lerp(BloubDecor.cometDot, 1, progress)),
                center: CGPoint(x: 0, y: BloubEase.lerp(0.11, 0, progress))
            )
            pose.eyeOpacity = BloubEase.clamp01((progress - 0.45) / 0.35)
            pose.arcs = BloubDecor.rings.prefix(3).enumerated().map { index, seed in
                BloubArcRequest(
                    id: "wk\(index)",
                    seed: seed,
                    t: t,
                    opacity: BloubEase.clamp01((t - CGFloat(index) * 0.08) / 0.16)
                        * BloubEase.clamp01((1.22 - t) / 0.28)
                )
            }
            return pose
        },

        .wakingFromDoze: BloubStateDefinition(
            id: .wakingFromDoze,
            duration: 0.6,
            morph: 0.25,
            blinkIn: true,
            baseBody: true,
            baseFace: false,
            settlesAt: 0.6
        ) { t in
            let progress = BloubEase.easeOutCubic(BloubEase.clamp01(t / 0.6))
            var pose = BloubPose()
            pose.body = BloubBody(
                profile: .circle(1),
                center: CGPoint(x: 0, y: (1 - progress) * 0.02),
                scale: CGSize(width: 1 + progress * 0.01, height: 0.985 + progress * 0.015)
            )
            pose.gaze = BloubGaze(yaw: 0, pitch: 8 - progress * 8, roll: 0)
            pose.eyes = .mirrored(0.19, 0.35, 0, 0.2 + progress * 0.8)
            return pose
        },

        .building: BloubStateDefinition(
            id: .building,
            duration: 2.8,
            morph: 0.45,
            blinkIn: true,
            baseBody: false,
            baseFace: false,
            settlesAt: nil
        ) { t in
            let phase = BloubStates.loopTime(t, period: 2.8)
            let wave = sin(phase * .pi * 2 / 2.8)
            let rotation = wave * 0.16
            var pose = BloubPose()
            pose.body = BloubBody(
                profile: BloubProfileFixture.hexagon,
                rotation: rotation,
                center: CGPoint(x: wave * 0.035, y: abs(wave) * 0.025),
                scale: CGSize(width: 1 + abs(wave) * 0.035, height: 1 - abs(wave) * 0.025)
            )
            pose.gaze = BloubGaze(yaw: 22 + wave * 10, pitch: 20 - wave * 8, roll: -12 + wave * 4)
            pose.split = 13.37
            pose.eyes = .pair(0.177, 0.411)
            pose.arcs = BloubDecor.swoosh.enumerated().map { index, seed in
                BloubArcRequest(
                    id: "bd\(index)",
                    seed: seed,
                    t: phase,
                    opacity: 0.25 + 0.55 * BloubEase.clamp01(
                        0.5 + 0.5 * sin(phase * .pi * 2 / 2.8 + CGFloat(index) * 0.8)
                    )
                )
            }
            return pose
        },

        .carrying: BloubStateDefinition(
            id: .carrying,
            duration: 2.2,
            morph: 0.4,
            blinkIn: true,
            baseBody: false,
            baseFace: false,
            settlesAt: nil
        ) { t in
            let phase = BloubStates.loopTime(t, period: 2.2)
            let bob = sin(phase * .pi * 2 / 2.2)
            var pose = BloubPose()
            pose.body = BloubBody(
                profile: BloubProfileFixture.egg,
                rotation: -0.12 + bob * 0.08,
                center: CGPoint(x: bob * 0.025, y: 0.04 + abs(bob) * 0.025),
                scale: CGSize(width: 0.96 + abs(bob) * 0.035, height: 1 - abs(bob) * 0.02)
            )
            pose.gaze = BloubGaze(yaw: 20 + bob * 12, pitch: 24 - bob * 8, roll: -17 + bob * 5)
            pose.split = 11.07
            pose.eyes = .pair(0.164, 0.385)
            pose.dots = [
                BloubDotSpec(x: -0.38 + bob * 0.04, y: -0.62, r: 0.045, opacity: 0.5 + 0.3 * abs(bob)),
                BloubDotSpec(x: 0.42 - bob * 0.04, y: -0.58, r: 0.035, opacity: 0.45 + 0.25 * abs(bob))
            ]
            return pose
        },

        .sweeping: BloubStateDefinition(
            id: .sweeping,
            duration: 2.4,
            morph: 0.45,
            blinkIn: false,
            baseBody: false,
            baseFace: false,
            settlesAt: nil
        ) { t in
            let phase = BloubStates.loopTime(t, period: 5.2)
            let travel = phase <= 2.6 ? phase : 5.2 - phase
            let collapse = 1 - (1 - BloubDecor.cometDot) * BloubEase.easeOutQuint(
                BloubEase.clamp01(travel / 0.65)
            )
            let regrow = BloubEase.easeOutQuint(BloubEase.clamp01((travel - 1.75) / 0.7))
            let radius = collapse + (1 - collapse) * regrow
            let fade = BloubEase.clamp01((travel - 0.1) / 0.25)
                * BloubEase.clamp01((2.2 - travel) / 0.4)
            var pose = BloubPose()
            pose.body = BloubBody(
                profile: .circle(radius),
                center: CGPoint(
                    x: sin(travel * .pi / 2.6) * 0.035,
                    y: sin(BloubEase.clamp01(travel / 1.8) * .pi) * 0.05
                )
            )
            pose.eyeOpacity = BloubEase.clamp01((travel - 1.9) / 0.35)
            pose.arcs = BloubDecor.cometRibbons.enumerated().map { index, seed in
                BloubArcRequest(id: "swp\(index)", seed: seed, t: travel, opacity: fade)
            }
            return pose
        },

        .egg: BloubStateDefinition(
            id: .egg,
            duration: 1.8,
            morph: 0.4,
            blinkIn: true,
            baseBody: false,
            baseFace: false,
            settlesAt: 0  // static pose
        ) { _ in
            var pose = BloubPose()
            pose.body = BloubBody(profile: BloubProfileFixture.egg)
            pose.gaze = BloubGaze(yaw: 19.97, pitch: 26.01, roll: -17.1)
            // The eyes tighten like the body.
            pose.split = 11.07
            pose.eyes = .pair(0.164, 0.385)
            return pose
        },

        .hexagon: BloubStateDefinition(
            id: .hexagon,
            duration: 1.6,
            morph: 0.4,
            blinkIn: true,
            baseBody: false,
            baseFace: false,
            settlesAt: 0  // static pose
        ) { _ in
            var pose = BloubPose()
            pose.body = BloubBody(profile: BloubProfileFixture.hexagon)
            pose.gaze = BloubGaze(yaw: 23.11, pitch: 24.42, roll: -13.3)
            pose.split = 13.37
            pose.eyes = .pair(0.177, 0.411)
            return pose
        },

        .play: BloubStateDefinition(
            id: .play,
            duration: 2,
            minDuration: nil,
            morph: 0.5,
            blinkIn: true,
            baseBody: false,
            baseFace: false,
            settlesAt: nil  // continuous working cycle
        ) { t in
            let phase = loopTime(t, period: 2.4)
            // The triangle stays nearly still while the bouquet crosses it.
            let fade = BloubEase.clamp01(phase / 0.35) * BloubEase.clamp01((2.2 - phase) / 0.5)
            var pose = BloubPose()
            pose.body = spinningTriangle(0)
            pose.gaze = BloubGaze(yaw: 12, pitch: -8, roll: -6)
            pose.split = 15
            pose.eyes = .pair(0.18, 0.34)
            // The bouquet sweeps right-to-left over the triangle.
            pose.arcs = BloubDecor.swoosh.enumerated().map { index, seed in
                BloubArcRequest(
                    id: "sw\(index)",
                    seed: BloubArcSeed(
                        a: seed.a, k: seed.k, tilt: seed.tilt, speed: seed.speed,
                        phase: seed.phase, sweep: seed.sweep, hue: seed.hue,
                        hueSpan: seed.hueSpan, width: seed.width,
                        cx: 0.45 - phase * 0.42, cy: seed.cy
                    ),
                    t: phase,
                    opacity: fade
                )
            }
            return pose
        },

        .orbit: BloubStateDefinition(
            id: .orbit,
            duration: 3.4,
            minDuration: nil,
            morph: 0.6,
            blinkIn: false,
            baseBody: false,
            baseFace: false,
            settlesAt: nil  // continuous multi-agent cycle
        ) { t in
            let phase = loopTime(t, period: 4.6)
            // The measured entry relaxes triangle -> ball. Mirror that
            // travel on the second half so the cycle returns to its exact
            // opening silhouette instead of snapping at the wrap point.
            let travel = phase <= 2.3 ? phase : 4.6 - phase
            // Measured rotation: ramp over 0.35 s then 1.25 turns/s
            // (counter-clockwise).
            let ramp = BloubEase.easeInOutCubic(BloubEase.clamp01(travel / 0.35))
            let rotation = -.pi * 2 * 1.25 * travel * ramp
            // The body relaxes from triangle to ball during the orbit.
            let back = BloubEase.easeInOutCubic(BloubEase.clamp01((travel - 1.6) / 0.9))
            let tri = spinningTriangle(rotation)
            let ball = BloubBody(profile: .circle(1), rotation: rotation)
            var radii = tri.profile.radii
            for index in 0..<radii.count {
                radii[index] += (ball.profile.radii[index] - radii[index]) * back
            }
            let body = BloubBody(
                profile: RadialProfile(radii: radii),
                rotation: rotation,
                center: CGPoint(x: tri.center.x * (1 - back), y: tri.center.y * (1 - back))
            )
            let fade = BloubEase.clamp01(phase / 0.8) * BloubEase.clamp01((4.2 - phase) / 0.9)
            var pose = BloubPose()
            pose.body = body
            // The eyes race around the sphere ~3x faster than the silhouette.
            pose.gaze = BloubGaze(
                yaw: BloubMotion.restGaze.yaw + sin(travel * 6.5) * 65 * (1 - back),
                pitch: CGFloat(-4) + back * CGFloat(32),
                roll: -13
            )
            pose.eyes = .pair(0.18, 0.34 + back * 0.07)
            // The rings enter one by one over 0.8 s.
            pose.arcs = BloubDecor.rings.enumerated().map { index, seed in
                BloubArcRequest(
                    id: "rg\(index)",
                    seed: seed,
                    t: phase,
                    opacity: fade * BloubEase.clamp01((phase - CGFloat(index) * 0.13) / 0.3)
                )
            }
            return pose
        },

        .swirl: BloubStateDefinition(
            id: .swirl,
            // A little more than a full gaze turn (1.1 s): the eyes must be
            // settled left before the rings fade away.
            duration: 1.3,
            minDuration: 1.3,
            morph: 0.3,
            blinkIn: true,
            baseBody: true,
            baseFace: true,
            settlesAt: 1.3  // rings gone
        ) { t in
            var pose = BloubPose()
            // Three rings out of orbit's six: half the bouquet is enough to
            // recognise it, and fewer arcs to rasterise per frame. They enter
            // one after another then fade before the block ends, so the
            // return to rest lands on an already-clean frame.
            pose.arcs = BloubDecor.rings.prefix(3).enumerated().map { index, seed in
                BloubArcRequest(
                    id: "sw\(index)",
                    seed: seed,
                    t: t,
                    opacity: BloubEase.clamp01((t - CGFloat(index) * 0.06) / 0.14)
                        * BloubEase.clamp01((1.22 - t) / 0.34)
                )
            }
            return pose
        },

        .burst: BloubStateDefinition(
            id: .burst,
            duration: 2.6,
            minDuration: 2.4,
            morph: 0.4,
            blinkIn: false,
            baseBody: false,
            baseFace: false,
            settlesAt: 2.5  // core regrown
        ) { t in
            // Measured collapse: 1.0 -> 0.166 in 0.7 s, ease-out, no bounce.
            let collapse = 1 - 0.834 * BloubEase.easeOutQuint(BloubEase.clamp01(t / 0.7))
            let regrow = BloubEase.easeOutQuint(BloubEase.clamp01((t - 1.7) / 0.7))
            var pose = BloubPose()
            pose.body = BloubBody(profile: .circle(collapse + (1 - collapse) * regrow))
            pose.eyeOpacity = BloubEase.clamp01((t - 1.85) / 0.4)
            pose.dots = BloubDecor.burstParticles(at: t)
            pose.dotsBehind = true
            return pose
        },

        .comet: BloubStateDefinition(
            id: .comet,
            duration: 2.4,
            minDuration: nil,
            morph: 0.45,
            blinkIn: false,
            baseBody: false,
            baseFace: false,
            settlesAt: nil  // continuous single-agent/compaction cycle
        ) { t in
            let phase = loopTime(t, period: 5.2)
            // Preserve the measured collapse/regrow on the first half and
            // play it backwards on the second half, making the final dot
            // meet the opening dot continuously at the loop boundary.
            let travel = phase <= 2.6 ? phase : 5.2 - phase
            let collapse = 1 - (1 - BloubDecor.cometDot) * BloubEase.easeOutQuint(BloubEase.clamp01(travel / 0.55))
            let regrow = BloubEase.easeOutQuint(BloubEase.clamp01((travel - 1.85) / 0.6))
            let fade = BloubEase.clamp01((travel - 0.15) / 0.25) * BloubEase.clamp01((1.95 - travel) / 0.3)
            var pose = BloubPose()
            // The dot drifts 0.035 downward then rises (measured wobble).
            pose.body = BloubBody(
                profile: .circle(collapse + (1 - collapse) * regrow),
                center: CGPoint(x: 0, y: sin(BloubEase.clamp01(travel / 1.7) * .pi) * 0.035)
            )
            pose.eyeOpacity = BloubEase.clamp01((travel - 2) / 0.35)
            pose.arcs = BloubDecor.cometRibbons.enumerated().map { index, seed in
                BloubArcRequest(id: "cm\(index)", seed: seed, t: travel, opacity: fade)
            }
            return pose
        },

        .dizzy: BloubStateDefinition(
            id: .dizzy,
            duration: 6,
            minDuration: nil,
            morph: 0.45,
            blinkIn: false,
            baseBody: true,
            baseFace: false,
            settlesAt: nil
        ) { t in
            let angle = BloubStates.loopTime(t, period: 3) * .pi * 2 / 3
            let wobble = sin(angle)
            var pose = BloubPose()
            // A small elliptical sway keeps the body grounded while the
            // rings and eyes communicate the original dizzy reaction.
            pose.body = BloubBody(
                profile: .circle(1),
                rotation: wobble * 0.06,
                center: CGPoint(x: cos(angle) * 0.018, y: sin(angle) * 0.012),
                scale: CGSize(width: 1 + wobble * 0.012, height: 1 - wobble * 0.012)
            )
            pose.gaze = BloubGaze(
                yaw: sin(angle * 2) * 24,
                pitch: cos(angle * 2) * 10,
                roll: sin(angle) * 8
            )
            pose.eyes = .pair(0.18, 0.34)
            pose.arcs = BloubDecor.rings.prefix(3).enumerated().map { index, seed in
                BloubArcRequest(
                    id: "dz\(index)",
                    seed: seed,
                    t: t,
                    opacity: 0.78
                )
            }
            return pose
        },

        .miniIdle: BloubStateDefinition(
            id: .miniIdle,
            duration: 2.4,
            morph: 0.35,
            blinkIn: false,
            baseBody: true,
            baseFace: true,
            settlesAt: 0
        ) { _ in
            BloubStates.miniRestPose()
        },

        .miniPeek: BloubStateDefinition(
            id: .miniPeek,
            duration: 1.2,
            morph: 0.3,
            blinkIn: true,
            baseBody: true,
            baseFace: false,
            settlesAt: 0.9
        ) { t in
            let wave = sin(BloubStates.loopTime(t, period: 0.9) * .pi * 2)
            var pose = BloubPose()
            pose.body = BloubBody(
                profile: .circle(1),
                rotation: wave * 0.035,
                center: CGPoint(x: wave * 0.025, y: abs(wave) * 0.025)
            )
            pose.gaze = BloubGaze(yaw: -12, pitch: -4, roll: wave * 3)
            pose.eyes = .pair(0.22, 0.42)
            return pose
        },

        .miniAlert: BloubStateDefinition(
            id: .miniAlert,
            duration: 2.2,
            morph: 0.35,
            blinkIn: true,
            baseBody: true,
            baseFace: false,
            settlesAt: 0.5
        ) { t in
            BloubStates.miniAlertPose(at: t)
        },

        .miniHappy: BloubStateDefinition(
            id: .miniHappy,
            duration: 2.6,
            morph: 0.35,
            blinkIn: false,
            baseBody: false,
            baseFace: false,
            settlesAt: 2.1
        ) { t in
            BloubStates.miniHappyPose(at: t)
        },

        .miniWorking: BloubStateDefinition(
            id: .miniWorking,
            duration: 2.0,
            morph: 0.35,
            blinkIn: true,
            baseBody: true,
            baseFace: false,
            settlesAt: nil
        ) { t in
            let phase = BloubStates.loopTime(t, period: 2.4)
            var pose = BloubPose()
            pose.body = BloubBody(
                profile: .circle(1),
                center: CGPoint(x: 0, y: sin(phase * .pi * 2 / 2.4) * 0.035),
                scale: CGSize(width: 1.015, height: 0.985)
            )
            pose.gaze = BloubGaze(yaw: 8, pitch: -6, roll: -4)
            pose.arcs = BloubDecor.swoosh.prefix(2).enumerated().map { index, seed in
                BloubArcRequest(
                    id: "mw\(index)",
                    seed: seed,
                    t: phase,
                    opacity: BloubEase.clamp01(phase / 0.35)
                        * BloubEase.clamp01((2.2 - phase) / 0.5)
                )
            }
            return pose
        },

        .miniCrabwalk: BloubStateDefinition(
            id: .miniCrabwalk,
            duration: 1.2,
            morph: 0.3,
            blinkIn: false,
            baseBody: true,
            baseFace: false,
            settlesAt: nil
        ) { t in
            let phase = BloubStates.loopTime(t, period: 0.65)
            let stride = sin(phase * .pi * 2)
            var pose = BloubPose()
            pose.body = BloubBody(
                profile: .circle(1),
                rotation: stride * 0.08,
                center: CGPoint(x: stride * 0.04, y: abs(stride) * 0.06),
                scale: CGSize(width: 1 + abs(stride) * 0.04, height: 1 - abs(stride) * 0.03)
            )
            pose.gaze = BloubGaze(yaw: -16, pitch: -2, roll: -4)
            return pose
        },

        .miniEnter: BloubStateDefinition(
            id: .miniEnter,
            duration: 3.2,
            morph: 0.35,
            blinkIn: true,
            baseBody: true,
            baseFace: false,
            settlesAt: 1.2
        ) { t in
            let progress = BloubEase.easeOutCubic(BloubEase.clamp01(t / 1.2))
            var pose = BloubPose()
            pose.body = BloubBody(
                profile: .circle(1),
                center: CGPoint(x: 0, y: (1 - progress) * 0.35),
                scale: CGSize(width: 0.92 + progress * 0.08, height: 0.88 + progress * 0.12)
            )
            pose.gaze = BloubGaze(yaw: -8 + progress * 8, pitch: -8 + progress * 4, roll: 0)
            return pose
        },

        .miniEnterSleep: BloubStateDefinition(
            id: .miniEnterSleep,
            duration: 2.4,
            morph: 0.35,
            blinkIn: false,
            baseBody: false,
            baseFace: false,
            settlesAt: 1.0
        ) { t in
            let progress = BloubEase.easeOutCubic(BloubEase.clamp01(t / 1.0))
            var pose = BloubPose()
            pose.body = BloubBody(
                profile: .circle(BloubEase.lerp(1, 0.1585, progress)),
                center: CGPoint(x: 0, y: BloubEase.lerp(0, 0.11, progress))
            )
            pose.eyeOpacity = 0
            return pose
        },

        .miniSleep: BloubStateDefinition(
            id: .miniSleep,
            duration: 2.4,
            morph: 0.35,
            blinkIn: false,
            baseBody: false,
            baseFace: false,
            settlesAt: nil
        ) { t in
            var pose = BloubPose()
            pose.body = BloubBody(
                profile: .circle(0.1585),
                center: CGPoint(x: 0, y: 0.11 + sin(t * (.pi * 2 / 0.6)) * 0.14)
            )
            pose.eyeOpacity = 0
            return pose
        }
    ]
}
