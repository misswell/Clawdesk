import AppKit
import Combine
import SwiftUI

@MainActor
public final class PermissionBubbleController: NSObject {
    private let model: ClawdeskModel
    private var panel: NSPanel?
    private var cancellables = Set<AnyCancellable>()

    public init(model: ClawdeskModel) {
        self.model = model
        super.init()
        model.$pendingPermissions.sink { [weak self] _ in
            self?.refresh()
        }.store(in: &cancellables)
        model.$pendingQuestions.sink { [weak self] _ in
            self?.refresh()
        }.store(in: &cancellables)
        model.preferences.$doNotDisturb.sink { [weak self] _ in
            self?.refresh()
        }.store(in: &cancellables)
        model.preferences.$language.sink { [weak self] _ in
            self?.refresh()
        }.store(in: &cancellables)
        model.preferences.$permissionBubbleFollowsPet.sink { [weak self] _ in
            self?.refresh()
        }.store(in: &cancellables)
        model.preferences.$permissionBubbleCorner.sink { [weak self] _ in
            self?.refresh()
        }.store(in: &cancellables)
        model.preferences.$windowOrigin.sink { [weak self] _ in
            guard self?.model.preferences.permissionBubbleFollowsPet == true else { return }
            self?.refresh()
        }.store(in: &cancellables)
    }

    public func refresh() {
        guard !model.preferences.doNotDisturb,
              !model.pendingPermissions.isEmpty || !model.pendingQuestions.isEmpty else {
            panel?.orderOut(nil)
            return
        }
        let view = PermissionBubbleView(model: model)
        let rowCount = model.pendingPermissions.count + model.pendingQuestions.reduce(0) { $0 + max(1, $1.questions.count) }
        let preferredHeight = min(620, max(180, 108 * rowCount + 64))
        if let panel {
            panel.contentView = NSHostingView(rootView: view)
            panel.setContentSize(NSSize(width: 410, height: preferredHeight))
        } else {
            let newPanel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 410, height: preferredHeight),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            newPanel.isOpaque = false
            newPanel.backgroundColor = .clear
            newPanel.hasShadow = true
            newPanel.level = .floating
            newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            newPanel.hidesOnDeactivate = false
            newPanel.contentView = NSHostingView(rootView: view)
            panel = newPanel
        }
        reposition()
        panel?.orderFrontRegardless()
    }

    private func reposition() {
        guard let panel else { return }
        if model.preferences.permissionBubbleFollowsPet,
           let petOrigin = model.preferences.windowOrigin {
            let screen = NSScreen.screens.first { $0.visibleFrame.contains(petOrigin) } ?? NSScreen.main
            guard let screen else { return }
            let frame = screen.visibleFrame
            let petWidth = PetSizing.bubbleAnchorWidth * CGFloat(model.preferences.petScale)
            let preferredX = petOrigin.x + petWidth + 12
            let x = min(max(frame.minX + 12, preferredX), frame.maxX - panel.frame.width - 12)
            let y = min(max(frame.minY + 12, petOrigin.y), frame.maxY - panel.frame.height - 12)
            panel.setFrameOrigin(NSPoint(x: x, y: y))
            return
        }
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let margin: CGFloat = 22
        let corner = model.preferences.permissionBubbleCorner
        let x = corner == .topLeft || corner == .bottomLeft
            ? frame.minX + margin
            : frame.maxX - panel.frame.width - margin
        let y = corner == .topLeft || corner == .topRight
            ? frame.maxY - panel.frame.height - margin
            : frame.minY + margin
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

private struct PermissionBubbleView: View {
    @ObservedObject var model: ClawdeskModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(.orange)
                Text(model.preferences.text("Permission review"))
                    .font(.headline)
                Spacer()
                Text("⌃⇧Y / ⌃⇧N")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(model.pendingQuestions) { prompt in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "questionmark.circle.fill")
                            .foregroundStyle(.blue)
                        Text(prompt.title)
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(model.preferences.text("Answer in Codex"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(prompt.questions) { question in
                        VStack(alignment: .leading, spacing: 4) {
                            if let header = question.header, !header.isEmpty {
                                Text(header)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            Text(question.question)
                                .font(.caption)
                                .lineLimit(4)
                            ForEach(question.options) { option in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(option.label).font(.caption2.weight(.semibold))
                                    if let description = option.description, !description.isEmpty {
                                        Text(description)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                                .padding(.leading, 8)
                            }
                        }
                    }
                    Text(prompt.agentID)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
            ForEach(model.pendingPermissions) { request in
                PermissionRequestCard(model: model, request: request)
            }
                }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.orange.opacity(0.45), lineWidth: 1))
        .padding(6)
    }
}

private struct PermissionRequestCard: View {
    @ObservedObject var model: ClawdeskModel
    let request: PermissionRequest
    @State private var expanded = false

    private var detailRows: [(String, String)] {
        [
            ("Action", request.action ?? ""),
            ("Command", request.command ?? ""),
            ("Input", request.input ?? "")
        ].filter { !$0.1.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(request.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(expanded ? nil : 2)
                Spacer()
                if !detailRows.isEmpty {
                    Button {
                        expanded.toggle()
                    } label: {
                        Image(systemName: expanded ? "chevron.up.circle" : "chevron.down.circle")
                    }
                    .buttonStyle(.plain)
                    .help(model.preferences.text(expanded ? "Hide details" : "Show details"))
                }
            }
            if expanded {
                ForEach(Array(detailRows.enumerated()), id: \.offset) { _, row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.0).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        Text(row.1)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else if let command = request.command, !command.isEmpty {
                Text(command)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack {
                Button(model.preferences.text("Deny")) { model.resolvePermission(id: request.id, decision: .deny) }
                    .keyboardShortcut(.init("n"), modifiers: [.control, .shift])
                Button(model.preferences.text("Allow")) { model.resolvePermission(id: request.id, decision: .allow) }
                    .keyboardShortcut(.init("y"), modifiers: [.control, .shift])
                    .buttonStyle(.borderedProminent)
                ForEach(request.suggestions) { suggestion in
                    Button(suggestion.label) { model.resolvePermission(id: request.id, decision: suggestion.decision) }
                        .buttonStyle(.bordered)
                }
                Spacer()
                Text(request.agentID)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
