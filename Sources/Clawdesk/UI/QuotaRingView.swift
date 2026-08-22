import AppKit

/// Draws the pet-attached quota "Orbit" coins: one coin per provider, each
/// with an outer ring (rolling window) and an optional inner ring (weekly),
/// plus a "+N" overflow row.
@MainActor
public final class QuotaRingView: NSView {
    public var coins: [QuotaCoin] = [] {
        didSet { needsDisplay = true }
    }
    public var overflow: Int = 0 {
        didSet { needsDisplay = true }
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setShouldAntialias(true)
        for (index, coin) in coins.enumerated() {
            let rect = QuotaRingGeometry.coinRect(index: index, size: bounds.size)
            drawCoin(coin, in: rect, context: context)
        }
        if overflow > 0 {
            ("+" + String(overflow) as NSString).draw(
                at: NSPoint(x: QuotaRingGeometry.coinSize + 6, y: 2),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
            )
        }
    }

    private func drawCoin(_ coin: QuotaCoin, in rect: CGRect, context: CGContext) {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outerRadius = rect.width / 2 - 3
        let innerRadius = outerRadius * 0.62
        drawRing(center: center, radius: outerRadius, percent: coin.outerPercent, width: 6, context: context)
        if let innerPercent = coin.innerPercent {
            drawRing(center: center, radius: innerRadius, percent: innerPercent, width: 5, context: context)
        }
        (String(coin.outerPercent) + "%" as NSString).draw(
            at: NSPoint(x: rect.maxX + 5, y: rect.midY - 7),
            withAttributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.labelColor
            ]
        )
    }

    private func drawRing(center: CGPoint, radius: CGFloat, percent: Int, width: CGFloat, context: CGContext) {
        let start = -CGFloat.pi / 2
        let end = start + 2 * CGFloat.pi * CGFloat(min(100, max(0, percent))) / 100
        let path = CGMutablePath()
        path.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
        context.addPath(path)
        context.setStrokeColor(color(for: percent))
        context.setLineWidth(width)
        context.setLineCap(.round)
        context.strokePath()
    }

    private func color(for percent: Int) -> CGColor {
        let color: NSColor = percent > 85 ? .systemRed : percent >= 60 ? .systemOrange : .systemGreen
        return color.cgColor
    }
}

/// Transparent window attached to the pet's side that shows the quota coins.
/// Translated from the upstream "Orbit" ring window semantics: hidden when
/// there is nothing to draw, repositioned with the pet, and clear of the
/// right-entering permission bubble.
@MainActor
public final class QuotaRingWindowController {
    private let model: ClawdeskModel
    private var panel: NSPanel?

    public init(model: ClawdeskModel) {
        self.model = model
    }

    public func update(petWindowFrame: NSRect) {
        let result = QuotaRingGeometry.coins(from: model.quotaReports, show: model.preferences.showQuotaRing)
        guard !result.coins.isEmpty else {
            panel?.orderOut(nil)
            return
        }
        let size = QuotaRingGeometry.clusterSize(coinCount: result.coins.count, overflow: result.overflow)
        if panel == nil {
            let newPanel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            newPanel.isOpaque = false
            newPanel.backgroundColor = .clear
            newPanel.hasShadow = false
            newPanel.level = .floating
            newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            newPanel.hidesOnDeactivate = false
            newPanel.contentView = QuotaRingView(frame: NSRect(x: 0, y: 0, width: size.width, height: size.height))
            panel = newPanel
        }
        if let view = panel?.contentView as? QuotaRingView {
            view.coins = result.coins
            view.overflow = result.overflow
        }
        panel?.setContentSize(size)
        let x = petWindowFrame.minX - size.width - QuotaRingGeometry.petGap
        let y = petWindowFrame.midY - size.height / 2
        panel?.setFrameOrigin(NSPoint(x: max(QuotaRingGeometry.edgeMargin, x), y: max(QuotaRingGeometry.edgeMargin, y)))
        panel?.orderFrontRegardless()
    }

    public func hide() {
        panel?.orderOut(nil)
    }
}
