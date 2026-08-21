import AppKit

@MainActor
public final class GlobalShortcutManager {
    private let model: ClawdeskModel
    private var localMonitor: Any?
    private var globalMonitor: Any?

    public init(model: ClawdeskModel) {
        self.model = model
    }

    public func start() {
        let handler: (NSEvent) -> NSEvent? = { [weak self] event in
            self?.handle(event)
            return event
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: handler)
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
    }

    public func stop() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
    }

    private func handle(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains([.control, .shift]) else { return }
        let decision: PermissionDecision?
        switch event.keyCode {
        case 16: decision = .allow // Y
        case 45: decision = .deny // N
        default: decision = nil
        }
        guard let decision, let request = model.pendingPermissions.first else { return }
        model.resolvePermission(id: request.id, decision: decision)
    }
}
