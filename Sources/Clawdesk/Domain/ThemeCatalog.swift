import Foundation

enum ThemeAssetPathPolicy {
    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else { return false }
        return path.split(separator: "/").allSatisfy { $0 != ".." && $0 != "." }
    }
}

public struct RGBColor: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

public struct PetPalette: Equatable, Sendable {
    public let body: RGBColor
    public let accent: RGBColor
    public let shadow: RGBColor
    public let highlight: RGBColor

    public init(
        body: RGBColor,
        accent: RGBColor,
        shadow: RGBColor,
        highlight: RGBColor
    ) {
        self.body = body
        self.accent = accent
        self.shadow = shadow
        self.highlight = highlight
    }
}

public struct ThemeIdleAnimation: Equatable, Sendable {
    public let file: String
    /// Duration in seconds. Theme manifests express this value in ms.
    public let duration: TimeInterval

    public init(file: String, duration: TimeInterval) {
        self.file = file
        self.duration = min(60, max(0.25, duration.isFinite ? duration : 1.0))
    }
}

/// A state entry in the upstream theme manifest. The original schema allows
/// either a string/array of files or an object with an explicit fallback.
/// Keeping the complete file list is important for themes that provide a
/// short animation or several visual variants for one logical state.
public struct ThemeStateBinding: Equatable, Sendable {
    public let files: [String]
    public let fallbackTo: String?

    public init(files: [String], fallbackTo: String? = nil) {
        self.files = files.filter(ThemeAssetPathPolicy.isSafeRelativePath)
        let trimmed = fallbackTo?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.fallbackTo = trimmed?.isEmpty == false ? trimmed : nil
    }

    public init(file: String, fallbackTo: String? = nil) {
        self.init(files: [file], fallbackTo: fallbackTo)
    }
}

/// A working/juggling tier from the upstream manifest. The largest matching
/// `minSessions` wins, so manifests can add as many tiers as they need.
public struct ThemeTier: Equatable, Sendable {
    public let minSessions: Int
    public let file: String

    public init(minSessions: Int, file: String) {
        self.minSessions = max(1, minSessions)
        self.file = file
    }
}

