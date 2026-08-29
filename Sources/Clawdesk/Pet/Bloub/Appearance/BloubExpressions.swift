import CoreGraphics
import Foundation

/// Resting expression of the bot.
///
/// The face is two capsules, so everything rides on four levers: head
/// orientation, eye separation, proportions, and each eye's own tilt. The
/// tilt is what makes anger and sadness possible — they need MIRRORED tilts,
/// impossible with head roll alone, which tilts both eyes the same way.
///
/// Only rest-face states wear this expression (`idle`, `swirl`); the
/// expressive video states keep their measured faces.
public enum BloubExpressionID: String, CaseIterable, Sendable, Equatable {
    case neutral
    case attentive
    case surprised
    case excited
    case happy
    case gleeful
    case angry
    case sad
    case scared
    case suspicious
    case confused
    case curious
    case proud
    case shy
    case unimpressed
    case sleepy

    /// Display names stay untranslated, like theme names.
    public var displayName: String {
        switch self {
        case .neutral: return "Neutral"
        case .attentive: return "Attentive"
        case .surprised: return "Surprised"
        case .excited: return "Excited"
        case .happy: return "Happy"
        case .gleeful: return "Gleeful"
        case .angry: return "Angry"
        case .sad: return "Sad"
        case .scared: return "Scared"
        case .suspicious: return "Suspicious"
        case .confused: return "Confused"
        case .curious: return "Curious"
        case .proud: return "Proud"
        case .shy: return "Shy"
        case .unimpressed: return "Unimpressed"
        case .sleepy: return "Sleepy"
        }
    }
}

public struct BloubExpression: Equatable, Sendable {
    public let id: BloubExpressionID
    public let gaze: BloubGaze
    public let split: CGFloat
    public let eyes: [BloubEyeConfig]

    public init(id: BloubExpressionID, gaze: BloubGaze, split: CGFloat, eyes: [BloubEyeConfig]) {
        self.id = id
        self.gaze = gaze
        self.split = split
        self.eyes = eyes
    }

    /// `tilt` in degrees, positive = the top of the capsule leans right.
    private static func eye(_ w: CGFloat, _ h: CGFloat, _ tilt: CGFloat = 0, _ open: CGFloat = 1) -> BloubEyeConfig {
        BloubEyeConfig(width: w, height: h, openness: open, tilt: tilt)
    }

    /// Two identical eyes, mirrored tilts when a tilt is given.
    private static func mirrored(_ w: CGFloat, _ h: CGFloat, _ tilt: CGFloat = 0, _ open: CGFloat = 1) -> [BloubEyeConfig] {
        [eye(w, h, tilt, open), eye(w, h, -tilt, open)]
    }

    public static let expressions: [BloubExpression] = [
        BloubExpression(
            // the pose measured frame by frame on the reference video
            id: .neutral,
            gaze: BloubMotion.restGaze,
            split: BloubFace.eyeSplit,
            eyes: .mirrored(BloubFace.eyeWidth, BloubFace.eyeHeight)
        ),
        BloubExpression(id: .attentive, gaze: BloubGaze(yaw: 4, pitch: 5, roll: -4), split: 16, eyes: .mirrored(0.21, 0.44)),
        BloubExpression(id: .surprised, gaze: BloubGaze(yaw: 3, pitch: -3, roll: 0), split: 19, eyes: .mirrored(0.45, 0.47)),
        BloubExpression(id: .excited, gaze: BloubGaze(yaw: 6, pitch: -14, roll: 0), split: 19.5, eyes: .mirrored(0.4, 0.56, -10)),
        // eyes narrowed into arcs: the tops converge slightly
        BloubExpression(id: .happy, gaze: BloubGaze(yaw: 5, pitch: 9, roll: 0), split: 17, eyes: .mirrored(0.27, 0.17, 14)),
        BloubExpression(id: .gleeful, gaze: BloubGaze(yaw: 4, pitch: 14, roll: 0), split: 18, eyes: .mirrored(0.34, 0.13, 20)),
        // eye tops converging hard towards the centre, eyes narrowed
        BloubExpression(id: .angry, gaze: BloubGaze(yaw: 3, pitch: 7, roll: 0), split: 17, eyes: .mirrored(0.34, 0.15, 30)),
        // the opposite: tops diverge and the gaze drops
        BloubExpression(id: .sad, gaze: BloubGaze(yaw: 3, pitch: -13, roll: 0), split: 16, eyes: .mirrored(0.22, 0.4, -28)),
        BloubExpression(id: .scared, gaze: BloubGaze(yaw: 2, pitch: -20, roll: 0), split: 20.5, eyes: .mirrored(0.4, 0.6)),
        // one eye clearly more closed than the other
        BloubExpression(id: .suspicious, gaze: BloubGaze(yaw: 12, pitch: 6, roll: -6), split: 16, eyes: [eye(0.21, 0.4), eye(0.22, 0.15)]),
        // asymmetric on both axes: sizes AND tilts mismatched. The narrowed
        // eye is deliberately flat (ratio 1.6): near a ratio of 1 it would be
        // round and its tilt invisible.
        BloubExpression(id: .confused, gaze: BloubGaze(yaw: -14, pitch: 3, roll: 8), split: 16.5, eyes: [eye(0.2, 0.44, -18), eye(0.28, 0.17, 14)]),
        // the head tips: roll carries the curiosity
        BloubExpression(id: .curious, gaze: BloubGaze(yaw: 16, pitch: -9, roll: -15), split: 16.5, eyes: [eye(0.24, 0.46, -8), eye(0.2, 0.38, -8)]),
        BloubExpression(id: .proud, gaze: BloubGaze(yaw: 5, pitch: 17, roll: 0), split: 17, eyes: .mirrored(0.3, 0.15, 18)),
        BloubExpression(id: .shy, gaze: BloubGaze(yaw: -19, pitch: -14, roll: -7), split: 14, eyes: .mirrored(0.17, 0.3)),
        // horizontal slits and a gaze drifting to the side
        BloubExpression(id: .unimpressed, gaze: BloubGaze(yaw: -22, pitch: 2, roll: 0), split: 16, eyes: .mirrored(0.3, 0.12)),
        // half-closed lids via `open`, i.e. the same screen-space squash as
        // the blink
        BloubExpression(id: .sleepy, gaze: BloubGaze(yaw: 6, pitch: -9, roll: -3), split: 16, eyes: .mirrored(0.2, 0.42, 0, 0.42))
    ]

    public static func expression(_ id: BloubExpressionID) -> BloubExpression {
        expressions.first { $0.id == id } ?? expressions[0]
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

    /// Interpolation of two expressions: the change glides instead of jumping.
    public static func blend(_ a: BloubExpression, _ b: BloubExpression, _ t: CGFloat) -> BloubExpression {
        BloubExpression(
            id: b.id,
            gaze: BloubGaze(
                yaw: BloubEase.lerp(a.gaze.yaw, b.gaze.yaw, t),
                pitch: BloubEase.lerp(a.gaze.pitch, b.gaze.pitch, t),
                roll: BloubEase.lerp(a.gaze.roll, b.gaze.roll, t)
            ),
            split: BloubEase.lerp(a.split, b.split, t),
            eyes: [
                blendEyeConfig(a.eyes[0], b.eyes[0], t),
                blendEyeConfig(a.eyes[1], b.eyes[1], t)
            ]
        )
    }
}
