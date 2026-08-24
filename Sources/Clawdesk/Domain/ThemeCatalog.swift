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

public struct ThemeDefinition: Identifiable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let palette: PetPalette
    public let supportsEyeTracking: Bool
    public let assetDirectory: URL?
    public let stateFiles: [String: String]
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
        self.stateFiles = stateFiles
        self.sounds = sounds
        self.idleAnimations = idleAnimations.filter { ThemeAssetPathPolicy.isSafeRelativePath($0.file) }
        self.timings = timings
        let declared = idleVisualFiles ?? stateFiles["idle"].map { [$0] } ?? []
        self.idleVisualFiles = declared.filter(ThemeAssetPathPolicy.isSafeRelativePath)
    }

    public func assetURL(
        for state: PetState,
        idleVisualFile: String? = nil,
        stateOverrideFile: String? = nil
    ) -> URL? {
        // Hover and dragging are pointer interaction states, not theme
        // decorations. Refusing these assets at the theme seam prevents a
        // legacy corner marker from being loaded by any renderer path.
        guard !state.isPointerInteraction else { return nil }
        guard let assetDirectory else { return nil }
        if let stateOverrideFile, ThemeAssetPathPolicy.isSafeRelativePath(stateOverrideFile) {
            let url = assetDirectory.appendingPathComponent(stateOverrideFile)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        if state == .idle, let idleVisualFile, ThemeAssetPathPolicy.isSafeRelativePath(idleVisualFile) {
            return assetDirectory.appendingPathComponent(idleVisualFile)
        }
        let candidates = [
            state.rawValue,
            state == .typing ? "working" : nil,
            state == .attention ? "happy" : nil,
            state == .miniIdle ? "idle" : nil
        ].compactMap { $0 }
        for key in candidates {
            guard let file = stateFiles[key], ThemeAssetPathPolicy.isSafeRelativePath(file) else { continue }
            return assetDirectory.appendingPathComponent(file)
        }
        return nil
    }

    public var supportsIdleVisualSelection: Bool { idleVisualFiles.count > 1 }

    /// Custom themes must provide a real asset before the model requests an
    /// artwork-specific transition. The built-in native renderer has a
    /// CoreGraphics fallback for every logical state, so it is considered
    /// capable even though it has no asset directory.
    public func hasVisualAsset(for state: PetState) -> Bool {
        guard !state.isPointerInteraction else { return false }
        guard let assetDirectory else { return true }
        let candidates = [
            state.rawValue,
            state == .typing ? "working" : nil,
            state == .attention ? "happy" : nil,
            state == .miniIdle ? "idle" : nil
        ].compactMap { $0 }
        return candidates.contains { key in
            guard let file = stateFiles[key], ThemeAssetPathPolicy.isSafeRelativePath(file) else { return false }
            return FileManager.default.fileExists(atPath: assetDirectory.appendingPathComponent(file).path)
        }
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
