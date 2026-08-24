import AppKit

/// A compact, layer-free session summary rendered directly with AppKit.
/// It stays dormant until the user clicks the pet, so idle Clawdesk pays no
/// renderer or browser-runtime cost for the HUD.
@MainActor
public final class SessionHUDView: NSView {
    public var rows = SessionHUDRows(sessions: []) {
        didSet { needsDisplay = true }
    }

    public var onSessionSelected: ((SessionSnapshot) -> Void)?
    public var onOverflowSelected: (() -> Void)?

    private let cornerRadius: CGFloat = 14

    public override var isOpaque: Bool { false }

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
            draw(session: session, in: rowRect, context: context)
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
        let top = bounds.maxY - SessionHUDGeometry.verticalPadding
        let index = Int((top - point.y) / SessionHUDGeometry.rowHeight)
        if index >= 0, index < rows.sessions.count {
            onSessionSelected?(rows.sessions[index])
        } else if rows.overflowCount > 0, index == rows.sessions.count {
            onOverflowSelected?()
        }
    }

    private func draw(session: SessionSnapshot, in rect: CGRect, context: CGContext) {
        let dotRect = CGRect(x: rect.minX + 4, y: rect.midY - 5, width: 10, height: 10)
        context.setFillColor(color(for: session.state).cgColor)
        context.fillEllipse(in: dotRect)

        let title = clipped(
            session.title.isEmpty ? session.agentID : session.title,
            maximumLength: 30
        )
        let detail = clipped(
            session.folder ?? session.lastEvent,
            maximumLength: 36
        )
        drawText(
            title + " · " + session.state.displayName,
            at: NSPoint(x: dotRect.maxX + 8, y: rect.midY + 1),
            font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            color: .labelColor
        )
        drawText(
            detail,
            at: NSPoint(x: dotRect.maxX + 8, y: rect.midY - 13),
            font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            color: .secondaryLabelColor
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

    private func clipped(_ value: String, maximumLength: Int) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > maximumLength else { return normalized }
        return String(normalized.prefix(maximumLength - 1)) + "…"
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
}

/// Owns the optional floating HUD panel and its short reveal lifetime.
@MainActor
public final class SessionHUDWindowController {
    private let model: ClawdeskModel
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private var isRevealed = false

    public var onSessionSelected: ((SessionSnapshot) -> Void)?
    public var onOverflowSelected: (() -> Void)?

    public init(model: ClawdeskModel) {
        self.model = model
    }

    public func reveal(petWindowFrame: NSRect) {
        isRevealed = true
        update(petWindowFrame: petWindowFrame)
        scheduleHide()
    }

    public func update(petWindowFrame: NSRect, enabled: Bool = true) {
        guard isRevealed, enabled else {
            panel?.orderOut(nil)
            return
        }
        let rows = SessionHUDGeometry.rows(from: model.sessions)
        let size = SessionHUDGeometry.contentSize(for: rows)
        guard !size.equalTo(.zero), let screen = screen(for: petWindowFrame) else {
            panel?.orderOut(nil)
            return
        }
        let frame = SessionHUDGeometry.frame(
            for: petWindowFrame,
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
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard let self, !Task.isCancelled else { return }
            self.hide()
        }
    }

    private func screen(for petFrame: NSRect) -> NSScreen? {
        NSScreen.screens.first { $0.frame.intersects(petFrame) } ?? NSScreen.main
    }
}
