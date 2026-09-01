import AppKit

/// A compact, layer-free session summary rendered directly with AppKit.
/// It stays dormant until the user clicks the pet, so idle Clawdesk pays no
/// renderer or browser-runtime cost for the HUD.
@MainActor
public final class SessionHUDView: NSView {
    public var rows = SessionHUDRows(sessions: []) {
        didSet { needsDisplay = true }
    }
    public var isPinned = false {
        didSet { needsDisplay = true }
    }
    public var showContextUsage = true {
        didSet { needsDisplay = true }
    }
    public var language = "en" {
        didSet { needsDisplay = true }
    }

    public var onSessionSelected: ((SessionSnapshot) -> Void)?
    public var onOverflowSelected: (() -> Void)?
    public var onPinToggled: ((Bool) -> Void)?
    public var onHoverChanged: ((Bool) -> Void)?

    private let cornerRadius: CGFloat = 14
    private var trackingArea: NSTrackingArea?

    public override var isOpaque: Bool { false }

    public override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    public override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    public override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.setShouldAntialias(true)

        let panelPath = CGPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
        context.addPath(panelPath)
        context.setFillColor(NSColor.windowBackgroundColor.withAlphaComponent(0.94).cgColor)
        context.fillPath()
        context.addPath(panelPath)
        context.setStrokeColor(NSColor.separatorColor.withAlphaComponent(0.8).cgColor)
        context.setLineWidth(1)
        context.strokePath()
        drawPin(in: context)

        let rowHeight = SessionHUDGeometry.rowHeight
        let top = bounds.maxY - SessionHUDGeometry.verticalPadding
        for (index, session) in rows.sessions.enumerated() {
            let rowTop = top - CGFloat(index) * rowHeight
            let rowRect = CGRect(
                x: SessionHUDGeometry.horizontalPadding,
                y: rowTop - rowHeight + 2,
                width: bounds.width - SessionHUDGeometry.horizontalPadding * 2,
                height: rowHeight - 4
            )
            draw(
                session: session,
                in: rowRect,
                rightInset: index == 0 ? 28 : 0,
                context: context
            )
        }

