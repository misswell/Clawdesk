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

    private var replies: [String: PermissionReply] = [:]
    private var completionTask: Task<Void, Never>?
    private var kimiSuspectTasks: [String: Task<Void, Never>] = [:]
    private var kimiGateOrder: [String: [String]] = [:]
    var lastPointerActivity = Date.now
    var dozingSince: Date?
    private var lastPointerLocation: CGPoint?
    private var preferenceCancellables = Set<AnyCancellable>()
    private var healthTimer: Timer?

    public init(preferences: AppPreferences = AppPreferences()) {
        self.preferences = preferences
        let server = LocalEventServer(preferredPort: preferences.serverPort)
        eventServer = server
        remoteSSHManager = RemoteSSHManager(eventServer: server)
        hookInstaller = HookInstaller()
        doctor = AgentDoctor(installer: hookInstaller)
        remoteNotifier = RemoteNotifier()
        mobileBridge = MobileBridge(preferredPort: preferences.mobilePort)
        codexLogMonitor = CodexLogMonitor()
        claudeHookHealth = ClaudeHookHealthMonitor(installer: hookInstaller)
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
                self.petState = .sleeping
            } else if self.petState == .sleeping {
                self.petState = self.preferences.isMiniMode ? .miniIdle : .idle
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
        eventServer.start()
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
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self else { return }
            serverPort = eventServer.port
            preferences.serverPort = eventServer.port
            try? hookInstaller.writeRuntimeFile(port: eventServer.port, autoStart: preferences.autoStart)
            if preferences.collectClaudeUsage {
                _ = try? hookInstaller.ensureClaudeStatusLine()
            }
        }
    }

    public func stop() {
        completionTask?.cancel()
        for task in kimiSuspectTasks.values { task.cancel() }
        kimiSuspectTasks.removeAll()
        kimiGateOrder.removeAll()
        eventServer.stop()
        mobileBridge.stop()
        codexLogMonitor.stop()
        healthTimer?.invalidate()
        healthTimer = nil
        remoteNotifier.stop()
        remoteSSHManager.stop()
    }

    private func runHealthCheck() {
        guard serverPort > 0 else { return }
        claudeHookHealth.check(port: serverPort)
        objectWillChange.send()
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
            replies[request.id] = reply
            apply(event)
            if preferences.doNotDisturb {
                resolvePermission(id: request.id, decision: .defer)
                return
            }
            remoteNotifier.send(RemoteNotification(title: "Permission request", body: request.title, sessionTitle: request.agentID))
            if preferences.permissionMode == .autoApprove {
                resolvePermission(id: request.id, decision: .allow)
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
            if preferences.showPermissionBubbles {
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
        guard !preferences.doNotDisturb, petState == .sleeping || petState == .dozing else { return }
        dozingSince = nil
        petState = .waking
        scheduleReturn(to: preferences.isMiniMode ? .miniIdle : fallbackState, after: 0.9)
    }

    public func resolvePermission(id: String, decision: PermissionDecision) {
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

    public func setTheme(_ id: String) {
        preferences.selectedThemeID = id
        objectWillChange.send()
    }

    public func installAgent(_ agentID: String) {
        do {
            let result = try hookInstaller.install(agentID: agentID, port: serverPort)
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
        guard !preferences.doNotDisturb, now.timeIntervalSince(lastPointerActivity) >= 60 else { return false }
        guard petState == .idle || petState == .typing || petState == .dozing else {
            dozingSince = nil
            return false
        }
        if let since = dozingSince {
            guard now.timeIntervalSince(since) >= 25 else { return false }
            dozingSince = nil
            petState = .sleeping
            return true
        }
        dozingSince = now
        petState = .dozing
        return true
    }

    public func tickForMaintenance() {
        if let transition = sessionStore.pruneStale() {
            sessions = transition.sessions
            publishSnapshot(state: transition.state, sessions: transition.sessions)
            if !preferences.doNotDisturb, petState != .sleeping { petState = transition.state }
        }
        _ = tickForSleep()
    }

    private func apply(_ event: AgentEvent) {
        dozingSince = nil
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
        if let quota = event.quota {
            quotaReports = quotaStore.apply(quota)
        }
        if event.eventName.lowercased().replacingOccurrences(of: "_", with: "") == "quotaupdate" {
            publishSnapshot(state: petState, sessions: sessions)
            return
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
                || self.petState == .waking || self.petState == .dozing || self.petState == .sleeping {
                self.petState = self.preferences.isMiniMode ? .miniIdle : state
            }
        }
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
