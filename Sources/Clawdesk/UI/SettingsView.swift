import AppKit
import SwiftUI
import UniformTypeIdentifiers

public struct SettingsView: View {
    @ObservedObject private var model: ClawdeskModel
    @ObservedObject private var prefs: AppPreferences
    @State private var selectedTab = "general"

    public init(model: ClawdeskModel) {
        self.model = model
        _prefs = ObservedObject(wrappedValue: model.preferences)
    }

    public var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsView(model: model)
                .tabItem { Label(prefs.text("General"), systemImage: "slider.horizontal.3") }
                .tag("general")
            AgentSettingsView(model: model)
                .tabItem { Label(prefs.text("Agents"), systemImage: "terminal") }
                .tag("agents")
            PermissionSettingsView(model: model)
                .tabItem { Label(prefs.text("Permissions"), systemImage: "checkmark.shield") }
                .tag("permissions")
            RemoteSettingsView(model: model)
                .tabItem { Label(prefs.text("Remote"), systemImage: "antenna.radiowaves.left.and.right") }
                .tag("remote")
            RemoteSSHSettingsView(model: model)
                .tabItem { Label(prefs.text("Remote SSH"), systemImage: "network") }
                .tag("remote-ssh")
            DoctorSettingsView(model: model)
                .tabItem { Label(prefs.text("Doctor"), systemImage: "stethoscope") }
                .tag("doctor")
            AboutSettingsView(model: model)
                .tabItem { Label(prefs.text("About"), systemImage: "info.circle") }
                .tag("about")
        }
        .frame(minWidth: 650, minHeight: 430)
        .padding(18)
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject var model: ClawdeskModel
    @State private var themeStatus = ""
    @State private var roamStatus = ""

    var body: some View {
        Form {
            Section {
                Picker(model.preferences.text("Theme"), selection: Binding(
                    get: { model.preferences.selectedThemeID },
                    set: { model.setTheme($0) }
                )) {
                    ForEach(model.preferences.availableThemes) { theme in
                        Text(theme.displayName).tag(theme.id)
                    }
                }
                if model.preferences.theme.supportsIdleVisualSelection {
                    Picker(model.preferences.text("Idle visual"), selection: Binding(
                        get: {
                            model.preferences.selectedIdleVisual(for: model.preferences.theme)
                                ?? model.preferences.theme.idleVisualFiles[0]
                        },
                        set: { model.preferences.setIdleVisual($0, for: model.preferences.theme) }
                    )) {
                        ForEach(model.preferences.theme.idleVisualFiles, id: \.self) { file in
                            Text(URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent)
                                .tag(file)
                        }
                    }
                }
                HStack {
                    Text(model.preferences.text("Pet size"))
                    Slider(value: $model.preferences.petScale, in: 0.4...2.0)
                    Text("\(Int((model.preferences.petScale * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .frame(width: 46, alignment: .trailing)
                }
                HStack {
                    Button(model.preferences.text("Import theme…")) {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = true
                        panel.canChooseDirectories = true
                        panel.allowsMultipleSelection = false
                        panel.allowedContentTypes = [.zip]
                        guard panel.runModal() == .OK, let url = panel.url else { return }
                        do {
                            try model.preferences.importTheme(from: url)
                            themeStatus = "Imported \(model.preferences.theme.displayName)."
                        } catch {
                            themeStatus = error.localizedDescription
                        }
                    }
                    if model.preferences.theme.assetDirectory != nil {
                        Button(model.preferences.text("Remove custom theme")) {
                            do {
                                try model.preferences.removeCustomTheme(id: model.preferences.theme.id)
                                themeStatus = "Custom theme removed."
                            } catch {
                                themeStatus = error.localizedDescription
                            }
                        }
                    }
                    if !themeStatus.isEmpty {
                        Text(themeStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Toggle(model.preferences.text("Mini mode"), isOn: $model.preferences.isMiniMode)
                Toggle(model.preferences.text("Low-power animations"), isOn: $model.preferences.lowPowerAnimations)
                Toggle(model.preferences.text("Sound effects"), isOn: $model.preferences.soundEnabled)
                Toggle(model.preferences.text("Launch at login"), isOn: $model.preferences.autoStart)
                Toggle(model.preferences.text("Do Not Disturb"), isOn: $model.preferences.doNotDisturb)
                Toggle(model.preferences.text("Free roam"), isOn: $model.preferences.freeRoamEnabled)
                HStack {
                    Button(model.preferences.text("Choose area…")) { chooseRoamArea() }
                    Button(model.preferences.text("Remove custom area")) { removeRoamArea() }
                    if !roamStatus.isEmpty {
                        Text(roamStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            } header: {
                Text(model.preferences.text("Desktop pet"))
            } footer: {
                Text("Low-power mode keeps idle animation on a low-frequency timer and pauses passive effects when Clawdesk is inactive.")
            }

            Section(model.preferences.text("Interface language")) {
                Picker(model.preferences.text("Interface language"), selection: $model.preferences.language) {
                    Text(model.preferences.text("System default")).tag("system")
                    Text("English").tag("en")
                    Text("简体中文").tag("zh-Hans")
                    Text("繁體中文").tag("zh-Hant")
                    Text("日本語").tag("ja")
                    Text("한국어").tag("ko")
                    Text("Español").tag("es")
                }
            }

            Section {
                Toggle(model.preferences.text("Collect local Claude usage"), isOn: $model.preferences.collectClaudeUsage)
            } header: {
                Text(model.preferences.text("Quota ring"))
            } footer: {
                Text("Off by default. Enabling it adds Clawdesk's status line to ~/.claude/settings.json using Claude Code's documented extension mechanism.")
            }

            HStack {
                Button(model.preferences.text("Reset position")) { model.preferences.resetPosition() }
                Spacer()
                Text("State server: 127.0.0.1:\(model.serverPort)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseRoamArea() {
        let coordinator = RoamFenceCoordinator()
        coordinator.refresh(from: model.preferences.roamAreaFileURL)
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let picker = RoamAreaPickerController { [weak model] area in
            guard let model, let area else { return }
            do {
                try RoamFenceCoordinator().apply(area, to: model.preferences.roamAreaFileURL)
                self.roamStatus = area.enabled ? "Roam area saved." : "Custom area removed."
            } catch {
                self.roamStatus = error.localizedDescription
            }
        }
        picker.present(on: screen, initial: coordinator.current)
    }

    private func removeRoamArea() {
        do {
            try RoamFenceCoordinator().disable(model.preferences.roamAreaFileURL)
            roamStatus = "Custom area removed."
        } catch {
            roamStatus = error.localizedDescription
        }
    }
}

private struct AgentSettingsView: View {
    @ObservedObject var model: ClawdeskModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Agent integrations")
                .font(.title2.weight(.semibold))
            Text("All integrations use the same small local event interface. The native app keeps adapters separate so upstream agent changes stay localized.")
                .foregroundStyle(.secondary)
            List {
                ForEach(AgentRegistry.all, id: \.id) { (agent: AgentDescriptor) in
                    HStack(spacing: 12) {
                        Image(systemName: agent.id == "custom" ? "network" : "terminal.fill")
                            .frame(width: 24)
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(agent.displayName).font(.headline)
                            Text(agent.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if HookInstaller.supportedAgentIDs.contains(agent.id) {
                            HStack(spacing: 6) {
                                Button(model.agentInstallStatus[agent.id] == nil ? "Install" : "Re-sync") {
                                    model.installAgent(agent.id)
                                }
                                .buttonStyle(.bordered)
                                Button("Remove") {
                                    model.uninstallAgent(agent.id)
                                }
                                .buttonStyle(.bordered)
                            }
                        } else {
                            Text(agent.stateOnly ? "State-only" : "Ready")
                                .font(.caption)
                                .foregroundStyle(Color.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            Text("Install merges only Clawdesk-owned entries and keeps a backup before changing an agent config. Agent-specific payload parsing stays inside each adapter so upstream changes remain localized.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if model.claudeHookHealth.status != .unknown {
                Label(
                    model.claudeHookHealth.status == .healthy
                        ? "Claude hooks: healthy"
                        : model.claudeHookHealth.status == .manualFixRequired
                            ? "Claude hooks: manual fix required"
                            : "Claude hooks: \(model.claudeHookHealth.status.rawValue)",
                    systemImage: model.claudeHookHealth.status == .healthy ? "checkmark.circle" : "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(model.claudeHookHealth.status == .healthy ? Color.secondary : Color.orange)
            }
        }
        .padding(8)
    }
}

private struct PermissionSettingsView: View {
    @ObservedObject var model: ClawdeskModel

    var body: some View {
        Form {
            Section {
                Picker("Permission handling", selection: $model.preferences.permissionMode) {
                    ForEach(PermissionMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Toggle("Show pop-up bubbles", isOn: $model.preferences.showPermissionBubbles)
            } header: {
                Text("Local approval")
            } footer: {
                Text("Auto-approve is intentionally opt-in and applies only to requests received through Clawdesk's local event server.")
            }

            Section("Keyboard shortcuts") {
                LabeledContent("Allow latest request", value: "⌃⇧Y")
                LabeledContent("Deny latest request", value: "⌃⇧N")
            }
        }
        .formStyle(.grouped)
    }
}

private struct RemoteSettingsView: View {
    @ObservedObject var model: ClawdeskModel
    @State private var remoteEnabled = false
    @State private var updateStatus = ""
    @State private var latestRelease: ReleaseInfo?
    @State private var latestAsset: ReleaseAsset?
    @State private var telegramApprovalEnabled = false
    @State private var telegramToken = ""
    @State private var telegramChatID = ""
    @State private var telegramUserID = ""
    @State private var telegramTimeout = 60
    @State private var telegramApprovalStatus = ""
    @State private var feishuApprovalEnabled = false
    @State private var feishuPlatform = "feishu"
    @State private var feishuAppID = ""
    @State private var feishuAppSecret = ""
    @State private var feishuApproverID = ""
    @State private var feishuApproverIDType = "open_id"
    @State private var feishuConnectionTimeout = 15
    @State private var feishuApprovalStatus = ""

    var body: some View {
        Form {
            Section("Local bridge") {
                LabeledContent("Endpoint", value: "http://127.0.0.1:\(model.serverPort)")
                Text("POST /state for lifecycle events, POST /permission for approval requests, GET /health for diagnostics, and GET /mobile for the read-only companion.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Mobile companion (read-only LAN)") {
                Toggle("Enable LAN bridge", isOn: $model.preferences.mobileEnabled)
                LabeledContent("LAN port", value: String(model.mobileBridge.port))
                if let pairingURL = model.mobileBridge.pairingURL() {
                    Text(pairingURL.absoluteString)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(3)
                } else {
                    Text("No non-loopback LAN address is available yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Rotate token") {
                        _ = model.mobileBridge.rotateToken()
                    }
                    Text("Token file: \(model.mobileBridge.tokenURL.path)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text("The bridge exposes only sanitized session state. It does not accept approvals, prompts, terminal commands, or tool input.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Remote notifications") {
                Toggle("Enable configured channels", isOn: $remoteEnabled)
                    .onChange(of: remoteEnabled) { enabled in
                        var settings = model.remoteNotifier.settings
                        settings.enabled = enabled
                        try? model.remoteNotifier.save(settings)
                    }
                Text("Telegram, Feishu/Lark, and Slack credentials are stored in a 0600 file outside UserDefaults. Configure the channels in \(model.remoteNotifier.configurationURL.path) when needed.")
                    .foregroundStyle(.secondary)
                Label(model.remoteNotifier.settings.enabled ? "Remote notifications enabled" : "No remote channel enabled", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
            Section("Telegram remote approval") {
                Toggle("Mirror eligible permission requests", isOn: $telegramApprovalEnabled)
                SecureField("Bot token (leave blank to keep saved)", text: $telegramToken)
                TextField("Target chat ID", text: $telegramChatID)
                TextField("Allowed approver user ID", text: $telegramUserID)
                Picker("Remote card timeout", selection: $telegramTimeout) {
                    ForEach([30, 60, 120, 300], id: \.self) { seconds in
                        Text("\(seconds) seconds").tag(seconds)
                    }
                }
                HStack {
                    Button("Save Telegram approval") {
                        var settings = model.remoteNotifier.settings
                        settings.telegramApprovalEnabled = telegramApprovalEnabled
                        settings.telegramChatID = telegramChatID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : telegramChatID.trimmingCharacters(in: .whitespacesAndNewlines)
                        settings.telegramApprovalUserID = telegramUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : telegramUserID.trimmingCharacters(in: .whitespacesAndNewlines)
                        settings.telegramApprovalTimeoutSeconds = telegramTimeout
                        let candidateToken = telegramToken.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !candidateToken.isEmpty { settings.telegramBotToken = candidateToken }
                        do {
                            try model.remoteNotifier.save(settings)
                            telegramToken = ""
                            telegramApprovalStatus = "Saved. The next pending request can be approved from Telegram."
                        } catch {
                            telegramApprovalStatus = error.localizedDescription
                        }
                    }
                    Text(telegramApprovalStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if model.remoteNotifier.settings.telegramBotToken != nil {
                    Text("A bot token is saved. The raw token is never shown here and is stored in a 0600 file.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Only the configured numeric user ID can tap Allow or Deny. Network failures leave the local permission bubble pending.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Feishu / Lark interactive approval") {
                Picker("Platform", selection: $feishuPlatform) {
                    Text("Feishu (China)").tag("feishu")
                    Text("Lark (International)").tag("lark")
                }
                Toggle("Mirror eligible permission requests", isOn: $feishuApprovalEnabled)
                TextField("App ID (cli_…)", text: $feishuAppID)
                SecureField("App secret (leave blank to keep saved)", text: $feishuAppSecret)
                TextField("Approver ID", text: $feishuApproverID)
                Picker("Approver ID type", selection: $feishuApproverIDType) {
                    Text("open_id (recommended)").tag("open_id")
                    Text("union_id").tag("union_id")
                    Text("user_id").tag("user_id")
                }
                Picker("Connection timeout", selection: $feishuConnectionTimeout) {
                    ForEach([5, 10, 15, 30, 60], id: \.self) { seconds in
                        Text("\(seconds) seconds").tag(seconds)
                    }
                }
                HStack {
                    Button("Save Feishu / Lark approval") {
                        var settings = model.remoteNotifier.settings
                        settings.feishuApprovalEnabled = feishuApprovalEnabled
                        settings.feishuPlatform = feishuPlatform
                        settings.feishuAppID = feishuAppID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? settings.feishuAppID
                            : feishuAppID.trimmingCharacters(in: .whitespacesAndNewlines)
                        let candidateSecret = feishuAppSecret.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !candidateSecret.isEmpty { settings.feishuAppSecret = candidateSecret }
                        settings.feishuApproverID = feishuApproverID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? nil
                            : feishuApproverID.trimmingCharacters(in: .whitespacesAndNewlines)
                        settings.feishuApproverIDType = feishuApproverIDType
                        settings.feishuConnectionTimeoutSeconds = feishuConnectionTimeout
                        do {
                            try model.remoteNotifier.save(settings)
                            feishuAppSecret = ""
                            feishuApprovalStatus = "Saved. Enable card.action.trigger in the app console before testing."
                        } catch {
                            feishuApprovalStatus = error.localizedDescription
                        }
                    }
                    Text(feishuApprovalStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if model.remoteNotifier.settings.feishuAppSecret != nil {
                    Text("An app secret is saved in the 0600 remote configuration file. It is never shown here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("The selected platform controls both REST and WebSocket endpoints. Only the configured approver ID can act on a card; transport failures leave the local bubble pending.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Updates") {
                HStack {
                    Button("Check GitHub releases") {
                        updateStatus = "Checking…"
                        Task {
                            do {
                                let service = UpdateService()
                                let release = try await service.latestRelease()
                                latestRelease = release
                                latestAsset = service.compatibleAsset(in: release)
                                updateStatus = latestAsset == nil
                                    ? "Latest: \(release.tag) (no compatible macOS package)"
                                    : "Latest: \(release.tag) · package: \(latestAsset!.name)"
                            } catch {
                                updateStatus = error.localizedDescription
                            }
                        }
                    }
                    if let release = latestRelease, let asset = latestAsset {
                        Button("Download package") {
                            guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
                            updateStatus = "Downloading \(asset.name)…"
                            Task {
                                do {
                                    let url = try await UpdateService().download(asset: asset, to: downloads)
                                    updateStatus = "Downloaded \(release.tag) to \(url.path)"
                                    NSWorkspace.shared.activateFileViewerSelecting([url])
                                } catch {
                                    updateStatus = error.localizedDescription
                                }
                            }
                        }
                    }
                    Text(updateStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            let settings = model.remoteNotifier.settings
            remoteEnabled = settings.enabled
            telegramApprovalEnabled = settings.telegramApprovalEnabled
            telegramChatID = settings.telegramChatID ?? ""
            telegramUserID = settings.telegramApprovalUserID ?? ""
            telegramTimeout = settings.telegramApprovalTimeoutSeconds
            feishuApprovalEnabled = settings.feishuApprovalEnabled
            feishuPlatform = settings.feishuPlatform
            feishuAppID = settings.feishuAppID ?? ""
            feishuApproverID = settings.feishuApproverID ?? ""
            feishuApproverIDType = settings.feishuApproverIDType
            feishuConnectionTimeout = settings.feishuConnectionTimeoutSeconds
        }
    }
}

private struct RemoteSSHSettingsView: View {
    @ObservedObject var model: ClawdeskModel
    @State private var label = "Remote host"
    @State private var host = ""
    @State private var port = 22
    @State private var identityFile = ""
    @State private var remoteForwardPort = 23333
    @State private var hostPrefix = ""
    @State private var transportMode: RemoteSSHTransportMode = .automatic
    @State private var autoStartCodexFallback = false
    @State private var status = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Remote SSH")
                        .font(.title2.weight(.semibold))
                    Text("Deploy native lifecycle hooks to remote Claude Code, Codex, or Copilot installations and carry events back through an SSH reverse tunnel. Passwords and passphrases stay with the system ssh client.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !model.remoteSSHManager.profiles.isEmpty {
                    ForEach(model.remoteSSHManager.profiles) { profile in
                        profileCard(profile)
                    }
                } else {
                    Text("No remote profiles yet.")
                        .foregroundStyle(.secondary)
                }

                Divider()
                Form {
                    Section("Add profile") {
                        TextField("Label", text: $label)
                        TextField("Host or SSH alias", text: $host)
                        HStack {
                            TextField("SSH port", value: $port, format: .number)
                            TextField("Remote forward port", value: $remoteForwardPort, format: .number)
                        }
                        TextField("Private key path (optional)", text: $identityFile)
                        TextField("Session prefix (optional)", text: $hostPrefix)
                        Picker("SSH transport", selection: $transportMode) {
                            ForEach(RemoteSSHTransportMode.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        Toggle("Auto-start Codex fallback monitor", isOn: $autoStartCodexFallback)
                        HStack {
                            Button("Add remote profile") {
                                do {
                                    try model.remoteSSHManager.add(RemoteSSHProfile(
                                        label: label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Remote host" : label,
                                        host: host.trimmingCharacters(in: .whitespacesAndNewlines),
                                        port: port,
                                        identityFile: identityFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : identityFile,
                                        remoteForwardPort: remoteForwardPort,
                                        hostPrefix: hostPrefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : hostPrefix,
                                        transportMode: transportMode,
                                        autoStartCodexFallback: autoStartCodexFallback
                                    ))
                                    status = "Profile added. Deploy hooks before connecting."
                                    host = ""
                                } catch {
                                    status = error.localizedDescription
                                }
                            }
                            Text(status)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .formStyle(.grouped)
                Text("Remote hooks include a per-profile nonce. The reverse tunnel binds only to the remote loopback interface; no remote port is exposed to the LAN.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private func profileCard(_ profile: RemoteSSHProfile) -> some View {
        let profileStatus = model.remoteSSHManager.statuses[profile.id] ?? .idle
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: profileStatus == .connected ? "link" : "network")
                    .foregroundStyle(profileStatus == .connected ? .green : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.label).font(.headline)
                    Text("\(profile.host):\(profile.port) · reverse \(profile.remoteForwardPort) · \(profile.transportMode.displayName)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(profileStatus.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(profileStatus == .failed ? .red : .secondary)
            }
            if let message = model.remoteSSHManager.messages[profile.id] {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                Label("Claude / Codex / Copilot", systemImage: "terminal")
                if profile.autoStartCodexFallback {
                    Label("Codex fallback", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            HStack {
                Button("Authenticate") { model.remoteSSHManager.authenticate(id: profile.id) }
                Button("Deploy / Repair Hooks") { model.remoteSSHManager.deploy(id: profile.id) }
                    .buttonStyle(.borderedProminent)
                if profileStatus == .connected || profileStatus == .connecting {
                    Button("Disconnect") { model.remoteSSHManager.disconnect(id: profile.id) }
                } else {
                    Button("Connect") { model.remoteSSHManager.connect(id: profile.id) }
                        .disabled(profile.deployedAt == nil)
                }
                Button("Delete") { try? model.remoteSSHManager.remove(id: profile.id) }
                    .foregroundStyle(.red)
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct DoctorSettingsView: View {
    @ObservedObject var model: ClawdeskModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(model.preferences.text("Doctor"))
                    .font(.title2.weight(.semibold))
                Spacer()
                Button(model.preferences.text("Run checks")) { model.refreshDoctor() }
                    .buttonStyle(.borderedProminent)
            }
            if model.doctorReports.isEmpty {
                Text("Run checks to inspect local agent integrations.")
                    .foregroundStyle(.secondary)
            } else {
                List(model.doctorReports, id: \.agentID) { report in
                    HStack(spacing: 10) {
                        Image(systemName: icon(for: report.state))
                            .foregroundStyle(color(for: report.state))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(report.displayName).font(.headline)
                            Text(report.message).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(label(for: report.state))
                            .font(.caption.weight(.semibold))
                        if report.state == .fixable {
                            Button(model.preferences.text("Fix")) { model.fixAgent(report.agentID) }
                                .buttonStyle(.bordered)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .padding(8)
    }

    private func icon(for state: AgentDiagnostic.State) -> String {
        switch state {
        case .ok: return "checkmark.circle"
        case .notInstalled: return "circle.dashed"
        case .fixable: return "exclamationmark.triangle"
        case .notChecked: return "questionmark.circle"
        }
    }

    private func color(for state: AgentDiagnostic.State) -> Color {
        switch state {
        case .ok: return .green
        case .fixable: return .orange
        case .notInstalled, .notChecked: return .secondary
        }
    }

    private func label(for state: AgentDiagnostic.State) -> String {
        switch state {
        case .ok: return model.preferences.text("OK")
        case .notInstalled: return model.preferences.text("Not installed")
        case .fixable: return model.preferences.text("Needs repair")
        case .notChecked: return model.preferences.text("Not checked")
        }
    }
}

private struct AboutSettingsView: View {
    @ObservedObject var model: ClawdeskModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "pawprint.fill")
                .font(.system(size: 52))
                .foregroundStyle(.orange)
            Text("Clawdesk")
                .font(.largeTitle.weight(.bold))
            Text(model.preferences.text("A native macOS desktop companion for coding agents."))
                .foregroundStyle(.secondary)
            Text(model.preferences.text("Built in Swift + AppKit/SwiftUI · no embedded browser runtime"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 30)
    }
}
