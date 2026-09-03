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
        switch event.keyCode {
        case 16: // ⌃⇧Y — allow the newest pending permission
            model.resolveLatestPermission(decision: .allow)
        case 45: // ⌃⇧N — deny the newest pending permission
            model.resolveLatestPermission(decision: .deny)
        case 35: // ⌃⇧P — upstream's togglePet action
            model.preferences.petHidden.toggle()
        default:
            break
        }
    }
}
