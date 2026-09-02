import Foundation

public enum ThemeSleepMode: String, Equatable, Sendable {
    case full
    case direct
}

/// Per-state timing overrides from a theme manifest. Values are stored in
/// seconds in the native runtime; the manifest importer converts its
/// millisecond values before constructing this type.
public struct ThemeTimingOverrides: Equatable, Sendable {
    public let minDisplay: [String: TimeInterval]
    public let autoReturn: [String: TimeInterval]

    public init(
        minDisplay: [String: TimeInterval] = [:],
        autoReturn: [String: TimeInterval] = [:]
    ) {
        self.minDisplay = Self.sanitize(minDisplay)
        self.autoReturn = Self.sanitize(autoReturn)
    }

    public func minimumDisplay(for state: PetState) -> TimeInterval? {
        minDisplay[state.rawValue] ?? minDisplay[state == .typing ? "working" : state.rawValue]
    }

    public func automaticReturn(for state: PetState) -> TimeInterval? {
        autoReturn[state.rawValue] ?? autoReturn[state == .typing ? "working" : state.rawValue]
    }

    private static func sanitize(_ values: [String: TimeInterval]) -> [String: TimeInterval] {
        values.reduce(into: [:]) { result, entry in
            let key = entry.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty, entry.value.isFinite, entry.value >= 0 else { return }
            result[key] = min(86_400, entry.value)
        }
    }
}

/// Timing values are stored in seconds inside the native runtime. Theme
/// manifests use milliseconds, so the importer is responsible for converting
/// them before constructing this value.
public struct ThemeTimings: Equatable, Sendable {
    public static let standard = ThemeTimings()

    public let mouseIdleTimeout: TimeInterval
    public let mouseSleepTimeout: TimeInterval
    public let yawnDuration: TimeInterval
    public let collapseDuration: TimeInterval
    public let wakeDuration: TimeInterval
    /// Upstream's cursor-circle reaction returns to the resolved state after
    /// six seconds by default. Themes may override the same timeout through
    /// `timings.autoReturn.dizzy`.
    public let dizzyDuration: TimeInterval
    public let deepSleepTimeout: TimeInterval
    public let dndSleepTransitionFile: String?
    public let dndSleepTransitionDuration: TimeInterval
    public let sleepMode: ThemeSleepMode
    public let dndSkipYawn: Bool
    /// The upstream renderer keeps a state visible for at least this long.
    /// These dictionaries use logical state names and seconds.
    public let minDisplay: [String: TimeInterval]
    public let autoReturn: [String: TimeInterval]
    public let miniMode: ThemeTimingOverrides?

    /// Duration used when DND enters the collapsing phase. A theme-specific
    /// transition only wins when both its file and positive duration exist;
    /// otherwise normal collapse timing remains the fallback.
    public var dndCollapseDuration: TimeInterval {
        if dndSleepTransitionFile != nil, dndSleepTransitionDuration > 0 {
            return dndSleepTransitionDuration
        }
        return collapseDuration
    }

    public init(
        mouseIdleTimeout: TimeInterval = 20,
        mouseSleepTimeout: TimeInterval = 60,
        yawnDuration: TimeInterval = 3,
        collapseDuration: TimeInterval = 1,
        wakeDuration: TimeInterval = 1.5,
        dizzyDuration: TimeInterval = 6,
        deepSleepTimeout: TimeInterval = 600,
        dndSleepTransitionFile: String? = nil,
        dndSleepTransitionDuration: TimeInterval = 0,
        sleepMode: ThemeSleepMode = .full,
        dndSkipYawn: Bool = false,
        minDisplay: [String: TimeInterval] = [:],
        autoReturn: [String: TimeInterval] = [:],
        miniMode: ThemeTimingOverrides? = nil
    ) {
        self.mouseIdleTimeout = Self.clamp(mouseIdleTimeout, minimum: 0.25, maximum: 3_600, fallback: 20)
        self.mouseSleepTimeout = Self.clamp(mouseSleepTimeout, minimum: 1, maximum: 86_400, fallback: 60)
        self.yawnDuration = Self.clamp(yawnDuration, minimum: 0.25, maximum: 60, fallback: 3)
        self.collapseDuration = Self.clamp(collapseDuration, minimum: 0, maximum: 60, fallback: 1)
        self.wakeDuration = Self.clamp(wakeDuration, minimum: 0.25, maximum: 60, fallback: 1.5)
        self.dizzyDuration = Self.clamp(dizzyDuration, minimum: 0.25, maximum: 60, fallback: 6)
        self.deepSleepTimeout = Self.clamp(deepSleepTimeout, minimum: 1, maximum: 86_400, fallback: 600)
        self.dndSleepTransitionFile = dndSleepTransitionFile.flatMap {
            ThemeAssetPathPolicy.isSafeRelativePath($0) ? $0 : nil
        }
        self.dndSleepTransitionDuration = Self.clamp(
            dndSleepTransitionDuration,
            minimum: 0,
            maximum: 120,
            fallback: 0
        )
        self.sleepMode = sleepMode
        self.dndSkipYawn = dndSkipYawn
        let overrides = ThemeTimingOverrides(minDisplay: minDisplay, autoReturn: autoReturn)
        self.minDisplay = overrides.minDisplay
        self.autoReturn = overrides.autoReturn
        self.miniMode = miniMode
    }

    private static func clamp(
        _ value: TimeInterval,
        minimum: TimeInterval,
        maximum: TimeInterval,
        fallback: TimeInterval
    ) -> TimeInterval {
        guard value.isFinite else { return fallback }
        return min(maximum, max(minimum, value))
    }

}

enum SleepSequenceTransition: Equatable, Sendable {
    case none
    case beginYawning
    case beginDozing
    case beginCollapsing
    case beginSleeping
}

/// Pure timing seam for the upstream full sleep sequence. The model owns the
/// published PetState and phase timestamp; this type only decides the next
/// transition, which keeps the long idle path cheap and deterministic in tests.
enum SleepSequencePlanner {
    static func next(
        state: PetState,
        now: Date,
        lastPointerActivity: Date,
        phaseStartedAt: Date?,
        timings: ThemeTimings
    ) -> SleepSequenceTransition {
        switch state {
        case .idle:
            guard now.timeIntervalSince(lastPointerActivity) >= timings.mouseSleepTimeout else {
                return .none
            }
            return timings.sleepMode == .direct ? .beginSleeping : .beginYawning
        case .yawning:
            guard now.timeIntervalSince(lastPointerActivity) >= timings.mouseSleepTimeout,
                  elapsed(now, since: phaseStartedAt) >= timings.yawnDuration else { return .none }
            return .beginDozing
        case .dozing:
            guard now.timeIntervalSince(lastPointerActivity) >= timings.deepSleepTimeout else { return .none }
            return .beginCollapsing
        case .collapsing:
            guard elapsed(now, since: phaseStartedAt) >= timings.collapseDuration else { return .none }
            return .beginSleeping
        default:
            return .none
        }
    }

    private static func elapsed(_ now: Date, since start: Date?) -> TimeInterval {
        guard let start else { return -.infinity }
        return max(0, now.timeIntervalSince(start))
    }
}
