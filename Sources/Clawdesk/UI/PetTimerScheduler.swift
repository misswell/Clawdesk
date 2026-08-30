import Foundation

/// Schedules pet refreshes in common modes so AppKit mouse tracking and menu
/// tracking do not pause eye-follow or animation callbacks.
@MainActor
enum PetTimerScheduler {
    static func pointerFrequency(lowPower: Bool) -> Double {
        lowPower ? 12 : 30
    }

    static func schedule(
        interval: TimeInterval,
        repeats: Bool,
        handler: @escaping @MainActor @Sendable () -> Void
    ) -> Timer {
        let timer = Timer(timeInterval: max(0.001, interval), repeats: repeats) { _ in
            MainActor.assumeIsolated {
                handler()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        // Keep explicit fallbacks as well. They make the contract true even
        // on run loops where AppKit has not registered eventTracking or
        // modalPanel as a common mode yet.
        RunLoop.main.add(timer, forMode: .eventTracking)
        RunLoop.main.add(timer, forMode: .modalPanel)
        return timer
    }
}
