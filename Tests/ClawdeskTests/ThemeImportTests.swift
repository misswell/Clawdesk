import Foundation
import XCTest
@testable import Clawdesk

@MainActor
final class ThemeImportTests: XCTestCase {
    private nonisolated(unsafe) var root: URL!
    private nonisolated(unsafe) var defaults: UserDefaults!
    private nonisolated(unsafe) var suiteName: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("clawdesk-theme-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suiteName = "clawdesk-theme-test-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        if let suiteName { defaults?.removePersistentDomain(forName: suiteName) }
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        defaults = nil
        root = nil
        super.tearDown()
    }

    func testImportsThemeDirectoryAndReloadsSelection() throws {
        let source = root.appendingPathComponent("pixel-cat", isDirectory: true)
        try makeTheme(at: source, id: "pixel-cat", displayName: "Pixel Cat")

        let preferences = AppPreferences(defaults: defaults, homeDirectory: root)
        try preferences.importTheme(from: source)

        XCTAssertEqual(preferences.selectedThemeID, "pixel-cat")
        XCTAssertEqual(preferences.theme.displayName, "Pixel Cat")
        XCTAssertTrue(preferences.theme.assetURL(for: .idle)?.lastPathComponent == "idle.png")

        let reloaded = AppPreferences(defaults: defaults, homeDirectory: root)
        XCTAssertEqual(reloaded.selectedThemeID, "pixel-cat")
        XCTAssertEqual(reloaded.theme.displayName, "Pixel Cat")
    }

    func testImportsThemeZipWithNestedRoot() throws {
        let source = root.appendingPathComponent("zip-theme", isDirectory: true)
        try makeTheme(at: source, id: "zip-theme", displayName: "ZIP Theme")
        let archive = root.appendingPathComponent("zip-theme.zip")
        try runProcess("/usr/bin/zip", arguments: ["-q", "-r", archive.path, source.lastPathComponent], currentDirectory: root)

        let preferences = AppPreferences(defaults: defaults, homeDirectory: root)
        try preferences.importTheme(from: archive)

        XCTAssertEqual(preferences.selectedThemeID, "zip-theme")
        XCTAssertEqual(preferences.theme.displayName, "ZIP Theme")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Library/Application Support/Clawdesk/themes/zip-theme/theme.json").path
        ))
    }

    func testIdleVisualSelectionIsStoredPerThemeAndFallsBackSafely() throws {
        let source = root.appendingPathComponent("idle-pool", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "id": "idle-pool",
            "name": "Idle Pool",
            "states": ["idle": ["idle-follow.png", "idle-reading.png"], "typing": "typing.png"]
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: source.appendingPathComponent("theme.json"), options: .atomic)
        for file in ["idle-follow.png", "idle-reading.png", "typing.png"] {
            try Data("placeholder".utf8).write(to: source.appendingPathComponent(file), options: .atomic)
        }

        let preferences = AppPreferences(defaults: defaults, homeDirectory: root)
        try preferences.importTheme(from: source)
        XCTAssertEqual(preferences.theme.idleVisualFiles, ["idle-follow.png", "idle-reading.png"])
        preferences.setIdleVisual("idle-reading.png", for: preferences.theme)
        let reloaded = AppPreferences(defaults: defaults, homeDirectory: root)
        XCTAssertEqual(reloaded.selectedIdleVisual(for: reloaded.theme), "idle-reading.png")
    }

    func testRejectsZipPathTraversalBeforeExtraction() throws {
        let archive = root.appendingPathComponent("unsafe.zip")
        let inner = root.appendingPathComponent("inner", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: root.appendingPathComponent("escape.txt"), options: .atomic)
        try runProcess("/usr/bin/zip", arguments: ["-q", archive.path, "../escape.txt"], currentDirectory: inner)

        let preferences = AppPreferences(defaults: defaults, homeDirectory: root)
        XCTAssertThrowsError(try preferences.importTheme(from: archive)) { error in
            guard case ThemeImportError.unsafeArchiveEntry = error else {
                return XCTFail("Expected unsafe archive entry, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Library/Application Support/Clawdesk/themes").path
        ))
    }

    func testImportsThemeSoundsAndSkipsMissingFiles() throws {
        let source = root.appendingPathComponent("sound-theme", isDirectory: true)
        try makeTheme(at: source, id: "sound-theme", displayName: "Sound Theme")
        let soundsDirectory = source.appendingPathComponent("sounds", isDirectory: true)
        try FileManager.default.createDirectory(at: soundsDirectory, withIntermediateDirectories: true)
        try Data("placeholder".utf8).write(to: soundsDirectory.appendingPathComponent("complete.mp3"), options: .atomic)

        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: source.appendingPathComponent("theme.json"))) as! [String: Any]
        manifest["sounds"] = [
            "complete": "complete.mp3",
            "confirm": "missing.mp3"
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: source.appendingPathComponent("theme.json"), options: .atomic)

        let preferences = AppPreferences(defaults: defaults, homeDirectory: root)
        try preferences.importTheme(from: source)

        XCTAssertEqual(preferences.theme.sounds["complete"], "complete.mp3")
        XCTAssertNil(preferences.theme.sounds["confirm"], "a sound file that does not exist must be skipped")
        XCTAssertTrue(preferences.theme.sounds.isEmpty == false)
    }

    private func makeTheme(at directory: URL, id: String, displayName: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "id": id,
            "displayName": displayName,
            "states": ["idle": "idle.png", "typing": "typing.png"]
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try data.write(to: directory.appendingPathComponent("theme.json"), options: .atomic)
        try Data("placeholder".utf8).write(to: directory.appendingPathComponent("idle.png"), options: .atomic)
        try Data("placeholder".utf8).write(to: directory.appendingPathComponent("typing.png"), options: .atomic)
    }

    private func runProcess(_ executable: String, arguments: [String], currentDirectory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(executable) failed")
    }
}
