# Upstream parity map

Source baseline: `e4961f2568d5fdb5e3365597e6b050fae76f61ae`
Latest local upstream inspection: `fda7301c`

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
| Low-power native animation loop | `PetCanvasView` | Implemented |
| Idle eye tracking, drag, mini mode, hover peek | `PetCanvasView` / `PetWindowController` | Implemented |
| Sleep sequence (doze → sleep → wake) | `ClawdeskModel` | Implemented: 60s of mouse idle enters dozing, then sleeping after another 25s; mouse activity wakes through a waking transition |
| Double tap / rapid four-tap reactions | `PetCanvasView` | Implemented |
| DND, sound cue, position memory, launch at login, continuously adjustable pet size | preferences + AppKit | Implemented: a 40%–200% scale slider resizes the pet window in place, anchored to its bottom center |
| Free Roam with roam fence | `RoamPlanner` + `RoamFenceCoordinator` + Settings overlay | Implemented: the pet periodically walks to a whole-window target inside a user-selected work-area rectangle stored in `~/.clawd/roam-area.json`; malformed input keeps the previous fence and deletion only counts after two consecutive checks |
| Interface language (en / zh-Hans / zh-Hant / ja / ko / es) | `Localization` table + `AppPreferences.language` | Implemented: settings, menus, dashboard, window titles, permission bubble, and About page switch immediately; untranslated keys fall back to English |
| Settings, Dashboard, permission bubble | SwiftUI windows | Implemented: the permission bubble renders the agent's concrete allow/deny suggestions alongside Allow/Deny |
| Doctor local integration diagnostics | `AgentDoctor` + Settings → Doctor | Implemented: read-only checks of registered agent config files for Clawdesk-managed entries and hook-script presence, with per-agent Fix actions; plugin-only integrations report not checked |
| Global allow/deny shortcuts | `GlobalShortcutManager` | Implemented |
| Sessions menu with terminal focus | pet/status menu + `TerminalFocusService` | Implemented: right-click and tray Sessions submenus list live sessions (debounced tray rebuild) and focus the owning terminal window |
| Other agent hook formats | adapter seam + generic HTTP endpoint | Implemented for the registered Claude-compatible, JSON/TOML, and plugin adapters. Plugin identities, extension directories, and the Kiro managed agent use Clawdesk's own names (never the upstream product id), so the two integrations cannot collide or impersonate each other |
| Codex `request_user_input` | `DefaultAgentEventAdapter` + `CodexLogMonitor` + read-only card | Implemented: bounded question/options preview parsed in the adapter; answers stay in Codex and the matching output clears the card |
| Gemini `AfterAgent` / `PreCompress` semantics | `EventStateMapper` | Implemented: AfterAgent returns idle; PreCompress is recorded without forcing sweeping |
| Kimi legacy approval modes | `DefaultAgentEventAdapter` + Kimi TOML adapter | Implemented: explicit/suspect modes, persisted command flag, runtime env overrides (`CLAWD_KIMI_PERMISSION_MODE`, `CLAWD_KIMI_PERMISSION_IMMEDIATE`, `CLAWD_KIMI_PERMISSION_SUSPECT`, `CLAWD_KIMI_PERMISSION_SUSPECT_MS`, `CLAWD_KIMI_DISABLE_PRETOOL_PERMISSION`), tunable suspect window, and per-session gate close ledger |
| Telegram / Feishu interactive approval and Slack notifications | remote notifier seam | Implemented: Telegram and Feishu/Lark approvals, Slack/Telegram/Feishu notifications; local bubble remains authoritative |
| Mobile read-only PWA | LAN companion seam | Implemented: token-gated HTTP fallback, v1 WebSocket snapshots, state/deletion broadcasts, pairing URL, and bounded clients/rate limits |
| Codex JSONL fallback and quota rings | session/telemetry adapters | Implemented: bounded JSONL fallback, Claude statusline quota, Codex/Codex Spark windows, dashboard rings |
| SSH / WSL deployment | transport adapters | Implemented for native macOS Remote SSH: profile-bound loopback ingress, nonce validation, atomic remote hook repair, Copilot registration, optional Codex fallback monitor, automatic/single-session transport mode, and reverse tunnel. WSL is outside the macOS product boundary |
| Custom animated asset packs | theme importer seam | Implemented for validated folder/ZIP themes with ImageIO animation plus static SVG fallback, per-theme idle visual selection, and bounded frame caching (downsampled frames, per-animation and total cache byte budgets); upstream Codex Pet atlas/capability schema is not bundled. Built-in pets are original characters (Pinch, Patches, Cumulus) drawn natively — no upstream character names or artwork are reused |
| GitHub release updater | update service seam | Implemented: compatible macOS asset selection, download, safe filename, SHA-256 verification, and Finder reveal; installation remains a deliberate manual step. Reachable from Settings → Remote and from the tray and pet "Check for Updates…" menus. The default repository is the Clawdesk project itself, never the upstream release feed |

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
