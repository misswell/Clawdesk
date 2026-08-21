import CryptoKit
import Foundation

public struct ReleaseAsset: Sendable, Equatable {
    public let name: String
    public let downloadURL: URL
    public let size: Int64?
    public let sha256: String?

    public init(name: String, downloadURL: URL, size: Int64? = nil, sha256: String? = nil) {
        self.name = name
        self.downloadURL = downloadURL
        self.size = size
        self.sha256 = sha256
    }
}

public struct ReleaseInfo: Sendable, Equatable {
    public let tag: String
    public let title: String
    public let url: URL
    public let assets: [ReleaseAsset]

    public init(tag: String, title: String, url: URL, assets: [ReleaseAsset] = []) {
        self.tag = tag
        self.title = title
        self.url = url
        self.assets = assets
    }
}

public enum UpdateServiceError: LocalizedError {
    case invalidResponse
    case noCompatibleAsset
    case downloadFailed
    case checksumMismatch

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: return "GitHub did not return a valid release response."
        case .noCompatibleAsset: return "The latest release has no compatible macOS package."
        case .downloadFailed: return "The update package could not be downloaded."
        case .checksumMismatch: return "The downloaded update failed its SHA-256 integrity check."
        }
    }
}

public struct UpdateService {
    public let repository: String

    public init(repository: String = "misswell/Clawdesk") {
        self.repository = repository
    }

    public func latestRelease() async throws -> ReleaseInfo {
        guard let endpoint = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            throw UpdateServiceError.invalidResponse
        }
        var request = URLRequest(url: endpoint)
        request.setValue("Clawdesk/0.1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String,
              let title = object["name"] as? String,
              let urlString = object["html_url"] as? String,
              let url = URL(string: urlString) else {
            throw UpdateServiceError.invalidResponse
        }
        let assets = (object["assets"] as? [[String: Any]] ?? []).compactMap { asset -> ReleaseAsset? in
            guard let name = asset["name"] as? String,
                  let downloadString = asset["browser_download_url"] as? String,
                  let downloadURL = URL(string: downloadString) else { return nil }
            let digest = (asset["digest"] as? String)?.lowercased().replacingOccurrences(of: "sha256:", with: "")
            let sha256 = digest?.count == 64 && digest?.allSatisfy(\.isHexDigit) == true ? digest : nil
            return ReleaseAsset(
                name: name,
                downloadURL: downloadURL,
                size: (asset["size"] as? NSNumber)?.int64Value,
                sha256: sha256
            )
        }
        return ReleaseInfo(tag: tag, title: title, url: url, assets: assets)
    }

    public func compatibleAsset(
        in release: ReleaseInfo,
        platform: String = "macos",
        architecture: String? = nil
    ) -> ReleaseAsset? {
        Self.selectCompatibleAsset(assets: release.assets, platform: platform, architecture: architecture ?? Self.machineArchitecture())
    }

    public func download(asset: ReleaseAsset, to directory: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var request = URLRequest(url: asset.downloadURL)
        request.setValue("Clawdesk/0.1", forHTTPHeaderField: "User-Agent")
        let (temporaryURL, response): (URL, URLResponse)
        do {
            (temporaryURL, response) = try await URLSession.shared.download(for: request)
        } catch {
            throw UpdateServiceError.downloadFailed
        }
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw UpdateServiceError.downloadFailed
        }

        let safeName = Self.safeFileName(asset.name)
        let destination = Self.uniqueDestination(directory: directory, fileName: safeName)
        do {
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
            if let expected = asset.sha256 {
                let actual = try Self.sha256(of: destination)
                guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
                    try? FileManager.default.removeItem(at: destination)
                    throw UpdateServiceError.checksumMismatch
                }
            }
            return destination
        } catch let error as UpdateServiceError {
            throw error
        } catch {
            throw UpdateServiceError.downloadFailed
        }
    }

    public func downloadLatestCompatibleAsset(to directory: URL) async throws -> URL {
        let release = try await latestRelease()
        guard let asset = compatibleAsset(in: release) else { throw UpdateServiceError.noCompatibleAsset }
        return try await download(asset: asset, to: directory)
    }

    public static func selectCompatibleAsset(
        assets: [ReleaseAsset],
        platform: String,
        architecture: String
    ) -> ReleaseAsset? {
        guard platform.lowercased() == "macos" else { return nil }
        let arch = architecture.lowercased()
        let candidates = assets.filter { asset in
            let name = asset.name.lowercased()
            guard [".dmg", ".pkg", ".zip"].contains(where: { name.hasSuffix($0) }) else { return false }
            return !name.contains("source") && !name.contains("checksums")
        }
        return candidates.max { lhs, rhs in
            score(lhs.name.lowercased(), architecture: arch) < score(rhs.name.lowercased(), architecture: arch)
        }
    }

    private static func score(_ name: String, architecture: String) -> Int {
        var value = 0
        if name.hasSuffix(".dmg") { value += 30 }
        if name.contains(architecture) { value += 40 }
        if architecture == "arm64" && (name.contains("aarch64") || name.contains("apple-silicon")) { value += 20 }
        if ["x86_64", "x64", "amd64"].contains(where: { architecture == "x86_64" && name.contains($0) }) { value += 20 }
        if name.contains("universal") { value += 10 }
        return value
    }

    private static func machineArchitecture() -> String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    private static func safeFileName(_ name: String) -> String {
        let candidate = URL(fileURLWithPath: name).lastPathComponent
        let allowed = candidate.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) || ".-_".unicodeScalars.contains(scalar)
        }
        let sanitized = String(zip(candidate, allowed).map { $0.1 ? $0.0 : "_" })
        return sanitized.isEmpty ? "Clawdesk-update" : String(sanitized.prefix(160))
    }

    private static func uniqueDestination(directory: URL, fileName: String) -> URL {
        let initial = directory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: initial.path) else { return initial }
        let stem = initial.deletingPathExtension().lastPathComponent
        let suffix = initial.pathExtension.isEmpty ? "" : ".\(initial.pathExtension)"
        return directory.appendingPathComponent("\(stem)-\(UUID().uuidString.prefix(8))\(suffix)")
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
