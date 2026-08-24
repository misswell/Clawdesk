import AppKit
import Combine
import Foundation

@MainActor
public final class PetWindowController: NSWindowController, NSWindowDelegate {
    private let model: ClawdeskModel
    private let petView: PetCanvasView
    private let quotaRing: QuotaRingWindowController
    private var animationTimer: Timer?
    private var pointerTimer: Timer?
    private var sleepTimer: Timer?
    private var roamTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var isDragging = false
    private var dragAnchor: PetDragAnchor?
    private var isRoaming = false
    private var hoverRestoreTask: Task<Void, Never>?
    private var nextRoamDate = Date.distantPast
    private let roamFence = RoamFenceCoordinator()

    public var onSettings: (() -> Void)?
    public var onDashboard: (() -> Void)?
    public var onCheckForUpdates: (() -> Void)?
    public var onQuit: (() -> Void)?

    public init(model: ClawdeskModel) {
        self.model = model
        quotaRing = QuotaRingWindowController(model: model)
        let base = 240.0 * model.preferences.petScale
        petView = PetCanvasView(frame: NSRect(x: 0, y: 0, width: base, height: base))
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: base, height: base),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.contentView = petView
        super.init(window: panel)
        panel.delegate = self
        panel.title = "Clawdesk"

        petView.theme = model.preferences.theme
        petView.idleVisualFile = model.preferences.selectedIdleVisual(for: model.preferences.theme)
        petView.onDragBegan = { [weak self] point in self?.beginDrag(at: point) }
        petView.onDrag = { [weak self] point in self?.drag(to: point) }
        petView.onDragEnded = { [weak self] in self?.endDrag() }
        petView.onDoubleTap = { [weak self] in self?.showReaction(.reactDouble, duration: 1.3) }
        petView.onFlail = { [weak self] in self?.showReaction(.reactFlail, duration: 1.4) }
        petView.onContextMenu = { [weak self] _ in self?.makeContextMenu() }
        petView.onHoverChanged = { [weak self] hovering in self?.handleHover(hovering) }

        model.$petState.sink { [weak self] state in
            self?.apply(state: state)
        }.store(in: &cancellables)
        model.$sessions.sink { [weak self] sessions in
            self?.petView.subagentCount = sessions.reduce(0) { $0 + max(0, $1.subagentCount) }
        }.store(in: &cancellables)
        model.preferences.$selectedThemeID.sink { [weak self] _ in
            self?.petView.theme = model.preferences.theme
            self?.petView.idleVisualFile = model.preferences.selectedIdleVisual(for: model.preferences.theme)
        }.store(in: &cancellables)
        model.preferences.$idleVisualByTheme.sink { [weak self] _ in
            self?.petView.idleVisualFile = model.preferences.selectedIdleVisual(for: model.preferences.theme)
        }.store(in: &cancellables)
        model.preferences.$isMiniMode.sink { [weak self] enabled in
            self?.setMiniMode(enabled, animate: true)
        }.store(in: &cancellables)
        model.preferences.$petScale.sink { [weak self] scale in
            self?.applyScale(scale, animate: true)
        }.store(in: &cancellables)
        model.$quotaReports.sink { [weak self] _ in
            self?.refreshQuotaRing()
        }.store(in: &cancellables)
        model.preferences.$showQuotaRing.sink { [weak self] _ in
            self?.refreshQuotaRing()
        }.store(in: &cancellables)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func windowDidLoad() {
        super.windowDidLoad()
        restorePosition()
    }

    public func start() {
        restorePosition()
        window?.orderFrontRegardless()
        let animationFrequency = model.preferences.lowPowerAnimations ? 30.0 : 60.0
        animationTimer = PetTimerScheduler.schedule(
            interval: 1.0 / animationFrequency,
            repeats: true
        ) { [weak self] in
            guard let self, !self.isDragging else { return }
            self.petView.advanceFrame()
        }
        pointerTimer = PetTimerScheduler.schedule(
            interval: 1.0 / 60.0,
            repeats: true
        ) { [weak self] in
            guard let self, let window = self.window else { return }
            guard !self.isDragging else { return }
            self.model.noteMouseActivity(at: NSEvent.mouseLocation)
            guard self.petView.petState == .idle || self.petView.petState == .miniIdle else { return }
            self.petView.setPointerLocation(NSEvent.mouseLocation)
            if window.isVisible == false { window.orderFrontRegardless() }
        }
        sleepTimer = PetTimerScheduler.schedule(
            interval: 5,
            repeats: true
        ) { [weak self] in
            self?.model.tickForMaintenance()
        }
        roamTimer = PetTimerScheduler.schedule(
            interval: 5,
            repeats: true
        ) { [weak self] in
            self?.checkRoam()
        }
    }

