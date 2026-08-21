import Foundation

/// Reads `~/.clawd/roam-area.json` with the upstream failure semantics: a
/// malformed file keeps the previous fence, deletion only counts after two
/// consecutive checks, and roaming holds until the first status is confirmed.
@MainActor
public final class RoamFenceCoordinator {
    public private(set) var current: RoamArea?
    public private(set) var confirmed = false

    private let fileManager: FileManager
    private var missingChecks = 0
    public private(set) var lastWarning: String?

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func refresh(from url: URL) {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            handleMissing(url: url)
            return
        }
        missingChecks = 0
        guard let area = RoamArea(json: object) else {
            // Malformed input keeps the previous fence. The warning is
            // deduplicated so a broken save does not spam the log.
            lastWarning = "Roam area file is malformed; keeping the previous fence."
            return
        }
        current = area
        confirmed = true
        lastWarning = nil
    }

    private func handleMissing(url: URL) {
        if current != nil {
            missingChecks += 1
            if missingChecks >= 2 {
                current = nil
                confirmed = true
                missingChecks = 0
            }
        } else if confirmed {
            missingChecks = 0
        }
    }

    /// Writes a new fence atomically and refreshes the cached state.
    public func apply(_ area: RoamArea, to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: area.wireObject, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        current = area
        confirmed = true
        missingChecks = 0
        lastWarning = nil
    }

    /// Disables the fence without deleting the file (upstream's `enabled: false`
    /// form), so the change is confirmed in one refresh.
    public func disable(_ url: URL) throws {
        let area = current?.withDisabled ?? RoamArea(enabled: false)
        try apply(area, to: url)
    }
}

private extension RoamArea {
    var withDisabled: RoamArea {
        RoamArea(enabled: false, left: left, top: top, right: right, bottom: bottom)
    }
}
