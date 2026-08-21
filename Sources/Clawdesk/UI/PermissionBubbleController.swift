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
    }

    public func refresh() {
        guard !model.preferences.doNotDisturb,
              !model.pendingPermissions.isEmpty || !model.pendingQuestions.isEmpty else {
            panel?.orderOut(nil)
            return
        }
        let view = PermissionBubbleView(model: model)
        let rowCount = model.pendingPermissions.count + model.pendingQuestions.reduce(0) { $0 + max(1, $1.questions.count) }
        if let panel {
            panel.contentView = NSHostingView(rootView: view)
            panel.setContentSize(NSSize(width: 390, height: min(620, 108 * rowCount + 36)))
        } else {
            let newPanel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 390, height: 180),
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
        guard let panel, let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: frame.maxX - panel.frame.width - 22, y: frame.minY + 22))
    }
}

private struct PermissionBubbleView: View {
    @ObservedObject var model: ClawdeskModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(.orange)
                Text("Permission review")
                    .font(.headline)
                Spacer()
                Text("⌃⇧Y / ⌃⇧N")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            ForEach(model.pendingQuestions) { prompt in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "questionmark.circle.fill")
                            .foregroundStyle(.blue)
                        Text(prompt.title)
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("Answer in Codex")
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
                VStack(alignment: .leading, spacing: 8) {
                    Text(request.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    if let command = request.command, !command.isEmpty {
                        Text(command)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    HStack {
                        Button("Deny") { model.resolvePermission(id: request.id, decision: .deny) }
                            .keyboardShortcut(.init("n"), modifiers: [.control, .shift])
                        Button("Allow") { model.resolvePermission(id: request.id, decision: .allow) }
                            .keyboardShortcut(.init("y"), modifiers: [.control, .shift])
                            .buttonStyle(.borderedProminent)
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
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.orange.opacity(0.45), lineWidth: 1))
        .padding(6)
    }
}
