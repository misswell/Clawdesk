import Combine
import Foundation

@MainActor
public final class ClawdeskModel: ObservableObject {
    public var preferences: AppPreferences
    public let sessionStore = SessionStore()
    public let eventServer: LocalEventServer
    public let hookInstaller: HookInstaller
    public let doctor: AgentDoctor
    public let remoteNotifier: RemoteNotifier
    public let remoteSSHManager: RemoteSSHManager
    public let mobileBridge: MobileBridge
    public let codexLogMonitor: CodexLogMonitor
    public let claudeHookHealth: ClaudeHookHealthMonitor
    let softwareUpdater: ClawdeskSoftwareUpdater
    public let quotaStore = QuotaStore()

    @Published public private(set) var petState: PetState = .idle
    @Published public private(set) var sessions: [SessionSnapshot] = []
    @Published public private(set) var pendingPermissions: [PermissionRequest] = []
    @Published public private(set) var pendingQuestions: [QuestionPrompt] = []
    @Published public private(set) var eventLog: [String] = []
    @Published public private(set) var quotaReports: [QuotaReport] = []
    @Published public private(set) var agentInstallStatus: [String: String] = [:]
    @Published public private(set) var doctorReports: [AgentDiagnostic] = []
    @Published public private(set) var serverPort: UInt16

    public var onPermission: ((PermissionRequest) -> Void)?
    public var onCompletion: (() -> Void)?
    public var onError: ((String) -> Void)?

    private var replies: [String: PermissionReply] = [:]
    private var permissionExpiryTasks: [String: Task<Void, Never>] = [:]
    private var permissionOrder: [String] = []
    var maximumPendingPermissionCount = 32
    var permissionReplyTimeout: Duration = .seconds(300)
    private var completionTask: Task<Void, Never>?
    private var kimiSuspectTasks: [String: Task<Void, Never>] = [:]
    private var kimiGateOrder: [String: [String]] = [:]
    var lastPointerActivity = Date.now
    var dozingSince: Date?

    // MARK: Startup recovery (upstream parity: a restart while a supported
    // CLI is running must not collapse into sleep before any hook fires)

    /// Injectable for tests; the production value shells out to `ps`.
    var agentRunningProbe: @Sendable () -> Bool = { AgentProcessProbe.isAnySupportedAgentRunning() }
    private(set) var startupRecoveryActive = false
    private var startupRecoveryDeadline: Date?
    private var lastStartupProbeAt: Date?
    /// Upstream caps the recovery window at five minutes: a wedged probe can
    /// keep the pet awake no longer than that.
    private let startupRecoveryWindow: TimeInterval = 300
    private let startupProbeInterval: TimeInterval = 10

    func beginStartupRecovery() {
        startupRecoveryActive = true
        startupRecoveryDeadline = .now.addingTimeInterval(startupRecoveryWindow)
        lastStartupProbeAt = nil
    }

    func endStartupRecovery() {
        startupRecoveryActive = false
        startupRecoveryDeadline = nil
        lastStartupProbeAt = nil
    }

    /// Re-probes while no session has claimed the pet yet: agents still
    /// running keeps recovery on; an empty probe ends it early. Real session
    /// events cancel it in `apply`.
    func tickStartupRecovery(now: Date = .now) {
        guard startupRecoveryActive else { return }
        if !sessions.isEmpty || now >= (startupRecoveryDeadline ?? now) {
            endStartupRecovery()
            return
        }
        if let last = lastStartupProbeAt, now.timeIntervalSince(last) < startupProbeInterval {
            return
        }
        lastStartupProbeAt = now
        let probe = agentRunningProbe
        Task { @MainActor [weak self] in
            let found = await Task.detached(priority: .utility) { probe() }.value
            guard let self, self.startupRecoveryActive, self.sessions.isEmpty else { return }
            if found { self.lastPointerActivity = .now } else { self.endStartupRecovery() }
        }
    }
    private var sleepPhaseStartedAt: Date?
    private var lastPointerLocation: CGPoint?
    private var preferenceCancellables = Set<AnyCancellable>()
    private var healthTimer: Timer?
    private var startupSyncTask: Task<Void, Never>?
    private var sleepTransitionTask: Task<Void, Never>?
    private var isStarted = false

