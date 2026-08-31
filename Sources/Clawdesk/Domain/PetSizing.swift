import CoreGraphics

/// Shared physical sizing for the transparent pet window and controls that
/// position themselves relative to it.
///
/// The renderer still speaks its 220-point logical canvas. The window's base
/// footprint is intentionally 120 points so the visible pet is half the size
/// of the original 240-point presentation, including at the smallest setting.
enum PetSizing {
    static let baseWindowSize: CGFloat = 120
    static let bubbleAnchorWidth: CGFloat = 95
    static let minimumScale = 0.4
    static let maximumScale = 2.0
    static let defaultScale = 1.0
    static let scaleRange: ClosedRange<Double> = minimumScale...maximumScale

    static func clampedScale(_ scale: Double) -> Double {
        min(maximumScale, max(minimumScale, scale))
    }
}
