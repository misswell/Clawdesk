# Clawdesk 95% parity audit — 2026-08-30

Reference: `rullerzhou-afk/clawd-on-desk` v0.16.0 at
`c8c153cce4fe1f0452e00212e0cd1d2725547f61`.

## Result

Clawdesk covers all 19 core native-macOS behavior groups below. The visual
theme-extension group is behavior-complete but intentionally substitutes the
original bloub renderer and does not import the upstream artwork/accessory
schema. Counting that partial group conservatively gives **19/20 = 95%** for
the requested product scope.

This percentage is a capability-group audit, not a source-line comparison.
Electron, DOM, Windows/WSL/Linux packaging, and upstream-owned artwork are not
requirements for a native Swift macOS implementation.

## Capability matrix

| # | User-facing capability group | Evidence | Result |
| --- | --- | --- | --- |
| 1 | Lifecycle state mapping and priority | `EventStateMapper`, `SessionStore`, reducer tests | Complete |
| 2 | Every upstream v0.16.0 macOS agent adapter | `AgentRegistry`, `HookInstaller.supportedAgentIDs`, all-adapter install test; includes TraeCode | Complete |
| 3 | Concurrent sessions and subagent tiers | session reducer, dashboard/HUD tests | Complete |
| 4 | Claude background work completion gate | typed subagent/task/cron/Stop-hook fields and reducer tests | Complete |
| 5 | Native animated pet state catalogue | `BloubEngine`, numeric fixtures, snapshots | Complete |
| 6 | Cursor gaze, click reactions, drag, mini mode | `PetCanvasView`, `PetWindowController`, interaction tests | Complete |
| 7 | Sleep/wake sequence, DND and sounds | sleep planner/model tests, theme sound routing | Complete |
| 8 | Free roam and user-selected roam fence | planner/coordinator and fence tests | Complete |
| 9 | Permission review and agent-native responses | event adapters, local server, permission model | Complete |
| 10 | Simultaneous permission queue, expanded details and placement | bounded SwiftUI scroll queue, disclosure cards, fixed/follow placement preferences | Complete |
| 11 | Per-agent bubble control, shortcuts and automation policy | agent switches, global shortcuts, fail-closed policy tests | Complete |
| 12 | Dashboard, Session HUD and terminal focus | window controllers, HUD geometry/context tests | Complete |
| 13 | Context and subscription quota display | statusline/Codex adapters, quota/ring tests | Complete |
| 14 | Startup recovery, process liveness and active-work retention | process probe and cleanup tests | Complete |
| 15 | Local hook server and startup integration repair | bounded local server, doctor, sync/health tests | Complete |
| 16 | Mobile read-only PWA/WebSocket companion | token, rate-limit and protocol tests | Complete |
| 17 | Native Remote SSH transport | profile-bound nonce, hook deployment and tunnel tests | Complete |
| 18 | Preferences, i18n, launch-at-login and single instance | preference/localization/runtime seams | Complete |
| 19 | Secure native auto-update | signed-package validation, updater/rollback tests | Complete |
| 20 | Theme import and upstream visual extension schema | native folder/ZIP animated themes work; Codex Pet atlas and independent head/mouth accessories are not ported | Partial |

## Explicit exclusions

- Remote Telegram/Feishu approval is not required by the requested scope. The
  existing implementation remains available but is not used to inflate the
  95% score.
- Windows, WSL and Linux behaviors are outside a native macOS product target.
- Discord Rich Presence and the first-run tutorial are optional companion UI.
- The upstream artwork license is separate from its source license. Clawdesk
  reproduces behavior with its original bloub-based renderer instead of
  redistributing or imitating the upstream character assets.

## Verification

- `swift test`: 242 tests passed, 0 failures.
- `CLAWDESK_ALLOW_ADHOC=1 scripts/build-app.sh`: production build succeeded.
- `codesign --verify --deep --strict dist/Clawdesk.app`: valid on disk and
  satisfies its designated requirement.
- Local artifact: `dist/Clawdesk.app`, arm64, ad-hoc signed. A Developer ID
  identity is still required for a distributable build.