    public func stop() {
        animationTimer?.invalidate()
        pointerTimer?.invalidate()
        sleepTimer?.invalidate()
        roamTimer?.invalidate()
        animationTimer = nil
        pointerTimer = nil
        sleepTimer = nil
        roamTimer = nil
        dragAnchor = nil
        hoverRestoreTask?.cancel()
        quotaRing.hide()
        close()
    }

    public func setMiniMode(_ enabled: Bool, animate: Bool) {
        guard window != nil else { return }
        petView.miniMode = enabled
        if enabled {
            moveToMiniEdge(animated: animate)
            if model.petState == .idle { petView.petState = .miniIdle }
        } else {
            moveBackFromMini()
            petView.petState = model.petState
        }
    }

    private func apply(state: PetState) {
        guard !isDragging else { return }
        if model.preferences.isMiniMode {
            switch state {
            case .notification: petView.petState = .miniAlert
            case .attention: petView.petState = .miniHappy
            case .idle: petView.petState = .miniIdle
            default: petView.petState = state
            }
        } else {
            petView.petState = state
        }
    }

    private func beginDrag(at screenPoint: CGPoint) {
        guard let window else { return }
        isDragging = true
        dragAnchor = PetDragAnchor(windowOrigin: window.frame.origin, pointerOrigin: screenPoint)
        petView.petState = .dragging
        window.invalidateCursorRects(for: petView)
    }

    private func drag(to screenPoint: CGPoint) {
        guard let window, let dragAnchor else { return }
        window.setFrameOrigin(dragAnchor.windowOrigin(for: screenPoint))
    }

    private func endDrag() {
        guard isDragging else { return }
        isDragging = false
        dragAnchor = nil
        if shouldEnterMiniMode {
            model.preferences.isMiniMode = true
        } else {
            model.preferences.windowOrigin = window?.frame.origin
            petView.petState = model.petState
        }
        refreshQuotaRing()
    }

    private var shouldEnterMiniMode: Bool {
        guard let window, let screen = screenForWindow(window) else { return false }
        return window.frame.maxX >= screen.visibleFrame.maxX - 8
    }

