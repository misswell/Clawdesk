# Upstream parity map

Source baseline: `c8c153cce4fe1f0452e00212e0cd1d2725547f61` (upstream v0.16.0)
Latest local upstream inspection: `c8c153cc` on 2026-08-30

Clawdesk ports the behavior described by the upstream project while replacing
Electron/DOM rendering with AppKit, CoreGraphics, SwiftUI, and Network.framework.

| Upstream capability | Native seam | Status |
| --- | --- | --- |
| Shared lifecycle states | `EventStateMapper` | Implemented |
| Multi-session priority | `SessionStore` | Implemented |
| Local `/state`, `/permission`, `/health` bridge | `LocalEventServer` | Implemented |
| Claude Code command + HTTP hooks + periodic health self-heal | `HookInstaller` + `ClaudeHookHealthMonitor` | Implemented: a read-only check every 5 minutes verifies the managed hook script still exists and repairs it without touching the statusLine slot; after 3 consecutive failed repairs it stops auto-retrying and asks for a manual fix. Local usage collection via the documented statusLine is opt-in and off by default |
| Codex Desktop + CLI official hook shape, feature flag, and rollout fallback | `HookInstaller` + `CodexLogMonitor` | Implemented: one canonical Codex integration honors `CODEX_HOME`, scans date-partitioned Desktop/CLI rollouts, and keeps response-item events attached to the session from `session_meta` |
| Transparent floating pet window | `PetWindowController` | Implemented |
| Low-power native animation loop | `PetWindowController` + `PetCanvasView` + `BloubEngine.isSettled` | Implemented: the loop runs full speed (60/30 fps) while anything discrete animates — state fades, gaze tracking, theme asset timelines — and throttles to 12/8 fps once the engine reports settled (only the slow rest life remains); a resting cursor no longer re-poses the look target, so the pet actually settles, and the low-power preference now applies live |
| Idle animation cycle | `IdleAnimationCycle` + `PetWindowController` | Implemented: theme `idleAnimations` durations are parsed from milliseconds, one random animation plays after 20 seconds of mouse silence, and movement/state changes cancel it back to the selected idle visual |
| Idle eye tracking, drag, mini mode, hover peek | `PetCanvasView` / `PetWindowController` / `PetPointerMapper` | Implemented: the gaze normalizes the cursor against half the screen (upstream divides by half the browser window), sweeps a wide centred cone (±45°/±38°) with upright eyes and a sub-linear response curve, and glides straight to the viewer while the cursor rests on the body; hover peek keeps tracking. Drag, mini mode and hover peek otherwise unchanged |
| Sleep sequence (yawn → doze → collapse → sleep → wake) | `SleepSequencePlanner` + `ClawdeskModel` + `PetCanvasView` | Implemented: theme timings are imported in milliseconds and clamped; full themes use `mouseSleepTimeout → yawning → dozing → deepSleepTimeout → collapsing → sleeping`, direct themes skip to sleeping, wake assets are optional in direct mode, and DND honors `dndSkipYawn`, `dndSleepTransitionSvg`, and `dndSleepTransitionDuration` |
| Double tap / rapid four-tap reactions | `PetCanvasView` | Implemented |
| DND, sound cue, position memory, launch at login, continuously adjustable pet size | preferences + AppKit | Implemented: a 40%–200% scale slider resizes the pet window in place, anchored to its bottom center |
| Free Roam with roam fence | `RoamPlanner` + `RoamFenceCoordinator` + Settings overlay | Implemented: upstream roam semantics — first walk 8 s after mouse silence then every 4 s, 80 px/s ease-out walks (1 s minimum), a 15% work-area margin band, a 100 px minimum hop with an 8-attempt + farthest-corner fallback, a hold while a permission bubble is visible, and drag-cancel. The pet periodically walks to a whole-window target inside a user-selected work-area rectangle stored in `~/.clawd/roam-area.json`; malformed input keeps the previous fence and deletion only counts after two consecutive checks |
| Pet-attached quota ring (Orbit) | `QuotaRingGeometry` + `QuotaRingView` + pet-attached window | Implemented: one coin per provider with an outer rolling-window ring and an inner weekly ring, a 4-coin cap with a "+N" overflow row, attached to the pet's left side, repositioned with it, and hidden when there is nothing to draw |
| Interface language (en / zh-Hans / zh-Hant / ja / ko / es) | `Localization` table + `AppPreferences.language` | Implemented: settings (all tabs' visible chrome), menus, dashboard, window titles, permission bubble, and About page switch immediately; long explanatory paragraphs and credential placeholders fall back to English |
| Settings, Dashboard, permission bubble | SwiftUI windows | Implemented: the permission window renders concrete agent suggestions alongside Allow/Deny (with upstream `addRules` merging into one "always allow" entry), keeps every simultaneous request reachable in a bounded scroll queue, expands action/command/input details, supports fixed four-corner or follow-pet placement, and can be disabled per permission-capable agent. Permission/question requests are transient (they never create or overwrite session rows, matching upstream); the pending-permission overlay pins the aggregate and resolution restores it; headless requests auto-deny; PASSTHROUGH_TOOLS auto-allow without a bubble; lifecycle events (PostToolUse/Stop/SessionEnd/UserPromptSubmit) sweep stale bubbles with a no-decision; Claude/CodeBuddy decisions reply in the `hookSpecificOutput` contract with `updatedInput` echoed for plan-mode allows. Remote egress (Telegram/Feishu/Slack) is secret-redacted and never carries raw commands |
| Pet window behaviors | `PetWindowController` + `PetCanvasView` | Implemented: drag clamped to the attached-displays union with startup off-screen fallback, mini mode snapping on both edges (30 pt tolerance) with exit anti-resnap and a click-to-exit, click accumulator on the upstream 400 ms window, Cmd-click opens the dashboard, Hide/Show Pet (context + status menu, persisted, HUD/quota follow) with a ⌃⇧P global shortcut, session rows open their folder from the dashboard, a menu-bar completion/error flash, and a test-result reaction driven by hook `test_result` payloads |
| Doctor local integration diagnostics | `AgentDoctor` + Settings → Doctor | Implemented: upstream's eight-check breadth minus the Windows-only probes — per-agent config checks with Fix actions, plus system checks for preferences readability, the local event server, the permission policy, Feishu approval configuration, theme health, and Remote SSH ingress/isolation, and a copyable markdown report with home paths redacted. Plugin-only integrations report not checked |
| Startup integration sync | `ClawdeskModel` + `AgentDoctor` + `HookInstaller` | Implemented: explicitly installed agents persist enabled intent; upgrades discover ownership markers and repair managed integrations after launch without creating unrelated agent configs; Kimi profile repair remains existing-only |
| Global allow/deny shortcuts | `GlobalShortcutManager` | Implemented |
| Permission automation policy (off / auto-tools / unattended) | `PermissionPolicy` + preferences | Implemented with fail-closed semantics: auto-tools auto-approves only clearly read-only tool names and defers the rest to the bubble; unattended denies unknown requests instead of guessing |
| Sessions menu with terminal focus | pet/status menu + `TerminalFocusService` | Implemented: right-click and tray Sessions submenus list live sessions (debounced tray rebuild) and focus the owning terminal window |
| Startup recovery + process liveness | `AgentProcessProbe` + `ClawdeskModel` | Implemented: at boot the model probes for supported CLI agents (upstream's needle table: claude-code, codex, copilot, codebuddy, kimi-code, zcode.cjs, pi) and holds the sleep sequence for up to five minutes while one runs — real session events cancel it, an empty probe ends it early; sessions pinned to a terminal PID are pruned as soon as that process dies (`kill(pid, 0)` + EPERM semantics). Stale cleanup mirrors upstream's contract: idle sessions delete after 10 minutes, silent working-tier sessions demote to idle after 5 minutes (Codex/OpenCode keep a 20-minute floor, 0 disables), and headless sessions are excluded from the dominant visible state. Active lifecycle states below the floor are never downgraded by silence; only explicit end events or a known dead owner retire them |
| Session HUD | `SessionHUDWindowController` + `SessionHUDView` | Implemented: click the pet to reveal a low-overhead native HUD near it, show up to five live sessions with agent marks, separate state chips, per-session context-usage chips, and an overflow row, click a row to focus its terminal, pin it open, keep it reachable through the upstream-style pet/HUD hot-zone grace, and restore the latest persisted account quota in the attached Orbit ring |
| Other agent hook formats | adapter seam + generic HTTP endpoint | Implemented for every v0.16.0 registered macOS agent, including TraeCode (Trae CN) state-only hooks with documented nested JSON shape, fail-closed schema checks, `{}` stdout, session namespacing and first-safe-prompt title derivation. Plugin identities, extension directories, and the Kiro managed agent use Clawdesk's own names (never the upstream product id), so the two integrations cannot collide or impersonate each other |
| Claude background completion gate | `LocalEventServer` + `SessionStore` | Implemented: exact typed background-subagent counts, background task counts, session crons and active Stop hooks keep the main Claude session working; an authoritative zero releases the hold and only then shows completion. Private task IDs, descriptions and commands are not retained |
| ZCode manual `PermissionRequest` approval | `AdditionalHookAdapters` + `AgentEventAdapters` | Implemented: the config adapter installs the blocking hook, Allow/Deny uses ZCode's strict `hookSpecificOutput` schema, and unknown/oversized tool input returns `204` so ZCode keeps its native permission UI |
| Codex `request_user_input` | `DefaultAgentEventAdapter` + `CodexLogMonitor` + read-only card | Implemented: bounded question/options preview parsed in the adapter; answers stay in Codex and the matching output clears the card. Codex official-hook turns run the upstream turn machine in the session store — turns open on UserPromptSubmit, tool events mark activity, `stop_hook_active` drops the completion side effects, subagent-role Stops resolve headless/idle, and a quiet turn ends idle instead of celebrating |
| Gemini `AfterAgent` / `PreCompress` semantics | `EventStateMapper` | Implemented: AfterAgent returns idle; PreCompress is recorded without forcing sweeping |
| Kimi legacy approval modes | `DefaultAgentEventAdapter` + Kimi TOML adapter | Implemented: explicit/suspect modes, persisted command flag, runtime env overrides (`CLAWD_KIMI_PERMISSION_MODE`, `CLAWD_KIMI_PERMISSION_IMMEDIATE`, `CLAWD_KIMI_PERMISSION_SUSPECT`, `CLAWD_KIMI_PERMISSION_SUSPECT_MS`, `CLAWD_KIMI_DISABLE_PRETOOL_PERMISSION`), tunable suspect window, and per-session gate close ledger |
| Telegram / Feishu interactive approval and Slack notifications | remote notifier seam | Implemented: Telegram and Feishu/Lark approvals, Slack/Telegram/Feishu notifications; local bubble remains authoritative |
| Mobile read-only PWA | LAN companion seam | Implemented: token-gated HTTP fallback, v1 WebSocket snapshots, state/deletion broadcasts, pairing URL, and bounded clients/rate limits |
| Codex JSONL fallback and quota rings | session/telemetry adapters | Implemented: bounded JSONL fallback, Claude statusline quota, Codex/Codex Spark windows, dashboard rings |
| SSH / WSL deployment | transport adapters | Implemented for native macOS Remote SSH: profile-bound loopback ingress, nonce validation, atomic remote hook repair, Copilot registration, optional Codex fallback monitor, automatic/single-session transport mode, and reverse tunnel. WSL is outside the macOS product boundary |
| Custom animated asset packs | theme importer seam | Behavior-complete for validated folder/ZIP themes with ImageIO animation plus static SVG fallback, per-theme idle visual selection, theme sounds (`complete`/`confirm`/`error` in a sibling `sounds/` directory, falling back to system cues), and bounded frame caching (downsampled frames, per-animation and total cache byte budgets). Upstream Codex Pet atlas/capability packs and the new independent head/mouth accessory slots are not bundled. The built-in pet is the bloub character (MIT, jeremy-prt/bloub) driven by the native `Pet/Bloub/BloubEngine` and mapped from agent semantics through `Pet/BloubStateMapper` — no upstream clawd-on-desk artwork or character names are reused |
| Auto-update | `ClawdeskSoftwareUpdater` + `ClawdeskUpdater` helper | Implemented: automatic check on launch (opt-out), GitHub Release discovery with SHA-256 digest requirement, download, archive/signature/team/Gatekeeper validation, then an atomic in-place replace by a separate updater process with launch verification and rollback. "Later" dismisses a pending release (persisted, pruned once the running version catches up) so background checks stay quiet while a manual check still offers it. Reachable from Settings → Software Update and the tray/pet "Check for Updates…" menus. Only Developer-ID-signed and notarized packages are accepted |

## Current integration boundary

The stable local contract is deliberately small: agents emit lifecycle events to
the local HTTP server, `EventStateReducer` and `SessionStore` derive the pet
state, and every renderer or companion view consumes sanitized snapshots. Hook
configuration and agent-specific payload parsing stay inside adapters. The
mobile bridge is read-only by design and never receives a raw filesystem path,
transcript, command output, or access token through its snapshot payload.
The HTTP receive path caps the cumulative request buffer at 512 KiB and the
frame cache is bounded in bytes as well as frame count, so a misbehaving local
client or an oversized theme cannot force unbounded memory growth.

When the upstream project adds a lifecycle event, update the state mapping and
its adapter first, then add a behavior test. When it adds a companion feature,
implement it behind a new transport seam rather than coupling it to the
CoreGraphics pet renderer.

The remaining upstream-specific boundaries are intentionally isolated from the
renderer and state model: Windows/WSL/Linux packaging is not part of this native
macOS target; remote approval is optional for the current product goal; Discord
Rich Presence, the tutorial window, Codex Pet atlas imports, and head/mouth
accessory slots are non-core extensions rather than agent lifecycle paths.
Artwork from the upstream repository is not bundled here because its
`assets/LICENSE` reserves the artwork separately from the source-code license.

## Upstream update procedure

1. Compare upstream `docs/guides/state-mapping.md`, setup, remote-SSH, and
   theme guides against this table.
2. Update `EventStateMapper` and `SessionStore` for lifecycle changes.
3. Update only the affected `HookInstaller` or adapter; keep the local event
   server and renderer contract stable.
4. Add a behavior test for the changed event or transport.
5. Run `swift test`, `scripts/build-app.sh`, and the app signature check.
