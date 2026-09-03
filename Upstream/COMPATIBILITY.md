# Bloub compatibility notes

What the native engine reproduces, what it adapts, and what it intentionally
does not (yet).

## Reproduced faithfully

- **State catalogue.** All 14 measured states plus the `swirl` interface
  transition, with the measured pose constants (dot positions, bar taper,
  bounce period, ring seeds, notification pop curve) ported verbatim.
- **Determinism.** `sample(at:)` is a pure function of time. Identical state +
  parameters + time give an identical frame; pause/resume/seek/preview are
  exact replays. Fixtures in `Tests/Bloub/BloubFixtureTests` were captured from
  the upstream TypeScript engine and must not drift.
- **Transition continuity.** A state change landing mid-fade starts from the
  frozen displayed composite, not the theoretical target pose. Chained
  mid-morph changes stay continuous by construction.
- **Entry easing.** Exponential ease-out, no body overshoot. The only local
  pops (notification badge, eye opening) are the ones measured upstream. No
  springs were added.
- **Spherical eyes.** The orthographic tangent-frame model with the measured
  rest/wide gazes, per-eye tilt, screen-space blink squash, and depth-based
  fade near the silhouette edge.
- **Depth.** Orbit arcs split front/back at the silhouette plane and are drawn
  around the body; burst particles pass behind the core.

## Adapted for the native pet window

- **State emphasis emblems.** The engine poses stay pinned to the bloub
  fixtures, but at desktop size (and from across a room) the working-family
  motion is too subtle to read. The renderer draws one additional emblem per
  state: a rotating activity ring around the body for `working`/`building`,
  and outlined thought bubbles rising past the head while `thinking`. The
  emblems size off the canvas (the engine frame speaks pixels), animate on
  the same clock, and are pinned by the `working`/`thinking` snapshot
  goldens. This is a deliberate Clawdesk-side presentation layer, not an
  upstream behavior.
- **Eyes as holes → clipped capsules.** Upstream punches real holes in the SVG
  body (mask) and backs them with an opaque `paper` underlay so back arcs do
  not leak through. On a transparent desktop there is no page background: the
  holes would show the actual desktop and leak ring pixels. The renderer
  instead fills paper-coloured capsules clipped to the current body path —
  near the edge they auto-trim (the property the mask existed to provide) and
  occlusion still works.
- **`paper` colour → theme eye colour.** The badge/eye "background" is a
  palette entry (`BloubPalette.eye`) bridged from the active theme instead of
  a fixed page colour.
- **Arc gradients.** SVG linear gradients are replaced by a stroked-path clip
  filled with an equivalent `CGGradient` along the major axis.
- **Coordinate handedness.** The engine speaks y-down screen points; the
  AppKit canvas flips once around the ball centre before drawing engine
  geometry verbatim.
- **Body-path hit testing.** The SVG hit region is replaced by
  `CGPath.contains` on the current silhouette, so transparent areas stay
  click-through as the shape morphs.

## Customizer

The appearance customizer is ported: 8 analytic body shapes, 12 colours, and
16 resting expressions (`Pet/Bloub/Appearance/`), with the eye-fit offset
table so faces stay inside narrow bodies. Two Clawdesk-side adaptations:

- **Table keyed by shape ID** instead of upstream's radii-array identity:
  Swift value semantics have no array identity, and unknown identifiers
  degrade to zero offset the same way.
- **Colour layering.** The customizer colour is opt-in (`theme` is the
  default): until the user picks a swatch, the body follows the active theme
  palette, so the built-in look is untouched. Picking a swatch overrides it.

The eye-fit table builds lazily on first non-circle use (the solver runs at
import time upstream); the circle short-circuits to zero, so default installs
never pay for it.

## Deliberately not ported

- **Cycle editor.** Clawdesk drives pet states from agent events, not from a
  montage timeline.

## License boundary

Bloub's source code is MIT, but its README states that the MIT license covers
the repository code only — the recreated x.ai bot avatar's **visual design
itself is not MIT-licensed**. Clawdesk therefore separates:

- *Bloub source code license* — the engine port above, MIT-attributed in
  `THIRD_PARTY_NOTICES.md`; and
- *Avatar visual design rights* — not claimable from bloub's license.

If Clawdesk is ever publicly released or commercialised, re-evaluate name,
visual similarity, assets and brand recognition; the fallback plan is to keep
the bloub engine architecture and design an original blob character on top of
it (`RadialProfile` + states already make the character swappable).
