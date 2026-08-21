import AppKit
import Combine
import CryptoKit
import Foundation

enum ClawdeskAppIdentity {
    static let name = "Clawdesk"
    static let bundleIdentifier = "com.clawdesk.native"
    static let githubRepository = "misswell/Clawdesk"
    static let appBundleName = "Clawdesk.app"
    static let executableName = "Clawdesk"
    static let updaterExecutableName = "ClawdeskUpdater"
    static let developerTeamIdentifier = "U8U443D7ZL"

    static func archiveName(for version: String) -> String {
        "Clawdesk-\(version)-macos.zip"
    }

    static func applicationURL(in directory: URL) -> URL {
        directory.appendingPathComponent(appBundleName, isDirectory: true)
    }

    static func updaterURL(in applicationURL: URL) -> URL {
        applicationURL.appendingPathComponent("Contents/MacOS/\(updaterExecutableName)")
    }
}

struct ClawdeskVersion: Comparable, Hashable, CustomStringConvertible, Sendable {
    private let components: [Int]

    init?(_ value: String) {
        let normalized = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let pieces = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard !pieces.isEmpty,
              pieces.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              pieces.compactMap({ Int($0) }).count == pieces.count else {
            return nil
        }
        components = pieces.compactMap { Int($0) }
    }

    var description: String {
        components.map(String.init).joined(separator: ".")
    }

    static func == (lhs: ClawdeskVersion, rhs: ClawdeskVersion) -> Bool {
        normalized(lhs.components) == normalized(rhs.components)
    }

    static func < (lhs: ClawdeskVersion, rhs: ClawdeskVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(Self.normalized(components))
    }

    private static func normalized(_ components: [Int]) -> [Int] {
        var result = components
        while result.count > 1 && result.last == 0 {
            result.removeLast()
        }
        return result
    }
}

struct ClawdeskRelease: Equatable, Sendable {
    let version: ClawdeskVersion
    let releaseNotes: String
    let archiveURL: URL
    let sha256: String

    func isNewer(than currentVersion: String) -> Bool {
        guard let current = ClawdeskVersion(currentVersion) else { return false }
        return current < version
    }

    static func decodeGitHubResponse(_ data: Data) throws -> ClawdeskRelease {
        let response = try JSONDecoder().decode(GitHubReleaseResponse.self, from: data)
        guard !response.draft,
              !response.prerelease,
              let version = ClawdeskVersion(response.tagName) else {
            throw ClawdeskUpdateError.invalidRelease
        }

        let expectedName = ClawdeskAppIdentity.archiveName(for: version.description)
        guard let asset = response.assets.first(where: { $0.name == expectedName }),
              asset.url.scheme == "https",
              let digest = asset.digest,
              digest.lowercased().hasPrefix("sha256:") else {
            throw ClawdeskUpdateError.missingVerifiedArchive
        }

        let sha256 = String(digest.dropFirst("sha256:".count)).lowercased()
        guard sha256.count == 64, sha256.allSatisfy(\.isHexDigit) else {
            throw ClawdeskUpdateError.missingVerifiedArchive
        }

        return ClawdeskRelease(
            version: version,
            releaseNotes: response.body ?? "",
            archiveURL: asset.url,
            sha256: sha256
        )
    }
}

private struct GitHubReleaseResponse: Decodable {
    struct Asset: Decodable {
        let name: String
        let url: URL
        let digest: String?

        enum CodingKeys: String, CodingKey {
            case name
            case url = "browser_download_url"
            case digest
        }
    }

    let tagName: String
    let body: String?
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case body
        case draft
        case prerelease
        case assets
    }
}

enum ClawdeskUpdateError: Error, Equatable, Sendable {
    case invalidRelease
    case missingVerifiedArchive
    case invalidResponse
    case digestMismatch
    case invalidApplication
    case versionMismatch
    case invalidSignature
    case wrongDeveloperTeam
    case gatekeeperRejected
    case installationUnavailable
    case updaterHelperMissing
    case commandFailed(String)
}

struct ClawdeskUpdateFailure: Equatable, Sendable {
    let message: String
    let detail: String?

    var displayText: String {
        guard let detail, !detail.isEmpty else { return message }
        return "\(message): \(detail)"
    }