        if rows.overflowCount > 0 {
            let index = rows.sessions.count
            let rowTop = top - CGFloat(index) * rowHeight
            let rowRect = CGRect(
                x: SessionHUDGeometry.horizontalPadding,
                y: rowTop - rowHeight + 2,
                width: bounds.width - SessionHUDGeometry.horizontalPadding * 2,
                height: rowHeight - 4
            )
            let label = "+" + String(rows.overflowCount) + " more · Open Dashboard"
            drawText(
                label,
                at: NSPoint(x: rowRect.minX + 8, y: rowRect.midY - 6),
                font: NSFont.systemFont(ofSize: 11, weight: .medium),
                color: .secondaryLabelColor
            )
        }
        context.restoreGState()
    }

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if pinButtonRect.contains(point) {
            onPinToggled?(!isPinned)
            return
        }
        let top = bounds.maxY - SessionHUDGeometry.verticalPadding
        let index = Int((top - point.y) / SessionHUDGeometry.rowHeight)
        if index >= 0, index < rows.sessions.count {
            onSessionSelected?(rows.sessions[index])
        } else if rows.overflowCount > 0, index == rows.sessions.count {
            onOverflowSelected?()
        }
    }

    private var pinButtonRect: CGRect {
        CGRect(x: bounds.maxX - 28, y: bounds.maxY - 25, width: 16, height: 16)
    }

    private func drawPin(in context: CGContext) {
        guard let image = NSImage(
            systemSymbolName: isPinned ? "pin.fill" : "pin",
            accessibilityDescription: nil
        ) else { return }
        image.draw(
            in: pinButtonRect,
            from: .zero,
            operation: .sourceOver,
            fraction: isPinned ? 1 : 0.55
        )
    }

    private func draw(
        session: SessionSnapshot,
        in rect: CGRect,
        rightInset: CGFloat,
        context: CGContext
    ) {
        let dotRect = CGRect(x: rect.minX + 4, y: rect.midY - 5, width: 10, height: 10)
        context.setFillColor(color(for: session.state).cgColor)
        context.fillEllipse(in: dotRect)

        let iconRect = CGRect(
            x: dotRect.maxX + 8,
            y: rect.midY - 12,
            width: 24,
            height: 24
        )
        AgentIconRenderer.draw(
            AgentRegistry.icon(for: session.agentID),
            in: iconRect,
            context: context
        )

        let titleFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let textX = iconRect.maxX + 8
        let status = SessionHUDPresentation.status(for: session)
        let statusFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
        let statusRect: CGRect?
        let usage = showContextUsage
            ? ContextUsageFormatter.presentation(for: session.contextUsage)
            : nil
        let usageRect: CGRect?
        var rightEdge = rect.maxX - rightInset
        if let usage {
            let chipFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
            let measured = (usage.label as NSString).size(withAttributes: [.font: chipFont]).width
            let chipWidth = max(
                SessionHUDGeometry.usageChipMinWidth,
                ceil(measured) + SessionHUDGeometry.usageChipGap * 2
            )
            let chipRect = SessionHUDGeometry.usageChipRect(
                in: rect,
                width: chipWidth,
                rightInset: rightInset
            )
            drawUsageChip(usage, in: chipRect, context: context)
            usageRect = chipRect
            rightEdge = chipRect.minX - SessionHUDGeometry.usageChipGap
        } else {
            usageRect = nil
        }

        if let status {
            let label = localized(status.label)
            let measured = (label as NSString).size(withAttributes: [.font: statusFont]).width
            let chipWidth = ceil(measured) + SessionHUDGeometry.usageChipGap * 2
            let chipRect = CGRect(
                x: rightEdge - chipWidth,
                y: rect.midY - SessionHUDGeometry.statusChipHeight / 2,
                width: chipWidth,
                height: SessionHUDGeometry.statusChipHeight
            )
            drawStatusChip(status, label: label, in: chipRect, context: context)
            statusRect = chipRect
        } else {
            statusRect = nil
        }

        let titleMaximumX = statusRect?.minX ?? usageRect?.minX ?? rect.maxX - rightInset
        let title = clippedToWidth(
            session.title.isEmpty ? session.agentID : session.title,
            maximumWidth: max(20, titleMaximumX - SessionHUDGeometry.usageChipGap - textX),
            font: titleFont
        )
        let detailFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let detail = clippedToWidth(
            session.folder ?? session.lastEvent,
            maximumWidth: max(20, titleMaximumX - SessionHUDGeometry.usageChipGap - textX),
            font: detailFont
        )
        drawText(
            title,
            at: NSPoint(x: textX, y: rect.midY + 1),
            font: titleFont,
            color: .labelColor
        )
        drawText(
            detail,
            at: NSPoint(x: textX, y: rect.midY - 13),
            font: detailFont,
            color: .secondaryLabelColor
        )
    }

    private func drawStatusChip(
        _ status: SessionHUDStatus,
        label: String,
        in rect: CGRect,
        context: CGContext
    ) {
        let color = statusColor(for: status.kind)
        let path = CGPath(
            roundedRect: rect,
            cornerWidth: rect.height / 2,
            cornerHeight: rect.height / 2,
            transform: nil
        )
        context.addPath(path)
        context.setFillColor(color.withAlphaComponent(0.18).cgColor)
        context.fillPath()
        drawText(
            label,
            at: NSPoint(x: rect.minX + SessionHUDGeometry.usageChipGap, y: rect.minY + 3),
            font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            color: color
        )
    }

    private func drawUsageChip(
        _ presentation: ContextUsagePresentation,
        in rect: CGRect,
        context: CGContext
    ) {
        let color: NSColor
        switch presentation.severity {
        case .neutral: color = .controlAccentColor
        case .warm: color = .systemOrange
        case .hot: color = .systemRed
        }
        let path = CGPath(
            roundedRect: rect,
            cornerWidth: rect.height / 2,
            cornerHeight: rect.height / 2,
            transform: nil
        )
        context.addPath(path)
        context.setFillColor(color.withAlphaComponent(0.18).cgColor)
        context.fillPath()
        context.addPath(path)
        context.setStrokeColor(color.withAlphaComponent(0.42).cgColor)
        context.setLineWidth(0.75)
        context.strokePath()
        drawText(
            presentation.label,
            at: NSPoint(x: rect.minX + SessionHUDGeometry.usageChipGap, y: rect.minY + 3),
            font: NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold),
            color: color
        )
    }

    private func drawText(
        _ text: String,
        at point: NSPoint,
        font: NSFont,
        color: NSColor
    ) {
        (text as NSString).draw(
            at: point,
            withAttributes: [
                .font: font,
                .foregroundColor: color
            ]
        )
    }

    private func clippedToWidth(_ value: String, maximumWidth: CGFloat, font: NSFont) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        guard (normalized as NSString).size(withAttributes: attributes).width > maximumWidth else {
            return normalized
        }

        var prefix = ""
        for character in normalized {
            let candidate = prefix + String(character) + "…"
            if (candidate as NSString).size(withAttributes: attributes).width > maximumWidth {
                break
            }
            prefix.append(character)
        }
        return prefix.isEmpty ? "…" : prefix + "…"
    }

    private func color(for state: PetState) -> NSColor {
        switch state {
        case .error: return .systemRed
        case .attention, .miniHappy: return .systemGreen
        case .notification, .miniAlert: return .systemOrange
        case .typing, .thinking, .building, .juggling: return .systemBlue
        case .sweeping, .carrying: return .systemPurple
        default: return .secondaryLabelColor
        }
    }

    private func statusColor(for kind: SessionHUDStatusKind) -> NSColor {
        switch kind {
        case .thinking: return .systemIndigo
        case .working: return .systemGreen
        case .building: return .systemBlue
        case .juggling: return .systemPurple
        case .compacting: return .systemPurple
        case .preparing: return .systemOrange
        case .complete: return .systemGreen
        case .attention: return .systemOrange
        case .error: return .systemRed
        }
    }

    private func localized(_ value: String) -> String {
        Localization.string(value, language: language) ?? value
    }
}

