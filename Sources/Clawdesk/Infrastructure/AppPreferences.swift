import Combine
import Foundation

public enum ThemeImportError: LocalizedError {
    case unsupportedFormat
    case unsafeArchiveEntry(String)
    case missingManifest
    case invalidManifest
    case invalidIdentifier
    case alreadyExists(URL)
    case extractionFailed

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat: return "Theme import accepts a folder or ZIP archive."
        case let .unsafeArchiveEntry(entry): return "Theme archive contains an unsafe path: \(entry)"
        case .missingManifest: return "The theme must contain a theme.json manifest."
        case .invalidManifest: return "The theme.json manifest is invalid or contains no image states."
        case .invalidIdentifier: return "Theme IDs may contain only letters, numbers, '_' and '-'."
        case let .alreadyExists(url): return "A theme with this ID already exists at \(url.path)."
        case .extractionFailed: return "The theme ZIP could not be extracted."
        }
    }
}

@MainActor
public final class AppPreferences: ObservableObject {
    private let defaults: UserDefaults
    private let homeDirectory: URL
    private var isLoading = true

    @Published public var selectedThemeID: String { didSet { persist() } }
    @Published public var isMiniMode: Bool { didSet { persist() } }
    @Published public var doNotDisturb: Bool { didSet { persist() } }
    @Published public var soundEnabled: Bool { didSet { persist() } }
    @Published public var lowPowerAnimations: Bool { didSet { persist() } }
    @Published public var autoStart: Bool { didSet { persist() } }
    @Published public var language: String { didSet { persist() } }
    @Published public var permissionMode: PermissionMode { didSet { persist() } }
    @Published public var permissionAutomation: PermissionAutomation { didSet { persist() } }
    @Published public var showPermissionBubbles: Bool { didSet { persist() } }
    @Published public var serverPort: UInt16 { didSet { persist() } }
    @Published public var mobileEnabled: Bool { didSet { persist() } }
    @Published public var mobilePort: UInt16 { didSet { persist() } }
    @Published public var petScale: Double { didSet { persist() } }
    @Published public var freeRoamEnabled: Bool { didSet { persist() } }
    @Published public var collectClaudeUsage: Bool { didSet { persist() } }
    @Published public var autoCheckForUpdates: Bool { didSet { persist() } }
    @Published public var showQuotaRing: Bool { didSet { persist() } }
    /// Agent integrations explicitly installed from Settings. Existing
    /// managed configurations are still discovered at startup so upgrades
    /// from versions before this preference remain repairable.
    @Published public var enabledAgentIDs: Set<String> { didSet { persist() } }
    @Published public var windowOrigin: CGPoint? { didSet { persist() } }
    @Published public var idleVisualByTheme: [String: String] { didSet { persist() } }
    @Published public private(set) var customThemes: [ThemeDefinition]

    public let customThemesDirectory: URL

    /// Upstream-compatible roam fence file (`~/.clawd/roam-area.json`).
    public var roamAreaFileURL: URL {
        homeDirectory.appendingPathComponent(".clawd/roam-area.json")
    }

    public init(
        defaults: UserDefaults = .standard,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.defaults = defaults
        self.homeDirectory = homeDirectory
        customThemesDirectory = homeDirectory.appendingPathComponent("Library/Application Support/Clawdesk/themes", isDirectory: true)
        selectedThemeID = defaults.string(forKey: "theme") ?? "pinch"
        isMiniMode = defaults.bool(forKey: "miniMode")
        doNotDisturb = defaults.bool(forKey: "doNotDisturb")
        soundEnabled = defaults.object(forKey: "soundEnabled") as? Bool ?? true
        lowPowerAnimations = defaults.object(forKey: "lowPowerAnimations") as? Bool ?? true
        autoStart = defaults.bool(forKey: "autoStart")
        language = defaults.string(forKey: "language") ?? "system"
        permissionMode = PermissionMode(rawValue: defaults.string(forKey: "permissionMode") ?? "ask-every-time") ?? .askEveryTime
        permissionAutomation = PermissionAutomation(rawValue: defaults.string(forKey: "permissionAutomation") ?? "") ?? .off
        showPermissionBubbles = defaults.object(forKey: "showPermissionBubbles") as? Bool ?? true
        serverPort = UInt16(defaults.integer(forKey: "serverPort")) == 0 ? 37777 : UInt16(defaults.integer(forKey: "serverPort"))
        mobileEnabled = defaults.bool(forKey: "mobileEnabled")
        mobilePort = UInt16(defaults.integer(forKey: "mobilePort")) == 0 ? 23334 : UInt16(defaults.integer(forKey: "mobilePort"))
        petScale = min(2.0, max(0.4, defaults.object(forKey: "petScale") as? Double ?? 1.0))
        freeRoamEnabled = defaults.bool(forKey: "freeRoam")
        collectClaudeUsage = defaults.object(forKey: "collectClaudeUsage") as? Bool ?? false
        autoCheckForUpdates = defaults.object(forKey: "autoCheckForUpdates") as? Bool ?? true
        showQuotaRing = defaults.object(forKey: "showQuotaRing") as? Bool ?? true
        enabledAgentIDs = Set(defaults.stringArray(forKey: "enabledAgentIDs") ?? [])
        idleVisualByTheme = defaults.dictionary(forKey: "idleVisualByTheme") as? [String: String] ?? [:]
        if defaults.object(forKey: "windowX") != nil, defaults.object(forKey: "windowY") != nil {
            windowOrigin = CGPoint(x: defaults.double(forKey: "windowX"), y: defaults.double(forKey: "windowY"))
        } else {
            windowOrigin = nil
        }
        customThemes = Self.loadCustomThemes(from: customThemesDirectory)
        isLoading = false
    }

