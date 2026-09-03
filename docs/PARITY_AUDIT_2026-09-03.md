# Upstream parity audit — 2026-09-03 (in progress)

Reference: upstream main `e5855877` (= v0.16.0 `c8c153cc` + 51 never-audited
commits). Audit performed domain-by-domain against
`/tmp/clod-main-audit` (materialized worktree). Status values: IMPLEMENTED /
PARTIAL / MISSING / OUT-OF-SCOPE. This file is appended to as each domain
audit lands; the consolidated gap matrix lives at the bottom.

## Domain: permission / bubble / remote approval / notification

~118 behavior clusters: IMPLEMENTED 26 · PARTIAL 30 · MISSING 55 · OOS 7.

Top gaps:

1. **Secret redaction absent on every remote egress.** Upstream redacts every
   remote payload (`secret-redact.js`, `compactRemoteApprovalText`,
   `safeLarkMd`, `scrubCredentials`); Clawdesk sends raw command/input/title to
   Telegram/Feishu/Slack and violates upstream's rule that `command`/`query`
   never leave the desktop bubble
   (`RemoteNotifier.swift:264-278`, `FeishuApprovalTransport.swift:358-366`).
2. **No overflow/queue presentation model.** Upstream overflow drawer, per-session
   representatives, queue ACK commit, expanded-card measurement epochs,
   fullscreen/pet-hidden suppression (`permission.js:799-830,1900-2098`) have no
   counterpart; Clawdesk's lossy 32-item defer-eviction
   (`ClawdeskModel.swift:36,400-403`) can silently drop the oldest approval.
3. **No interaction-intent model** — plan review (approve/reject/feedback),
   answerable elicitation (in-bubble stepper + remote elicitation cards),
   decision-tool fail-closed classification, per-adapter response contracts
   (Codex/Qwen/Copilot/Hermes/DSH/opencode); only ZCode got a real port.
4. **Slack channel far behind** — Clawdesk announces permissions
   unconditionally (before the bubble decides) to an unvalidated webhook URL;
   upstream has gating, bounded queue, retry classification, credential
   scrubbing, host pinning (`ClawdeskModel.swift:281` vs `slack-notify-client.js`).
5. **Telegram/Feishu hardening** — no chat-id/message-id binding on taps, no
   status rewrite after desktop-side decisions, no conflict/429 handling, no
   test-card verification, no token env-file isolation, no remote elicitation.

Notable detail diffs: per-category bubble autoclose timers missing (upstream
6/9/0s defaults, 0 disables; Clawdesk fixed 300s defer that cannot be disabled);
hotkey resolves oldest instead of newest visible card; passive Codex/Kimi
informational cards missing; Antigravity/irreversible-action badge/MCP pill
formatting missing; Feishu approver provenance binding + WS status machine +
email→open_id lookup missing; permission body-size cap (512KB) missing;
PASSTHROUGH_TOOLS auto-allow missing; headless permission gate missing.

## Domain: pet window / interaction / roam / idle

~120 behaviors: IMPLEMENTED ~40 · PARTIAL ~45 · MISSING ~30 · OOS ~15.

Top gaps (mac-relevant):

1. **Pet hide/show does not exist** — no Hide/Show Pet item (context menu +
   tray), no `petHidden` layer (`pet-window-runtime.js:1361-1466`,
   `menu.js:330-344`).
2. **Edge-pinning + clamping absent** — no drag clamp
   (`clampToScreenVisual`, `computeFinalDragBounds`, `looseClampPetToDisplays`),
   no startup off-screen regularization (unplugged display → pet restores
   off-screen).
3. **Accessory/customization system missing** — hats/tints/mouth slot/holiday
   accessories + hitbox/layout/mirror machinery (6 files) have no counterpart.
4. **Mini mode right-edge only, simplified** — no left-edge snap (8pt vs 30px
   tolerance), no theme offsetRatio, no exit parabola/anti-resnap shift, no
   click-to-exit-mini, no mini display-change reflow.