/// Owns the optional floating HUD panel and its short reveal lifetime.
@MainActor
public final class SessionHUDWindowController {
    private let model: ClawdeskModel
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private var isRevealed = false
    private var isEnabled = true
    private var isPinned = false
    private var showContextUsage = true
    private var petHovering = false
    private var hudHovering = false
    private var lastPetWindowFrame = NSRect.zero

    public var onSessionSelected: ((SessionSnapshot) -> Void)?
    public var onOverflowSelected: (() -> Void)?

    public init(model: ClawdeskModel) {
        self.model = model
    }

    public func reveal(petWindowFrame: NSRect) {
        lastPetWindowFrame = petWindowFrame
        isRevealed = true
        update(petWindowFrame: petWindowFrame, enabled: isEnabled)
        scheduleHide()
    }

    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if !enabled {
            hide()
        } else {
            refresh()
        }
    }

    public func setPinned(_ pinned: Bool) {
        isPinned = pinned
        if pinned {
            hideTask?.cancel()
            hideTask = nil
        }
        refresh()
        if !pinned { scheduleHide() }
    }

    public func setShowContextUsage(_ show: Bool) {
        showContextUsage = show
        refresh()
    }

    public func setPetHover(_ hovering: Bool) {
        petHovering = hovering
        if hovering {
            hideTask?.cancel()
            hideTask = nil
        } else {
            scheduleHide()
        }
    }

    private func setHUDHover(_ hovering: Bool) {
        hudHovering = hovering
        if hovering {
            hideTask?.cancel()
            hideTask = nil
        } else {
            scheduleHide()
        }
    }

    public func update(petWindowFrame: NSRect, enabled: Bool = true) {
        lastPetWindowFrame = petWindowFrame
        isEnabled = enabled
        refresh()
    }

    private func refresh() {
        let rows = SessionHUDGeometry.rows(from: model.sessions)
        guard SessionHUDVisibility.shouldShow(
            enabled: isEnabled,
            pinned: isPinned,
            revealed: isRevealed,
            hasVisibleSessions: !rows.sessions.isEmpty
        ), !lastPetWindowFrame.equalTo(.zero),
        let screen = screen(for: lastPetWindowFrame) else {
            panel?.orderOut(nil)
            return
        }
        let size = SessionHUDGeometry.contentSize(for: rows)
        guard !size.equalTo(.zero) else {
            panel?.orderOut(nil)
            return
        }
        let frame = SessionHUDGeometry.frame(
            for: lastPetWindowFrame,
            workArea: screen.visibleFrame,
            contentSize: size
        )
        guard !frame.equalTo(.zero) else {
            panel?.orderOut(nil)
            return
        }
        let view = ensurePanel(size: size)
        view.frame = NSRect(origin: .zero, size: size)
        view.autoresizingMask = [.width, .height]
        view.rows = rows
        view.isPinned = isPinned
        view.showContextUsage = showContextUsage
        view.language = model.preferences.resolvedLanguage
        panel?.setContentSize(size)
        panel?.setFrame(frame, display: true)
        panel?.orderFrontRegardless()
    }

    public func hide() {
        hideTask?.cancel()
        hideTask = nil
        isRevealed = false
        panel?.orderOut(nil)
    }

    public func stop() {
        hide()
        panel?.close()
        panel = nil
    }

    private func ensurePanel(size: CGSize) -> SessionHUDView {
        if let view = panel?.contentView as? SessionHUDView {
            return view
        }
        let view = SessionHUDView(frame: NSRect(origin: .zero, size: size))
        view.onSessionSelected = { [weak self] session in
            self?.onSessionSelected?(session)
        }
        view.onOverflowSelected = { [weak self] in
            self?.onOverflowSelected?()
        }
        view.onPinToggled = { [weak self] pinned in
            self?.model.preferences.sessionHUDPinned = pinned
        }
        view.onHoverChanged = { [weak self] hovering in
            self?.setHUDHover(hovering)
        }
        let newPanel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = true
        newPanel.level = .floating
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        newPanel.hidesOnDeactivate = false
        newPanel.isMovableByWindowBackground = false
        newPanel.contentView = view
        panel = newPanel
        return view
    }

    private func scheduleHide() {
        guard isRevealed, !isPinned else { return }
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(SessionHUDVisibility.hideGrace))
            guard let self, !Task.isCancelled else { return }
            let pointerInHotZone: Bool
            if let panel = self.panel {
                pointerInHotZone = SessionHUDVisibility.isInsideHotZone(
                    NSEvent.mouseLocation,
                    petFrame: self.lastPetWindowFrame,
                    hudFrame: panel.frame
                )
            } else {
                pointerInHotZone = false
            }
            guard !SessionHUDVisibility.shouldKeepVisible(
                pinned: self.isPinned,
                petHovering: self.petHovering,
                hudHovering: self.hudHovering,
                pointerInHotZone: pointerInHotZone
            ) else {
                self.scheduleHide()
                return
            }
            self.hide()
        }
    }

    private func screen(for petFrame: NSRect) -> NSScreen? {
        NSScreen.screens.first { $0.frame.intersects(petFrame) } ?? NSScreen.main
    }
}