    public var theme: ThemeDefinition {
        availableThemes.first(where: { $0.id == selectedThemeID }) ?? ThemeCatalog.theme(id: "pinch")
    }

    public var availableThemes: [ThemeDefinition] {
        customThemes + ThemeCatalog.builtIn
    }

    /// Resolves the picker value ("system" or a locale tag) to a concrete
    /// language used by the localization table.
    public var resolvedLanguage: String {
        guard language == "system" else { return language }
        let preferred = Locale.preferredLanguages.first ?? "en"
        if preferred.hasPrefix("zh-Hant") || preferred.hasPrefix("zh-HK") || preferred.hasPrefix("zh-TW") {
            return "zh-Hant"
        }
        if preferred.hasPrefix("zh") { return "zh-Hans" }
        return "en"
    }

    /// Localized UI string for the current language, falling back to the
    /// English key when no translation exists.
    public func text(_ key: String) -> String {
        Localization.string(key, language: resolvedLanguage) ?? key
    }

    public func selectedIdleVisual(for theme: ThemeDefinition) -> String? {
        guard !theme.idleVisualFiles.isEmpty else { return nil }
        let selected = idleVisualByTheme[theme.id]
        guard let selected, theme.idleVisualFiles.contains(selected) else {
            return theme.idleVisualFiles.first
        }
        guard let directory = theme.assetDirectory,
              FileManager.default.fileExists(atPath: directory.appendingPathComponent(selected).path) else {
            return theme.idleVisualFiles.first
        }
        return selected
    }

    public func setIdleVisual(_ file: String, for theme: ThemeDefinition) {
        guard theme.idleVisualFiles.contains(file) else { return }
        idleVisualByTheme[theme.id] = file
    }

    public func resetPosition() {
        windowOrigin = nil
    }

    public func importTheme(from source: URL) throws {
        let fileManager = FileManager.default
        let temporary = fileManager.temporaryDirectory.appendingPathComponent("clawdesk-theme-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporary) }

        let root: URL
        if (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            root = source
        } else if source.pathExtension.lowercased() == "zip" {
            try Self.extractThemeArchive(source, to: temporary)
            guard let extracted = Self.findThemeRoot(in: temporary) else { throw ThemeImportError.missingManifest }
            root = extracted
        } else {
            throw ThemeImportError.unsupportedFormat
        }

        let definition = try Self.loadTheme(at: root)
        try fileManager.createDirectory(at: customThemesDirectory, withIntermediateDirectories: true)
        let destination = customThemesDirectory.appendingPathComponent(definition.id, isDirectory: true)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw ThemeImportError.alreadyExists(destination)
        }
        try fileManager.copyItem(at: root, to: destination)
        customThemes = Self.loadCustomThemes(from: customThemesDirectory)
        selectedThemeID = definition.id
    }

    public func removeCustomTheme(id: String) throws {
        guard customThemes.contains(where: { $0.id == id }) else { return }
        let directory = customThemesDirectory.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.removeItem(at: directory)
        customThemes = Self.loadCustomThemes(from: customThemesDirectory)
        if selectedThemeID == id { selectedThemeID = "pinch" }
    }

