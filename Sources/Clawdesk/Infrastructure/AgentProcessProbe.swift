import Foundation

/// One probe rule for "is this supported agent running right now?"
///
/// Mirrors upstream's startup-recovery registry: an agent may be declared by
/// an exact executable name (`pgrep -x`) and/or a command-line marker
/// (`pgrep -f`). A command marker matches anywhere in the command line — the
/// upstream treats this only as a weak keep-awake signal (it never creates a
/// session), so a stray substring in an editor's arguments is tolerated.
public struct AgentProcessNeedle: Equatable, Sendable {
    public let agentID: String
    public let executableName: String?
    public let commandMarker: String?

    public init(agentID: String, executableName: String? = nil, commandMarker: String? = nil) {
        self.agentID = agentID
        self.executableName = executableName
        self.commandMarker = commandMarker
    }
}

/// Answers "is any supported agent running right now?" for startup recovery.
///
/// Upstream keeps Clawd awake after a restart while a supported CLI runs but
/// has not fired a hook yet (Claude Code sitting at a prompt, a Codex session
/// between turns). The answer gates nothing else: it never creates a session
/// and never publishes a task state.
public enum AgentProcessProbe {
    /// Command-line markers ported from upstream's startup-recovery table,
    /// plus the pi CLI markers (POSIX-only upstream, which matches Clawdesk).
    public static let defaultNeedles: [AgentProcessNeedle] = [
        AgentProcessNeedle(agentID: "claude-code", commandMarker: "claude-code"),
        AgentProcessNeedle(agentID: "codex", commandMarker: "codex"),
        AgentProcessNeedle(agentID: "copilot-cli", commandMarker: "copilot"),
        AgentProcessNeedle(agentID: "codebuddy", commandMarker: "codebuddy"),
        AgentProcessNeedle(agentID: "kimi-cli", commandMarker: "kimi-code"),
        // ZCode runs through resources/glm/zcode.cjs; the cmdline token
        // disambiguates the working process from the GUI shell.
        AgentProcessNeedle(agentID: "zcode", commandMarker: "zcode.cjs"),
        AgentProcessNeedle(agentID: "pi", commandMarker: "@earendil-works/pi-coding-agent"),
        AgentProcessNeedle(agentID: "pi", commandMarker: "pi-coding-agent/dist/cli.js")
    ]

    /// Pure matcher over raw command lines (as `ps -axo command=` reports
    /// them). An executable needle matches the basename of the first token
    /// exactly; a command marker matches as a case-sensitive substring — the
    /// same semantics as `pgrep -x` / a joined `pgrep -f` pattern.
    public static func isRunningAgent(
        commandLines: [String],
        needles: [AgentProcessNeedle]
    ) -> Bool {
        let basenames = commandLines.map { line in
            let first = line.split(separator: " ", maxSplits: 1).first.map(String.init) ?? line
            let path = first.split(separator: "/").last.map(String.init) ?? first
            return path
        }
        for needle in needles {
            if let name = needle.executableName,
               basenames.contains(where: { $0 == name }) {
                return true
            }
            if let marker = needle.commandMarker,
               commandLines.contains(where: { $0.contains(marker) }) {
                return true
            }
        }
        return false
    }

    /// Live process table. Returns raw command lines so the matching stays a
    /// pure, testable function; `ps` failing (unlikely on macOS) reads as "no
    /// agents running" — the probe may only keep the pet awake, never wake it.
    public static func runningCommandLines(
        processPath: String = "/bin/ps",
        arguments: [String] = ["-axo", "command="]
    ) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: processPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }
        return String(data: data, encoding: .utf8)?
            .split(separator: "\n")
            .map(String.init) ?? []
    }

    /// Convenience for the startup-recovery gate.
    public static func isAnySupportedAgentRunning(
        needles: [AgentProcessNeedle] = defaultNeedles
    ) -> Bool {
        isRunningAgent(commandLines: runningCommandLines(), needles: needles)
    }
}
