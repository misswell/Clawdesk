import Foundation

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

public struct ThemeDefinition: Identifiable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let palette: PetPalette
    public let supportsEyeTracking: Bool
    public let assetDirectory: URL?
    public let stateFiles: [String: String]
    public let idleVisualFiles: [String]

    public init(
        id: String,
        displayName: String,
        palette: PetPalette,
        supportsEyeTracking: Bool = true,
        assetDirectory: URL? = nil,
        stateFiles: [String: String] = [:],
        idleVisualFiles: [String]? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.palette = palette
        self.supportsEyeTracking = supportsEyeTracking
        self.assetDirectory = assetDirectory
        self.stateFiles = stateFiles
        let declared = idleVisualFiles ?? stateFiles["idle"].map { [$0] } ?? []
        self.idleVisualFiles = declared.filter(Self.isSafeRelativePath)
    }

    public func assetURL(for state: PetState, idleVisualFile: String? = nil) -> URL? {
        guard let assetDirectory else { return nil }
        if state == .idle, let idleVisualFile, Self.isSafeRelativePath(idleVisualFile) {
            return assetDirectory.appendingPathComponent(idleVisualFile)
        }
        let candidates = [
            state.rawValue,
            state == .typing ? "working" : nil,
            state == .attention ? "happy" : nil,
            state == .miniIdle ? "idle" : nil
        ].compactMap { $0 }
        for key in candidates {
            guard let file = stateFiles[key], Self.isSafeRelativePath(file) else { continue }
            return assetDirectory.appendingPathComponent(file)
        }
        return nil
    }

    public var supportsIdleVisualSelection: Bool { idleVisualFiles.count > 1 }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else { return false }
        return path.split(separator: "/").allSatisfy { $0 != ".." && $0 != "." }
    }
}

public enum ThemeCatalog {
    public static let builtIn: [ThemeDefinition] = [
        ThemeDefinition(
            id: "clawd",
            displayName: "Clawd",
            palette: PetPalette(
                body: RGBColor(red: 0.95, green: 0.35, blue: 0.16),
                accent: RGBColor(red: 0.98, green: 0.62, blue: 0.18),
                shadow: RGBColor(red: 0.46, green: 0.17, blue: 0.10),
                highlight: RGBColor(red: 1.0, green: 0.84, blue: 0.40)
            )
        ),
        ThemeDefinition(
            id: "calico",
            displayName: "Calico",
            palette: PetPalette(
                body: RGBColor(red: 0.93, green: 0.79, blue: 0.61),
                accent: RGBColor(red: 0.34, green: 0.18, blue: 0.13),
                shadow: RGBColor(red: 0.27, green: 0.13, blue: 0.10),
                highlight: RGBColor(red: 1.0, green: 0.91, blue: 0.71)
            )
        ),
        ThemeDefinition(
            id: "cloudling",
            displayName: "Cloudling",
            palette: PetPalette(
                body: RGBColor(red: 0.47, green: 0.73, blue: 1.0),
                accent: RGBColor(red: 0.29, green: 0.42, blue: 0.92),
                shadow: RGBColor(red: 0.14, green: 0.23, blue: 0.50),
                highlight: RGBColor(red: 0.86, green: 0.95, blue: 1.0)
            )
        )
    ]

    public static func theme(id: String) -> ThemeDefinition {
        builtIn.first(where: { $0.id == id }) ?? builtIn[0]
    }
}
