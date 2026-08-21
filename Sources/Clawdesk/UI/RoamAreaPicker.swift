import AppKit
import SwiftUI

/// Full-screen overlay that lets the user drag a rectangle on the display where
/// Free Roam may wander. The selected rectangle is returned as work-area
/// fractions, matching the upstream roam-fence file.
@MainActor
public final class RoamAreaPickerController {
    private var panel: NSPanel?
    private let completion: (RoamArea?) -> Void

    public init(completion: @escaping (RoamArea?) -> Void) {
        self.completion = completion
    }

    public func present(on screen: NSScreen, initial: RoamArea?) {
        let picker = RoamAreaPickerView(
            screen: screen,
            initial: initial,
            onCancel: { [weak self] in self?.close() },
            onConfirm: { [weak self] area in
                guard let self else { return }
                self.close()
                self.completion(area)
            }
        )
        let hosting = NSHostingController(rootView: picker)
        let panel = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.contentViewController = hosting
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.panel = panel
    }

    private func close() {
        panel?.close()
        panel = nil
    }
}

private struct RoamAreaPickerView: View {
    let screen: NSScreen
    let initial: RoamArea?
    let onCancel: () -> Void
    let onConfirm: (RoamArea) -> Void

    @State private var selectionStart: CGPoint?
    @State private var selection: CGRect?

    var body: some View {
        GeometryReader { _ in
            ZStack(alignment: .top) {
                Color.black.opacity(0.25)
                    .ignoresSafeArea()
                if let selection {
                    Rectangle()
                        .fill(Color.orange.opacity(0.18))
                        .overlay(Rectangle().stroke(Color.orange, lineWidth: 2))
                        .frame(width: selection.width, height: selection.height)
                        .position(x: selection.midX, y: selection.midY)
                }
                HStack(spacing: 10) {
                    Button("Confirm") { commit() }
                        .buttonStyle(.borderedProminent)
                    Button("Cancel", action: onCancel)
                        .buttonStyle(.bordered)
                    if initial != nil {
                        Button("Remove custom area") { onConfirm(RoamArea(enabled: false)) }
                            .buttonStyle(.bordered)
                    }
                }
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        if selectionStart == nil { selectionStart = value.startLocation }
                        selection = Self.rect(from: selectionStart ?? value.startLocation, to: value.location)
                    }
                    .onEnded { value in
                        selection = Self.rect(from: selectionStart ?? value.startLocation, to: value.location)
                        selectionStart = nil
                    }
            )
        }
    }

    private static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(a.x - b.x),
            height: abs(a.y - b.y)
        )
    }

    private func commit() {
        guard let selection else { return }
        // SwiftUI local coordinates are top-left; the screen frame is bottom-left.
        let full = screen.frame
        let visible = screen.visibleFrame
        let screenMinX = full.minX + selection.minX
        let screenMaxX = full.minX + selection.maxX
        let screenMaxY = full.maxY - selection.minY
        let screenMinY = full.maxY - selection.maxY
        let left = (screenMinX - visible.minX) / visible.width
        let right = (screenMaxX - visible.minX) / visible.width
        let top = (screenMaxY - visible.minY) / visible.height
        let bottom = (screenMinY - visible.minY) / visible.height
        let area = RoamArea(enabled: true, left: left, top: top, right: right, bottom: bottom)
        guard left >= 0, top >= 0, right <= 1, bottom <= 1, left < right, top < bottom else { return }
        onConfirm(area)
    }
}