    init(_ error: Error) {
        guard let error = error as? ClawdeskUpdateError else {
            message = "Network request failed"
            detail = error.localizedDescription
            return
        }

        switch error {
        case .invalidRelease, .missingVerifiedArchive, .invalidResponse:
            message = "The GitHub release or archive is invalid"
            detail = nil
        case .digestMismatch:
            message = "The downloaded archive failed its SHA-256 check"
            detail = nil
        case .invalidApplication, .versionMismatch, .invalidSignature, .wrongDeveloperTeam, .gatekeeperRejected:
            message = "The archive signature or version failed validation"
            detail = nil
        case .installationUnavailable:
            message = "The current app location is not writable"
            detail = "Move Clawdesk to a writable folder (for example /Applications) and try again"
        case .updaterHelperMissing:
            message = "The current installation is missing the update component"
            detail = "Install a newer version that includes online updates first"
        case .commandFailed(let command):
            message = "The update command failed"
            detail = command
        }
    }

    init(previousFailure message: String) {
        self.message = "The previous update failed"
        detail = message
    }
}

enum ClawdeskUpdateState: Equatable, Sendable {
    case idle
    case checking
    case upToDate
    case available(ClawdeskRelease)
    case downloading(ClawdeskRelease)
    case installing(ClawdeskRelease)
    case failed(ClawdeskUpdateFailure)

    var isBusy: Bool {
        switch self {
        case .checking, .downloading, .installing:
            return true
        default:
            return false
        }
    }

    var availableRelease: ClawdeskRelease? {
        switch self {
        case .available(let release), .downloading(let release), .installing(let release):
            return release
        default:
            return nil
        }
    }
}

enum ClawdeskUpdatePaths {
    static let updateLogURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Clawdesk/update.log")
    static let failureMarkerURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Clawdesk/update-failure.txt")
}

@MainActor
final class ClawdeskSoftwareUpdater: ObservableObject {
    static let latestReleaseURL = URL(string: "https://api.github.com/repos/\(ClawdeskAppIdentity.githubRepository)/releases/latest")!

    @Published private(set) var state: ClawdeskUpdateState = .idle
    let currentVersion: String

    private let session: URLSession
    private let applicationURL: URL
    private let failureMarkerURL: URL

    init(
        currentVersion: String = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.1.0",
        session: URLSession = .shared,
        applicationURL: URL = Bundle.main.bundleURL,
        failureMarkerURL: URL = ClawdeskUpdatePaths.failureMarkerURL
    ) {
        self.currentVersion = currentVersion
        self.session = session
        self.applicationURL = applicationURL
        self.failureMarkerURL = failureMarkerURL

        if let previousFailure = Self.consumeFailureMarker(at: failureMarkerURL) {
            state = .failed(ClawdeskUpdateFailure(previousFailure: previousFailure))
        }
    }

    func checkForUpdates() async {
        guard !state.isBusy else { return }
        state = .checking
        do {
            let release = try await fetchLatestRelease()
            state = release.isNewer(than: currentVersion) ? .available(release) : .upToDate
        } catch {
            state = .failed(ClawdeskUpdateFailure(error))
        }
    }

    func downloadAndInstall() async {
        guard case .available(let release) = state else { return }
        state = .downloading(release)
        do {
            let (downloadURL, response) = try await session.download(from: release.archiveURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw ClawdeskUpdateError.invalidResponse
            }

            state = .installing(release)
            let package = try await Task.detached(priority: .userInitiated) {
                try ClawdeskUpdatePackageValidator.prepare(downloadURL: downloadURL, release: release)
            }.value
            try launchInstaller(for: package)
            terminateForUpdate()
        } catch {
            state = .failed(ClawdeskUpdateFailure(error))
        }
    }

    private func fetchLatestRelease() async throws -> ClawdeskRelease {
        var request = URLRequest(url: Self.latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Clawdesk/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ClawdeskUpdateError.invalidResponse
        }
        return try ClawdeskRelease.decodeGitHubResponse(data)
    }

