import CoreGraphics
import Foundation
import XCTest
@testable import Clawdesk

/// Startup recovery + process liveness (upstream parity: a restart while a
/// supported CLI runs must not collapse into sleep, and sessions pinned to a
/// dead terminal are orphans).
final class AgentProcessTests: XCTestCase {
    // MARK: - probe matcher

    func testCommandMarkersMatchRealAgentCommandLineShapes() {
        let needles = AgentProcessProbe.defaultNeedles
        XCTAssertTrue(AgentProcessProbe.isRunningAgent(
            commandLines: ["claude-code --resume --prompt fix the tests"],
            needles: needles
        ))
        XCTAssertTrue(AgentProcessProbe.isRunningAgent(
            commandLines: ["node /usr/local/bin/codex exec --full-auto"],
            needles: needles
        ))
        XCTAssertTrue(AgentProcessProbe.isRunningAgent(
            commandLines: ["/Applications/ChatGPT.app/Contents/Frameworks/Codex Framework.framework/Versions/151.0.7922.174/Helpers/Codex (Renderer).app/Contents/MacOS/Codex (Renderer) --type=renderer"],
            needles: needles
        ))
        XCTAssertTrue(AgentProcessProbe.isRunningAgent(
            commandLines: ["node /opt/zcode/resources/glm/zcode.cjs app-server"],
            needles: needles
        ))
        XCTAssertTrue(AgentProcessProbe.isRunningAgent(
            commandLines: ["node /x/pi-coding-agent/dist/cli.js"],
            needles: needles
        ))
        XCTAssertFalse(AgentProcessProbe.isRunningAgent(
            commandLines: [
                "/Applications/Safari.app/Contents/MacOS/Safari",
                "vim ~/.claude/settings.json"
            ],
            needles: needles
        ))
        // Known upstream tolerance: a "codex" substring anywhere — even in a
        // log tail's path — counts as the weak keep-awake signal. Documented,
        // accepted, and never turned into a session.
        XCTAssertTrue(AgentProcessProbe.isRunningAgent(
            commandLines: ["tail -f /Users/me/.codex/log.txt"],
            needles: needles
        ))
    }

    func testExecutableNeedleMatchesTheBasenameExactly() {
        let needles = [AgentProcessNeedle(agentID: "gemini-cli", executableName: "gemini")]
        XCTAssertTrue(AgentProcessProbe.isRunningAgent(
            commandLines: ["/usr/local/bin/gemini --yolo"],
            needles: needles
        ))
        // A longer basename sharing the prefix must not match (pgrep -x rule).
        XCTAssertFalse(AgentProcessProbe.isRunningAgent(
            commandLines: ["/usr/local/bin/geminish"],
            needles: needles
        ))
    }

    func testLiveProcessListingFeedsTheMatcher() {
        // /bin/echo stands in for ps: the plumbing (spawn → lines → matcher)
        // is exercised end to end without depending on host processes.
        XCTAssertTrue(AgentProcessProbe.isAnySupportedAgentRunning(
            needles: AgentProcessProbe.defaultNeedles
        ) == AgentProcessProbe.isRunningAgent(
            commandLines: AgentProcessProbe.runningCommandLines(),
            needles: AgentProcessProbe.defaultNeedles
        ))
        let fake = AgentProcessProbe.runningCommandLines(
            processPath: "/bin/echo",
            arguments: ["node /opt/zcode/resources/glm/zcode.cjs app-server"]
        )
        XCTAssertTrue(AgentProcessProbe.isRunningAgent(
            commandLines: fake,
            needles: AgentProcessProbe.defaultNeedles
        ))
    }

    // MARK: - orphan-session liveness prune

    func testPruneDropsSessionsPinnedToDeadTerminalsOnly() {
        let store = SessionStore()
        _ = store.apply(AgentEvent(sessionID: "live", eventName: "UserPromptSubmit", terminalPID: Int(ProcessInfo.processInfo.processIdentifier)))
        _ = store.apply(AgentEvent(sessionID: "dead", eventName: "UserPromptSubmit", terminalPID: Int(Int32.max)))
        _ = store.apply(AgentEvent(sessionID: "unpinned", eventName: "UserPromptSubmit"))

        let transition = store.pruneStale(isProcessAlive: ClawdeskModel.isProcessAlive)
        XCTAssertEqual(Set(transition?.sessions.map(\.id) ?? []), ["live", "unpinned"])
        // Without a checker nothing new is pruned.
        let store2 = SessionStore()
        _ = store2.apply(AgentEvent(sessionID: "dead", eventName: "UserPromptSubmit", terminalPID: Int(Int32.max)))
        XCTAssertNil(store2.pruneStale())
    }

