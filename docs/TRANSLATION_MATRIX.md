# Upstream → Clawdesk translation matrix

Working audit of the upstream `clawd-on-desk` implementation (`src/**`, `hooks/**`,
baseline `e4961f25…`) translated module-by-module into native Swift Clawdesk.
Status legend:

- **Done** — semantics implemented in Clawdesk (native seam listed).
- **Partial** — core behavior implemented; details pending.
- **Missing** — not yet translated.
- **Excluded** — intentionally out of the macOS product boundary (documented).

## Server / event / state

| Upstream module(s) | Status | Clawdesk seam |
| --- | --- | --- |
| `server.js`, `server-route-state.js`, `server-route-permission.js`, `server-hook-events.js`, `server-permission-utils.js`, `server-agent-id.js` | Done | `LocalEventServer` |
| `server-codex-official-turns.js` | Partial | Codex official hook path + JSONL fallback |
| `state.js`, `state-priority.js`, `state-session-events.js`, `state-session-snapshot.js`, `state-stale-cleanup.js`, `state-session-dedupe.js` | Done | `EventStateReducer` / `SessionStore` |
| `state-visual-resolver.js`, `state-agent-icons.js`, `state-hitbox-resolver.js` | Partial | visual mapping done; agent icons/hitboxes pending |
| `state-account-quota.js` | Partial | `QuotaStore`; account-level persistence pending |
| `subagent-lifecycle.js`, `server-windows-process-metadata.js` | Partial | subagent count mapping; Windows process metadata excluded |
| `transcript-path.js`, `codex-monitor-callback.js`, `codex-official-activity.js`, `codex-assistant-output.js`, `codex-session-index.js`, `codex-user-input.js`, `codex-subagent-fields.js`, `codex-turn-id.js`, `codex-turn-fence.js`, `codex-originator.js` | Partial | `CodexLogMonitor` + adapters |
| `session-alias.js`, `session-key.js`, `session-open-folder.js`, `session-recovery-loader.js`, `session-focus*.js`, `session-ipc.js`, `session-hud*.js` | Partial | Dashboard/Sessions menu focus; Session HUD pending |
| `session-automation-*.js`, `permission-automation-policy.js`, `permission-automation-confirmation*.js` | Partial | `PermissionPolicy` (fail-closed); per-session grants pending |
| `bubble-format.js`, `bubble-policy.js`, `bubble-renderer.js`, `permission.js`, `preload-bubble.js` | Partial | `PermissionBubbleController` + suggestions |
| `agent-gate.js`, `agent-installation-detector.js`, `agent-runtime-main.js`, `agent-display-name.js` | Partial | `AgentRegistry` / `HookInstaller` |

## Agent integrations (`hooks/`, `src/…-install.js`, `src/…-hook.js`)

| Upstream | Status | Clawdesk seam |
| --- | --- | --- |
| claude (hook/install/statusline/rate-limits/stop-disposition), `claude-hook-health.js`, `claude-hook-operations.js`, `claude-settings-watcher.js` | Done | `HookInstaller` + `ClaudeHookHealthMonitor` |
| codex (hook/install/rate-limits/debug/remote-monitor) | Done | `HookInstaller` + `CodexLogMonitor` |
| copilot, gemini, antigravity, cursor, codebuddy, workbuddy, qwen, codewhale, kiro, kimi, reasonix, qoder/qoderwork/qwenwork | Done | `AdditionalHookAdapters` |
| zcode lifecycle + manual `PermissionRequest` approval | Done | `AdditionalHookAdapters` + `AgentEventAdapters` strict ZCode response |
| opencode/mimocode, openclaw, hermes, pi, dsh | Done | `PluginHookAdapters` |
| `context-usage.js`, `antigravity-*` | Partial | statusline quota for Claude; Antigravity context pending |
| `integration-sync.js` | Done | startup reconciliation of explicitly enabled or previously managed integrations; ownership markers prevent unrelated config creation |

## Pet / rendering / themes / roam

