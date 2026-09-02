import CoreGraphics
import Foundation

/// Detects a deliberate cursor circle around the pet.
///
/// The detector is deliberately independent of AppKit and of the animation
/// engine. Callers provide screen-space samples and explicitly gate it to the
/// ordinary idle state. A signed angle accumulator makes back-and-forth
/// movement cancel instead of accidentally looking like a completed circle.
public struct CursorSpinDetector: Sendable {
    public static let defaultThreshold: CGFloat = .pi * 4
    public static let defaultResetAfter: TimeInterval = 0.5
    public static let defaultMinimumRadius: CGFloat = 24
    public static let defaultCooldown: TimeInterval = 12

    public let threshold: CGFloat
    public let resetAfter: TimeInterval
    public let minimumRadius: CGFloat
    public let cooldown: TimeInterval

    private var lastAngle: CGFloat?
    private var accumulatedAngle: CGFloat = 0
    private var lastSampleAt: TimeInterval?
    private var lastCursor: CGPoint?
    private var cooldownUntil: TimeInterval = -.infinity

    public init(
        threshold: CGFloat = CursorSpinDetector.defaultThreshold,
        resetAfter: TimeInterval = CursorSpinDetector.defaultResetAfter,
        minimumRadius: CGFloat = CursorSpinDetector.defaultMinimumRadius,
        cooldown: TimeInterval = CursorSpinDetector.defaultCooldown
    ) {
        self.threshold = max(0, threshold.isFinite ? threshold : Self.defaultThreshold)
        self.resetAfter = max(0, resetAfter.isFinite ? resetAfter : Self.defaultResetAfter)
        self.minimumRadius = max(0, minimumRadius.isFinite ? minimumRadius : Self.defaultMinimumRadius)
        self.cooldown = max(0, cooldown.isFinite ? cooldown : Self.defaultCooldown)
    }

    /// Clears the current gesture and cooldown. Useful when a new screen or
    /// pet session is created.
    public mutating func reset() {
        resetGesture()
        cooldownUntil = -.infinity
    }

    /// Clears only the in-progress gesture. The cooldown intentionally stays
    /// in force, so leaving idle cannot be used to bypass the reaction guard.
    public mutating func resetGesture() {
        lastAngle = nil
        accumulatedAngle = 0
        lastSampleAt = nil
        lastCursor = nil
    }

    public func isCoolingDown(at time: TimeInterval) -> Bool {
        time.isFinite && time < cooldownUntil
    }

    /// Records one screen-space cursor sample and returns true exactly when a
    /// new dizzy reaction should be emitted.
    @discardableResult
    public mutating func sample(
        cursor: CGPoint,
        center: CGPoint,
        at time: TimeInterval,
        enabled: Bool = true
    ) -> Bool {
        guard enabled,
              time.isFinite,
              cursor.x.isFinite, cursor.y.isFinite,
              center.x.isFinite, center.y.isFinite else {
            resetGesture()
            return false
        }

        let dx = cursor.x - center.x
        let dy = cursor.y - center.y
        let distance = hypot(dx, dy)
        guard distance >= minimumRadius else {
            resetGesture()
            return false
        }

        // Samples arriving after a clock correction or a long pause start a
        // new gesture. A sample exactly at the boundary is still continuous.
        if let lastSampleAt {
            guard time >= lastSampleAt else {
                resetGesture()
                return false
            }
            if time - lastSampleAt > resetAfter {
                resetGesture()
            }
        }

        guard time >= cooldownUntil else {
            // Do not retain angles during cooldown. Otherwise the first move
            // after the cooldown could inherit an old partial turn.
            resetGesture()
            return false
        }

        // Pointer polling continues while the cursor is stationary. Do not
        // treat those heartbeats as fresh gesture samples: doing so extends a
        // half-finished circle forever and makes a later pause impossible to
        // detect. The timestamp check above has already cleared a gesture
        // that really did go quiet for longer than resetAfter.
        if lastCursor == cursor {
            return false
        }

        let angle = atan2(dy, dx)
        if let lastAngle {
            var delta = angle - lastAngle
            if delta > .pi { delta -= .pi * 2 }
            if delta < -.pi { delta += .pi * 2 }
            accumulatedAngle += delta
            if abs(accumulatedAngle) >= threshold {
                cooldownUntil = time + cooldown
                resetGesture()
                return true
            }
        }

        self.lastAngle = angle
        self.lastSampleAt = time
        self.lastCursor = cursor
        return false
    }
}
