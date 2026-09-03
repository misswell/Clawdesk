# Upstream sync changelog

## 2026-09-03 — parity batch 2 (turn machine, doctor, session actions)

- **Codex official-hook turn machine** ported into the session store
  (`server-codex-official-turns.js`): turns open on UserPromptSubmit, tool
  events mark activity (FIFO table capped at 200), a Stop resolves
  attention only with tool activity or final assistant output — a quiet
  turn ends idle — `stop_hook_active` drops the completion side effects,
  and subagent-role Stops resolve headless/idle.
- **Doctor breadth**: the upstream eight-check sweep minus Windows-only
  probes — per-agent integrations plus system checks (preferences, local
  server, permission policy, Feishu approval config, theme health, Remote
  SSH ingress/isolation) and a copyable markdown report with home paths
  redacted, surfaced in Settings → Doctor.
- **Session actions**: dashboard rename (persisted aliases, empty restores
  the automatic title) and hide (dismiss recomputes the aggregate), plus
  the upstream hotkey rule that ⌃⇧Y/⌃⇧N target the NEWEST visible card.
- 319 tests green; app rebuilt and redeployed.

## 2026-09-03 — parity batches P1–P3 (same-day follow-up to the audit)

- **P1 wire fidelity**: Claude Code/CodeBuddy permission decisions now reply
  in the `hookSpecificOutput` envelope (allow echoes `updatedInput` so
  ExitPlanMode works; deny carries a message; no-decision stays 204);
  PostToolUse/Stop/SessionEnd/UserPromptSubmit sweep pending bubbles with a
  no-decision ("answered in terminal"); PASSTHROUGH_TOOLS
  (TaskCreate/TaskUpdate/TaskGet/TaskList/TaskStop/TaskOutput) auto-allow;
  `addRules` suggestions merge into one entry; a `~/.claude` directory
  watcher triggers a health check ~1 s after an external overwrite
  (`ClaudeSettingsWatcher`); sessionless hook posts coalesce onto
  `<agent>:default` instead of orphan UUIDs; ownership detection no longer
  claims arbitrary localhost `/permission` URLs.
- **P2 pet window**: Hide/Show Pet layer (persisted, ⌃⇧P, context + status
  menus, HUD/quota follow); drag clamped to the attached-display union plus
  startup off-screen fallback; mini mode snaps on both edges with exit
  anti-resnap and click-to-exit; 400 ms click accumulator; Cmd-click opens
  the dashboard; upstream roam cadence/speed/margins (8 s/4 s, 80 px/s, 15%,
  100 px min hop, permission-bubble hold, drag cancel).
- **P3 companions**: menu-bar completion/error flash; `test_result` hook
  reaction; updater "Later" pipeline (persisted dismissals, reconcile prune,
  background-check suppression); dashboard per-session Open Folder.
- Verification: 310 tests green, `scripts/build-app.sh` succeeds.

## 2026-09-03 — clawd-on-desk parity audit (latest main `e5855877`) + P0 fixes

- Audited ~600 upstream behaviors across five domains against latest main
  (51 commits beyond the v0.16.0 baseline). Full matrix in
  `docs/PARITY_AUDIT_2026-09-03.md`.
- P0 correctness/security batch landed: transient permission/question events
  no longer create or overwrite session rows (upstream lifecycle rule), the
  pending-permission overlay pins the aggregate and resolution restores it;
  stale cleanup mirrors upstream (10 min idle delete, 5 min silent working
  demotion, 20 min Codex/OpenCode floor); duplicate Claude Stop deliveries no
  longer re-celebrate; headless sessions stay out of the dominant state and
  resolve permission requests with a no-decision; `assistant_last_output` is
  control-char-scrubbed and capped at 2400; the session menu comparator now
  sorts by state priority then recency (dead-code fix).
- Remote egress hardening: new `SecretRedactor` (port of upstream
  `secret-redact.js`) applied to every Telegram/Feishu/Slack payload, and the
  approval cards follow upstream's rule that commands and raw tool input
  never leave the desktop (redacted title + action + path/URL fallback
  only). Telegram approval taps now fail closed on both approver ID and
  chat ID.

## 2026-08-30 — clawd-on-desk v0.16.0 parity audit

- Advanced the tracked agent baseline from `a7283581` to `c8c153cc` (51
  upstream commits, v0.16.0).
- Added the TraeCode (Trae CN) state-only integration with the documented six
  events, nested hook schema, bounded fail-open transport, `{}` stdout,
  namespaced sessions, and first-safe-prompt title semantics.
- Upgraded the native permission surface with a scrollable simultaneous-request
  queue, expandable action/command/input details, fixed/follow-pet placement,
  and per-agent bubble switches.
- Added Claude background-subagent/task/cron Stop gating and an independent
  active Codex silence timeout so long-running work is not celebrated or
  removed prematurely.
- Kept v0.16.0 artwork accessories, Discord Rich Presence, tutorial-only UI,
  and non-macOS platform deployment outside the native core parity boundary.

## 2026-08-29 — bloub customization sync

- Ported the customizer layer: 8 analytic body shapes, 12 colours and 16
  resting expressions (`Pet/Bloub/Appearance/`), including the eye-fit
  translation table (same build-time directional solver as upstream, keyed by
  shape ID).
- Engine gained `setShape`/`setExpression` (0.45 s ease-out morphs, replay
  pure) and the two-axis eye-offset interpolation along shape × expression
  morph bounds.
- `BloubAppearance` persisted in `AppPreferences`, surfaced in Settings →
  Desktop pet (body shape / body colour / resting expression); the default
  `theme` colour keeps the built-in look untouched.
- Appearance fixtures captured from the upstream engine (shape radii,
  expression tables, sampled eye-fit offsets).

## 2026-08-29 — bloub initial sync

- Synced `jeremy-prt/bloub` @ `b4bb3c1b5f93c7b87a2e8d620f667c4093d97749`
  (main).
- Ported the full bloub engine to native Swift: 14 catalogue states + `swirl`,
  64-sample radial profile morphing with transition-continuity freeze,
  spherical eye model, decoration catalogue (orbit rings, thinking dots,
  burst particles, comet ribbons, notification badge), clock-less `sample(at:)`
  semantics.
- Introduced `BloubStateMapper` as the single seam between `PetState` (agent
  semantics) and `BloubState` (pet appearance); the agent runtime never
  references bloub types.
- `PetCanvasView` now renders the built-in pet from engine frames
  (back arcs → dots behind → body → eyes → dots → badge → front arcs) and hit
  tests against the current body path.
- Added the `BloubTests` target with geometry fixtures captured from the
  upstream TypeScript engine.
- See `Upstream/MAPPING.md` and `Upstream/COMPATIBILITY.md`.

## clawd-on-desk

Tracked in `docs/UPSTREAM_PARITY.md` (baseline
`c8c153cce4fe1f0452e00212e0cd1d2725547f61`).
