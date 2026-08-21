import Foundation
import ServiceManagement

public enum LaunchAtLogin {
    public static func setEnabled(_ enabled: Bool) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Running from `swift run` has no bundle registration point. A packaged
            // Clawdesk app uses the same call with the normal macOS login item API.
        }
    }
}
