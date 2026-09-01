import AppKit
import Combine
import Foundation

@MainActor
public final class PetWindowController: NSWindowController, NSWindowDelegate {
    private let model: ClawdeskModel
    private let petView: PetCanvasView
    private let quotaRing: QuotaRingWindowController
    private let sessionHUD: SessionHUDWindowController
    private var animationTimer: Timer?
    /// True while the animation loop runs at its full frequency; false while
    /// the pet is resting and the loop is throttled down.
    private var animationTimerHigh = true
    private var pointerTimer: Timer?
    private var sleepTimer: Timer?
    private var roamTimer: Timer?
    private var idleAnimationTask: Task<Void, Never>?
    private var idleAnimationCycle = IdleAnimationCycle()
    private var cancellables = Set<AnyCancellable>()
    private var isDragging = false
    private var dragAnchor: PetDragAnchor?
    private var isRoaming = false
    private var arrivalTracker = SessionArrivalTracker()
    private var hoverRestoreTask: Task<Void, Never>?
    private var nextRoamDate = Date.distantPast
    private let roamFence = RoamFenceCoordinator()
    private var isStarted = false

    public var onSettings: (() -> Void)?
    public var onDashboard: (() -> Void)?
    public var onCheckForUpdates: (() -> Void)?
    public var onQuit: (() -> Void)?