    private func showReaction(_ state: PetState, duration: Double) {
        guard !isDragging else { return }
        petView.petState = model.preferences.isMiniMode
            ? (state == .reactDouble ? .miniHappy : .miniAlert)
            : state
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard let self, !Task.isCancelled else { return }
            self.apply(state: self.model.petState)
        }
    }

    private func handleHover(_ hovering: Bool) {
        guard model.preferences.isMiniMode, !isDragging else { return }
        hoverRestoreTask?.cancel()
        if hovering {
            petView.petState = .miniPeek
        } else {
            hoverRestoreTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled else { return }
                self.apply(state: self.model.petState)
            }
        }
    }

    private func restorePosition() {
        guard let window else { return }
        if model.preferences.isMiniMode {
            moveToMiniEdge(animated: false)
            return
        }
        if let saved = model.preferences.windowOrigin {
            window.setFrameOrigin(saved)
        } else if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: frame.maxX - window.frame.width - 26, y: frame.minY + 30))
        }
    }

    private func moveToMiniEdge(animated: Bool) {
        guard let window, let screen = screenForWindow(window) else { return }
        let frame = screen.visibleFrame
        let target = NSPoint(x: frame.maxX - window.frame.width * 0.48, y: max(frame.minY + 16, window.frame.minY))
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.28
                window.animator().setFrameOrigin(target)
            }
        } else {
            window.setFrameOrigin(target)
        }
    }

    private func moveBackFromMini() {
        guard let window, let screen = screenForWindow(window) else { return }
        let frame = screen.visibleFrame
        let target = NSPoint(x: frame.maxX - window.frame.width - 26, y: max(frame.minY + 30, window.frame.minY))
        window.setFrameOrigin(target)
        model.preferences.windowOrigin = target
    }

    private func checkRoam() {
        guard model.preferences.freeRoamEnabled,
              !model.preferences.isMiniMode,
              !model.preferences.doNotDisturb,
              !isDragging,
              let window,
              !model.petState.isTransient,
              model.petState == .idle || model.petState == .typing else { return }
        let now = Date.now
        guard now >= nextRoamDate else { return }
        roamFence.refresh(from: model.preferences.roamAreaFileURL)
        guard roamFence.confirmed else {
            nextRoamDate = now.addingTimeInterval(5)
            return
        }
        guard let screen = screenForWindow(window) else { return }
        guard let target = RoamPlanner.nextTarget(
            currentOrigin: window.frame.origin,
            windowSize: window.frame.size,
            workArea: screen.visibleFrame,
            fence: roamFence.current,
            random: { CGFloat.random(in: $0) }
        ) else {
            // The window cannot fit inside the fence; hold and retry later.
            nextRoamDate = now.addingTimeInterval(10)
            return
        }
        let newOrigin = NSPoint(x: target.x, y: target.y)
        guard abs(newOrigin.x - window.frame.origin.x) + abs(newOrigin.y - window.frame.origin.y) > 8 else {
            nextRoamDate = now.addingTimeInterval(8)
            return
        }
        nextRoamDate = now.addingTimeInterval(TimeInterval.random(in: 10...20))
        isRoaming = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 1.6
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrameOrigin(newOrigin)
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                self?.isRoaming = false
            }
        }
    }

    /// Continuously resizes the pet window from the 240-point logical canvas.
    /// The bottom-center of the pet stays anchored so enlarging or shrinking
    /// feels like the pet itself is scaling in place.
    private func applyScale(_ scale: Double, animate: Bool) {
        guard let window else { return }
        let clamped = min(2.0, max(0.4, scale))
        let size = NSSize(width: 240 * clamped, height: 240 * clamped)
        let current = window.frame
        let target = NSRect(
            x: current.midX - size.width / 2,
            y: current.minY,
            width: size.width,
            height: size.height
        )
        if animate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                window.animator().setFrame(target, display: true)
            }
        } else {
            window.setFrame(target, display: true)
        }
        if model.preferences.isMiniMode {
            moveToMiniEdge(animated: animate)
        } else if !isDragging {
            model.preferences.windowOrigin = target.origin
        }
    }

    private func screenForWindow(_ window: NSWindow) -> NSScreen? {
        NSScreen.screens.first { $0.frame.intersects(window.frame) } ?? NSScreen.main
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        addMenuItem(to: menu, title: model.preferences.text("Open Dashboard"), action: #selector(openDashboard))
        addMenuItem(to: menu, title: model.preferences.text("Settings…"), action: #selector(openSettings))
        addMenuItem(to: menu, title: model.preferences.text("Check for Updates…"), action: #selector(checkForUpdates))
        let sessions = NSMenuItem(title: model.preferences.text("Sessions"), action: nil, keyEquivalent: "")
        sessions.submenu = makeSessionsMenu()
        menu.addItem(sessions)
        menu.addItem(.separator())
        let mini = addMenuItem(to: menu, title: model.preferences.text(model.preferences.isMiniMode ? "Exit Mini Mode" : "Mini Mode"), action: #selector(toggleMini))
        mini.state = model.preferences.isMiniMode ? .on : .off
        let dnd = addMenuItem(to: menu, title: model.preferences.text(model.preferences.doNotDisturb ? "Wake Clawdesk" : "Do Not Disturb"), action: #selector(toggleDND))
        dnd.state = model.preferences.doNotDisturb ? .on : .off
        let sound = addMenuItem(to: menu, title: model.preferences.text("Sound effects"), action: #selector(toggleSound))
        sound.state = model.preferences.soundEnabled ? .on : .off
        menu.addItem(.separator())
        addMenuItem(to: menu, title: model.preferences.text("Quit Clawdesk"), action: #selector(quit))
        return menu
    }

    private func makeSessionsMenu() -> NSMenu {
        let menu = NSMenu()
        let sessions = model.sessions
        if sessions.isEmpty {
            let item = NSMenuItem(title: model.preferences.text("No active sessions"), action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            for session in sessions {
                let title = session.title.isEmpty ? session.agentID : session.title
                let item = NSMenuItem(title: title, action: #selector(focusSession(_:)), keyEquivalent: "")
                item.representedObject = session.id
                item.target = self
                menu.addItem(item)
            }
        }
        return menu
    }

    @objc private func focusSession(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let session = model.sessions.first(where: { $0.id == id }) else { return }
        _ = TerminalFocusService.focus(session)
    }

    @discardableResult
    private func addMenuItem(to menu: NSMenu, title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    @objc private func openDashboard() { onDashboard?() }
    @objc private func openSettings() { onSettings?() }
    @objc private func checkForUpdates() { onCheckForUpdates?() }
    @objc private func toggleMini() { model.preferences.isMiniMode.toggle() }
    @objc private func toggleDND() { model.preferences.doNotDisturb.toggle() }
    @objc private func toggleSound() { model.preferences.soundEnabled.toggle() }
    @objc private func quit() { onQuit?() ?? NSApp.terminate(nil) }

    public func windowDidMove(_ notification: Notification) {
        guard !isDragging else { return }
        refreshQuotaRing()
        guard !model.preferences.isMiniMode, !isRoaming else { return }
        model.preferences.windowOrigin = window?.frame.origin
    }

    private func refreshQuotaRing() {
        guard let window, !model.preferences.isMiniMode else {
            quotaRing.hide()
            return
        }
        quotaRing.update(petWindowFrame: window.frame)
    }
}