    func testSilentActiveSessionsDemoteOnUpstreamStaleFloors() {
        // Upstream's stale-cleanup contract: a silent working-tier session
        // demotes to idle after 5 minutes (Claude) / 20 minutes (Codex), so a
        // dead CLI cannot leave the pet "working" forever. Below the floor it
        // stays working.
        let started = Date(timeIntervalSince1970: 1_000)

        let claudeStore = SessionStore()
        _ = claudeStore.apply(AgentEvent(
            sessionID: "claude-live",
            agentID: "claude-code",
            eventName: "UserPromptSubmit",
            timestamp: started
        ))
        XCTAssertNil(claudeStore.pruneStale(
            now: started.addingTimeInterval(5 * 60 - 1),
            olderThan: 10 * 60,
            workingTimeout: 5 * 60,
            codexActiveTimeout: 20 * 60
        ))
        let claudeDemoted = claudeStore.pruneStale(
            now: started.addingTimeInterval(5 * 60),
            olderThan: 10 * 60,
            workingTimeout: 5 * 60,
            codexActiveTimeout: 20 * 60
        )
        XCTAssertEqual(claudeDemoted?.sessions.first { $0.id == "claude-live" }?.state, .idle)

        let codexStore = SessionStore()
        _ = codexStore.apply(AgentEvent(
            sessionID: "codex-live",
            agentID: "codex",
            eventName: "UserPromptSubmit",
            timestamp: started
        ))
        // Codex holds its working tier for its own 20-minute floor.
        XCTAssertNil(codexStore.pruneStale(
            now: started.addingTimeInterval(6 * 60),
            olderThan: 10 * 60,
            workingTimeout: 5 * 60,
            codexActiveTimeout: 20 * 60
        ))
        XCTAssertEqual(codexStore.sessions.first?.state, .thinking)

        let ended = codexStore.apply(AgentEvent(
            sessionID: "codex-live",
            agentID: "codex",
            eventName: "SessionEnd",
            timestamp: started.addingTimeInterval(2 * 60 * 60)
        ))
        XCTAssertTrue(ended.sessions.isEmpty)
        XCTAssertEqual(ended.state, .idle)
    }

    // MARK: - startup recovery state machine

    @MainActor
    private func makeModel(probe: @escaping @Sendable () -> Bool) -> ClawdeskModel {
        let suite = "clawdesk-recovery-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("clawdesk-recovery-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let prefs = AppPreferences(defaults: defaults, homeDirectory: root)
        let model = ClawdeskModel(preferences: prefs)
        model.agentRunningProbe = probe
        return model
    }

    @MainActor
    func testRecoveryHoldsSleepWhileAgentsRun() {
        let model = makeModel(probe: { true })
        model.beginStartupRecovery()
        let now = Date()
        model.lastPointerActivity = now.addingTimeInterval(-61)

        // The sleep clock is held: the same instant that would yawn stays idle.
        XCTAssertFalse(model.tickForSleep(now: now))
        XCTAssertEqual(model.petState, .idle)
        XCTAssertTrue(model.startupRecoveryActive)

        // Past the five-minute cap the hold lifts and sleep proceeds.
        XCTAssertFalse(model.tickForSleep(now: now.addingTimeInterval(400)))
        XCTAssertFalse(model.startupRecoveryActive)
        XCTAssertTrue(model.tickForSleep(now: now.addingTimeInterval(461)))
        XCTAssertEqual(model.petState, .yawning)
    }

    @MainActor
    func testRealSessionEventCancelsRecovery() {
        let model = makeModel(probe: { true })
        model.beginStartupRecovery()
        XCTAssertTrue(model.startupRecoveryActive)

        model.accept(AgentEvent(sessionID: "s", agentID: "claude-code", eventName: "UserPromptSubmit"))
        XCTAssertFalse(model.startupRecoveryActive, "forward progress owns the pet now")
        XCTAssertEqual(model.petState, .thinking)
    }

    @MainActor
    func testEmptyProbeEndsRecoveryEarly() async {
        let model = makeModel(probe: { false })
        model.beginStartupRecovery()
        model.tickStartupRecovery(now: .now)
        // The probe runs on a background task; give it a moment.
        for _ in 0..<40 where model.startupRecoveryActive {
            try? await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertFalse(model.startupRecoveryActive, "no agent running: recovery ends early")
        XCTAssertEqual(model.sessions.count, 0)
    }

    @MainActor
    func testRecoveryProbeKeepsRecoveryAliveWhileAgentsRun() async {
        let model = makeModel(probe: { true })
        model.beginStartupRecovery()
        model.tickStartupRecovery(now: .now)
        for _ in 0..<40 where !model.startupRecoveryActive {
            try? await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(model.startupRecoveryActive, "agent still running: stay awake")
    }

    // MARK: - liveness helper

    func testIsProcessAliveUsesKillZeroSemantics() {
        XCTAssertTrue(ClawdeskModel.isProcessAlive(1), "launchd is always alive")
        XCTAssertFalse(ClawdeskModel.isProcessAlive(Int32.max), "no process owns the top pid")
        XCTAssertFalse(ClawdeskModel.isProcessAlive(0), "pid 0 is not a session owner")
    }
}
