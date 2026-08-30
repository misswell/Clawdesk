import CoreGraphics
import Foundation

/// The small, deterministic motion model used by jeremy-prt/bloub.
///
/// Keeping this model independent from AppKit makes the native renderer cheap
/// to sample and gives us a stable seam for behavior tests. The renderer only
/// consumes the resulting angles and micro-motion values; it never owns a
/// second animation clock or a random-number generator.
public enum BloubMotion {
    public static let restGaze = BloubGaze(yaw: 28.49, pitch: 28.62, roll: -13)

    /// Amplitudes of the desktop tracking cone, in degrees. Wider than the
    /// web original's ±16/±13 (which was tuned against a page layout): on the
    /// desktop the eyes visibly slide around the ball towards the cursor,
    /// approaching the limb in all four directions — the effect asked for.
    public static let gazeYawMax = 45.0
    public static let gazePitchMax = 38.0
    /// Head pitch with the cursor centred: slightly above the equator, the
    /// original's "attentive" stance.
    public static let gazePitch = 8.0
    /// Response exponent < 1: small cursor moves still move the eyes clearly,
    /// while the full sweep saturates at the screen edge.
    public static let gazeResponse = 0.65

    /// Maps a normalized pointer position (-1...1 per half screen, y down
    /// positive) to the absolute tracking gaze: upright (roll 0) and centred
    /// on forward, so the eyes genuinely run to whichever side the cursor is
    /// on — the four-direction follow.
    public static func targetGaze(normalizedX: Double, normalizedY: Double) -> BloubGaze {
        func curve(_ value: Double) -> Double {
            let v = clamp(value)
            let shaped = pow(abs(v), gazeResponse)
            return v < 0 ? -shaped : shaped
        }
        return BloubGaze(
            yaw: curve(normalizedX) * gazeYawMax,
            pitch: gazePitch - curve(normalizedY) * gazePitchMax,
            roll: 0
        )
    }

    /// Port of bloub's pure `liveliness()` function. The periods are
    /// intentionally incommensurate, so the eye drift feels organic without
    /// requiring mutable state or per-frame allocations.
    public static func liveliness(
        at time: TimeInterval,
        wander: Double = 1,
        blink: Bool = true,
        float: Bool = true
    ) -> BloubLiveliness {
        let t = time.isFinite ? max(0, time) : 0
        let amount = min(1, max(0, wander.isFinite ? wander : 0))
        return BloubLiveliness(
            dYaw: (loopNoise(t, period: 11.3, seed: 0.4) * 5.5
                + loopNoise(t, period: 3.7, seed: 2.1) * 1.6) * amount,
            dPitch: (loopNoise(t, period: 9.1, seed: 1.3) * 4.2
                + loopNoise(t, period: 4.3, seed: 0.7) * 1.3) * amount,
            dRoll: loopNoise(t, period: 13.7, seed: 3.2) * 2.2 * amount,
            lid: blink ? blinkLid(at: t) : 1,
            driftX: float ? loopNoise(t, period: 7.9, seed: 1.9) * 0.006 : 0,
            driftY: float ? loopNoise(t, period: 5.3, seed: 0.3) * 0.007 : 0,
            breath: float ? 1 + sin((t / 3.4) * .pi * 2) * 0.005 : 1
        )
    }

    /// Quintic ease-out used by bloub for short gaze morphs.
    public static func easeOutQuint(_ value: Double) -> Double {
        let t = min(1, max(0, value.isFinite ? value : 0))
        return 1 - pow(1 - t, 5)
    }

    static func blinkLid(at time: TimeInterval) -> Double {
        for start in blinkStarts {
            if time < start { break }
            let progress = (time - start) / blinkDuration
            if progress >= 0 && progress <= 1 {
                return progress < 0.45
                    ? 1 - progress / 0.45
                    : (progress - 0.45) / 0.55
            }
        }
        return 1
    }

    private static let blinkDuration = 0.18

    private static let blinkStarts: [Double] = {
        var random = Mulberry32(seed: 0x5eed)
        var starts: [Double] = []
        var time = 1.4
        while time < 900 {
            starts.append(time)
            time += 1.9 + random.next() * 2.7
            if random.next() < 0.18 {
                starts.append(time)
                time += 0.24
            }
        }
        return starts
    }()

    private static func loopNoise(_ time: Double, period: Double, seed: Double) -> Double {
        let phase = (time / period) * (.pi * 2)
        return 0.55 * sin(phase + seed)
            + 0.3 * sin(2 * phase + seed * 1.7 + 1.1)
            + 0.15 * sin(3 * phase + seed * 2.3 + 2.4)
    }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(-1, value))
    }
}

public struct BloubGaze: Equatable, Sendable {
    public let yaw: Double
    public let pitch: Double
    public let roll: Double

    public init(yaw: Double, pitch: Double, roll: Double) {
        self.yaw = yaw
        self.pitch = pitch
        self.roll = roll
    }
}

public struct BloubLiveliness: Equatable, Sendable {
    public let dYaw: Double
    public let dPitch: Double
    public let dRoll: Double
    public let lid: Double
    public let driftX: Double
    public let driftY: Double
    public let breath: Double

    public init(
        dYaw: Double,
        dPitch: Double,
        dRoll: Double,
        lid: Double,
        driftX: Double,
        driftY: Double,
        breath: Double
    ) {
        self.dYaw = dYaw
        self.dPitch = dPitch
        self.dRoll = dRoll
        self.lid = lid
        self.driftX = driftX
        self.driftY = driftY
        self.breath = breath
    }
}

private struct Mulberry32 {
    private var state: UInt32

    init(seed: UInt32) {
        state = seed
    }

    mutating func next() -> Double {
        state &+= 0x6d2b79f5
        var value = (state ^ (state >> 15)) &* (state | 1)
        value = (value &+ ((value ^ (value >> 7)) &* (value | 61))) ^ value
        return Double(value ^ (value >> 14)) / 4_294_967_296
    }
}
