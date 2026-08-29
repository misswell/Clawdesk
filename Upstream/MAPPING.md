# Upstream responsibility mapping

Clawdesk has two upstreams, synced independently:

- **clawd-on-desk** — agent behavior (hooks, sessions, permissions, runtime).
  See `docs/UPSTREAM_PARITY.md`.
- **jeremy-prt/bloub** — pet appearance and motion language. This file.

The bloub mapping is a **responsibility mapping, not a line-by-line
translation**: the Vue/SVG/DOM rendering is deliberately replaced by a native
CoreGraphics engine with the same observable geometry.

## bloub → Clawdesk

| bloub source | Clawdesk seam | Status |
| --- | --- | --- |
| `src/bot/engine.ts` (`BotEngine`, `BotFrame`, `Look`) | `Pet/Bloub/BloubEngine.swift` (`BloubEngine`, `BloubFrame`, `BloubLook`) | Ported: clock-less `sample(at:)`, timestamped setters, transition-continuity freeze, forced blink, gaze blending |
| `src/bot/states.ts` (15 `StateId`s, `Pose`, pose functions) | `Pet/Bloub/BloubState.swift` (`BloubState`, `BloubStates.catalog`, `BloubPose`) | Ported: all 14 catalogue states + `swirl`, measured constants verbatim |
| `src/bot/shape.ts` (`Silhouette`, profiles, blend, paths) | `Pet/Bloub/BloubGeometry.swift` (`RadialProfile`, `BloubBody`, `BloubShapeFactory`, `BloubPaths`) | Ported: 64-sample radial profiles, Catmull-Rom closed path, capsule, ray-cast polygon, hull of circles, shortest-path rotation blend |
| `src/bot/profiles.ts` (measured egg/hexagon/triangle) | `Pet/Bloub/BloubGeometry.swift` (`BloubProfileFixture`) | Ported verbatim (compatibility fixtures) |
| `src/bot/face.ts` (spherical eye model, blink, liveliness) | `Pet/Bloub/BloubFace.swift` (eye poses, blink scale) + `Domain/BloubMotion.swift` (gaze mapping, blink calendar, drift) | Ported: `BloubMotion` predates the full port and keeps the pure motion model; the engine consumes it |
| `src/bot/decor.ts` (arcs, rings, particles, comet, notification) | `Pet/Bloub/BloubDecoration.swift` (`BloubDecor`, `BloubArcSeed`, seeds) | Ported: identical PRNG seeds and call order; hue wheel quantised to 8 bits like upstream |
| `src/bot/math.ts` (TAU, easings, mulberry32, loopNoise) | `Pet/Bloub/BloubGeometry.swift` (`BloubEase`, `BloubRandom`) + `Domain/BloubMotion.swift` | Ported |
| `src/bot/repere.ts` (viewBox helpers) | not needed — the engine speaks screen points and the renderer owns the window transform | N/A |
| `src/bot/skins.ts` (8 customizer body shapes, 12 colours) | `Pet/Bloub/Appearance/BloubShapes.swift` (`BloubShapeID`, `BloubShapeCatalog`, `BloubColorID`) | Ported: analytic pebble/cloud/droplet/capsule/squircle/rounded polygons + colour palette |
| `src/bot/expressions.ts` (16 rest expressions) | `Pet/Bloub/Appearance/BloubExpressions.swift` (`BloubExpressionID`, `BloubExpression`) | Ported: measured faces, mirrored/asymmetric tilts verbatim, gliding blend |
| `src/bot/eyefit.ts` (tabulated eye offsets for custom shapes) | `Pet/Bloub/Appearance/BloubEyeFit.swift` | Ported: same build-time directional solver (footprints, segment approach, 12 directions × 8 bisections); table keyed by shape ID instead of array identity |
| `src/bot/cycles.ts` (timeline editor blocks) | not ported — Clawdesk drives states from agent events, not a montage editor | N/A (deliberate) |
| `src/components/BloubBot.vue` (SVG render order, mask) | `UI/PetCanvasView.swift` (`drawBloubFrame`) | Adapted: same draw order (back arcs → dots-behind → body → eyes → dots → badge → front arcs); eye holes become paper capsules clipped to the body path so the transparent desktop shows through correctly |
| `src/App.vue` (pointer tracking, look driving) | `UI/PetCanvasView.swift` (`setPointerLocation`, `updateBloubLook`) + `UI/PetWindowController.swift` | Adapted to AppKit pointer polling |

## Clawdesk-only layers (no bloub counterpart)

| Layer | File |
| --- | --- |
| `PetState` (agent semantics) → `BloubState` mapping | `Pet/BloubStateMapper.swift` |
| Appearance persistence + Settings UI | `Infrastructure/AppPreferences.swift` (`bloubAppearance`), `UI/SettingsView.swift`, `Pet/Bloub/Appearance/BloubAppearance.swift` |
| Theme palette bridge (theme colors → `BloubPalette`) | `UI/PetCanvasView.swift` |
| Window/hit-testing/drag/mini-mode | `UI/PetWindowController.swift`, `UI/PetCanvasView.swift` |

## Compatibility tests

`Tests/Bloub/` pins the port with fixtures captured by running the upstream
TypeScript engine at the synced commit (`BloubFixtureTests`): orbit @
0.0/0.1/0.5/1.0 body and eye matrices, ring seeds, per-state pose constants,
spherical eye projections at the rest and wide gazes. The appearance layer is
pinned the same way (`BloubAppearanceTests`): analytic shape radii, the 16
expression tables, and sampled eye-fit solver outputs for every shape.
Structural behaviour (purity, continuity, easing, decorations) is covered by
the state/shape/morph/eye/gaze/timing suites in the same target.

Never judge bloub compatibility by screenshots alone; the fixture numbers are
the contract.