    public init(model: ClawdeskModel) {
        self.model = model
        quotaRing = QuotaRingWindowController(model: model)
        sessionHUD = SessionHUDWindowController(model: model)
        let base = PetSizing.baseWindowSize * CGFloat(model.preferences.petScale)
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
        petView.bloubAppearance = model.preferences.bloubAppearance
        petView.idleVisualFile = model.preferences.selectedIdleVisual(for: model.preferences.theme)
        petView.onDragBegan = { [weak self] point in self?.beginDrag(at: point) }
        petView.onDrag = { [weak self] point in self?.drag(to: point) }
        petView.onDragEnded = { [weak self] in self?.endDrag() }
        petView.onClick = { [weak self] in self?.revealSessionHUD() }
        petView.onDoubleTap = { [weak self] in self?.showReaction(.reactDouble, duration: 1.3) }
        petView.onFlail = { [weak self] in self?.showReaction(.reactFlail, duration: 1.4) }
        petView.onContextMenu = { [weak self] _ in self?.makeContextMenu() }
        petView.onHoverChanged = { [weak self] hovering in self?.handleHover(hovering) }
        sessionHUD.onSessionSelected = { [weak self] session in
            _ = TerminalFocusService.focus(session)
            self?.sessionHUD.hide()
        }
        sessionHUD.onOverflowSelected = { [weak self] in
            self?.sessionHUD.hide()
            self?.onDashboard?()
        }
        sessionHUD.setEnabled(model.preferences.sessionHUDEnabled)
        sessionHUD.setPinned(model.preferences.sessionHUDPinned)
        sessionHUD.setShowContextUsage(model.preferences.sessionHUDShowContextUsage)

        model.$petState.sink { [weak self] state in
            self?.apply(state: state)
        }.store(in: &cancellables)
        model.$sessions.sink { [weak self] sessions in
            self?.petView.subagentCount = sessions.reduce(0) { $0 + max(0, $1.subagentCount) }
            self?.refreshSessionHUD()
            self?.celebrateArrivals(in: sessions)
        }.store(in: &cancellables)
        model.preferences.$selectedThemeID.sink { [weak self] _ in
            self?.cancelIdleAnimation(resetCycle: true)
            self?.petView.theme = model.preferences.theme
            self?.petView.idleVisualFile = model.preferences.selectedIdleVisual(for: model.preferences.theme)
            self?.updateStateAssetOverride()
        }.store(in: &cancellables)
        model.preferences.$bloubAppearance.sink { [weak self] appearance in
            self?.petView.bloubAppearance = appearance
        }.store(in: &cancellables)
        model.preferences.$idleVisualByTheme.sink { [weak self] _ in
            self?.cancelIdleAnimation(resetCycle: true)
            self?.petView.idleVisualFile = model.preferences.selectedIdleVisual(for: model.preferences.theme)
        }.store(in: &cancellables)
        model.preferences.$isMiniMode.sink { [weak self] enabled in
            self?.setMiniMode(enabled, animate: true)
        }.store(in: &cancellables)
        model.preferences.$doNotDisturb.sink { [weak self] _ in
            self?.updateStateAssetOverride()
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
        model.preferences.$sessionHUDEnabled.sink { [weak self] enabled in
            self?.sessionHUD.setEnabled(enabled)
            self?.refreshSessionHUD()
        }.store(in: &cancellables)
        model.preferences.$sessionHUDPinned.sink { [weak self] pinned in
            self?.sessionHUD.setPinned(pinned)
            self?.refreshSessionHUD()
        }.store(in: &cancellables)
        model.preferences.$sessionHUDShowContextUsage.sink { [weak self] show in
            self?.sessionHUD.setShowContextUsage(show)
            self?.refreshSessionHUD()
        }.store(in: &cancellables)
        model.preferences.$language.sink { [weak self] _ in
            self?.refreshSessionHUD()
        }.store(in: &cancellables)
        model.preferences.$lowPowerAnimations.dropFirst().sink { [weak self] _ in
            self?.restartAnimationTimer()
            self?.restartPointerTimer()
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
        guard !isStarted else { return }
        isStarted = true
        restorePosition()
        window?.orderFrontRegardless()
        // The quota store may have restored the last account report before
        // this controller was created; draw that balance immediately instead
        // of waiting for the next hook/statusline event.
        refreshQuotaRing()
        refreshSessionHUD()
        restartAnimationTimer()
        restartPointerTimer()
        sleepTimer = PetTimerScheduler.schedule(
            interval: 5,
            repeats: true
        ) { [weak self] in
            self?.model.tickForMaintenance()
            self?.tickIdleAnimation()
        }
        roamTimer = PetTimerScheduler.schedule(
            interval: 5,
            repeats: true
        ) { [weak self] in
            self?.checkRoam()
        }
    }

    /// Animation frequencies: full speed while anything discrete is animating
    /// (state fades, tracking, decorations, theme asset timelines) and a low
    /// idle cadence once the pet has settled — the frame then only changes
    /// through bloub's slow rest life, and the reference video itself rests
    /// at ~10 fps. Idle therefore never means a permanent 60 FPS clock.
    private var animationFrequencies: (high: Double, idle: Double) {
        model.preferences.lowPowerAnimations ? (30, 8) : (60, 12)
    }

    private func restartAnimationTimer() {
        animationTimer?.invalidate()
        let frequencies = animationFrequencies
        let interval = 1.0 / (animationTimerHigh ? frequencies.high : frequencies.idle)
        animationTimer = PetTimerScheduler.schedule(
            interval: interval,
            repeats: true
        ) { [weak self] in
            guard let self, !self.isDragging else { return }
            self.petView.advanceFrame()
            self.adaptAnimationFrequency()
        }
    }

    private func restartPointerTimer() {
        pointerTimer?.invalidate()
        let frequency = PetTimerScheduler.pointerFrequency(lowPower: model.preferences.lowPowerAnimations)
        pointerTimer = PetTimerScheduler.schedule(
            interval: 1.0 / frequency,
            repeats: true
        ) { [weak self] in
            guard let self, let window = self.window, !self.isDragging else { return }
            let previousActivity = self.model.lastPointerActivity
            self.model.noteMouseActivity(at: NSEvent.mouseLocation)
            if self.model.lastPointerActivity != previousActivity {
                self.cancelIdleAnimation(resetCycle: true)
            }
            guard self.petView.petState == .idle
                || self.petView.petState == .miniIdle
                || self.petView.petState == .miniPeek else { return }
            self.petView.setPointerLocation(NSEvent.mouseLocation)
            if window.isVisible == false { window.orderFrontRegardless() }
        }
    }

    /// Re-schedules the loop whenever the resting boundary is crossed. State
    /// changes and pointer moves mark the engine unsettled, so the very next
    /// tick brings the full frequency back; at idle cadence that reaction
    /// costs at most one low-frequency tick.
    private func adaptAnimationFrequency() {
        let wantsHigh = !petView.isResting
        guard wantsHigh != animationTimerHigh else { return }
        animationTimerHigh = wantsHigh
        restartAnimationTimer()
    }

    public func stop() {
        // Persist the last on-screen frame before disabling the delegate
        // callbacks and closing the panel. This is especially important for
        // mini mode, where a move can happen without a later mouse-up.
        persistCurrentWindowOrigin(allowDragging: true)
        isStarted = false
        animationTimer?.invalidate()
        pointerTimer?.invalidate()
        sleepTimer?.invalidate()
        roamTimer?.invalidate()
        animationTimer = nil
        pointerTimer = nil
        sleepTimer = nil
        roamTimer = nil
        cancelIdleAnimation(resetCycle: true)
        dragAnchor = nil
        hoverRestoreTask?.cancel()
        sessionHUD.stop()
        quotaRing.hide()
        close()
    }

    public func setMiniMode(_ enabled: Bool, animate: Bool) {
        guard let window else { return }
        cancelIdleAnimation(resetCycle: true)
        petView.miniMode = enabled
        // @Published sends its current value immediately when the controller
        // subscribes during init. Sync the visual flag, but defer docking and
        // persistence until the real startup path has restored the position.
        guard isStarted else {
            if enabled, model.petState == .idle {
                setPetVisualState(.miniIdle)
            }
            return
        }
        if enabled {
            // Park the normal-mode position: entering mini mode re-docks the
            // pet, and leaving must bring it back where the user had it.
            model.preferences.preMiniWindowOrigin = window.frame.origin
            sessionHUD.hide()
            moveToMiniEdge(animated: animate)
            if model.petState == .idle { setPetVisualState(.miniIdle) }
        } else {
            if let parked = model.preferences.preMiniWindowOrigin,
               !isLegacyStartupParkedOrigin(parked) {
                window.setFrameOrigin(parked)
                model.preferences.windowOrigin = parked
                model.preferences.preMiniWindowOrigin = nil
            } else if let saved = model.preferences.windowOrigin {
                // A pre-0.1.27 startup callback could save the controller's
                // initial (0, 0) frame as the parked position. Keep the last
                // real position rather than reviving that lower-left value.
                window.setFrameOrigin(saved)
                model.preferences.windowOrigin = saved
                model.preferences.preMiniWindowOrigin = nil
            } else {
                moveBackFromMini()
            }
            setPetVisualState(model.petState)
        }
    }

    private func apply(state: PetState) {
        guard !isDragging else { return }
        updateStateAssetOverride(for: state)
        let wasResting = petView.petState == .idle || petView.petState == .miniIdle
        if state != .idle || !wasResting {
            cancelIdleAnimation(resetCycle: true)
        }
        if model.preferences.isMiniMode {
            switch state {
            case .notification: setPetVisualState(.miniAlert)
            case .attention: setPetVisualState(.miniHappy)
            case .idle: setPetVisualState(.miniIdle)
            default: setPetVisualState(state)
            }
        } else {
            setPetVisualState(state)
        }
    }

    private func setPetVisualState(_ state: PetState) {
        guard petView.petState != state else { return }
        petView.petState = state
        petView.redrawImmediately()
    }

    private func updateStateAssetOverride(for state: PetState? = nil) {
        let logicalState = state ?? model.petState
        let timings = model.preferences.theme.timings
        petView.stateAssetOverride = model.preferences.doNotDisturb && logicalState == .collapsing
            ? timings.dndSleepTransitionFile
            : nil
    }

    private func beginDrag(at screenPoint: CGPoint) {
        guard let window else { return }
        cancelIdleAnimation(resetCycle: true)
        sessionHUD.hide()
        isDragging = true
        dragAnchor = PetDragAnchor(windowOrigin: window.frame.origin, pointerOrigin: screenPoint)
        setPetVisualState(.dragging)
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
            model.preferences.preMiniWindowOrigin = window?.frame.origin
                ?? model.preferences.windowOrigin
            model.preferences.isMiniMode = true
        } else {
            model.preferences.windowOrigin = window?.frame.origin
            setPetVisualState(model.petState)
        }
        refreshQuotaRing()
    }

    private var shouldEnterMiniMode: Bool {
        guard let window, let screen = screenForWindow(window) else { return false }
        return window.frame.maxX >= screen.visibleFrame.maxX - 8
    }

    /// Clawdesk Behavior: a genuinely new session earns a one-shot wink (the
    /// double-tap reaction maps to bloub's wink). The launch batch never
    /// celebrates — see `SessionArrivalTracker`.
    private func celebrateArrivals(in sessions: [SessionSnapshot]) {
        let arrivals = arrivalTracker.arrivals(in: sessions)
        guard !arrivals.isEmpty else { return }
        showReaction(.reactDouble, duration: 0.9)
    }

    private func showReaction(_ state: PetState, duration: Double) {
        guard !isDragging else { return }
        setPetVisualState(model.preferences.isMiniMode
            ? (state == .reactDouble ? .miniHappy : .miniAlert)
            : state)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard let self, !Task.isCancelled else { return }
            self.apply(state: self.model.petState)
        }
    }

