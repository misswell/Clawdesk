import Foundation

/// Read-only periodic health check for the Claude Code hook integration.
///
/// Mirrors the upstream contract: every check verifies that the managed hook
/// script referenced by `~/.claude/settings.json` still exists on disk. When
/// it is missing (for example a Temp-folder cleanup), the monitor repairs the
/// script and hook entries via `repairClaudeHooks`, which never touches the
/// statusLine slot. After three consecutive failed repairs it stops
/// auto-repairing and reports `manualFixRequired` for a human fix.
@MainActor
public final class ClaudeHookHealthMonitor: ObservableObject {
    public enum HealthStatus: String, Equatable {
        case healthy
        case repairing
        case manualFixRequired = "manual-fix-required"
        case guarded
        case unknown
    }

    @Published public private(set) var status: HealthStatus = .unknown
    public private(set) var consecutiveFailures = 0

    private let installer: HookInstaller
    private let fileManager: FileManager

    public init(installer: HookInstaller, fileManager: FileManager = .default) {
        self.installer = installer
        self.fileManager = fileManager
    }

    public func check(port: UInt16) {
        let settingsURL = installer.homeDirectory.appendingPathComponent(".claude/settings.json")
        guard fileManager.fileExists(atPath: settingsURL.path) else {
            // Nothing installed: stay guarded without mutating anything.
            status = .guarded
            return
        }
        guard configReferencesMarker(settingsURL) else {
            // Managed hook entries were lost or removed; attempt a repair.
            repair(port: port)
            return
        }
        if fileManager.fileExists(atPath: installer.hookScript.path) {
            consecutiveFailures = 0
            status = .healthy
        } else {
            repair(port: port)
        }
    }

    private func configReferencesMarker(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) else { return false }
        return containsMarker(object)
    }

    private func containsMarker(_ value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            return dictionary.values.contains { containsMarker($0) }
        } else if let array = value as? [Any] {
            return array.contains { containsMarker($0) }
        } else if let string = value as? String, string.contains(HookInstaller.marker) {
            return true
        }
        return false
    }

    private func repair(port: UInt16) {
        do {
            _ = try installer.repairClaudeHooks(port: port)
            if fileManager.fileExists(atPath: installer.hookScript.path) {
                consecutiveFailures = 0
                status = .healthy
            } else {
                consecutiveFailures += 1
                status = consecutiveFailures >= 3 ? .manualFixRequired : .repairing
            }
        } catch {
            consecutiveFailures += 1
            status = consecutiveFailures >= 3 ? .manualFixRequired : .repairing
        }
    }
}
