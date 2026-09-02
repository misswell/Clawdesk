import Combine
import Foundation

private struct StoredWindowPoint: Codable, Equatable {
    let x: Double
    let y: Double

    init(_ point: CGPoint) {
        x = Double(point.x)
        y = Double(point.y)
    }

    var point: CGPoint? {
        guard x.isFinite, y.isFinite else { return nil }
        return CGPoint(x: x, y: y)
    }
}

private struct WindowPositionRecovery: Codable, Equatable {
    let version: Int
    let windowOrigin: StoredWindowPoint?
    let preMiniWindowOrigin: StoredWindowPoint?
}

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
    private let positionRecoveryURL: URL
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
    @Published public var permissionBubbleFollowsPet: Bool { didSet { persist() } }
    @Published public var permissionBubbleCorner: PermissionBubbleCorner { didSet { persist() } }
    @Published public var permissionBubbleDisabledAgentIDs: Set<String> { didSet { persist() } }
    @Published public var serverPort: UInt16 { didSet { persist() } }
    @Published public var mobileEnabled: Bool { didSet { persist() } }
    @Published public var mobilePort: UInt16 { didSet { persist() } }
    @Published public var petScale: Double { didSet { persist() } }
    @Published public var freeRoamEnabled: Bool { didSet { persist() } }
    @Published public var collectClaudeUsage: Bool { didSet { persist() } }
    @Published public var autoCheckForUpdates: Bool { didSet { persist() } }
    @Published public var showQuotaRing: Bool { didSet { persist() } }
    @Published public var sessionHUDEnabled: Bool { didSet { persist() } }
    @Published public var sessionHUDPinned: Bool { didSet { persist() } }
    @Published public var sessionHUDShowContextUsage: Bool { didSet { persist() } }
    /// Agent integrations explicitly installed from Settings. Existing
    /// managed configurations are still discovered at startup so upgrades
    /// from versions before this preference remain repairable.
    @Published public var enabledAgentIDs: Set<String> { didSet { persist() } }
    @Published public var windowOrigin: CGPoint? { didSet { persist() } }
    /// The normal-mode position, parked while mini mode docks the pet so a
    /// mini round-trip does not lose where the user left it.
    @Published public var preMiniWindowOrigin: CGPoint? { didSet { persist() } }
    @Published public var idleVisualByTheme: [String: String] { didSet { persist() } }
    /// Bloub customizer choices (body shape, colour, resting expression).
    @Published public var bloubAppearance: BloubAppearance { didSet { persist() } }
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
        positionRecoveryURL = homeDirectory.appendingPathComponent("Library/Application Support/Clawdesk/window-position.json")
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
        permissionBubbleFollowsPet = defaults.bool(forKey: "permissionBubbleFollowsPet")
        permissionBubbleCorner = PermissionBubbleCorner(
            rawValue: defaults.string(forKey: "permissionBubbleCorner") ?? "bottom-right"
        ) ?? .bottomRight
        permissionBubbleDisabledAgentIDs = Set(defaults.stringArray(forKey: "permissionBubbleDisabledAgentIDs") ?? [])
        serverPort = UInt16(defaults.integer(forKey: "serverPort")) == 0 ? 37777 : UInt16(defaults.integer(forKey: "serverPort"))
        mobileEnabled = defaults.bool(forKey: "mobileEnabled")
        mobilePort = UInt16(defaults.integer(forKey: "mobilePort")) == 0 ? 23334 : UInt16(defaults.integer(forKey: "mobilePort"))
        petScale = PetSizing.clampedScale(
            defaults.object(forKey: "petScale") as? Double ?? PetSizing.defaultScale
        )
        freeRoamEnabled = defaults.bool(forKey: "freeRoam")
        collectClaudeUsage = defaults.object(forKey: "collectClaudeUsage") as? Bool ?? false
        autoCheckForUpdates = defaults.object(forKey: "autoCheckForUpdates") as? Bool ?? true
        showQuotaRing = defaults.object(forKey: "showQuotaRing") as? Bool ?? true
        sessionHUDEnabled = defaults.object(forKey: "sessionHUDEnabled") as? Bool ?? true
        sessionHUDPinned = defaults.object(forKey: "sessionHUDPinned") as? Bool ?? false
        sessionHUDShowContextUsage = defaults.object(forKey: "sessionHUDShowContextUsage") as? Bool ?? true
        enabledAgentIDs = Set(defaults.stringArray(forKey: "enabledAgentIDs") ?? [])
        idleVisualByTheme = defaults.dictionary(forKey: "idleVisualByTheme") as? [String: String] ?? [:]
        if let data = defaults.data(forKey: "bloubAppearance"),
           let decoded = try? JSONDecoder().decode(BloubAppearance.self, from: data) {
            bloubAppearance = decoded
        } else {
            bloubAppearance = .standard
        }
        let defaultsWindowOrigin: CGPoint? = if defaults.object(forKey: "windowX") != nil,
                                                defaults.object(forKey: "windowY") != nil {
            CGPoint(x: defaults.double(forKey: "windowX"), y: defaults.double(forKey: "windowY"))
        } else {
            nil
        }
        let defaultsPreMiniOrigin: CGPoint? = if defaults.object(forKey: "preMiniX") != nil,
                                                  defaults.object(forKey: "preMiniY") != nil {
            CGPoint(x: defaults.double(forKey: "preMiniX"), y: defaults.double(forKey: "preMiniY"))
        } else {
            nil
        }
        // The recovery file is intentionally authoritative when present. It
        // survives preference-domain migrations and captures the last frame
        // even when AppKit emits a startup move callback for the panel's
        // initial lower-left frame.
        let hasRecoveryFile: Bool
        if let recovery = Self.loadWindowPosition(from: positionRecoveryURL) {
            windowOrigin = recovery.windowOrigin?.point
            preMiniWindowOrigin = recovery.preMiniWindowOrigin?.point
            hasRecoveryFile = true
        } else {
            windowOrigin = Self.finitePoint(defaultsWindowOrigin)
            preMiniWindowOrigin = Self.finitePoint(defaultsPreMiniOrigin)
            hasRecoveryFile = false
        }
        customThemes = Self.loadCustomThemes(from: customThemesDirectory)
        // Versions before the recovery file could persist AppKit's initial
        // panel frame as (0, 0). Once that value was stored, every subsequent
        // launch treated the bad frame as a real saved position and stayed in
        // the lower-left corner. A real (0, 0) chosen in the current version
        // is always represented by the recovery file, so discard only the
        // legacy defaults value here.
        if !hasRecoveryFile {
            if windowOrigin == .zero { windowOrigin = nil }
            if preMiniWindowOrigin == .zero { preMiniWindowOrigin = nil }
        }
        // Before startup position restoration was guarded, the initial panel
        // frame could be recorded as the parked normal-mode position. A
        // non-zero saved frame paired with preMini=(0, 0) is that legacy
        // signature; discard only that combination so a real lower-left
        // position (which is also stored as windowOrigin=(0, 0)) survives.
        if isMiniMode,
           preMiniWindowOrigin == .zero,
           let windowOrigin,
           windowOrigin != .zero {
            preMiniWindowOrigin = nil
        }
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
        preMiniWindowOrigin = nil
        removeWindowPositionRecovery()
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
        defaults.set(permissionBubbleFollowsPet, forKey: "permissionBubbleFollowsPet")
        defaults.set(permissionBubbleCorner.rawValue, forKey: "permissionBubbleCorner")
        defaults.set(Array(permissionBubbleDisabledAgentIDs).sorted(), forKey: "permissionBubbleDisabledAgentIDs")
        defaults.set(Int(serverPort), forKey: "serverPort")
        defaults.set(mobileEnabled, forKey: "mobileEnabled")
        defaults.set(Int(mobilePort), forKey: "mobilePort")
        defaults.set(petScale, forKey: "petScale")
        defaults.set(freeRoamEnabled, forKey: "freeRoam")
        defaults.set(collectClaudeUsage, forKey: "collectClaudeUsage")
        defaults.set(autoCheckForUpdates, forKey: "autoCheckForUpdates")
        defaults.set(showQuotaRing, forKey: "showQuotaRing")
        defaults.set(sessionHUDEnabled, forKey: "sessionHUDEnabled")
        defaults.set(sessionHUDPinned, forKey: "sessionHUDPinned")
        defaults.set(sessionHUDShowContextUsage, forKey: "sessionHUDShowContextUsage")
        defaults.set(Array(enabledAgentIDs).sorted(), forKey: "enabledAgentIDs")
        defaults.set(idleVisualByTheme, forKey: "idleVisualByTheme")
        if let data = try? JSONEncoder().encode(bloubAppearance) {
            defaults.set(data, forKey: "bloubAppearance")
        }
        if let windowOrigin {
            defaults.set(windowOrigin.x, forKey: "windowX")
            defaults.set(windowOrigin.y, forKey: "windowY")
        } else {
            defaults.removeObject(forKey: "windowX")
            defaults.removeObject(forKey: "windowY")
        }
        if let preMiniWindowOrigin {
            defaults.set(preMiniWindowOrigin.x, forKey: "preMiniX")
            defaults.set(preMiniWindowOrigin.y, forKey: "preMiniY")
        } else {
            defaults.removeObject(forKey: "preMiniX")
            defaults.removeObject(forKey: "preMiniY")
        }
        persistWindowPositionRecovery()
    }

    private static func finitePoint(_ point: CGPoint?) -> CGPoint? {
        guard let point, point.x.isFinite, point.y.isFinite else { return nil }
        return point
    }

    private static func loadWindowPosition(from url: URL) -> WindowPositionRecovery? {
        guard let data = try? Data(contentsOf: url),
              let recovery = try? JSONDecoder().decode(WindowPositionRecovery.self, from: data),
              recovery.version == 1 else { return nil }
        return recovery
    }

    private func persistWindowPositionRecovery() {
        guard windowOrigin != nil || preMiniWindowOrigin != nil else {
            removeWindowPositionRecovery()
            return
        }
        let recovery = WindowPositionRecovery(
            version: 1,
            windowOrigin: windowOrigin.map(StoredWindowPoint.init),
            preMiniWindowOrigin: preMiniWindowOrigin.map(StoredWindowPoint.init)
        )
        guard let data = try? JSONEncoder().encode(recovery) else { return }
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: positionRecoveryURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: positionRecoveryURL, options: [.atomic])
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: positionRecoveryURL.path)
        } catch {
            // Preferences remain the fallback if the recovery file cannot be
            // written (for example, a read-only home directory).
        }
    }

    private func removeWindowPositionRecovery() {
        try? FileManager.default.removeItem(at: positionRecoveryURL)
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
        // The shipped clawd theme has no explicit id. The upstream loader
        // uses the theme directory as its stable identity in that case.
        let rawID = (object["id"] as? String)
            ?? (object["_id"] as? String)
            ?? directory.lastPathComponent
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
            miniMode: object["miniMode"] as? [String: Any],
            directory: directory
        )

        var stateFiles: [String: String] = [:]
        var stateBindings: [String: ThemeStateBinding] = [:]
        var fallbackTo: [String: String] = [:]
        var miniStateFiles: [String: String] = [:]
        var miniStateBindings: [String: ThemeStateBinding] = [:]
        var idleVisualFiles: [String] = []
        var idleAnimations: [ThemeIdleAnimation] = []

        func manifestFiles(_ value: Any) -> ([String], String?) {
            if let value = value as? String { return ([value], nil) }
            if let values = value as? [Any] {
                return (values.compactMap { $0 as? String }, nil)
            }
            if let value = value as? [String: Any] {
                let rawFiles: [String]
                if let file = value["file"] as? String {
                    rawFiles = [file]
                } else if let fileValues = value["files"] as? [Any] {
                    rawFiles = fileValues.compactMap { $0 as? String }
                } else if let file = value["files"] as? String {
                    rawFiles = [file]
                } else {
                    rawFiles = []
                }
                return (rawFiles, value["fallbackTo"] as? String)
            }
            return ([], nil)
        }

        func validBinding(_ value: Any) -> ThemeStateBinding? {
            let (files, fallback) = manifestFiles(value)
            let validFiles = files.filter {
                ThemeAssetPathPolicy.isSafeRelativePath($0)
                    && FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
            }
            guard !validFiles.isEmpty || fallback?.isEmpty == false else { return nil }
            return ThemeStateBinding(files: validFiles, fallbackTo: fallback)
        }

        if let states = object["states"] as? [String: Any] {
            for (state, value) in states {
                let normalizedState = state.lowercased()
                guard let binding = validBinding(value) else { continue }
                stateBindings[normalizedState] = binding
                if let file = binding.files.first { stateFiles[normalizedState] = file }
                if let fallback = binding.fallbackTo { fallbackTo[normalizedState] = fallback }
                if normalizedState == "idle" { idleVisualFiles.append(contentsOf: binding.files) }
            }
        }
        // The upstream theme schema keeps mini artwork in a nested
        // `miniMode.states` table. Parse it independently so a mini asset is
        // selected only while the window is docked; falling back to a normal
        // state here would make mini mode show a full-size animation.
        if let miniMode = object["miniMode"] as? [String: Any],
           let states = miniMode["states"] as? [String: Any] {
            for (state, value) in states {
                guard let binding = validBinding(value) else { continue }
                let normalizedState = state.lowercased()
                miniStateBindings[normalizedState] = binding
                if let file = binding.files.first { miniStateFiles[normalizedState] = file }
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
        guard !stateBindings.isEmpty else { throw ThemeImportError.invalidManifest }
        let eyeTracking = (object["supportsEyeTracking"] as? Bool)
            ?? ((object["eyeTracking"] as? [String: Any])?["enabled"] as? Bool)
            ?? true
        func manifestStringMap(_ value: Any?) -> [String: String] {
            guard let values = value as? [String: Any] else { return [:] }
            return values.reduce(into: [:]) { result, entry in
                guard let value = entry.value as? String else { return }
                result[entry.key] = value
            }
        }

        func manifestTiers(_ value: Any?) -> [ThemeTier] {
            guard let values = value as? [[String: Any]] else { return [] }
            return values.compactMap { entry in
                guard let file = entry["file"] as? String,
                      let minimum = (entry["minSessions"] as? NSNumber)?.intValue,
                      ThemeAssetPathPolicy.isSafeRelativePath(file),
                      FileManager.default.fileExists(atPath: directory.appendingPathComponent(file).path) else {
                    return nil
                }
                return ThemeTier(minSessions: minimum, file: file)
            }
        }

        return ThemeDefinition(
            id: id,
            displayName: name.isEmpty ? id : String(name.prefix(80)),
            palette: palette,
            supportsEyeTracking: eyeTracking,
            assetDirectory: directory,
            stateFiles: stateFiles,
            stateBindings: stateBindings,
            miniStateFiles: miniStateFiles,
            miniStateBindings: miniStateBindings,
            workingTiers: manifestTiers(object["workingTiers"]),
            jugglingTiers: manifestTiers(object["jugglingTiers"]),
            fallbackTo: fallbackTo,
            displayHintMap: manifestStringMap(object["displayHintMap"]),
            updateVisuals: manifestStringMap(object["updateVisuals"]),
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
        miniMode: [String: Any]?,
        directory: URL
    ) -> ThemeTimings {
        let defaults = ThemeTimings.standard
        func seconds(_ key: String, fallback: TimeInterval) -> TimeInterval {
            guard let raw = object?[key] as? NSNumber else { return fallback }
            let milliseconds = raw.doubleValue
            guard milliseconds.isFinite else { return fallback }
            return milliseconds / 1_000
        }
        let dizzyDuration: TimeInterval = {
            if object?["dizzyDuration"] is NSNumber {
                return seconds("dizzyDuration", fallback: defaults.dizzyDuration)
            }
            guard let autoReturn = object?["autoReturn"] as? [String: Any],
                  let raw = autoReturn["dizzy"] as? NSNumber,
                  raw.doubleValue.isFinite else {
                return defaults.dizzyDuration
            }
            return raw.doubleValue / 1_000
        }()
        func timingMap(_ value: Any?) -> [String: TimeInterval] {
            guard let values = value as? [String: Any] else { return [:] }
            return values.reduce(into: [:]) { result, entry in
                guard let raw = entry.value as? NSNumber,
                      raw.doubleValue.isFinite,
                      raw.doubleValue >= 0 else { return }
                let key = entry.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !key.isEmpty else { return }
                result[key] = min(86_400, raw.doubleValue / 1_000)
            }
        }
        let minDisplay = timingMap(object?["minDisplay"])
        let autoReturn = timingMap(object?["autoReturn"])
        let miniTimingOverrides: ThemeTimingOverrides? = {
            guard let miniTimings = miniMode?["timings"] as? [String: Any] else {
                return nil
            }
            return ThemeTimingOverrides(
                minDisplay: timingMap(miniTimings["minDisplay"]),
                autoReturn: timingMap(miniTimings["autoReturn"])
            )
        }()
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
            dizzyDuration: dizzyDuration,
            deepSleepTimeout: seconds("deepSleepTimeout", fallback: defaults.deepSleepTimeout),
            dndSleepTransitionFile: dndTransitionFile,
            dndSleepTransitionDuration: seconds(
                "dndSleepTransitionDuration",
                fallback: defaults.dndSleepTransitionDuration
            ),
            sleepMode: mode,
            dndSkipYawn: (object?["dndSkipYawn"] as? Bool) ?? false,
            minDisplay: minDisplay,
            autoReturn: autoReturn,
            miniMode: miniTimingOverrides
        )
    }
}
