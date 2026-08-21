import Darwin
import Foundation

public final class SingleInstanceGuard {
    private var descriptor: Int32 = -1
    private let lockURL: URL

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        lockURL = homeDirectory.appendingPathComponent("Library/Application Support/Clawdesk/instance.lock")
    }

    deinit {
        release()
    }

    public func acquire() -> Bool {
        guard descriptor < 0 else { return true }
        do {
            try FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            return false
        }
        descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return false }
        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            close(descriptor)
            descriptor = -1
            return false
        }
        return true
    }

    public func release() {
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }
}