    private func persist() {
        guard !isLoading else { return }
        defaults.set(selectedThemeID, forKey: "theme")
        defaults.set(isMiniMode, forKey: "miniMode")
        defaults.set(doNotDisturb, forKey: "doNotDisturb")
        defaults.set(soundEnabled, forKey: "soundEnabled")
        defaults.set(lowPowerAnimations, forKey: "lowPowerAnimations")
        defaults.set(autoStart, forKey: "autoStart")
        defaults.set(language, forKey: "language")
        defaults.set(permissionMode.rawValue, forKey: "permissionMode")
        defaults.set(permissionAutomation.rawValue, forKey: "permissionAutomation")
        defaults.set(showPermissionBubbles, forKey: "showPermissionBubbles")
        defaults.set(Int(serverPort), forKey: "serverPort")
        defaults.set(mobileEnabled, forKey: "mobileEnabled")
        defaults.set(Int(mobilePort), forKey: "mobilePort")
        defaults.set(petScale, forKey: "petScale")
        defaults.set(freeRoamEnabled, forKey: "freeRoam")
        defaults.set(collectClaudeUsage, forKey: "collectClaudeUsage")
        defaults.set(autoCheckForUpdates, forKey: "autoCheckForUpdates")
        defaults.set(showQuotaRing, forKey: "showQuotaRing")
        defaults.set(Array(enabledAgentIDs).sorted(), forKey: "enabledAgentIDs")
        defaults.set(idleVisualByTheme, forKey: "idleVisualByTheme")
        if let windowOrigin {
            defaults.set(windowOrigin.x, forKey: "windowX")
            defaults.set(windowOrigin.y, forKey: "windowY")
        } else {
            defaults.removeObject(forKey: "windowX")
            defaults.removeObject(forKey: "windowY")
        }
    }

    private static func loadCustomThemes(from directory: URL) -> [ThemeDefinition] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.compactMap { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            return try? loadTheme(at: url)
        }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private static func loadTheme(at directory: URL) throws -> ThemeDefinition {
        let manifestURL = directory.appendingPathComponent("theme.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ThemeImportError.missingManifest
        }
        let rawID = (object["id"] as? String) ?? (object["_id"] as? String) ?? ""
        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSafeThemeID(id), !ThemeCatalog.builtIn.contains(where: { $0.id == id }) else {
            throw ThemeImportError.invalidIdentifier
        }
        let name = ((object["displayName"] as? String) ?? (object["name"] as? String) ?? id)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let basePalette = ThemeCatalog.theme(id: "pinch").palette
        let paletteObject = object["palette"] as? [String: Any] ?? [:]
        let palette = PetPalette(
            body: color(paletteObject["body"], fallback: basePalette.body),
            accent: color(paletteObject["accent"], fallback: basePalette.accent),
            shadow: color(paletteObject["shadow"], fallback: basePalette.shadow),
            highlight: color(paletteObject["highlight"], fallback: basePalette.highlight)
        )
        let timings = themeTimings(
            object["timings"] as? [String: Any],
            sleepSequence: object["sleepSequence"] as? [String: Any],
            directory: directory
        )

        var stateFiles: [String: String] = [:]
        var idleVisualFiles: [String] = []
        var idleAnimations: [ThemeIdleAnimation] = []
        if let states = object["states"] as? [String: Any] {
            for (state, value) in states {
                let files: [String]
                if let value = value as? String {
                    files = [value]
                } else if let values = value as? [Any] {
                    files = values.compactMap { $0 as? String }
                } else {
                    files = []
                }
                let validFiles = files.filter {
                    ThemeAssetPathPolicy.isSafeRelativePath($0) && FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
                }
                guard let file = validFiles.first else { continue }
                let normalizedState = state.lowercased()
                stateFiles[normalizedState] = file
                if normalizedState == "idle" { idleVisualFiles.append(contentsOf: validFiles) }
            }
        }
        if let animations = object["idleAnimations"] as? [[String: Any]] {
            for entry in animations {
                guard let file = entry["file"] as? String,
                      ThemeAssetPathPolicy.isSafeRelativePath(file),
                      FileManager.default.fileExists(atPath: directory.appendingPathComponent(file).path) else { continue }
                let rawMilliseconds = (entry["duration"] as? NSNumber)?.doubleValue ?? 1_000
                let milliseconds = min(60_000, max(250, rawMilliseconds.isFinite ? rawMilliseconds : 1_000))
                idleAnimations.append(ThemeIdleAnimation(file: file, duration: milliseconds / 1_000))
                idleVisualFiles.append(file)
            }
        }
        idleVisualFiles = Array(NSOrderedSet(array: idleVisualFiles)) as? [String] ?? idleVisualFiles
        var sounds: [String: String] = [:]
        if let rawSounds = object["sounds"] as? [String: Any] {
            for (name, value) in rawSounds {
                guard let file = value as? String,
                      ThemeAssetPathPolicy.isSafeRelativePath(file),
                      FileManager.default.fileExists(atPath: directory.appendingPathComponent("sounds").appendingPathComponent(file).path) else { continue }
                sounds[name] = file
            }
        }
        guard !stateFiles.isEmpty else { throw ThemeImportError.invalidManifest }
        let eyeTracking = (object["supportsEyeTracking"] as? Bool)
            ?? ((object["eyeTracking"] as? [String: Any])?["enabled"] as? Bool)
            ?? true
        return ThemeDefinition(
            id: id,
            displayName: name.isEmpty ? id : String(name.prefix(80)),
            palette: palette,
            supportsEyeTracking: eyeTracking,
            assetDirectory: directory,
            stateFiles: stateFiles,
            idleVisualFiles: idleVisualFiles,
            idleAnimations: idleAnimations,
            timings: timings,
            sounds: sounds
        )
    }