    public init(
        preferences: AppPreferences = AppPreferences(),
        hookInstaller providedHookInstaller: HookInstaller? = nil
    ) {
        self.preferences = preferences
        let server = LocalEventServer(preferredPort: preferences.serverPort)
        eventServer = server
        remoteSSHManager = RemoteSSHManager(eventServer: server)
        let installer = providedHookInstaller ?? HookInstaller()
        hookInstaller = installer
        doctor = AgentDoctor(installer: installer)
        remoteNotifier = RemoteNotifier()
        mobileBridge = MobileBridge(preferredPort: preferences.mobilePort)
        codexLogMonitor = CodexLogMonitor()
        claudeHookHealth = ClaudeHookHealthMonitor(installer: installer)
        softwareUpdater = ClawdeskSoftwareUpdater()
        serverPort = preferences.serverPort
        eventServer.onMessage = { [weak self] message in
            Task { @MainActor [weak self] in
                self?.receive(message)
            }
        }
        codexLogMonitor.onQuota = { [weak self] report in
            self?.acceptQuota(report)
        }
        preferences.$doNotDisturb.sink { [weak self] enabled in
            guard let self else { return }
            if enabled {
                self.resetSleepSequence()
                let timings = self.preferences.theme.timings
                if timings.sleepMode == .direct {
                    self.petState = .sleeping
                } else if timings.dndSleepTransitionFile != nil || timings.dndSkipYawn {
                    self.beginSleepPhase(.collapsing, at: .now, after: timings.dndCollapseDuration)
                } else {
                    self.beginSleepPhase(.yawning, at: .now, after: timings.yawnDuration)
                }
            } else if self.petState.isSleepSequence {
                self.resetSleepSequence()
                self.beginWakeTransition()
            }
        }.store(in: &preferenceCancellables)
        preferences.$autoStart.dropFirst().sink { [weak self] enabled in
            guard self != nil else { return }
            LaunchAtLogin.setEnabled(enabled)
        }.store(in: &preferenceCancellables)
        preferences.$mobileEnabled.dropFirst().sink { [weak self] enabled in
            guard let self else { return }
            if enabled { self.mobileBridge.start() } else { self.mobileBridge.stop() }
        }.store(in: &preferenceCancellables)
        preferences.$collectClaudeUsage.dropFirst().sink { [weak self] enabled in
            guard let self else { return }
            if enabled {
                _ = try? self.hookInstaller.ensureClaudeStatusLine()
            } else {
                _ = try? self.hookInstaller.removeClaudeStatusLine()
            }
        }.store(in: &preferenceCancellables)
    }

