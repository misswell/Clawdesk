import CoreGraphics
import Foundation

/// The roam fence limits where Free Roam can walk. Edges are fractions of the
/// screen work area (`0` = left/top edge, `1` = right/bottom edge); a missing
/// edge defaults to the full range, mirroring upstream `~/.clawd/roam-area.json`.
public struct RoamArea: Equatable, Sendable {
    public let enabled: Bool
    public let left: Double?
    public let top: Double?
    public let right: Double?
    public let bottom: Double?

    public init(
        enabled: Bool = true,
        left: Double? = nil,
        top: Double? = nil,
        right: Double? = nil,
        bottom: Double? = nil
    ) {
        self.enabled = enabled
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }

    /// Parses the documented JSON shape. Returns nil for malformed input so the
    /// caller can keep the previous fence instead of roaming the full area.
    public init?(json: [String: Any]) {
        guard let enabled = json["enabled"] as? Bool else { return nil }
        // A present edge that is not a finite number (for example a string)
        // makes the whole fence invalid rather than silently defaulting it.
        for key in ["left", "top", "right", "bottom"] {
            if let value = json[key], (value as? NSNumber)?.doubleValue.isFinite != true {
                return nil
            }
        }
        func edge(_ key: String) -> Double? {
            guard let value = json[key] else { return nil }
            return (value as? NSNumber)?.doubleValue
        }
        let left = edge("left") ?? 0
        let top = edge("top") ?? 0
        let right = edge("right") ?? 1
        let bottom = edge("bottom") ?? 1
        guard left >= 0, top >= 0, right <= 1, bottom <= 1, left < right, top < bottom else {
            return nil
        }
        self.init(
            enabled: enabled,
            left: json["left"] != nil ? left : nil,
            top: json["top"] != nil ? top : nil,
            right: json["right"] != nil ? right : nil,
            bottom: json["bottom"] != nil ? bottom : nil
        )
    }

    public var wireObject: [String: Any] {
        var object: [String: Any] = ["enabled": enabled]
        if let left { object["left"] = left }
        if let top { object["top"] = top }
        if let right { object["right"] = right }
        if let bottom { object["bottom"] = bottom }
        return object
    }
}

/// Picks a whole-window target inside the work area, optionally confined to a
/// fence rectangle. Returns nil when no valid position exists (the window is
/// larger than the area on either axis), in which case roaming holds.
///
/// Semantics mirror upstream `roam.js`: the target keeps a 15% margin band
/// from the work-area edges, must be at least 100 px (euclidean) away from
/// the current origin, and after 8 random attempts the farthest of the four
/// area corners wins so long treks stay likely.
public enum RoamPlanner {
    public static let edgeMarginFraction: CGFloat = 0.15
    public static let minimumHopDistance: CGFloat = 100
    public static let maxAttempts = 8

    public static func nextTarget(
        currentOrigin: CGPoint,
        windowSize: CGSize,
        workArea: CGRect,
        fence: RoamArea?,
        random: (ClosedRange<CGFloat>) -> CGFloat
    ) -> CGPoint? {
        var rect = workArea.insetBy(
            dx: workArea.width * edgeMarginFraction,
            dy: workArea.height * edgeMarginFraction
        )
        if rect.width <= 0 || rect.height <= 0 { rect = workArea }
        if let fence, fence.enabled {
            let x0 = workArea.minX + workArea.width * CGFloat(fence.left ?? 0)
            let x1 = workArea.minX + workArea.width * CGFloat(fence.right ?? 1)
            let y0 = workArea.minY + workArea.height * CGFloat(fence.top ?? 0)
            let y1 = workArea.minY + workArea.height * CGFloat(fence.bottom ?? 1)
            rect = CGRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0))
        }
        let maxX = rect.maxX - windowSize.width
        let maxY = rect.maxY - windowSize.height
        guard maxX >= rect.minX, maxY >= rect.minY else { return nil }
        let candidates = (0..<maxAttempts).map { _ in
            CGPoint(x: random(rect.minX...maxX), y: random(rect.minY...maxY))
        }
        let valid = candidates.filter { origin in
            let dx = origin.x - currentOrigin.x
            let dy = origin.y - currentOrigin.y
            return (dx * dx + dy * dy) >= minimumHopDistance * minimumHopDistance
        }
        if let picked = valid.randomElement() { return picked }
        // Upstream's fallback: the farthest area corner from the current
        // origin keeps the walk meaningful when the fence is small.
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: maxY),
            CGPoint(x: maxX, y: maxY)
        ]
        return corners.max { lhs, rhs in
            distance(lhs, currentOrigin) < distance(rhs, currentOrigin)
        }
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}
