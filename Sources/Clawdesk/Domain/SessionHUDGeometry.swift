import Foundation

/// The small, deterministic layout seam for the native Session HUD.
///
/// Keeping filtering, row limits, sizing, and screen clamping outside AppKit
/// makes the floating window cheap to update and straightforward to test.
public struct SessionHUDRows: Equatable, Sendable {
    public let sessions: [SessionSnapshot]
    public let overflowCount: Int

    public init(sessions: [SessionSnapshot], overflowCount: Int = 0) {
        self.sessions = sessions
        self.overflowCount = max(0, overflowCount)
    }
}

public enum SessionHUDVisibility {
    public static let hotZonePadding: CGFloat = 24
    public static let hideGrace: TimeInterval = 0.5

    public static func shouldShow(
        enabled: Bool,
        pinned: Bool,
        revealed: Bool,
        hasVisibleSessions: Bool
    ) -> Bool {
        enabled && hasVisibleSessions && (pinned || revealed)
    }

    public static func isInsideHotZone(
        _ point: CGPoint,
        petFrame: CGRect,
        hudFrame: CGRect?,
        padding: CGFloat = hotZonePadding
    ) -> Bool {
        contains(point, in: petFrame, padding: padding)
            || (hudFrame.map { contains(point, in: $0, padding: padding) } ?? false)
    }

    public static func shouldKeepVisible(
        pinned: Bool,
        petHovering: Bool,
        hudHovering: Bool,
        pointerInHotZone: Bool
    ) -> Bool {
        pinned || petHovering || hudHovering || pointerInHotZone
    }

    private static func contains(_ point: CGPoint, in rect: CGRect, padding: CGFloat) -> Bool {
        guard rect.width > 0, rect.height > 0 else { return false }
        return rect.insetBy(dx: -max(0, padding), dy: -max(0, padding)).contains(point)
    }
}

public enum SessionHUDGeometry {
    /// The upstream keeps five rows when status labels are enabled. The native
    /// HUD always renders those labels, so the same limit avoids hiding active
    /// agents behind an overflow row on ordinary multi-agent work.
    public static let maximumVisibleRows = 5
    public static let rowHeight: CGFloat = 42
    public static let contentWidth: CGFloat = 286
    public static let horizontalPadding: CGFloat = 12
    public static let verticalPadding: CGFloat = 8
    public static let petGap: CGFloat = 8
    public static let edgeMargin: CGFloat = 10
    public static let usageChipHeight: CGFloat = 18
    public static let statusChipHeight: CGFloat = 18
    public static let usageChipMinWidth: CGFloat = 34
    public static let usageChipGap: CGFloat = 6

    public static func usageChipRect(
        in rowRect: CGRect,
        width: CGFloat,
        rightInset: CGFloat = 0
    ) -> CGRect {
        let chipWidth = max(usageChipMinWidth, width)
        return CGRect(
            x: rowRect.maxX - max(0, rightInset) - chipWidth,
            y: rowRect.midY - usageChipHeight / 2,
            width: chipWidth,
            height: usageChipHeight
        )
    }

    public static func rows(
        from sessions: [SessionSnapshot],
        maximumVisibleRows: Int = maximumVisibleRows
    ) -> SessionHUDRows {
        let limit = max(1, maximumVisibleRows)
        let eligible = sessions.filter { $0.state != .sleeping }
        return SessionHUDRows(
            sessions: Array(eligible.prefix(limit)),
            overflowCount: max(0, eligible.count - limit)
        )
    }

    public static func contentSize(for rows: SessionHUDRows) -> CGSize {
        let rowCount = rows.sessions.count + (rows.overflowCount > 0 ? 1 : 0)
        guard rowCount > 0 else { return .zero }
        return CGSize(
            width: contentWidth,
            height: verticalPadding * 2 + CGFloat(rowCount) * rowHeight
        )
    }

    /// Places the HUD below the pet when possible, otherwise above it, while
    /// keeping the complete panel inside the current screen's visible area.
    public static func frame(
        for petFrame: CGRect,
        workArea: CGRect,
        contentSize: CGSize,
        gap: CGFloat = petGap,
        margin: CGFloat = edgeMargin
    ) -> CGRect {
        guard contentSize.width > 0, contentSize.height > 0,
              workArea.width >= contentSize.width + margin * 2,
              workArea.height >= contentSize.height + margin * 2 else {
            return .zero
        }

        let minX = workArea.minX + margin
        let maxX = workArea.maxX - margin - contentSize.width
        let x = min(max(petFrame.midX - contentSize.width / 2, minX), maxX)

        let belowY = petFrame.minY - gap - contentSize.height
        if belowY >= workArea.minY + margin {
            return CGRect(x: x, y: belowY, width: contentSize.width, height: contentSize.height)
        }

        let aboveY = petFrame.maxY + gap
        let maxY = workArea.maxY - margin - contentSize.height
        let y = min(max(aboveY, workArea.minY + margin), maxY)
        return CGRect(x: x, y: y, width: contentSize.width, height: contentSize.height)
    }
}
