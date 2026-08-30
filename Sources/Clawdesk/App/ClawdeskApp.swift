import AppKit
import Combine
import Foundation

@main
@MainActor
public final class ClawdeskApp: NSObject, NSApplicationDelegate {
    private let model = ClawdeskModel()
    private var petWindow: PetWindowController!
    private var permissionBubbles: PermissionBubbleController!
    private var settingsWindow: SettingsWindowController!
    private var dashboardWindow: DashboardWindowController!
    private var statusItem: NSStatusItem!
    private var shortcuts: GlobalShortcutManager!
    private let instanceGuard = SingleInstanceGuard()
    private var cancellables = Set<AnyCancellable>()
    private var statusMenuRebuildTask: Task<Void, Never>?
    private var updateCheckTask: Task<Void, Never>?

    public static func main() {
        let application = NSApplication.shared
        let delegate = ClawdeskApp()
        application.delegate = delegate
        application.run()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        guard instanceGuard.acquire() else {
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        NSApp.applicationIconImage = RobotIcon.applicationImage()

        petWindow = PetWindowController(model: model)
        permissionBubbles = PermissionBubbleController(model: model)
        settingsWindow = SettingsWindowController(model: model)
        dashboardWindow = DashboardWindowController(model: model)
        shortcuts = GlobalShortcutManager(model: model)
        petWindow.onSettings = { [weak self] in self?.showSettings() }
        petWindow.onDashboard = { [weak self] in self?.showDashboard() }
        petWindow.onCheckForUpdates = { [weak self] in self?.checkForUpdates() }
        petWindow.onQuit = { NSApp.terminate(nil) }

        model.onPermission = { [weak self] _ in
            self?.playSound(logical: "confirm", systemFallback: "Funk")
        }
        model.onCompletion = { [weak self] in
            self?.playSound(logical: "complete", systemFallback: "Glass")
        }
        model.onError = { [weak self] _ in
            self?.playSound(logical: "error", systemFallback: "Sosumi")
        }

        installStatusItem()
        model.preferences.$language.sink { [weak self] _ in
            guard let self else { return }
            self.statusItem?.menu = self.makeStatusMenu()
            self.settingsWindow.window?.title = self.model.preferences.text("Clawdesk Settings")
            self.dashboardWindow.window?.title = self.model.preferences.text("Clawdesk Dashboard")
        }.store(in: &cancellables)
        model.preferences.$autoCheckForUpdates
            .sink { [weak self] enabled in
                self?.setAutomaticUpdateChecks(enabled)
            }
            .store(in: &cancellables)
        model.$sessions.sink { [weak self] _ in
            self?.scheduleStatusMenuRebuild()
        }.store(in: &cancellables)
        model.start()
        shortcuts.start()
        petWindow.start()
        setAutomaticUpdateChecks(model.preferences.autoCheckForUpdates)
    }

    public func applicationWillTerminate(_ notification: Notification) {
        model.stop()
        shortcuts.stop()
        updateCheckTask?.cancel()
        petWindow.stop()
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        petWindow.window?.orderFrontRegardless()
        return true
    }

    private func installStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = RobotIcon.menuBarImage()
        statusItem.menu = makeStatusMenu()
    }

    private func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        addMenuItem(to: menu, title: model.preferences.text("Open Dashboard"), action: #selector(showDashboard))
        addMenuItem(to: menu, title: model.preferences.text("Settings…"), action: #selector(showSettings))
        addMenuItem(to: menu, title: model.preferences.text("Check for Updates…"), action: #selector(checkForUpdates))
        let sessions = NSMenuItem(title: model.preferences.text("Sessions"), action: nil, keyEquivalent: "")
        sessions.submenu = makeStatusSessionsMenu()
        menu.addItem(sessions)
        menu.addItem(.separator())
        addMenuItem(to: menu, title: model.preferences.text("Mini Mode"), action: #selector(toggleMini))
        addMenuItem(to: menu, title: model.preferences.text("Do Not Disturb"), action: #selector(toggleDND))
        addMenuItem(to: menu, title: model.preferences.text("Sound effects"), action: #selector(toggleSound))
        menu.addItem(.separator())
        addMenuItem(to: menu, title: model.preferences.text("Quit Clawdesk"), action: #selector(terminate))
        return menu
    }

    /// Session changes rebuild the tray menu so the Sessions submenu stays
    /// current; the rebuild is debounced to avoid churn during heavy activity.
    private func scheduleStatusMenuRebuild() {
        statusMenuRebuildTask?.cancel()
        statusMenuRebuildTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard let self, !Task.isCancelled else { return }
            self.statusItem?.menu = self.makeStatusMenu()
        }
    }

    private func makeStatusSessionsMenu() -> NSMenu {
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

    @objc private func showSettings() { settingsWindow.show() }
    @objc private func showDashboard() { dashboardWindow.show() }
    @objc private func toggleMini() { model.preferences.isMiniMode.toggle() }
    @objc private func toggleDND() { model.preferences.doNotDisturb.toggle() }
    @objc private func toggleSound() { model.preferences.soundEnabled.toggle() }
    @objc private func terminate() { NSApp.terminate(nil) }

    @objc private func checkForUpdates() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.model.softwareUpdater.checkForUpdates()
            if let release = self.model.softwareUpdater.state.availableRelease {
                self.presentUpdatePrompt(release)
            }
        }
    }

    private func presentUpdatePrompt(_ release: ClawdeskRelease) {
        let alert = NSAlert()
        alert.messageText = model.preferences.text("Update available")
        alert.informativeText = "Clawdesk \(release.version) is available."
        alert.addButton(withTitle: model.preferences.text("Download & Install"))
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            Task { @MainActor [weak self] in
                await self?.model.softwareUpdater.downloadAndInstall()
            }
        }
    }

    private func setAutomaticUpdateChecks(_ enabled: Bool) {
        updateCheckTask?.cancel()
        updateCheckTask = nil
        guard enabled else { return }

        updateCheckTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            while let self, !Task.isCancelled {
                guard self.model.preferences.autoCheckForUpdates else { return }
                await self.model.softwareUpdater.checkForUpdates()
                if let release = self.model.softwareUpdater.state.availableRelease {
                    self.presentUpdatePrompt(release)
                }
                try? await Task.sleep(for: .seconds(6 * 60 * 60))
            }
        }
    }

    /// Plays the active theme's sound for a logical name, falling back to a
    /// system sound when the theme has none or the file cannot be loaded.
    private func playSound(logical name: String, systemFallback: String?) {
        guard model.preferences.soundEnabled else { return }
        if let file = model.preferences.theme.sounds[name],
           let directory = model.preferences.theme.assetDirectory {
            let url = directory.appendingPathComponent("sounds").appendingPathComponent(file)
            if let sound = NSSound(contentsOf: url, byReference: true) {
                sound.play()
                return
            }
        }
        if let systemFallback, let sound = NSSound(named: systemFallback) {
            sound.play()
        }
    }
}
