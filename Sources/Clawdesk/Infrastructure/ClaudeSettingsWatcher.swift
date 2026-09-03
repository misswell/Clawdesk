import Foundation

/// Watches the `~/.claude` directory so an external overwrite (CC-Switch
/// style profile swaps, manual edits) triggers an immediate health check
/// instead of waiting for the five-minute timer. Mirrors upstream's
/// directory-scoped `fs.watch`: watching the directory survives atomic
/// replace swaps of `settings.json` because the inode stays the same.
@MainActor
final class ClaudeSettingsWatcher {
    private let directoryPath: String
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var debounceTask: Task<Void, Never>?

    init(homeDirectory: URL, onChange: @escaping () -> Void) {
        directoryPath = homeDirectory.appendingPathComponent(".claude", isDirectory: true).path
        self.onChange = onChange
    }

    func start() {
        guard source == nil else { return }
        let descriptor = open(directoryPath, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleCheck()
            }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        self.source = source
    }

    func stop() {
        debounceTask?.cancel()
        debounceTask = nil
        source?.cancel()
        source = nil
    }

    /// Test hook: runs the coalesced check without waiting for the 1 s debounce.
    func dispatchCheckForTesting() {
        scheduleCheck()
    }

    private func scheduleCheck() {
        // Coalesce the event burst an atomic replace produces.
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }
            self.onChange()
        }
    }
}