    private func launchInstaller(for package: VerifiedClawdeskUpdatePackage) throws {
        let fileManager = FileManager.default
        let parent = applicationURL.deletingLastPathComponent()
        guard applicationURL.pathExtension == "app",
              Bundle(url: applicationURL)?.bundleIdentifier == ClawdeskAppIdentity.bundleIdentifier,
              fileManager.isWritableFile(atPath: parent.path) else {
            throw ClawdeskUpdateError.installationUnavailable
        }

        let bundledHelper = ClawdeskAppIdentity.updaterURL(in: applicationURL)
        guard fileManager.isExecutableFile(atPath: bundledHelper.path) else {
            throw ClawdeskUpdateError.updaterHelperMissing
        }

        let helperDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("ClawdeskUpdater-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: helperDirectory, withIntermediateDirectories: true)
        let helperURL = helperDirectory.appendingPathComponent(ClawdeskAppIdentity.updaterExecutableName)
        do {
            try fileManager.copyItem(at: bundledHelper, to: helperURL)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperURL.path)

            let process = Process()
            process.executableURL = helperURL
            process.arguments = [
                String(ProcessInfo.processInfo.processIdentifier),
                package.applicationURL.path,
                applicationURL.path,
                package.workingDirectory.path,
                helperDirectory.path,
                ClawdeskUpdatePaths.updateLogURL.path,
                failureMarkerURL.path
            ]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
        } catch {
            try? fileManager.removeItem(at: helperDirectory)
            throw error
        }
    }

    private func terminateForUpdate() {
        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
    }

    private static func consumeFailureMarker(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !message.isEmpty else {
            return nil
        }
        try? FileManager.default.removeItem(at: url)
        return message
    }
}

struct VerifiedClawdeskUpdatePackage: Sendable {
    let applicationURL: URL
    let workingDirectory: URL
}

enum ClawdeskUpdatePackageValidator {
    static func prepare(downloadURL: URL, release: ClawdeskRelease) throws -> VerifiedClawdeskUpdatePackage {
        let digest = try sha256(of: downloadURL)
        guard digest == release.sha256 else {
            throw ClawdeskUpdateError.digestMismatch
        }

        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClawdeskUpdate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)

        do {
            let archiveURL = workingDirectory.appendingPathComponent("update.zip")
            try FileManager.default.copyItem(at: downloadURL, to: archiveURL)
            try run("/usr/bin/ditto", arguments: ["-x", "-k", archiveURL.path, workingDirectory.path])

            let applicationURL = ClawdeskAppIdentity.applicationURL(in: workingDirectory)
            guard let bundle = Bundle(url: applicationURL),
                  bundle.bundleIdentifier == ClawdeskAppIdentity.bundleIdentifier,
                  let executableName = bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String,
                  executableName == ClawdeskAppIdentity.executableName,
                  FileManager.default.isExecutableFile(
                      atPath: applicationURL.appendingPathComponent("Contents/MacOS/\(executableName)").path
                  ),
                  FileManager.default.isExecutableFile(
                      atPath: ClawdeskAppIdentity.updaterURL(in: applicationURL).path
                  ) else {
                throw ClawdeskUpdateError.invalidApplication
            }

            let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            guard version.flatMap(ClawdeskVersion.init) == release.version else {
                throw ClawdeskUpdateError.versionMismatch
            }

            try run("/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", applicationURL.path])
            let signatureDetails = try run(
                "/usr/bin/codesign",
                arguments: ["--display", "--verbose=4", applicationURL.path]
            )
            guard signatureDetails.contains("TeamIdentifier=\(ClawdeskAppIdentity.developerTeamIdentifier)") else {
                throw ClawdeskUpdateError.wrongDeveloperTeam
            }

            do {
                try run("/usr/sbin/spctl", arguments: ["--assess", "--type", "execute", applicationURL.path])
            } catch {
                throw ClawdeskUpdateError.gatekeeperRejected
            }

            return VerifiedClawdeskUpdatePackage(
                applicationURL: applicationURL,
                workingDirectory: workingDirectory
            )
        } catch {
            try? FileManager.default.removeItem(at: workingDirectory)
            throw error
        }
    }

    static func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    private static func run(_ executable: String, arguments: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            if executable == "/usr/bin/codesign" {
                throw ClawdeskUpdateError.invalidSignature
            }
            throw ClawdeskUpdateError.commandFailed(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output
    }
}
