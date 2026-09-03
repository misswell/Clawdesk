import Foundation

/// The immutable relationship between the pointer and the pet window at the
/// start of a drag. Keeping this in screen coordinates prevents the moving
/// window from changing the coordinate system used for the next event.
public struct PetDragAnchor: Equatable, Sendable {
    public let windowOrigin: CGPoint
    public let pointerOrigin: CGPoint

    public init(windowOrigin: CGPoint, pointerOrigin: CGPoint) {
        self.windowOrigin = windowOrigin
        self.pointerOrigin = pointerOrigin
    }

    public func windowOrigin(for pointer: CGPoint) -> CGPoint {
        CGPoint(
            x: windowOrigin.x + pointer.x - pointerOrigin.x,
            y: windowOrigin.y + pointer.y - pointerOrigin.y
        )
    }
}

/// Pointer-to-gaze normalization, ported from bloub's `ui/gaze.ts` +
/// `BloubBot.aim()`: the pointer offset from the pet's centre is divided by
/// HALF THE SCREEN extents and clamped, so the gaze saturates exactly when
/// the cursor reaches the screen edge — the same sweep as the original,
/// where the bot's head covers its whole designed range as the mouse
/// travels the page.
///
/// `AppKit` screen coordinates grow upward; the returned offset uses the
/// screen convention instead (y positive = cursor BELOW the pet), matching
/// the `Aim` struct the upstream rule consumes.
public enum PetPointerMapper {
    /// Whether a fixed Dock (or any reserved strip) occupies the screen's
    /// left/right edge, derived from the screen frame vs. its visible
    /// (work-area) frame. A mini-mode pet docked on an occupied edge would
    /// sit under the Dock, where the Dock eats every click — so those edges
    /// must refuse docking.
    public static func dockOccupiesEdges(
        screenFrame: CGRect,
        visibleFrame: CGRect,
        threshold: CGFloat = 20
    ) -> (left: Bool, right: Bool) {
        let left = visibleFrame.minX - screenFrame.minX > threshold
        let right = screenFrame.maxX - visibleFrame.maxX > threshold
        return (left, right)
    }

    /// Normalized gaze offset: x right-positive, y down-positive, -1...1.
    public static func gazeOffset(
        petCenter: CGPoint,
        cursor: CGPoint,
        screenSize: CGSize
    ) -> CGPoint {
        let halfWidth = max(1, screenSize.width / 2)
        let halfHeight = max(1, screenSize.height / 2)
        // AppKit y grows upward; flip so y-down is positive, like upstream.
        let nx = (cursor.x - petCenter.x) / halfWidth
        let ny = (petCenter.y - cursor.y) / halfHeight
        return CGPoint(
            x: min(1, max(-1, nx)),
            y: min(1, max(-1, ny))
        )
    }

    /// How much the pet should look STRAIGHT AT THE VIEWER because the cursor
    /// is on its body: 1 at the centre of `petRect`, 0 at its edge (and
    /// beyond), falling smoothly in between so the gaze never pops between
    /// "forward" and "tracking".
    ///
    /// The original does the same by construction — a cursor resting on the
    /// bot produces a near-zero offset, and its gaze comes to the front.
    /// `petRect` should be the ball, not the whole window.
    public static func forwardFactor(petRect: CGRect, cursor: CGPoint) -> CGFloat {
        guard petRect.width > 0, petRect.height > 0 else { return 0 }
        let dx = abs(cursor.x - petRect.midX) / (petRect.width / 2)
        let dy = abs(cursor.y - petRect.midY) / (petRect.height / 2)
        let edgeDistance = max(dx, dy)
        return min(1, max(0, 1 - edgeDistance))
    }
}
