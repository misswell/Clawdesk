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
    private var miniTransitionTask: Task<Void, Never>?
    private var miniTransitionGeneration = 0
    private var isMiniTransitioning = false
    private var cancellables = Set<AnyCancellable>()
    private var isDragging = false
    private var dragAnchor: PetDragAnchor?
    private var isRoaming = false
    private var roamAnimationGeneration = 0
    private var arrivalTracker = SessionArrivalTracker()
    private var hoverRestoreTask: Task<Void, Never>?
    private var nextRoamDate = Date.distantPast
    private let roamFence = RoamFenceCoordinator()
    private var isStarted = false
    /// AppKit can emit a delayed move notification for the panel's initial
    /// lower-left frame while startup preferences are being applied. Keep
    /// that callback from winning over the restored origin.
    private var isRestoringPosition = false
    private var positionRestoreGeneration = 0
    /// The origin deliberately applied by the latest restore. A move callback
    /// with this exact origin is a startup notification; another origin is a
    /// real user move and must be retained immediately.
    private var restoredWindowOrigin: NSPoint?
    /// The panel's origin before restoration. AppKit may deliver this parked
    /// origin after the restored frame has already been applied.
    private var startupWindowOrigin: NSPoint?

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
        petView.onClick = { [weak self] in self?.handlePetClick() }
        petView.onCommandClick = { [weak self] in self?.onDashboard?() }
        petView.onDoubleTap = { [weak self] in self?.showReaction(.reactDouble, duration: 1.3) }
        petView.onFlail = { [weak self] in self?.showReaction(.reactFlail, duration: 1.4) }
        petView.onDizzy = { [weak self] in self?.model.triggerDizzy() }
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
            self?.petView.activeSessionCount = sessions.count
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
        model.preferences.$petHidden.sink { [weak self] _ in
            self?.applyPetVisibility()
        }.store(in: &cancellables)
        model.preferences.$doNotDisturb.sink { [weak self] _ in
            self?.updateStateAssetOverride()
        }.store(in: &cancellables)
        model.preferences.$petScale.sink { [weak self] scale in
            guard let self else { return }
            // @Published replays the current value when this controller is
            // created. Before start() that callback is only a size sync; an
            // animation launched here can finish after restorePosition() and
            // move the freshly restored window back to its initial (0, 0)
            // frame. Startup must be synchronous; later user changes may
            // animate normally.
            self.applyScale(scale, animate: self.isStarted)
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
        // Respect a persisted Hide Pet choice; otherwise bring the panel up.
        applyPetVisibility()
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
                if self.isRoaming { self.cancelRoamAnimation() }
                // Upstream: the first walk after mouse silence waits 8 s.
                self.nextRoamDate = Date.now.addingTimeInterval(8)
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
        persistCurrentWindowOrigin(
            allowDragging: true,
            allowRestoring: true,
            allowRoaming: true,
            allowTransition: true
        )
        isStarted = false
        animationTimer?.invalidate()
        pointerTimer?.invalidate()
        sleepTimer?.invalidate()
        roamTimer?.invalidate()
        animationTimer = nil
        pointerTimer = nil
        sleepTimer = nil
        roamTimer = nil
        cancelMiniTransition()
        cancelRoamAnimation()
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
        // @Published sends its current value immediately when the controller
        // subscribes during init. Sync the visual flag, but defer docking and
        // persistence until the real startup path has restored the position.
        guard isStarted else {
            petView.miniMode = enabled
            updateStateAssetOverride()
            setPetVisualState(visualState(for: model.petState, mini: enabled))
            return
        }

        if petView.miniMode == enabled, !isMiniTransitioning {
            setPetVisualState(visualState(for: model.petState, mini: enabled))
            return
        }

        cancelMiniTransition()
        if enabled {
            // Park the normal-mode position: entering mini mode re-docks the
            // pet, and leaving must bring it back where the user had it.
            model.preferences.preMiniWindowOrigin = window.frame.origin
            sessionHUD.hide()
            petView.miniMode = true
            updateStateAssetOverride()
            isMiniTransitioning = true
            let generation = miniTransitionGeneration
            // The original enters mini mode with a short crab-walk before the
            // body slides into its docked position. Keep that intermediate
            // action visible while the window is moving, then play the
            // dedicated mini-enter (or mini-enter-sleep) animation in place.
            if animate { setPetVisualState(.miniCrabwalk) }
            moveToMiniEdge(animated: animate) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.isMiniTransitioning,
                          self.miniTransitionGeneration == generation else { return }
                    self.beginMiniEntry(generation: generation)
                }
            }
        } else {
            isMiniTransitioning = true
            let generation = miniTransitionGeneration
            let target = miniExitOrigin(for: window)
            moveBackFromMini(to: target, animated: animate) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.isMiniTransitioning,
                          self.miniTransitionGeneration == generation else { return }
                    self.finishMiniExit(target: target)
                }
            }
        }
    }

    private func apply(state: PetState) {
        guard !isDragging else { return }
        // A real hook/status change must win over a background roam walk.
        // AppKit's animator completion can otherwise put the window back at
        // the old target after the new state has already been rendered.
        if isRoaming { cancelRoamAnimation() }
        // During mini entry/exit the window and renderer are in a deliberate
        // transition. Defer external state application until it settles so a
        // hook arriving during the handoff cannot replace mini-enter midway.
        if isMiniTransitioning { return }
        updateStateAssetOverride(for: state)
        let wasResting = petView.petState == .idle || petView.petState == .miniIdle
        if state != .idle || !wasResting {
            cancelIdleAnimation(resetCycle: true)
        }
        setPetVisualState(visualState(for: state, mini: model.preferences.isMiniMode))
    }

    /// Converts the agent lifecycle state to the renderer state for the
    /// current window mode. The model stays in the full semantic vocabulary;
    /// mini mode deliberately has its own artwork and motion for every
    /// working, sleeping, completion and notification path.
    private func visualState(for state: PetState, mini: Bool) -> PetState {
        guard mini else { return state }
        switch state {
        case .idle, .miniIdle:
            return .miniIdle
        case .notification, .miniAlert, .error:
            return .miniAlert
        case .attention, .reactDouble, .miniHappy:
            return .miniHappy
        case .thinking, .typing, .building, .juggling, .sweeping, .carrying, .miniWorking:
            return .miniWorking
        case .roam, .miniCrabwalk:
            return .miniCrabwalk
        case .yawning, .dozing, .collapsing, .sleeping, .miniEnterSleep, .miniSleep:
            return .miniSleep
        case .waking, .wakingFromDoze:
            return .miniIdle
        case .dizzy, .reactFlail:
            return .miniAlert
        case .dragging:
            return .dragging
        case .miniPeek:
            return .miniPeek
        case .miniEnter:
            return .miniEnter
        }
    }

    private func miniEntryState(for state: PetState) -> PetState {
        if model.preferences.doNotDisturb || state.isSleepSequence {
            return .miniEnterSleep
        }
        return .miniEnter
    }

    private func miniTransitionDuration(for state: PetState) -> TimeInterval {
        guard let definition = BloubStates.catalog[
            BloubStateMapper.state(for: state)
        ] else { return 1.2 }
        return max(definition.morph, definition.settlesAt ?? definition.duration)
    }

    private func beginMiniEntry(generation: Int) {
        guard isMiniTransitioning, miniTransitionGeneration == generation else { return }
        let entry = miniEntryState(for: model.petState)
        setPetVisualState(entry)
        miniTransitionTask?.cancel()
        let duration = miniTransitionDuration(for: entry)
        miniTransitionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(max(1, Int(duration * 1_000))))
            guard let self, !Task.isCancelled,
                  self.isMiniTransitioning,
                  self.miniTransitionGeneration == generation else { return }
            self.miniTransitionTask = nil
            self.isMiniTransitioning = false
            self.model.preferences.windowOrigin = self.window?.frame.origin
            self.persistCurrentWindowOrigin(allowDragging: true, allowTransition: true)
            self.apply(state: self.model.petState)
        }
    }

    private func finishMiniExit(target: NSPoint) {
        miniTransitionTask?.cancel()
        miniTransitionTask = nil
        petView.miniMode = false
        model.preferences.windowOrigin = target
        model.preferences.preMiniWindowOrigin = nil
        isMiniTransitioning = false
        updateStateAssetOverride()
        setPetVisualState(visualState(for: model.petState, mini: false))
        persistCurrentWindowOrigin(allowDragging: true, allowTransition: true)
        refreshQuotaRing()
        refreshSessionHUD()
    }

    private func cancelMiniTransition() {
        miniTransitionGeneration &+= 1
        miniTransitionTask?.cancel()
        miniTransitionTask = nil
        isMiniTransitioning = false
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
        // Upstream's drag-lock cancels an in-flight roam; otherwise the roam
        // animator fights the drag for the window frame.
        cancelRoamAnimation()
        cancelIdleAnimation(resetCycle: true)
        sessionHUD.hide()
        isDragging = true
        dragAnchor = PetDragAnchor(windowOrigin: window.frame.origin, pointerOrigin: screenPoint)
        setPetVisualState(.dragging)
        window.invalidateCursorRects(for: petView)
    }

    private func drag(to screenPoint: CGPoint) {
        guard let window, let dragAnchor else { return }
        window.setFrameOrigin(clampedToAttachedScreens(dragAnchor.windowOrigin(for: screenPoint), windowSize: window.frame.size))
        // Do not wait for mouse-up: a crash, quit, or mode change during a
        // drag must still leave the latest position recoverable.
        persistCurrentWindowOrigin(allowDragging: true)
    }

    private func endDrag() {
        guard isDragging else { return }
        isDragging = false
        dragAnchor = nil
        guard let window else { return }
        // Upstream's final drag clamp: the resting origin always stays inside
        // the attached-displays union.
        let clamped = clampedToAttachedScreens(window.frame.origin, windowSize: window.frame.size)
        if clamped != window.frame.origin {
            window.setFrameOrigin(clamped)
        }
        if shouldEnterMiniMode {
            model.preferences.preMiniWindowOrigin = window.frame.origin
            model.preferences.isMiniMode = true
        } else {
            model.preferences.windowOrigin = window.frame.origin
            setPetVisualState(model.petState)
        }
        refreshQuotaRing()
    }

    /// Upstream `looseClampPetToDisplays`: the pet must remain reachable on
    /// the union of the attached screens, even when dragging across displays.
    private func clampedToAttachedScreens(_ origin: NSPoint, windowSize: CGSize) -> NSPoint {
        let union = NSScreen.screens.reduce(NSRect.null) { $0.union($1.visibleFrame) }
        guard union.width > 0, union.height > 0 else { return origin }
        let x = min(max(origin.x, union.minX), max(union.minX, union.maxX - windowSize.width))
        let y = min(max(origin.y, union.minY), max(union.minY, union.maxY - windowSize.height))
        return NSPoint(x: x, y: y)
    }

    /// Upstream's startup gate: a saved origin that no longer intersects any
    /// attached screen (unplugged monitor) falls back to the default spot.
    private func originIsVisibleOnAttachedScreens(_ origin: NSPoint, windowSize: CGSize) -> Bool {
        let frame = NSRect(origin: origin, size: windowSize)
        return NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
    }

    private var shouldEnterMiniMode: Bool {
        guard let window, let screen = screenForWindow(window) else { return false }
        // Upstream snaps on BOTH edges within a 30 px tolerance and remembers
        // which side docked so a restart re-docks to the same edge. An edge
        // occupied by a fixed Dock is refused: the pet would sit under the
        // Dock where the Dock eats every click.
        let frame = screen.visibleFrame
        let dock = PetPointerMapper.dockOccupiesEdges(
            screenFrame: screen.frame,
            visibleFrame: frame
        )
        if window.frame.maxX >= frame.maxX - 30 {
            guard !dock.right else { return false }
            model.preferences.miniEdgeLeft = false
            return true
        }
        if window.frame.minX <= frame.minX + 30 {
            guard !dock.left else { return false }
            model.preferences.miniEdgeLeft = true
            return true
        }
        return false
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
            // The upstream peek is a resting/sleep affordance. It must not
            // interrupt mini-working, mini-alert or mini-happy animations.
            guard petView.petState == .miniIdle || petView.petState == .miniSleep
                || petView.petState == .miniPeek else { return }
            setPetVisualState(.miniPeek)
        } else {
            guard petView.petState == .miniPeek else { return }
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

    /// Upstream: the first click reveals the HUD; in mini mode a click exits
    /// mini mode instead.
    private func handlePetClick() {
        if model.preferences.isMiniMode {
            model.preferences.isMiniMode = false
            return
        }
        revealSessionHUD()
    }

    /// Upstream's manual pet visibility layer: Hide Pet keeps the runtime and
    /// hooks fully working while removing every on-screen surface; Show Pet
    /// brings the window back exactly where it was.
    func applyPetVisibility() {
        guard let window else { return }
        if model.preferences.petHidden {
            sessionHUD.hide()
            window.orderOut(nil)
        } else {
            window.orderFrontRegardless()
        }
        refreshQuotaRing()
        refreshSessionHUD()
    }

    @objc private func togglePetHidden() {
        model.preferences.petHidden.toggle()
    }

    /// Upstream's decorative test-result reaction. The bloub vocabulary has
    /// no pass/fail artwork, so a pass winks and a failure plays the flail.
    func showTestReaction(passed: Bool) {
        guard !model.preferences.petHidden, !isDragging else { return }
        showReaction(passed ? .reactDouble : .reactFlail, duration: 1.3)
    }

    private func refreshSessionHUD() {
        guard let frame = window?.frame else { return }
        sessionHUD.update(
            petWindowFrame: frame,
            enabled: model.preferences.sessionHUDEnabled
                && !model.preferences.isMiniMode
                && !model.preferences.petHidden
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
        guard idleAnimationTask == nil else { return }
        let choice = idleAnimationCycle.chooseScene(
            now: .now,
            activity: activity,
            animations: model.preferences.theme.idleAnimations,
            selectedIdleFile: selected,
            quietPeriod: model.preferences.theme.timings.mouseIdleTimeout,
            randomIndex: { Int.random(in: 0..<$0) }
        )
        switch choice {
        case .none:
            return
        case .theme(let animation):
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
        case .bloub(.wink):
            // Bloub-native stand-ins for themed idle animations (upstream
            // idle easter eggs). showReaction owns the return to idle.
            showReaction(.reactDouble, duration: 0.9)
        case .bloub(.dizzy):
            model.triggerDizzy()
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
        positionRestoreGeneration &+= 1
        let generation = positionRestoreGeneration
        isRestoringPosition = true

        // Position memory (upstream parity, including mini mode): the last
        // spot the pet appeared at wins — in mini mode that is wherever it
        // was docked or dragged when the session ended. Compute the target
        // first and publish it before moving the NSWindow; this closes the
        // race where AppKit reports the panel's initial lower-left frame.
        startupWindowOrigin = window.frame.origin
        let target: NSPoint
        if let saved = model.preferences.windowOrigin,
           originIsVisibleOnAttachedScreens(saved, windowSize: window.frame.size) {
            target = saved
        } else if model.preferences.isMiniMode {
            target = miniDockOrigin(for: window)
        } else if let screen = screenForWindow(window) {
            let frame = screen.visibleFrame
            target = NSPoint(x: frame.maxX - window.frame.width - 26, y: frame.minY + 30)
        } else {
            target = window.frame.origin
        }
        restoredWindowOrigin = target
        window.setFrameOrigin(target)

        // `persistCurrentWindowOrigin` deliberately ignores the guarded move
        // above. Save the final restored frame explicitly, then release the
        // guard on the next run-loop turn so AppKit's startup move callback
        // cannot overwrite it with the panel's initial (0, 0) origin.
        if isStarted {
            model.preferences.windowOrigin = target
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.positionRestoreGeneration == generation else { return }
            self.isRestoringPosition = false
            self.startupWindowOrigin = nil
            // A user can drag the pet before the deferred startup callback
            // runs. Preserve that move instead of letting the guard silently
            // discard it; the stop/close path also force-saves this frame.
            if let window = self.window,
               let restored = self.restoredWindowOrigin,
               window.frame.origin != restored {
                self.persistCurrentWindowOrigin(
                    allowDragging: true,
                    allowRestoring: true,
                    allowTransition: true
                )
            }
        }
    }

    private func moveToMiniEdge(animated: Bool, completion: (@Sendable () -> Void)? = nil) {
        guard let window else { return }
        let target = miniDockOrigin(for: window)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.28
                window.animator().setFrameOrigin(target)
            } completionHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.persistCurrentWindowOrigin(allowDragging: true)
                    completion?()
                }
            }
        } else {
            window.setFrameOrigin(target)
            persistCurrentWindowOrigin(allowDragging: true)
            completion?()
        }
    }

    private func miniDockOrigin(for window: NSWindow) -> NSPoint {
        guard let screen = screenForWindow(window) else { return window.frame.origin }
        let frame = screen.visibleFrame
        // A persisted edge that a fixed Dock has since occupied flips to the
        // free side, so a restored pet never wakes up under the Dock.
        let dock = PetPointerMapper.dockOccupiesEdges(
            screenFrame: screen.frame,
            visibleFrame: frame
        )
        var edgeLeft = model.preferences.miniEdgeLeft
        if edgeLeft && dock.left { edgeLeft = false }
        if !edgeLeft && dock.right { edgeLeft = true }
        model.preferences.miniEdgeLeft = edgeLeft
        // Upstream docks by theme offsetRatio (48% visible); the mirrored
        // edge shows the same sliver on the other side.
        if edgeLeft {
            return NSPoint(
                x: frame.minX - window.frame.width * 0.52,
                y: max(frame.minY + 16, window.frame.minY)
            )
        }
        return NSPoint(
            x: frame.maxX - window.frame.width * 0.48,
            y: max(frame.minY + 16, window.frame.minY)
        )
    }

    private func miniExitOrigin(for window: NSWindow) -> NSPoint {
        var target: NSPoint
        if let parked = model.preferences.preMiniWindowOrigin,
           !isLegacyStartupParkedOrigin(parked) {
            target = parked
        } else if let saved = model.preferences.windowOrigin {
            // A pre-0.1.27 startup callback could save the initial (0, 0)
            // frame as the parked position. Keep the last real position rather
            // than reviving that lower-left value.
            target = saved
        } else {
            let frame = screenForWindow(window)?.visibleFrame
                ?? NSRect(origin: window.frame.origin, size: window.frame.size)
            target = NSPoint(
                x: frame.maxX - window.frame.width - 26,
                y: max(frame.minY + 30, window.frame.minY)
            )
        }
        // Upstream's exit anti-resnap: shift the resting position 100 px
        // inside the snap zone so the very next drag does not re-dock.
        if let screen = screenForWindow(window) {
            let frame = screen.visibleFrame
            if target.x + window.frame.width >= frame.maxX - 30 {
                target.x = frame.maxX - window.frame.width - 100
            } else if target.x <= frame.minX + 30 {
                target.x = frame.minX + 100
            }
        }
        return target
    }

    private func moveBackFromMini(
        to target: NSPoint,
        animated: Bool,
        completion: (@Sendable () -> Void)? = nil
    ) {
        guard let window else { return }
        sessionHUD.hide()
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.28
                window.animator().setFrameOrigin(target)
            } completionHandler: {
                DispatchQueue.main.async {
                    completion?()
                }
            }
        } else {
            window.setFrameOrigin(target)
            completion?()
        }
    }

    private func isLegacyStartupParkedOrigin(_ origin: CGPoint) -> Bool {
        origin == .zero
            && model.preferences.windowOrigin != nil
            && model.preferences.windowOrigin != .zero
    }

    private func persistCurrentWindowOrigin(
        allowDragging: Bool = false,
        allowRestoring: Bool = false,
        allowRoaming: Bool = false,
        allowTransition: Bool = false
    ) {
        guard isStarted,
              let window,
              (allowDragging || !isDragging),
              (allowRestoring || !isRestoringPosition),
              (allowRoaming || !isRoaming),
              (allowTransition || !isMiniTransitioning) else { return }
        model.preferences.windowOrigin = window.frame.origin
    }

    /// Upstream roam cadence: the first walk starts after 8 s of quiet, later
    /// walks every 4 s; walks move at 80 px/s (minimum 1 s), and a visible
    /// permission bubble holds roaming — the pet must not wander from its
    /// waiting spot.
    private func checkRoam() {
        guard model.preferences.freeRoamEnabled,
              !model.preferences.isMiniMode,
              !model.preferences.doNotDisturb,
              !isDragging,
              !isRoaming,
              model.pendingPermissions.isEmpty,
              let window,
              !model.petState.isTransient,
              model.petState == .idle else { return }
        let now = Date.now
        guard now >= nextRoamDate else { return }
        roamFence.refresh(from: model.preferences.roamAreaFileURL)
        guard roamFence.confirmed else {
            nextRoamDate = now.addingTimeInterval(4)
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
        let distance = hypot(
            newOrigin.x - window.frame.origin.x,
            newOrigin.y - window.frame.origin.y
        )
        guard distance >= RoamPlanner.minimumHopDistance else {
            nextRoamDate = now.addingTimeInterval(4)
            return
        }
        nextRoamDate = now.addingTimeInterval(4)
        isRoaming = true
        roamAnimationGeneration &+= 1
        let generation = roamAnimationGeneration
        setPetVisualState(.roam)
        let duration = max(1.0, distance / 80)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().setFrameOrigin(newOrigin)
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isRoaming,
                      self.roamAnimationGeneration == generation else { return }
                self.isRoaming = false
                if self.model.petState == .idle {
                    self.setPetVisualState(.idle)
                }
                self.persistCurrentWindowOrigin()
            }
        }
    }

    private func cancelRoamAnimation() {
        guard isRoaming else { return }
        isRoaming = false
        roamAnimationGeneration &+= 1
        if let window {
            // A non-animating write replaces the presentation position and
            // prevents the completion handler from snapping back to the old
            // roam target after a hook has already changed the state.
            window.setFrame(window.frame, display: true, animate: false)
        }
        if model.petState == .idle {
            setPetVisualState(.idle)
        }
        persistCurrentWindowOrigin(allowDragging: true)
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
            } completionHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.persistCurrentWindowOrigin(allowDragging: true)
                }
            }
        } else {
            window.setFrame(target, display: true)
        }
        if model.preferences.isMiniMode {
            moveToMiniEdge(animated: animate) { [weak self] in
                Task { @MainActor [weak self] in
                    self?.persistCurrentWindowOrigin(allowDragging: true)
                }
            }
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
        let hidden = addMenuItem(to: menu, title: model.preferences.text(model.preferences.petHidden ? "Show Pet" : "Hide Pet"), action: #selector(togglePetHidden))
        hidden.state = model.preferences.petHidden ? .on : .off
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
        if isRestoringPosition {
            guard let window else { return }
            let current = window.frame.origin
            // AppKit can deliver a delayed notification for either the frame
            // that was already restored or the panel's original parked frame.
            // Ignore the former and immediately re-apply the latter. A real
            // user move is any other coordinate and is persisted below.
            if let restored = restoredWindowOrigin, current == restored {
                return
            }
            if let startup = startupWindowOrigin, current == startup,
               let restored = restoredWindowOrigin {
                window.setFrameOrigin(restored)
                return
            }
            isRestoringPosition = false
            persistCurrentWindowOrigin(
                allowRestoring: true,
                allowTransition: true
            )
            refreshQuotaRing()
            refreshSessionHUD()
            return
        }
        guard !isDragging else { return }
        refreshQuotaRing()
        refreshSessionHUD()
        persistCurrentWindowOrigin()
    }

    public func windowWillClose(_ notification: Notification) {
        persistCurrentWindowOrigin(
            allowDragging: true,
            allowRestoring: true,
            allowRoaming: true,
            allowTransition: true
        )
    }

    private func refreshQuotaRing() {
        guard let window,
              !model.preferences.isMiniMode,
              !model.preferences.petHidden else {
            quotaRing.hide()
            return
        }
        quotaRing.update(petWindowFrame: window.frame)
    }
}
