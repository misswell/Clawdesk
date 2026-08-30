# Upstream sync changelog

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
