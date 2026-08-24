import Foundation

/// Monotonic animation time that is independent of the render callback rate.
///
/// A timer may be delayed by AppKit event tracking or a busy main run loop.
/// Advancing from timestamps keeps the animation speed stable instead of
/// making it run faster or slower whenever the callback frequency changes.
public struct PetAnimationClock: Equatable, Sendable {
    public private(set) var time: TimeInterval = 0

    private var lastTimestamp: TimeInterval?
    private let maximumDelta: TimeInterval

    public init(maximumDelta: TimeInterval = 0.25) {
        self.maximumDelta = max(0.01, maximumDelta)
    }

    @discardableResult
    public mutating func advance(to timestamp: TimeInterval) -> TimeInterval {
        guard timestamp.isFinite else { return 0 }

        guard let lastTimestamp else {
            self.lastTimestamp = timestamp
            return 0
        }

        let delta = min(maximumDelta, max(0, timestamp - lastTimestamp))
        self.lastTimestamp = timestamp
        time += delta
        if time > 86_400 {
            time.formTruncatingRemainder(dividingBy: 86_400)
        }
        return delta
    }

    public mutating func reset() {
        time = 0
        lastTimestamp = nil
    }
}