| Upstream | Status | Clawdesk seam |
| --- | --- | --- |
| `renderer.js`, `animation-cycle.js`, `mini.js`, `tick.js`, `test-reaction.js`, `text-scale.js`, `size-utils.js` | Partial | `PetCanvasView` + `PetWindowController`; low-power idle random animation cycle is implemented, full SVG timeline/mini transition parity pending |
| `theme-loader.js`, `theme-runtime.js`, `theme-metadata.js`, `theme-context.js`, `theme-sanitizer.js`, `theme-schema.js`, `theme-variants.js`, `theme-fade-sequencer.js`, `theme-assets-cache.js`, `theme-importer` | Partial | `AppPreferences` importer + `PetCanvasView` caching |
| `idle-visual.js`, `pet-customization-catalog.js`, `settings-tab-anim-overrides.js`, `settings-anim-overrides-merge.js` | Partial | idle visual selection done; overrides pending |
| `pet-geometry-main.js`, `pet-window-runtime.js`, `floating-window-runtime.js`, `topmost-runtime.js`, `window-opacity-transition.js`, `display-edge.js`, `drag-position.js`, `work-area.js`, `visible-margins.js` | Partial | window controller covers subset |
| `hit-geometry.js`, `hit-renderer.js`, `pet-accessory-*.js`, `holiday-accessory.js` | Missing | not translated |
| `roam.js`, `roam-fence*.js`, `roam-fence-picker*.js`, `preload-roam-fence-picker.js` | Done | `RoamFence` / `RoamPlanner` / `RoamFenceCoordinator` |
| `quota-ring-geometry.js`, `quota-ring-renderer.js`, `preload-quota-ring.js` | Done | `QuotaRingGeometry` + `QuotaRingView` + pet-attached window |

## Settings / windows / menus / i18n / HUD / tutorial

| Upstream | Status | Clawdesk seam |
| --- | --- | --- |
| `settings-*.js`, `settings-tab-*.js`, `settings-store.js`, `settings-validators.js`, `settings-controller.js`, `preload-settings.js` | Partial | `SettingsView` + `AppPreferences` |
| `menu.js`, `mac-*.js`, `taskbar.js`, `login-item.js`, `launch-claude.js`, `single-instance` | Partial | menus + `LaunchAtLogin` + `SingleInstanceGuard` |
| `i18n.js`, `language-picker.js`, `settings-i18n.js` | Done | `Localization` |
| `dashboard.js`, `dashboard-renderer.js`, `session-hud*.js` | Partial | `DashboardView`; Session HUD pending |
| `tutorial*.js`, `update-bubble.js`, `passive-notify-entry.js` | Partial | auto-update prompt done; tutorial pending |
| `prefs.js`, `secret-redact.js`, `log-rotate.js`, `log-timestamp.js`, `custom-applications.js` | Partial | preferences + runtime.json; log rotation pending |
| `system-wake-recovery.js`, `tray-*.js`, `shortcut-*.js`, `settings-actions-*.js` | Partial | shortcut manager + DND/auto-approve subset |

## Remote notifications / mobile / quota clients / remote SSH / doctor / updater

| Upstream | Status | Clawdesk seam |
| --- | --- | --- |
| telegram-*.js, feishu-*.js, `telegram-native-client.js`, `telegram-direct-send.js` | Partial | `RemoteNotifier` + `FeishuApprovalTransport` |
| `discord-presence-*.js` | Missing | not translated |
| `network/mobile-preview-server.js`, `mobile-protocol` | Done | `MobileBridge` |
| `kimi-quota-*.js` | Missing | not translated |
| `remote-ssh-*.js` | Done | `RemoteSSHManager` |
| `wsl-*.js`, `win-*.js`, `linux-ozone.js` | Excluded | macOS product boundary |
| `doctor.js`, `doctor-*.js`, `doctor-detectors/*` | Partial | `AgentDoctor` + Claude health |
| `updater.js` | Done | `ClawdeskSoftwareUpdater` / `ClawdeskUpdater` |

## Hooks helpers shared by agents

`clawd-hook.js`, `json-utils.js`, `auto-start.js`, `cleanup-integrations.js`,
`codex-install-utils.js`, `codex-session-index.js` — translated into the
shared `/bin/sh` hook transport (`HookInstaller.prepareHookScript`) plus
plugin adapters; JSONC ownership helpers mirror `json-utils.js`.
