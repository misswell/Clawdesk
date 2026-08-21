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
        NSApp.applicationIconImage = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "Clawdesk")

        petWindow = PetWindowController(model: model)
        permissionBubbles = PermissionBubbleController(model: model)
        settingsWindow = SettingsWindowController(model: model)
        dashboardWindow = DashboardWindowController(model: model)
        shortcuts = GlobalShortcutManager(model: model)
        petWindow.onSettings = { [weak self] in self?.showSettings() }
        petWindow.onDashboard = { [weak self] in self?.showDashboard() }
        petWindow.onQuit = { NSApp.terminate(nil) }

        model.onPermission = { [weak self] _ in
            if self?.model.preferences.soundEnabled == true {
                NSSound(named: "Funk")?.play()
            }
        }
        model.onCompletion = { [weak self] in
            guard let self, self.model.preferences.soundEnabled else { return }
            NSSound(named: "Glass")?.play()
        }

        installStatusItem()
        model.preferences.$language.sink { [weak self] _ in
            guard let self else { return }
            self.statusItem?.menu = self.makeStatusMenu()
            self.settingsWindow.window?.title = self.model.preferences.text("Clawdesk Settings")
            self.dashboardWindow.window?.title = self.model.preferences.text("Clawdesk Dashboard")
        }.store(in: &cancellables)
        model.start()
        shortcuts.start()
        petWindow.start()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        model.stop()
        shortcuts.stop()
        petWindow.stop()
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        petWindow.window?.orderFrontRegardless()
        return true
    }

    private func installStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "Clawdesk")
        statusItem.button?.image?.isTemplate = true
        statusItem.menu = makeStatusMenu()
    }

    private func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        addMenuItem(to: menu, title: model.preferences.text("Open Dashboard"), action: #selector(showDashboard))
        addMenuItem(to: menu, title: model.preferences.text("Settings…"), action: #selector(showSettings))
        menu.addItem(.separator())
        addMenuItem(to: menu, title: model.preferences.text("Mini Mode"), action: #selector(toggleMini))
        addMenuItem(to: menu, title: model.preferences.text("Do Not Disturb"), action: #selector(toggleDND))
        addMenuItem(to: menu, title: model.preferences.text("Sound effects"), action: #selector(toggleSound))
        menu.addItem(.separator())
        addMenuItem(to: menu, title: model.preferences.text("Quit Clawdesk"), action: #selector(terminate))
        return menu
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
}