    public func start() {
        guard !isStarted else { return }
        isStarted = true
        eventServer.start()
        beginStartupRecovery()
        if preferences.mobileEnabled { mobileBridge.start() }
        codexLogMonitor.onEvent = { [weak self] event in self?.accept(event) }
        codexLogMonitor.start()
        try? hookInstaller.writeRuntimeFile(port: eventServer.port, autoStart: preferences.autoStart)
        LaunchAtLogin.setEnabled(preferences.autoStart)
        // Read-only Claude hook health check every five minutes, matching the
        // upstream cadence. It only mutates when a managed script is missing
        // and never touches the statusLine slot.
        healthTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.runHealthCheck() }
        }
        startupSyncTask?.cancel()
        startupSyncTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self else { return }
            serverPort = eventServer.port
            preferences.serverPort = eventServer.port
            try? hookInstaller.writeRuntimeFile(port: eventServer.port, autoStart: preferences.autoStart)
            synchronizeEnabledIntegrations()
            if preferences.collectClaudeUsage {
                _ = try? hookInstaller.ensureClaudeStatusLine()
            }
        }
    }

    public func stop() {
        isStarted = false
        for id in Array(replies.keys) {
            resolvePermission(id: id, decision: .defer)
        }
        permissionExpiryTasks.values.forEach { $0.cancel() }
        permissionExpiryTasks.removeAll()
        permissionOrder.removeAll()
        completionTask?.cancel()
        sleepTransitionTask?.cancel()
        sleepTransitionTask = nil
        for task in kimiSuspectTasks.values { task.cancel() }
        kimiSuspectTasks.removeAll()
        kimiGateOrder.removeAll()
        eventServer.stop()
        mobileBridge.stop()
        codexLogMonitor.stop()
        healthTimer?.invalidate()
        healthTimer = nil
        startupSyncTask?.cancel()
        startupSyncTask = nil
        remoteNotifier.stop()
        remoteSSHManager.stop()
    }

    private func runHealthCheck() {
        guard serverPort > 0 else { return }
        claudeHookHealth.check(port: serverPort)
        objectWillChange.send()
    }

    /// Reconcile only integrations that the user explicitly enabled or that
    /// still contain a verifiable Clawdesk ownership marker. This mirrors the
    /// upstream startup sync while preventing a launch from creating config
    /// files for agents the user never installed.
    private func synchronizeEnabledIntegrations() {
        let discovered = Set(doctor.managedAgentIDs())
        let candidates = AgentRegistry.all.map(\.id).filter { agentID in
            HookInstaller.supportedAgentIDs.contains(agentID)
                && (preferences.enabledAgentIDs.contains(agentID) || discovered.contains(agentID))
        }

        for agentID in candidates {
            do {
                let result: HookInstallResult
                if discovered.contains(agentID) {
                    result = try hookInstaller.repairExistingAgent(agentID: agentID, port: serverPort)
                } else {
                    result = try hookInstaller.install(agentID: agentID, port: serverPort)
                }
                guard result.changed else { continue }
                agentInstallStatus[agentID] = result.message
                eventLog.insert("system · startup integration sync: \(result.message)", at: 0)
            } catch {
                let message = "startup integration sync failed for \(agentID): \(error.localizedDescription)"
                agentInstallStatus[agentID] = message
                eventLog.insert("system · \(message)", at: 0)
            }
        }
    }

    public func receive(_ message: ServerMessage) {
        switch message {
        case let .event(event):
            apply(event)
        case let .permission(event, reply):
            let request = event.permission ?? PermissionRequest(
                sessionID: event.sessionID,
                agentID: event.agentID,
                title: "Agent is waiting for permission"
            )
            retainPermissionReply(reply, for: request.id)
            apply(event)
            if preferences.doNotDisturb {
                resolvePermission(id: request.id, decision: .defer)
                return
            }
            let isZCode = request.agentID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "zcode"
            remoteNotifier.send(RemoteNotification(title: "Permission request", body: request.title, sessionTitle: request.agentID))
            // ZCode's native permission runner remains the owner of global
            // and per-session automation. Clawdesk may still present its
            // manual bubble (or remote approval) for a concrete request.
            if !isZCode, preferences.permissionMode == .autoApprove {
                resolvePermission(id: request.id, decision: .allow)
                return
            }
            if !isZCode, preferences.permissionAutomation != .off,
               let decision = PermissionPolicy.decide(request: request, automation: preferences.permissionAutomation) {
                resolvePermission(id: request.id, decision: decision)
                return
            }
            if preferences.permissionMode == .toolsOnly,
               request.action == nil, request.command == nil, request.input == nil {
                // Question/elicitation-shaped requests stay in the agent's
                // native UI in tools-only mode, matching upstream's explicit
                // automation gate.
                resolvePermission(id: request.id, decision: .defer)
                return
            }

            let remoteStarted = remoteNotifier.startApproval(for: request) { [weak self] decision in
                Task { @MainActor [weak self] in
                    self?.resolvePermission(id: request.id, decision: decision)
                }
            }
            let localBubbleEnabled = preferences.showPermissionBubbles
                && !preferences.permissionBubbleDisabledAgentIDs.contains(request.agentID)
            if localBubbleEnabled {
                if !pendingPermissions.contains(where: { $0.id == request.id }) {
                    pendingPermissions.append(request)
                }
                onPermission?(request)
            } else if !remoteStarted {
                resolvePermission(id: request.id, decision: .defer)
            }
        }
    }

    public func accept(_ event: AgentEvent) {
        apply(event)
    }

    public func acceptQuota(_ report: QuotaReport) {
        quotaReports = quotaStore.apply(report)
        publishSnapshot(state: petState, sessions: sessions)
    }

    /// Pointer activity, rather than incoming agent traffic, controls the
    /// sleep transition. A busy agent can therefore finish in the background
    /// without keeping the pet awake solely because a hook is noisy.
    public func noteMouseActivity(at point: CGPoint) {
        if let previous = lastPointerLocation {
            let dx = point.x - previous.x
            let dy = point.y - previous.y
            guard (dx * dx + dy * dy) >= 0.25 else { return }
        }
        lastPointerLocation = point
        lastPointerActivity = .now
        guard !preferences.doNotDisturb, petState.isSleepSequence else { return }
        resetSleepSequence()
        if petState == .yawning {
            petState = preferences.isMiniMode ? .miniIdle : fallbackState
        } else if petState == .dozing {
            beginDozeWakeTransition()
        } else {
            beginWakeTransition()
        }
    }

    public func resolvePermission(id: String, decision: PermissionDecision) {
        permissionExpiryTasks.removeValue(forKey: id)?.cancel()
        permissionOrder.removeAll { $0 == id }
        remoteNotifier.cancelApproval(id: id)
        replies.removeValue(forKey: id)?.resolve(decision)
        pendingPermissions.removeAll { $0.id == id }
        if petState == .notification {
            petState = sessions.first?.state ?? .idle
        }
    }

    public func resolveLatestPermission(decision: PermissionDecision) {
        guard let request = pendingPermissions.first else { return }
        resolvePermission(id: request.id, decision: decision)
    }

    private func retainPermissionReply(_ reply: PermissionReply, for id: String) {
        permissionExpiryTasks.removeValue(forKey: id)?.cancel()
        permissionOrder.removeAll { $0 == id }
        replies.removeValue(forKey: id)?.resolve(.defer)
        replies[id] = reply
        permissionOrder.append(id)
        let timeout = permissionReplyTimeout
        permissionExpiryTasks[id] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            guard let self, !Task.isCancelled, self.replies[id] != nil else { return }
            self.resolvePermission(id: id, decision: .defer)
        }
        let limit = max(1, maximumPendingPermissionCount)
        while permissionOrder.count > limit, let oldest = permissionOrder.first {
            resolvePermission(id: oldest, decision: .defer)
        }
    }

    public func setTheme(_ id: String) {
        preferences.selectedThemeID = id
        objectWillChange.send()
    }

    public func installAgent(_ agentID: String) {
        do {
            let result = try hookInstaller.install(agentID: agentID, port: serverPort)
            preferences.enabledAgentIDs.insert(agentID)
            agentInstallStatus[agentID] = result.message
            if agentID == "claude-code", preferences.collectClaudeUsage {
                _ = try hookInstaller.ensureClaudeStatusLine()
            }
            eventLog.insert("system · \(result.message)", at: 0)
        } catch {
            agentInstallStatus[agentID] = error.localizedDescription
            eventLog.insert("system · hook install failed: \(error.localizedDescription)", at: 0)
        }
    }

    public func uninstallAgent(_ agentID: String) {
        do {
            let result = try hookInstaller.uninstall(agentID: agentID)
            preferences.enabledAgentIDs.remove(agentID)
            agentInstallStatus[agentID] = result.message
            eventLog.insert("system · \(result.message)", at: 0)
        } catch {
            agentInstallStatus[agentID] = error.localizedDescription
            eventLog.insert("system · hook removal failed: \(error.localizedDescription)", at: 0)
        }
    }

    public func refreshDoctor() {
        doctorReports = doctor.diagnose()
    }

    public func fixAgent(_ agentID: String) {
        installAgent(agentID)
        refreshDoctor()
    }

    public func tickForSleep(now: Date = .now) -> Bool {
        guard !preferences.doNotDisturb else { return false }
        if startupRecoveryActive {
            // A supported CLI is running but no hook has fired yet — hold the
            // sleep clock so the pet stays awake (upstream startup recovery).
            if let deadline = startupRecoveryDeadline, now >= deadline {
                endStartupRecovery()
            }
            return false
        }
        let transition = SleepSequencePlanner.next(
            state: petState,
            now: now,
            lastPointerActivity: lastPointerActivity,
            phaseStartedAt: sleepPhaseStartedAt,
            timings: preferences.theme.timings
        )
        switch transition {
        case .none:
            return false
        case .beginYawning:
            dozingSince = nil
            beginSleepPhase(.yawning, at: now, after: preferences.theme.timings.yawnDuration)
        case .beginDozing:
            let timings = preferences.theme.timings
            let remainingDeepSleep = timings.deepSleepTimeout - now.timeIntervalSince(lastPointerActivity)
            if remainingDeepSleep <= 0 {
                beginSleepPhase(.collapsing, at: now, after: timings.collapseDuration)
            } else {
                sleepPhaseStartedAt = now
                dozingSince = now
                petState = .dozing
                scheduleSleepTransition(after: remainingDeepSleep)
            }
        case .beginCollapsing:
            beginSleepPhase(.collapsing, at: now, after: preferences.theme.timings.collapseDuration)
        case .beginSleeping:
            resetSleepSequence()
            petState = .sleeping
        }
        return true
    }

    /// `kill(pid, 0)` semantics: exists (or is owned by another user), or not.
    nonisolated static func isProcessAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    public func tickForMaintenance() {
        tickStartupRecovery()
        if let transition = sessionStore.pruneStale(isProcessAlive: Self.isProcessAlive) {
            sessions = transition.sessions
            publishSnapshot(state: transition.state, sessions: transition.sessions)
            if !preferences.doNotDisturb, !petState.isSleepSequence { petState = transition.state }
        }
        _ = tickForSleep()
    }

    private func apply(_ event: AgentEvent) {
        let normalizedEvent = event.eventName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
        let metadataOnly = event.metadataOnly || normalizedEvent == "quotaupdate"
        if !metadataOnly {
            resetSleepSequence()
            if startupRecoveryActive { endStartupRecovery() }
        }
        if let quota = event.quota {
            quotaReports = quotaStore.apply(quota)
        }
        if let contextUsage = event.contextUsage,
           let transition = sessionStore.updateContextUsage(
               sessionID: event.sessionID,
               usage: contextUsage
           ) {
            sessions = transition.sessions
        }
        if metadataOnly {
            publishSnapshot(state: petState, sessions: sessions)
            return
        }
        if let question = event.question {
            pendingQuestions.removeAll { $0.id == question.id }
            pendingQuestions.append(question)
            if pendingQuestions.count > 8 { pendingQuestions.removeFirst(pendingQuestions.count - 8) }
        }
        if event.questionResolution {
            let resolvedID = event.toolCallID ?? event.payload["question_call_id"]
            if let toolCallID = resolvedID {
                pendingQuestions.removeAll { $0.id == toolCallID }
            } else {
                pendingQuestions.removeAll { $0.sessionID == event.sessionID && $0.agentID == event.agentID }
            }
        }
        if event.permissionGated {
            closeKimiGate(for: event)
        }
        let transition = sessionStore.apply(event)
        sessions = transition.sessions
        publishSnapshot(state: transition.state, sessions: transition.sessions)
        eventLog.insert("\(event.agentID) · \(event.eventName)", at: 0)
        if eventLog.count > 80 { eventLog.removeLast(eventLog.count - 80) }

        if event.permissionSuspect {
            armKimiSuspectCue(for: event)
        }

        if preferences.doNotDisturb {
            petState = .sleeping
            return
        }

        petState = transition.state
        if transition.state == .attention {
            onCompletion?()
            remoteNotifier.send(RemoteNotification(title: "Task complete", body: event.eventName, sessionTitle: event.title))
            scheduleReturn(to: fallbackState, after: 4)
        } else if transition.state == .error || transition.state == .notification {
            if transition.state == .error {
                remoteNotifier.send(RemoteNotification(title: "Agent error", body: event.eventName, sessionTitle: event.title))
                onError?(event.title ?? event.eventName)
            }
            scheduleReturn(to: fallbackState, after: 6)
        } else {
            completionTask?.cancel()
        }
    }

    private func scheduleReturn(to state: PetState, after seconds: Double) {
        completionTask?.cancel()
        completionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled else { return }
            if self.petState == .attention || self.petState == .error || self.petState == .notification
                || self.petState == .waking || self.petState == .wakingFromDoze || self.petState.isSleepSequence {
                self.petState = self.preferences.isMiniMode ? .miniIdle : state
            }
        }
    }

    private func scheduleSleepTransition(after seconds: TimeInterval) {
        sleepTransitionTask?.cancel()
        guard seconds > 0 else { return }
        sleepTransitionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled else { return }
            self.sleepTransitionTask = nil
            if self.preferences.doNotDisturb {
                self.advanceDoNotDisturbSleep()
            } else {
                _ = self.tickForSleep()
            }
        }
    }

    private func beginSleepPhase(_ state: PetState, at date: Date, after seconds: TimeInterval) {
        sleepPhaseStartedAt = date
        petState = state
        if state == .collapsing, seconds <= 0 {
            resetSleepSequence()
            petState = .sleeping
            return
        }
        scheduleSleepTransition(after: seconds)
    }

    private func advanceDoNotDisturbSleep() {
        guard preferences.doNotDisturb else { return }
        switch petState {
        case .yawning:
            beginSleepPhase(.collapsing, at: .now, after: preferences.theme.timings.dndCollapseDuration)
        case .collapsing:
            resetSleepSequence()
            petState = .sleeping
        default:
            break
        }
    }

    private func resetSleepSequence() {
        sleepTransitionTask?.cancel()
        sleepTransitionTask = nil
        sleepPhaseStartedAt = nil
        dozingSince = nil
    }

    private func beginWakeTransition() {
        let target = preferences.isMiniMode ? .miniIdle : fallbackState
        let timings = preferences.theme.timings
        guard timings.sleepMode == .full || preferences.theme.hasVisualAsset(for: .waking) else {
            petState = target
            return
        }
        petState = .waking
        scheduleReturn(to: target, after: preferences.theme.timings.wakeDuration)
    }

    private func beginDozeWakeTransition() {
        let target = preferences.isMiniMode ? .miniIdle : fallbackState
        petState = .wakingFromDoze
        scheduleReturn(to: target, after: 0.35)
    }

    private var fallbackState: PetState {
        sessions.first(where: { ![.attention, .error, .notification].contains($0.state) })?.state ?? .idle
    }

    private func kimiGateKey(for event: AgentEvent, fallbackID: String? = nil) -> String {
        let id = event.permissionGateID ?? fallbackID ?? "fifo"
        return "\(event.sessionID)|\(id)"
    }

    private func armKimiSuspectCue(for event: AgentEvent) {
        let key = kimiGateKey(for: event, fallbackID: UUID().uuidString)
        kimiSuspectTasks[key]?.cancel()
        kimiGateOrder[event.sessionID, default: []].append(key)
        let delayMilliseconds = event.permissionSuspectDelayMilliseconds ?? 800
        kimiSuspectTasks[key] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(delayMilliseconds))
            guard let self, !Task.isCancelled else { return }
            self.kimiSuspectTasks.removeValue(forKey: key)
            self.kimiGateOrder[event.sessionID]?.removeAll { $0 == key }
            guard !self.preferences.doNotDisturb else { return }
            self.petState = .notification
            self.scheduleReturn(to: self.fallbackState, after: 3)
        }
    }

    private func closeKimiGate(for event: AgentEvent) {
        let sessionID = event.sessionID
        var key: String?
        if let gateID = event.permissionGateID {
            key = kimiGateOrder[sessionID]?.first(where: { $0 == "\(sessionID)|\(gateID)" })
        }
        if key == nil { key = kimiGateOrder[sessionID]?.first }
        guard let key else { return }
        kimiSuspectTasks.removeValue(forKey: key)?.cancel()
        kimiGateOrder[sessionID]?.removeAll { $0 == key }
        if kimiGateOrder[sessionID]?.isEmpty == true { kimiGateOrder.removeValue(forKey: sessionID) }
    }

    private func publishSnapshot(state: PetState, sessions: [SessionSnapshot]) {
        let payload: [[String: Any]] = sessions.map { session in
            [
                "id": session.id,
                "agentID": session.agentID,
                "title": session.title,
                "folder": session.folder ?? "",
                "state": session.state.rawValue,
                "subagentCount": session.subagentCount,
                "lastEvent": session.lastEvent,
                "recentEvents": session.recentEvents,
            "lastActivity": session.lastActivity.timeIntervalSince1970
            ]
        }
        let quota = quotaReports.map(\.wireObject)
        eventServer.updateSnapshot(["state": state.rawValue, "sessions": payload, "quota": quota, "updatedAt": Date.now.timeIntervalSince1970])
        mobileBridge.updateSnapshot(["state": state.rawValue, "sessions": payload, "quota": quota])
    }
}