    private func handleHover(_ hovering: Bool) {
        sessionHUD.setPetHover(hovering)
        guard model.preferences.isMiniMode, !isDragging else { return }
        hoverRestoreTask?.cancel()
        if hovering {
            setPetVisualState(.miniPeek)
        } else {
            hoverRestoreTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled else { return }
                self.apply(state: self.model.petState)
            }
        }
    }

    private func revealSessionHUD() {
        guard !model.preferences.isMiniMode,
              !isDragging,
              let frame = window?.frame else { return }
        sessionHUD.reveal(petWindowFrame: frame)
    }

    private func refreshSessionHUD() {
        guard let frame = window?.frame else { return }
        sessionHUD.update(
            petWindowFrame: frame,
            enabled: model.preferences.sessionHUDEnabled
                && !model.preferences.isMiniMode
                && !isDragging
        )
    }

    /// Replays one upstream theme-provided idle animation after a quiet mouse
    /// period, then returns to the user-selected resting visual. The check is
    /// intentionally on the five-second maintenance cadence so the idle path
    /// remains cheap while the animation itself still advances on the render
    /// timer. Pointer movement cancels the replay immediately in the pointer
    /// timer above.
    private func tickIdleAnimation() {
        guard !model.preferences.isMiniMode,
              !model.preferences.doNotDisturb,
              !isDragging,
              model.petState == .idle else {
            cancelIdleAnimation(resetCycle: false)
            return
        }

        let activity = model.lastPointerActivity
        if idleAnimationCycle.activity != activity {
            cancelIdleAnimation(resetCycle: true)
        }
        let selected = model.preferences.selectedIdleVisual(for: model.preferences.theme)
        guard idleAnimationTask == nil,
              let animation = idleAnimationCycle.choose(
                  now: .now,
                  activity: activity,
                  animations: model.preferences.theme.idleAnimations,
                  selectedIdleFile: selected,
                  quietPeriod: model.preferences.theme.timings.mouseIdleTimeout,
                  randomIndex: { Int.random(in: 0..<$0) }
              ) else { return }

        petView.idleVisualFile = animation.file
        let duration = animation.duration
        idleAnimationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(max(250, Int(duration * 1_000))))
            guard let self, !Task.isCancelled else { return }
            guard self.model.petState == .idle,
                  !self.model.preferences.isMiniMode,
                  self.model.lastPointerActivity == activity else {
                self.idleAnimationTask = nil
                return
            }
            self.petView.idleVisualFile = self.model.preferences.selectedIdleVisual(for: self.model.preferences.theme)
            self.idleAnimationTask = nil
        }
    }

    private func cancelIdleAnimation(resetCycle: Bool) {
        idleAnimationTask?.cancel()
        idleAnimationTask = nil
        if resetCycle {
            idleAnimationCycle.reset(for: model.lastPointerActivity)
            petView.idleVisualFile = model.preferences.selectedIdleVisual(for: model.preferences.theme)
        }
    }

    private func restorePosition() {
        guard let window else { return }
        // Position memory (upstream parity, including mini mode): the last
        // spot the pet appeared at wins — in mini mode that is wherever it
        // was docked or dragged when the session ended.
        if let saved = model.preferences.windowOrigin {
            window.setFrameOrigin(saved)
            persistCurrentWindowOrigin()
            return
        }
        if model.preferences.isMiniMode {
            moveToMiniEdge(animated: false)
            persistCurrentWindowOrigin()
            return
        }
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: frame.maxX - window.frame.width - 26, y: frame.minY + 30))
            persistCurrentWindowOrigin()
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
            persistCurrentWindowOrigin()
        }
    }

    private func moveBackFromMini() {
        guard let window, let screen = screenForWindow(window) else { return }
        let frame = screen.visibleFrame
        let target = NSPoint(x: frame.maxX - window.frame.width - 26, y: max(frame.minY + 30, window.frame.minY))
        window.setFrameOrigin(target)
        persistCurrentWindowOrigin()
        sessionHUD.hide()
    }

    private func isLegacyStartupParkedOrigin(_ origin: CGPoint) -> Bool {
        origin == .zero
            && model.preferences.windowOrigin != nil
            && model.preferences.windowOrigin != .zero
    }

    private func persistCurrentWindowOrigin(allowDragging: Bool = false) {
        guard isStarted,
              let window,
              (allowDragging || !isDragging),
              !isRoaming else { return }
        model.preferences.windowOrigin = window.frame.origin
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
                guard let self else { return }
                self.isRoaming = false
                self.persistCurrentWindowOrigin()
            }
        }
    }

    /// Continuously resizes the pet window from the reduced 120-point base.
    /// The bottom-center of the pet stays anchored so enlarging or shrinking
    /// feels like the pet itself is scaling in place.
    private func applyScale(_ scale: Double, animate: Bool) {
        guard let window else { return }
        let clamped = PetSizing.clampedScale(scale)
        let size = NSSize(
            width: PetSizing.baseWindowSize * CGFloat(clamped),
            height: PetSizing.baseWindowSize * CGFloat(clamped)
        )
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
        } else if isStarted && !isDragging {
            model.preferences.windowOrigin = target.origin
        }
        refreshSessionHUD()
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
        guard isStarted else { return }
        guard !isDragging else { return }
        refreshQuotaRing()
        refreshSessionHUD()
        persistCurrentWindowOrigin()
    }

    public func windowWillClose(_ notification: Notification) {
        persistCurrentWindowOrigin(allowDragging: true)
    }

    private func refreshQuotaRing() {
        guard let window, !model.preferences.isMiniMode else {
            quotaRing.hide()
            return
        }
        quotaRing.update(petWindowFrame: window.frame)
    }
}
