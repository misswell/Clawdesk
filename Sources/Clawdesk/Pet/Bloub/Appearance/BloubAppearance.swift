import Foundation

/// The bloub customizer settings: body shape, body colour, resting
/// expression.
///
/// Appearance is deliberately separate from the agent state: `PetState`
/// decides WHICH animation plays, this decides what the pet looks like while
/// playing it. All values are persisted as stable string identifiers and
/// re-validated against the catalogues at resolution time, so a value written
/// by another version degrades to the default instead of crashing.
public struct BloubAppearance: Equatable, Sendable, Codable {
    public var shapeID: String
    /// `"theme"` keeps following the active theme palette.
    public var colorID: String
    /// `nil` or `"neutral"` is the face measured on the reference video.
    public var expressionID: String?

    public init(shapeID: String, colorID: String, expressionID: String?) {
        self.shapeID = shapeID
        self.colorID = colorID
        self.expressionID = expressionID
    }

    /// Follow the theme palette with the measured circle body and face.
    public static let standard = BloubAppearance(
        shapeID: BloubShapeID.circle.rawValue,
        colorID: BloubColorID.theme.rawValue,
        expressionID: nil
    )

    public var shape: BloubShape {
        BloubShapeCatalog.shape(BloubShapeID(rawValue: shapeID) ?? .circle)
    }

    public var shapeExists: Bool { BloubShapeID(rawValue: shapeID) != nil }

    public var color: BloubColorID? { BloubColorID(rawValue: colorID) }

    /// The resolved resting expression, or `nil` for the measured neutral face.
    public var expression: BloubExpression? {
        guard let id = expressionID.flatMap(BloubExpressionID.init(rawValue:)), id != .neutral
        else { return nil }
        return BloubExpression.expression(id)
    }

    /// Body colour override, or `nil` when the theme palette rules.
    public var bodyColor: BloubRGB? {
        color?.hex.map(BloubRGB.init(hex:))
    }
}
