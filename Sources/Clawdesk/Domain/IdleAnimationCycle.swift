import Foundation

/// Pure once-per-quiet-period selection for theme-provided idle animations.
/// The UI owns the timer and cancellation; this type owns the upstream rule
/// that a quiet period may consume at most one random animation.
public struct IdleAnimationCycle: Equatable, Sendable {
    public static let quietPeriod: TimeInterval = 20

    public private(set) var activity: Date?
    public private(set) var hasPlayed = false

    public init() {}

    public mutating func reset(for activity: Date) {
        self.activity = activity
        hasPlayed = false
    }

    public mutating func choose(
        now: Date,
        activity: Date,
        animations: [ThemeIdleAnimation],
        selectedIdleFile: String?,
        quietPeriod: TimeInterval = Self.quietPeriod,
        randomIndex: (Int) -> Int
    ) -> ThemeIdleAnimation? {
        if self.activity != activity {
            reset(for: activity)
        }
        guard !hasPlayed,
              now.timeIntervalSince(activity) >= max(0.25, quietPeriod) else { return nil }

        hasPlayed = true
        let pool = animations.filter { $0.file != selectedIdleFile }
        guard !pool.isEmpty else { return nil }
        let index = min(pool.count - 1, max(0, randomIndex(pool.count)))
        return pool[index]
    }
}