public struct ThemeDefinition: Identifiable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let palette: PetPalette
    public let supportsEyeTracking: Bool
    public let assetDirectory: URL?
    public let stateFiles: [String: String]
    public let stateBindings: [String: ThemeStateBinding]
    /// Assets declared under the upstream `miniMode.states` namespace. Keep
    /// them separate from normal states: a mini idle file must never become
    /// the full-size idle visual, and a normal `idle` fallback must not hide a
    /// dedicated mini animation.
    public let miniStateFiles: [String: String]
    public let miniStateBindings: [String: ThemeStateBinding]
    public let workingTiers: [ThemeTier]
    public let jugglingTiers: [ThemeTier]
    public let fallbackTo: [String: String]
    public let displayHintMap: [String: String]
    public let updateVisuals: [String: String]
    public let idleVisualFiles: [String]
    public let idleAnimations: [ThemeIdleAnimation]
    public let timings: ThemeTimings
    public let sounds: [String: String]

    public init(
        id: String,
        displayName: String,
        palette: PetPalette,
        supportsEyeTracking: Bool = true,
        assetDirectory: URL? = nil,
        stateFiles: [String: String] = [:],
        stateBindings: [String: ThemeStateBinding] = [:],
        miniStateFiles: [String: String] = [:],
        miniStateBindings: [String: ThemeStateBinding] = [:],
        workingTiers: [ThemeTier] = [],
        jugglingTiers: [ThemeTier] = [],
        fallbackTo: [String: String] = [:],
        displayHintMap: [String: String] = [:],
        updateVisuals: [String: String] = [:],
        idleVisualFiles: [String]? = nil,
        idleAnimations: [ThemeIdleAnimation] = [],
        timings: ThemeTimings = .standard,
        sounds: [String: String] = [:]
    ) {
        self.id = id
        self.displayName = displayName
        self.palette = palette
        self.supportsEyeTracking = supportsEyeTracking
        self.assetDirectory = assetDirectory
        var resolvedBindings: [String: ThemeStateBinding] = [:]
        for (state, binding) in stateBindings {
            resolvedBindings[state.lowercased()] = binding
        }
        for (state, file) in stateFiles where resolvedBindings[state.lowercased()] == nil {
            resolvedBindings[state.lowercased()] = ThemeStateBinding(file: file)
        }
        self.stateBindings = resolvedBindings
        self.stateFiles = resolvedBindings.compactMapValues(\.files.first)
        var resolvedMiniBindings: [String: ThemeStateBinding] = [:]
        for (state, binding) in miniStateBindings {
            resolvedMiniBindings[state.lowercased()] = binding
        }
        for (state, file) in miniStateFiles where resolvedMiniBindings[state.lowercased()] == nil {
            resolvedMiniBindings[state.lowercased()] = ThemeStateBinding(file: file)
        }
        self.miniStateBindings = resolvedMiniBindings
        self.miniStateFiles = resolvedMiniBindings.compactMapValues(\.files.first)
        self.workingTiers = workingTiers
            .filter { ThemeAssetPathPolicy.isSafeRelativePath($0.file) }
            .sorted { $0.minSessions > $1.minSessions }
        self.jugglingTiers = jugglingTiers
            .filter { ThemeAssetPathPolicy.isSafeRelativePath($0.file) }
            .sorted { $0.minSessions > $1.minSessions }
        self.fallbackTo = fallbackTo.reduce(into: [:]) { result, entry in
            let state = entry.key.lowercased()
            let fallback = entry.value.lowercased()
            guard !state.isEmpty, !fallback.isEmpty else { return }
            result[state] = fallback
        }
        self.displayHintMap = displayHintMap.filter {
            ThemeAssetPathPolicy.isSafeRelativePath($0.key)
                && ThemeAssetPathPolicy.isSafeRelativePath($0.value)
        }
        self.updateVisuals = updateVisuals.filter {
            ThemeAssetPathPolicy.isSafeRelativePath($0.key)
                && ThemeAssetPathPolicy.isSafeRelativePath($0.value)
        }
        self.sounds = sounds
        self.idleAnimations = idleAnimations.filter { ThemeAssetPathPolicy.isSafeRelativePath($0.file) }
        self.timings = timings
        let declared = idleVisualFiles ?? stateFiles["idle"].map { [$0] } ?? []
        self.idleVisualFiles = declared.filter(ThemeAssetPathPolicy.isSafeRelativePath)
    }

    public func assetURL(
        for state: PetState,
        idleVisualFile: String? = nil,
        stateOverrideFile: String? = nil,
        activeSessionCount: Int = 1,
        subagentCount: Int = 0,
        displayHint: String? = nil
    ) -> URL? {
        // Dragging is a view interaction, not a theme state. Refusing that
        // asset at the theme seam prevents a legacy corner marker from being
        // loaded by any renderer path. Mini peek is also pointer-driven, but
        // unlike dragging it has an official upstream animation asset.
        guard state != .dragging else { return nil }
        guard let assetDirectory else { return nil }
        if let stateOverrideFile, ThemeAssetPathPolicy.isSafeRelativePath(stateOverrideFile) {
            let url = assetDirectory.appendingPathComponent(stateOverrideFile)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        if state == .idle, let idleVisualFile, ThemeAssetPathPolicy.isSafeRelativePath(idleVisualFile) {
            let url = assetDirectory.appendingPathComponent(idleVisualFile)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        let candidates = candidateFiles(
            for: state,
            activeSessionCount: activeSessionCount,
            subagentCount: subagentCount,
            displayHint: displayHint
        )
        for file in candidates {
            let url = assetDirectory.appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    public var supportsIdleVisualSelection: Bool { idleVisualFiles.count > 1 }

    /// Custom themes must provide a real asset before the model requests an
    /// artwork-specific transition. The built-in native renderer has a
    /// CoreGraphics fallback for every logical state, so it is considered
    /// capable even though it has no asset directory.
    public func hasVisualAsset(
        for state: PetState,
        activeSessionCount: Int = 1,
        subagentCount: Int = 0,
        displayHint: String? = nil
    ) -> Bool {
        guard state != .dragging else { return false }
        guard let assetDirectory else { return true }
        return candidateFiles(
            for: state,
            activeSessionCount: activeSessionCount,
            subagentCount: subagentCount,
            displayHint: displayHint
        ).contains { file in
            FileManager.default.fileExists(atPath: assetDirectory.appendingPathComponent(file).path)
        }
    }

    private func candidateFiles(
        for state: PetState,
        activeSessionCount: Int,
        subagentCount: Int,
        displayHint: String?
    ) -> [String] {
        if let displayHint,
           let mapped = displayHintMap[displayHint] ?? displayHintMap[displayHint.lowercased()],
           ThemeAssetPathPolicy.isSafeRelativePath(mapped) {
            return [mapped]
        }

        if state.isMini {
            return resolveBindingFiles(
                state.rawValue,
                bindings: miniStateBindings,
                fallback: [:]
            )
        }

        let sessionCount = max(1, max(activeSessionCount, subagentCount))
        if state == .typing || state == .building {
            let tierFiles = workingTiers
                .filter { $0.minSessions <= sessionCount }
                .map(\.file)
            if !tierFiles.isEmpty { return tierFiles }
        }
        if state == .juggling {
            let tierFiles = jugglingTiers
                .filter { $0.minSessions <= sessionCount }
                .map(\.file)
            if !tierFiles.isEmpty { return tierFiles }
        }

        var candidates = resolveBindingFiles(
            state.rawValue,
            bindings: stateBindings,
            fallback: fallbackTo
        )
        if state == .typing { candidates += resolveBindingFiles("working", bindings: stateBindings, fallback: fallbackTo) }
        if state == .attention { candidates += resolveBindingFiles("happy", bindings: stateBindings, fallback: fallbackTo) }
        return Array(NSOrderedSet(array: candidates)) as? [String] ?? candidates
    }

    private func resolveBindingFiles(
        _ key: String,
        bindings: [String: ThemeStateBinding],
        fallback: [String: String],
        visited: Set<String> = []
    ) -> [String] {
        let normalized = key.lowercased()
        guard !visited.contains(normalized) else { return [] }
        var nextVisited = visited
        nextVisited.insert(normalized)
        if let binding = bindings[normalized] {
            let own = binding.files
            if !own.isEmpty { return own + resolveBindingFiles(
                binding.fallbackTo ?? fallback[normalized] ?? "",
                bindings: bindings,
                fallback: fallback,
                visited: nextVisited
            ) }
            if let target = binding.fallbackTo ?? fallback[normalized] {
                return resolveBindingFiles(target, bindings: bindings, fallback: fallback, visited: nextVisited)
            }
        }
        guard let target = fallback[normalized] else { return [] }
        return resolveBindingFiles(target, bindings: bindings, fallback: fallback, visited: nextVisited)
    }

}

public enum ThemeCatalog {
    public static let builtIn: [ThemeDefinition] = [
        ThemeDefinition(
            id: "pinch",
            displayName: "Pinch",
            palette: PetPalette(
                body: RGBColor(red: 0.07, green: 0.07, blue: 0.08),
                accent: RGBColor(red: 0.98, green: 0.62, blue: 0.18),
                shadow: RGBColor(red: 0.02, green: 0.02, blue: 0.03),
                highlight: RGBColor(red: 1.0, green: 0.84, blue: 0.40)
            )
        ),
        ThemeDefinition(
            id: "patches",
            displayName: "Patches",
            palette: PetPalette(
                body: RGBColor(red: 0.93, green: 0.79, blue: 0.61),
                accent: RGBColor(red: 0.34, green: 0.18, blue: 0.13),
                shadow: RGBColor(red: 0.27, green: 0.13, blue: 0.10),
                highlight: RGBColor(red: 1.0, green: 0.91, blue: 0.71)
            )
        ),
        ThemeDefinition(
            id: "cumulus",
            displayName: "Cumulus",
            palette: PetPalette(
                body: RGBColor(red: 0.47, green: 0.73, blue: 1.0),
                accent: RGBColor(red: 0.29, green: 0.42, blue: 0.92),
                shadow: RGBColor(red: 0.14, green: 0.23, blue: 0.50),
                highlight: RGBColor(red: 0.86, green: 0.95, blue: 1.0)
            )
        ),
        ThemeDefinition(
            id: "rose",
            displayName: "Rose",
            palette: PetPalette(
                body: RGBColor(red: 0.92, green: 0.28, blue: 0.48),
                accent: RGBColor(red: 0.72, green: 0.08, blue: 0.28),
                shadow: RGBColor(red: 0.38, green: 0.04, blue: 0.14),
                highlight: RGBColor(red: 1.0, green: 0.72, blue: 0.82)
            )
        ),
        ThemeDefinition(
            id: "mint",
            displayName: "Mint",
            palette: PetPalette(
                body: RGBColor(red: 0.20, green: 0.78, blue: 0.59),
                accent: RGBColor(red: 0.04, green: 0.43, blue: 0.31),
                shadow: RGBColor(red: 0.02, green: 0.24, blue: 0.17),
                highlight: RGBColor(red: 0.72, green: 1.0, blue: 0.88)
            )
        ),
        ThemeDefinition(
            id: "violet",
            displayName: "Violet",
            palette: PetPalette(
                body: RGBColor(red: 0.55, green: 0.34, blue: 0.90),
                accent: RGBColor(red: 0.29, green: 0.12, blue: 0.62),
                shadow: RGBColor(red: 0.15, green: 0.06, blue: 0.34),
                highlight: RGBColor(red: 0.86, green: 0.76, blue: 1.0)
            )
        ),
        ThemeDefinition(
            id: "lemon",
            displayName: "Lemon",
            palette: PetPalette(
                body: RGBColor(red: 0.96, green: 0.78, blue: 0.18),
                accent: RGBColor(red: 0.64, green: 0.39, blue: 0.02),
                shadow: RGBColor(red: 0.39, green: 0.22, blue: 0.01),
                highlight: RGBColor(red: 1.0, green: 0.96, blue: 0.60)
            )
        )
    ]

    public static func theme(id: String) -> ThemeDefinition {
        builtIn.first(where: { $0.id == id }) ?? builtIn[0]
    }
}
