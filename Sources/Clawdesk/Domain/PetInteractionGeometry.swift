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

public enum PetPointerMapper {
    public static func offset(for localPoint: CGPoint, in bounds: CGRect) -> CGPoint {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        let dx = (localPoint.x - bounds.midX) / max(1, bounds.width * 0.20)
        let dy = (localPoint.y - bounds.midY) / max(1, bounds.height * 0.25)
        return CGPoint(
            x: max(-5, min(5, dx * 5)),
            y: max(-4, min(4, dy * 4))
        )
    }
}
