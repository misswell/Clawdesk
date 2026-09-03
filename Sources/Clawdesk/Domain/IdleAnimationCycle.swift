import Foundation

/// One quiet-period idle pick: a theme-provided animation when the theme has
/// them, otherwise a bloub-native idle scene standing in for upstream's idle
/// easter eggs.
public enum IdleSceneChoice: Equatable, Sendable {
    case none
    case theme(ThemeIdleAnimation)
    case bloub(BloubIdleScene)
}

public enum BloubIdleScene: String, CaseIterable, Sendable {
    case wink
    case dizzy
}

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
        if case .theme(let animation) = chooseScene(
            now: now,
            activity: activity,
            animations: animations,
            selectedIdleFile: selectedIdleFile,
            quietPeriod: quietPeriod,
            randomIndex: randomIndex
        ) {
            return animation
        }
        return nil
    }

    /// Upstream plays a random themed animation once per quiet period. When
    /// the theme has no idle files (the built-in bloub), a bloub-native scene
    /// keeps the pet alive instead: mostly a wink, rarely a dizzy spell.
    public mutating func chooseScene(
        now: Date,
        activity: Date,
        animations: [ThemeIdleAnimation],
        selectedIdleFile: String?,
        quietPeriod: TimeInterval = Self.quietPeriod,
        randomIndex: (Int) -> Int
    ) -> IdleSceneChoice {
        if self.activity != activity {
            reset(for: activity)
        }
        guard !hasPlayed,
              now.timeIntervalSince(activity) >= max(0.25, quietPeriod) else { return .none }

        hasPlayed = true
        let pool = animations.filter { $0.file != selectedIdleFile }
        if !pool.isEmpty {
            let index = min(pool.count - 1, max(0, randomIndex(pool.count)))
            return .theme(pool[index])
        }
        // Weighted toward the subtle: three winks for every dizzy spell.
        let scenes: [BloubIdleScene] = [.wink, .wink, .wink, .dizzy]
        let index = min(scenes.count - 1, max(0, randomIndex(scenes.count)))
        return .bloub(scenes[index])
    }
}
