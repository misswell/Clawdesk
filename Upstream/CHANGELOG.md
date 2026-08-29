# Upstream sync changelog

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
`a7283581f1d46421beba91ef10ffaa994bc0a52f`).
