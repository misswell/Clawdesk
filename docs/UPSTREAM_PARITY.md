# Upstream parity map

Source baseline: `a7283581f1d46421beba91ef10ffaa994bc0a52f`
Latest local upstream inspection: `a7283581`

Clawdesk ports the behavior described by the upstream project while replacing
Electron/DOM rendering with AppKit, CoreGraphics, SwiftUI, and Network.framework.

| Upstream capability | Native seam | Status |
| --- | --- | --- |
| Shared lifecycle states | `EventStateMapper` | Implemented |
| Multi-session priority | `SessionStore` | Implemented |
| Local `/state`, `/permission`, `/health` bridge | `LocalEventServer` | Implemented |
| Claude Code command + HTTP hooks + periodic health self-heal | `HookInstaller` + `ClaudeHookHealthMonitor` | Implemented: a read-only check every 5 minutes verifies the managed hook script still exists and repairs it without touching the statusLine slot; after 3 consecutive failed repairs it stops auto-retrying and asks for a manual fix. Local usage collection via the documented statusLine is opt-in and off by default |
| Codex official hook shape + feature flag | `HookInstaller` | Implemented |
| Transparent floating pet window | `PetWindowController` | Implemented |
| Low-power native animation loop | `PetWindowController` + `PetCanvasView` + `BloubEngine.isSettled` | Implemented: the loop runs full speed (60/30 fps) while anything discrete animates — state fades, gaze tracking, theme asset timelines — and throttles to 12/8 fps once the engine reports settled (only the slow rest life remains); a resting cursor no longer re-poses the look target, so the pet actually settles, and the low-power preference now applies live |
| Idle animation cycle | `IdleAnimationCycle` + `PetWindowController` | Implemented: theme `idleAnimations` durations are parsed from milliseconds, one random animation plays after 20 seconds of mouse silence, and movement/state changes cancel it back to the selected idle visual |
| Idle eye tracking, drag, mini mode, hover peek | `PetCanvasView` / `PetWindowController` / `PetPointerMapper` | Implemented: the gaze normalizes the cursor against half the screen (upstream divides by half the browser window), sweeps a wide centred cone (±45°/±38°) with upright eyes and a sub-linear response curve, and glides straight to the viewer while the cursor rests on the body; hover peek keeps tracking. Drag, mini mode and hover peek otherwise unchanged |
| Sleep sequence (yawn → doze → collapse → sleep → wake) | `SleepSequencePlanner` + `ClawdeskModel` + `PetCanvasView` | Implemented: theme timings are imported in milliseconds and clamped; full themes use `mouseSleepTimeout → yawning → dozing → deepSleepTimeout → collapsing → sleeping`, direct themes skip to sleeping, wake assets are optional in direct mode, and DND honors `dndSkipYawn`, `dndSleepTransitionSvg`, and `dndSleepTransitionDuration` |
| Double tap / rapid four-tap reactions | `PetCanvasView` | Implemented |
| DND, sound cue, position memory, launch at login, continuously adjustable pet size | preferences + AppKit | Implemented: a 40%–200% scale slider resizes the pet window in place, anchored to its bottom center |
| Free Roam with roam fence | `RoamPlanner` + `RoamFenceCoordinator` + Settings overlay | Implemented: the pet periodically walks to a whole-window target inside a user-selected work-area rectangle stored in `~/.clawd/roam-area.json`; malformed input keeps the previous fence and deletion only counts after two consecutive checks |
| Pet-attached quota ring (Orbit) | `QuotaRingGeometry` + `QuotaRingView` + pet-attached window | Implemented: one coin per provider with an outer rolling-window ring and an inner weekly ring, a 4-coin cap with a "+N" overflow row, attached to the pet's left side, repositioned with it, and hidden when there is nothing to draw |
| Interface language (en / zh-Hans / zh-Hant / ja / ko / es) | `Localization` table + `AppPreferences.language` | Implemented: settings (all tabs' visible chrome), menus, dashboard, window titles, permission bubble, and About page switch immediately; long explanatory paragraphs and credential placeholders fall back to English |
| Settings, Dashboard, permission bubble | SwiftUI windows | Implemented: the permission bubble renders the agent's concrete allow/deny suggestions alongside Allow/Deny |
| Doctor local integration diagnostics | `AgentDoctor` + Settings → Doctor | Implemented: read-only checks of registered agent config files for Clawdesk-managed entries and hook-script presence, with per-agent Fix actions; plugin-only integrations report not checked |
| Startup integration sync | `ClawdeskModel` + `AgentDoctor` + `HookInstaller` | Implemented: explicitly installed agents persist enabled intent; upgrades discover ownership markers and repair managed integrations after launch without creating unrelated agent configs; Kimi profile repair remains existing-only |
| Global allow/deny shortcuts | `GlobalShortcutManager` | Implemented |
| Permission automation policy (off / auto-tools / unattended) | `PermissionPolicy` + preferences | Implemented with fail-closed semantics: auto-tools auto-approves only clearly read-only tool names and defers the rest to the bubble; unattended denies unknown requests instead of guessing |
| Sessions menu with terminal focus | pet/status menu + `TerminalFocusService` | Implemented: right-click and tray Sessions submenus list live sessions (debounced tray rebuild) and focus the owning terminal window |
| Startup recovery + process liveness | `AgentProcessProbe` + `ClawdeskModel` | Implemented: at boot the model probes for supported CLI agents (upstream's needle table: claude-code, codex, copilot, codebuddy, kimi-code, zcode.cjs, pi) and holds the sleep sequence for up to five minutes while one runs — real session events cancel it, an empty probe ends it early; sessions pinned to a terminal PID are pruned as soon as that process dies (`kill(pid, 0)` + EPERM semantics) instead of waiting out the stale window |
| Session HUD | `SessionHUDWindowController` + `SessionHUDView` | Implemented: click the pet to reveal a low-overhead native HUD near it, show up to three live sessions plus an overflow row, click a row to focus its terminal, pin it open, and keep it reachable through the upstream-style pet/HUD hot-zone grace; context-usage chips remain pending |
| Other agent hook formats | adapter seam + generic HTTP endpoint | Implemented for the registered Claude-compatible, JSON/TOML, and plugin adapters. Plugin identities, extension directories, and the Kiro managed agent use Clawdesk's own names (never the upstream product id), so the two integrations cannot collide or impersonate each other |
| ZCode manual `PermissionRequest` approval | `AdditionalHookAdapters` + `AgentEventAdapters` | Implemented: the config adapter installs the blocking hook, Allow/Deny uses ZCode's strict `hookSpecificOutput` schema, and unknown/oversized tool input returns `204` so ZCode keeps its native permission UI |
| Codex `request_user_input` | `DefaultAgentEventAdapter` + `CodexLogMonitor` + read-only card | Implemented: bounded question/options preview parsed in the adapter; answers stay in Codex and the matching output clears the card |
| Gemini `AfterAgent` / `PreCompress` semantics | `EventStateMapper` | Implemented: AfterAgent returns idle; PreCompress is recorded without forcing sweeping |
| Kimi legacy approval modes | `DefaultAgentEventAdapter` + Kimi TOML adapter | Implemented: explicit/suspect modes, persisted command flag, runtime env overrides (`CLAWD_KIMI_PERMISSION_MODE`, `CLAWD_KIMI_PERMISSION_IMMEDIATE`, `CLAWD_KIMI_PERMISSION_SUSPECT`, `CLAWD_KIMI_PERMISSION_SUSPECT_MS`, `CLAWD_KIMI_DISABLE_PRETOOL_PERMISSION`), tunable suspect window, and per-session gate close ledger |
| Telegram / Feishu interactive approval and Slack notifications | remote notifier seam | Implemented: Telegram and Feishu/Lark approvals, Slack/Telegram/Feishu notifications; local bubble remains authoritative |
| Mobile read-only PWA | LAN companion seam | Implemented: token-gated HTTP fallback, v1 WebSocket snapshots, state/deletion broadcasts, pairing URL, and bounded clients/rate limits |
| Codex JSONL fallback and quota rings | session/telemetry adapters | Implemented: bounded JSONL fallback, Claude statusline quota, Codex/Codex Spark windows, dashboard rings |
| SSH / WSL deployment | transport adapters | Implemented for native macOS Remote SSH: profile-bound loopback ingress, nonce validation, atomic remote hook repair, Copilot registration, optional Codex fallback monitor, automatic/single-session transport mode, and reverse tunnel. WSL is outside the macOS product boundary |
| Custom animated asset packs | theme importer seam | Implemented for validated folder/ZIP themes with ImageIO animation plus static SVG fallback, per-theme idle visual selection, theme sounds (`complete`/`confirm`/`error` in a sibling `sounds/` directory, falling back to system cues), and bounded frame caching (downsampled frames, per-animation and total cache byte budgets); upstream Codex Pet atlas/capability schema is not bundled. The built-in pet is the bloub character (MIT, jeremy-prt/bloub) driven by the native `Pet/Bloub/BloubEngine` and mapped from agent semantics through `Pet/BloubStateMapper` — no upstream clawd-on-desk artwork or character names are reused |
| Auto-update | `ClawdeskSoftwareUpdater` + `ClawdeskUpdater` helper | Implemented: automatic check on launch (opt-out), GitHub Release discovery with SHA-256 digest requirement, download, archive/signature/team/Gatekeeper validation, then an atomic in-place replace by a separate updater process with launch verification and rollback. Reachable from Settings → Software Update and the tray/pet "Check for Updates…" menus. Only Developer-ID-signed and notarized packages are accepted |

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
renderer and state model: WSL is not part of this macOS target, and the native
renderer does not bundle the upstream Codex Pet atlas/capability schema.
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
