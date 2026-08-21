import AppKit
import Darwin
import Foundation

/// Best-effort local focus handoff. Remote SSH sessions intentionally return
/// false because a macOS process cannot activate a terminal window on another
/// host.
@MainActor
public enum TerminalFocusService {
    @discardableResult
    public static func focus(_ session: SessionSnapshot) -> Bool {
        guard let pid = session.terminalPID, isRunning(pid: pid),
              let application = NSRunningApplication(processIdentifier: pid_t(pid)) else {
            if let folder = session.folder, !folder.isEmpty {
                return NSWorkspace.shared.open(URL(fileURLWithPath: folder))
            }
            return false
        }
        return application.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    }

    public static func isRunning(pid: Int) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid_t(pid), 0) == 0 { return true }
        return errno == EPERM
    }
}