5. **Roam semantics drift** — 10–20s cadence vs 8s/4s; fixed 1.6s walk vs
   80px/s; 8px margins vs 15%; no axis-constrained roam (#686); no
   permission-bubble hold gate (new in main); drag doesn't cancel in-flight
   roam.
6. **Click reaction set differs** — no side-based clickLeft/clickRight or
   annoyed reaction, 900ms vs 400ms accumulator, no Cmd-click dashboard
   shortcut, no mini exit on click.
7. **IME editing dodge missing** — no pet fade/click-through while a text
   bubble overlaps the pet (#640, mac-relevant).
8. **Session focus is PID-activate only** — no iTerm/Ghostty/tmux/cmux/Orca/
   Superset per-tab focus, no throttle/dedup/queue, no codex deep-link, no
   open-folder affordance.
9. **No tray completion flash, no test-result reaction, no text-scale.**

Non-gaps: Linux reconcile/edge-virtualization stack, Windows cloak/HWND/
topmost/#935-fullscreen work, taskbar, WSL — OUT-OF-SCOPE.

## Domain: state machine / session runtime

118 behaviors: IMPLEMENTED 33 · PARTIAL 42 · MISSING 38 · OOS 5.

Core is solid: state priority order, sleep-sequence timings (yawn 3 s /
doze→collapse 600 s / wake 0.35-1.5 s / direct mode / DND), subagent identity
tracking with parent resume, Claude Stop completion gate with debounce,
cursor-spin dizzy constants, idle animation cycle, startup recovery, Kimi
suspect/gate ledger, theme fallback/idle-visual selection.

Top gaps:

1. **Stale-cleanup contract diverges** (`state-stale-cleanup.js`): no
   working-timeout idle demotion, no Codex/OpenCode 20-min floors, no 30-s
   detached cleanup, no desktop-idle (Codex/ZCode/Trae) timeouts, 15 min vs
   10 min idle cutoff — a dead silent CLI can leave "working" forever.
2. **Session automation (trust grants) missing**
   (`session-automation-store/coordinator/identity/remote`): no per-session
   auto-tools grants, CAS/revoke, identity eligibility, remote card lifecycle.
3. **Notification/permission lifecycle leak**: permission events create
   `.notification` session rows for unknown sessions (upstream forbids) and
   the row is never downgraded after resolve; no `permissionLocked` aggregate
   pin; duplicate Stop re-celebrates (no completion-tail suppression).
4. **Account-quota per-source semantics + shared-file schema clash**
   (`state-account-quota.js` v6 host-keyed vs Clawdesk v1 provider-keyed on
   the same `~/.clawd/account-quota.json`) — downgrade + cross-tool hazard.
5. **No canonical session identity / snapshot fidelity**: no `s1`
   profile-scoped keys, no aliases/TTL, no done/interrupted badges, no
   snapshot signature dedup, no host/WSL grouping, no MAX_SESSIONS=20 cap, no
   recap pipeline; ER:113-118 menu sort has identical ternary branches
   (latent bug, intended state-priority sort is dead code).

Also missing: DSH watermark fence (macOS supported upstream), Qwen
self-submit filter (2 s window), Antigravity trailing-PostToolUse drop,
system-wake handling, per-agent notification mute, idle easter eggs,
adaptive tick ladder, session eviction, title sanitization (bidi/control
chars), displayHint, session eviction, `touchSessionActivity` liveness,
updater visual-state override, headless dominant-state exclusion.

## Domain: event server / hooks / agents

~120 behaviors: IMPLEMENTED ≈40 · PARTIAL ≈45 · MISSING ≈25 · OOS ≈8.

Strengths: agent roster at full parity (24 agents incl. new traecode); ZCode
permission contract is a near-exact port; Kimi suspect/gate ledger, traecode
title redaction, Gemini PreCompress preservation, Claude Stop
hold/debounce arbitration all faithfully mirror upstream.

Top gaps:

1. **Claude permission decision wire contract** — Clawdesk replies top-level
   `{behavior}` with no `hookSpecificOutput.permissionDecision` and no
   `updatedInput`, so ExitPlanMode-allow and strict CC parsers misbehave
   (`server-route-permission.js:1972-2160` vs
   `AgentEventAdapters.swift:389-396`).
2. **No pending-permission lifecycle correlation** — upstream resolves
   bubbles when the user answers in the terminal (PostToolUse/Stop/SessionEnd
   sweeps via `findPendingPermissionForForStateEvent` + tool fingerprints);
   Clawdesk leaves requests to time out.
3. **No Claude settings watcher** — directory fs.watch + repair signature +
   suspicious-shrink guard reduced to a 5-minute marker/script check
   (`claude-settings-watcher.js` vs `ClaudeHookHealthMonitor.swift`).
4. **Codex official-hook state machine absent** — turn table, stop_hook_active
   drop, subagent headless/idle, turn fence, JSONL↔official suppression,
   token_count metadata (`server-codex-official-turns.js`,
   `codex-turn-fence.js`, `codex-official-activity.js`).
5. **DSH integration state-only** — no version-pinned verified contracts, no
   sequence fence, no blocking approval waterfall.
6. **Hermes/Copilot/opencode-family permission contracts diverge** — Hermes
   has no approval/elicitation hooks; opencode uses synchronous reply instead
   of reverse bridge + `permission_event:"replied"`.
7. **Elicitation/suggestion fidelity** — Claude `AskUserQuestion` not parsed
   as question cards; `permission_suggestions` lack `addRules` merge; no
   `PASSTHROUGH_TOOLS`; headless doesn't suppress permission bubbles.
8. **Recap/Footprints provenance fields** — `recap_boundary`/`recap_is_subagent`
   etc. and the whole recap stack absent (contained, no transport breakage).
9. **Runtime identity/diagnostics** — no ownerPid liveness anchor, no
   hook-event diagnostics ring, no `x-clawd-server` header, no
   `X-Clawd-Metadata-Accepted`, sessionless posts create fresh-UUID orphans
   instead of per-agent `default` sessions.
10. **Missing macOS utilities** — `launch-claude.js` terminal launcher (new
    session/resume/continue in Terminal.app), Ghostty terminal-id capture,
    Codex Pet theme importer.

Also: Claude hook registers WorktreeCreate which upstream explicitly
deprecated (breaks `claude -w`); antigravity missing statusline install;
`containsManagedEntry` claims any 127.0.0.1/permission URL (ownership
overreach); server-agent-id lacks hook_source mapping / CC-subagent
disambiguation; `assistant_last_output` not scrubbed/capped; named quota
fields (`claude_quota`/`codex_quota`/…) unparsed; `/state` 16 KiB cap vs
Clawdesk 512 KiB.

## Domain: settings / dashboard / HUD / quota / themes / misc

128 behaviors: IMPLEMENTED 34 · PARTIAL 39 · MISSING 46 · OOS 9.

Top gaps:

1. **Recap/Footprints end-to-end** (new upstream feature): runtime + store +
   Settings tab + `recapEnabled` — no Clawdesk counterpart at all.
2. **Kimi quota stack** — opt-in collection, encrypted credential store,
   client/normalizer/runtime, Settings + Dashboard refresh UI.
3. **Quota ring display controls** — used|remaining mode, hidden providers,
   merge sources, staleness/expiry handling, per-source Dashboard grouping.
4. **Session aliases + Dashboard actions** — rename, hide, open folder,
   mark-read ack, per-session automation override.
5. **Global shortcuts framework** — customizable accelerators with recording
   UI + togglePet action (Clawdesk hardcodes ⌃⇧Y/⌃⇧N only).
6. **Updater pending-version pipeline** — dismissed versions, startup
   reconcile, tray badge, error classification; 12h vs 6h scheduler.
7. **Doctor breadth** — 8 upstream checks vs Clawdesk's agent-integrations
   only; no redacted diagnostic report, no log opener.
8. **Stale-interval preferences** (`sessionStaleMs`/`workingStaleMs`/…) and
   behavior toggles `keepAwakeWhileWorking`/`keepSizeAcrossDisplays`/
   `allowEdgePinning`/`disableMiniMode`/`roamConstrainAxis`.
9. **HUD completeness** — state-label/elapsed toggles, unread bell,
   interrupted chip, per-row open-folder, compact 3-row mode.
10. **Discord Rich Presence, pt-BR localization, first-run tutorial,
    text-scale, sound-override editing, log rotation, mac app-Hide bridge.**

Note: the c8c153cc..e5855877 delta has NO theme-schema/sanitizer changes
(empty diff). Remote SSH lacks identity rotation / `chainStatusline` /
`connectOnLaunch` profile fields.

## Consolidated verdict (2026-09-03)

~600 upstream behaviors audited across 5 domains:
**IMPLEMENTED ≈175 · PARTIAL ≈200 · MISSING ≈194 · OUT-OF-SCOPE ≈44.**

Core architecture (state machine, 24-agent hook roster, transport seams,
sleep/idle/gaze, HUD/quotas, updater, mobile/SSH) is genuinely at parity,
but upstream detail fidelity is far from complete: the biggest structural
absences are the Recap feature, session-automation trust grants, the
overflow-queue permission drawer, accessory/tint customization, Kimi quota,
Discord presence, the tutorial, and the cross-cutting secret-redaction layer
(a security gap, not just parity).

Priority fix batches (this repo's chosen order):

- **P0 correctness/security — DONE 2026-09-03**: permission session-row leak,
  stale-cleanup alignment, duplicate-Stop suppression, menu-sort dead code,
  headless gating, assistant-output scrub, remote-egress secret redaction +
  command-never-leaves rule, Telegram chat-id binding.
- **P1 wire fidelity — DONE 2026-09-03**: Claude `hookSpecificOutput` +
  `updatedInput` reply, pending-permission lifecycle sweep, PASSTHROUGH_TOOLS,
  suggestion `addRules` merge, `~/.claude` settings watcher, per-agent
  default session keys, ownership-marker overreach fix.
- **P2 pet/window — DONE 2026-09-03**: pet hide/show (menus + ⌃⇧P), drag
  clamp + startup off-screen fallback, left-edge mini snap + anti-resnap +
  click-to-exit, 400 ms click accumulator, Cmd-click dashboard, roam
  cadence/speed/margins + bubble hold + drag cancel.
- **P3 companions — partially DONE 2026-09-03**: menu-bar completion flash,
  test-result reaction, updater "Later"/dismissed-version pipeline,
  dashboard Open Folder, ⌃⇧P togglePet shortcut.
- **P3 remaining (next sessions)**: Recap feature, session automation (trust
  grants), overflow-queue permission drawer, Kimi quota stack, session
  aliases/mark-read/hide, customizable shortcuts framework, doctor breadth
  expansion, Discord Rich Presence, first-run tutorial, pt-BR localization,
  text-scale, accessory system (needs design decision vs bloub customizer),
  Codex official turn machine, per-agent response contracts (Hermes/opencode
  reverse bridge), elicitation answering.
