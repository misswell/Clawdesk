import Foundation

/// Per-display window containment. The union of the attached screens'
/// visible frames is only an outer bound: with staggered monitors the
/// bounding box admits dead zones where no display exists, and a window
/// clamped into such a gap is unreachable. Clamping is "loose" like
/// upstream's `looseClampPetToDisplays` (a window may overhang a display
/// edge), but the result must still overlap a real display's work area —
/// otherwise it is pulled to the nearest one.
public enum DisplayTopology {
    /// Clamp `origin` (a window's frame origin in screen coordinates) so the
    /// window stays inside the union of `visibleFrames` and overlaps at
    /// least one of them. Returns `origin` unchanged when the list is empty.
    public static func clampLooseOrigin(
        _ origin: CGPoint,
        windowSize: CGSize,
        visibleFrames: [CGRect]
    ) -> CGPoint {
        guard !visibleFrames.isEmpty else { return origin }
        let union = visibleFrames.reduce(CGRect.null) { $0.union($1) }
        guard union.width > 0, union.height > 0 else { return origin }
        let clamped = CGPoint(
            x: min(max(origin.x, union.minX), max(union.minX, union.maxX - windowSize.width)),
            y: min(max(origin.y, union.minY), max(union.minY, union.maxY - windowSize.height))
        )
        let frame = CGRect(origin: clamped, size: windowSize)
        if visibleFrames.contains(where: { $0.intersects(frame) }) {
            return clamped
        }
        // The union clamp landed in a dead zone between staggered displays
        // (or off a detached display's old spot): pull the window to the
        // nearest real work area so it stays reachable.
        guard let nearest = nearestVisibleFrame(toCenterOf: frame, in: visibleFrames) else {
            return clamped
        }
        return clamp(origin: clamped, windowSize: windowSize, into: nearest)
    }

    /// The visible frame whose centre lies closest to the centre of `frame`.
    public static func nearestVisibleFrame(
        toCenterOf frame: CGRect,
        in visibleFrames: [CGRect]
    ) -> CGRect? {
        guard !visibleFrames.isEmpty else { return nil }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        // CGRect.center requires macOS 15; midX/midY keep the macOS 13 target.
        return visibleFrames.min {
            distance($0.centerPoint, center) < distance($1.centerPoint, center)
        }
    }

    /// Contain `origin` fully inside `bounds`, preserving the window size.
    public static func clamp(
        origin: CGPoint,
        windowSize: CGSize,
        into bounds: CGRect
    ) -> CGPoint {
        CGPoint(
            x: min(max(origin.x, bounds.minX), max(bounds.minX, bounds.maxX - windowSize.width)),
            y: min(max(origin.y, bounds.minY), max(bounds.minY, bounds.maxY - windowSize.height))
        )
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}

extension CGRect {
    fileprivate var centerPoint: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}
