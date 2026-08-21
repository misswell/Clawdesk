import SwiftUI

public struct DashboardView: View {
    @ObservedObject private var model: ClawdeskModel

    public init(model: ClawdeskModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !model.quotaReports.isEmpty {
                quotaStrip
                Divider()
            } else {
                Divider()
            }
            HStack(spacing: 0) {
                sessionsPane
                Divider()
                eventPane
            }
        }
        .frame(minWidth: 860, minHeight: 560)
    }

    private var quotaStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(model.quotaReports) { report in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(report.displayName)
                            .font(.caption.weight(.semibold))
                        ForEach(report.buckets) { bucket in
                            HStack(spacing: 8) {
                                Text(bucket.displayWindow)
                                    .font(.caption2.monospaced())
                                    .frame(width: 42, alignment: .leading)
                                ProgressView(value: Double(bucket.usedPercent), total: 100)
                                    .tint(quotaColor(bucket.usedPercent))
                                    .frame(width: 110)
                                Text("\(bucket.usedPercent)%")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
            .padding(.horizontal, 18)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "pawprint.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Clawdesk Dashboard")
                    .font(.title2.weight(.semibold))
                Text("\(model.sessions.count) live session\(model.sessions.count == 1 ? "" : "s") · \(model.petState.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Circle()
                .fill(model.petState == .error ? .red : .green)
                .frame(width: 9, height: 9)
            Text("127.0.0.1:\(model.serverPort)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(18)
    }

    private var sessionsPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Live sessions")
                .font(.headline)
            if model.sessions.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "moon.zzz")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("No active sessions")
                        .font(.headline)
                    Text("Start a supported coding agent to see it here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.sessions) { session in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "terminal.fill")
                                .foregroundStyle(.orange)
                            Text(session.title).font(.headline)
                            Spacer()
                            Text(session.state.displayName)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(color(for: session.state))
                        }
                        Text(session.folder ?? session.agentID)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        HStack {
                            Text(session.lastEvent)
                            if session.subagentCount > 0 {
                                Text("· \(session.subagentCount) subagent\(session.subagentCount == 1 ? "" : "s")")
                            }
                            Spacer()
                            Button("Focus") {
                                _ = TerminalFocusService.focus(session)
                            }
                            .buttonStyle(.borderless)
                            .font(.caption2)
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 5)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 390, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var eventPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent events")
                .font(.headline)
            if model.eventLog.isEmpty {
                Text("Waiting for local agent events…")
                    .foregroundStyle(.secondary)
                    .padding(.top, 10)
            } else {
                List(model.eventLog, id: \.self) { event in
                    Text(event)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                }
            }
            if !model.pendingPermissions.isEmpty {
                Divider()
                Label("\(model.pendingPermissions.count) permission request pending", systemImage: "exclamationmark.shield.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }
        }
        .padding(16)
        .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func color(for state: PetState) -> Color {
        switch state {
        case .error: return .red
        case .attention: return .green
        case .notification: return .orange
        case .idle, .sleeping, .miniIdle: return .secondary
        default: return .blue
        }
    }

    private func quotaColor(_ usedPercent: Int) -> Color {
        if usedPercent > 85 { return .red }
        if usedPercent >= 60 { return .orange }
        return .green
    }
}