    private static func findThemeRoot(in directory: URL) -> URL? {
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("theme.json").path) { return directory }
        guard let children = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return nil }
        return children.first {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                && FileManager.default.fileExists(atPath: $0.appendingPathComponent("theme.json").path)
        }
    }

    private static func extractThemeArchive(_ archive: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-Z1", archive.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ThemeImportError.extractionFailed }
        let listing = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let entries = listing.split(whereSeparator: \.isNewline).map(String.init)
        guard entries.count <= 2_000 else { throw ThemeImportError.extractionFailed }
        for entry in entries {
            guard !entry.hasPrefix("/"), !entry.contains("\\"),
                  entry.split(separator: "/").allSatisfy({ $0 != ".." && $0 != "." }) else {
                throw ThemeImportError.unsafeArchiveEntry(entry)
            }
        }

        let extraction = Process()
        extraction.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        extraction.arguments = ["-q", "-o", archive.path, "-d", destination.path]
        extraction.standardOutput = Pipe()
        extraction.standardError = Pipe()
        try extraction.run()
        extraction.waitUntilExit()
        guard extraction.terminationStatus == 0 else { throw ThemeImportError.extractionFailed }
    }

    private static func isSafeThemeID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 48 else { return false }
        return id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" }
    }

    private static func color(_ value: Any?, fallback: RGBColor) -> RGBColor {
        if let values = value as? [NSNumber], values.count >= 3 {
            return RGBColor(red: values[0].doubleValue, green: values[1].doubleValue, blue: values[2].doubleValue)
        }
        if let object = value as? [String: Any] {
            let red = (object["red"] as? NSNumber)?.doubleValue ?? (object["r"] as? NSNumber)?.doubleValue
            let green = (object["green"] as? NSNumber)?.doubleValue ?? (object["g"] as? NSNumber)?.doubleValue
            let blue = (object["blue"] as? NSNumber)?.doubleValue ?? (object["b"] as? NSNumber)?.doubleValue
            if let red, let green, let blue { return RGBColor(red: red, green: green, blue: blue) }
        }
        if let string = value as? String {
            let hex = string.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
            if hex.count == 6, let number = UInt64(hex, radix: 16) {
                return RGBColor(
                    red: Double((number >> 16) & 0xff) / 255,
                    green: Double((number >> 8) & 0xff) / 255,
                    blue: Double(number & 0xff) / 255
                )
            }
        }
        return fallback
    }

    private static func themeTimings(
        _ object: [String: Any]?,
        sleepSequence: [String: Any]?,
        directory: URL
    ) -> ThemeTimings {
        let defaults = ThemeTimings.standard
        func seconds(_ key: String, fallback: TimeInterval) -> TimeInterval {
            guard let raw = object?[key] as? NSNumber else { return fallback }
            let milliseconds = raw.doubleValue
            guard milliseconds.isFinite else { return fallback }
            return milliseconds / 1_000
        }
        let mode = (sleepSequence?["mode"] as? String)
            .flatMap { ThemeSleepMode(rawValue: $0.lowercased()) }
            ?? defaults.sleepMode
        let dndTransitionFile: String?
        if let raw = object?["dndSleepTransitionSvg"] as? String,
           ThemeAssetPathPolicy.isSafeRelativePath(raw),
           FileManager.default.fileExists(atPath: directory.appendingPathComponent(raw).path) {
            dndTransitionFile = raw
        } else {
            dndTransitionFile = nil
        }
        return ThemeTimings(
            mouseIdleTimeout: seconds("mouseIdleTimeout", fallback: defaults.mouseIdleTimeout),
            mouseSleepTimeout: seconds("mouseSleepTimeout", fallback: defaults.mouseSleepTimeout),
            yawnDuration: seconds("yawnDuration", fallback: defaults.yawnDuration),
            collapseDuration: seconds("collapseDuration", fallback: defaults.collapseDuration),
            wakeDuration: seconds("wakeDuration", fallback: defaults.wakeDuration),
            deepSleepTimeout: seconds("deepSleepTimeout", fallback: defaults.deepSleepTimeout),
            dndSleepTransitionFile: dndTransitionFile,
            dndSleepTransitionDuration: seconds(
                "dndSleepTransitionDuration",
                fallback: defaults.dndSleepTransitionDuration
            ),
            sleepMode: mode,
            dndSkipYawn: (object?["dndSkipYawn"] as? Bool) ?? false
        )
    }
}
