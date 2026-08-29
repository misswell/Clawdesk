# Clawdesk project notes

Clawdesk is a native macOS Swift implementation of the behavior of
[clawd-on-desk](https://github.com/rullerzhou-afk/clawd-on-desk). The upstream
repository is the product specification; this repository deliberately keeps a
native implementation instead of embedding its Electron renderer.

The pet's visual and motion language comes from a second upstream,
[jeremy-prt/bloub](https://github.com/jeremy-prt/bloub), ported to a native
CoreGraphics engine. Follow clawd-on-desk for agent behavior and bloub for pet
motion behavior; never couple an agent directly to an animation.

## Upstream tracking

Both upstreams are tracked independently in `Upstream/` (manifests, mapping,
compatibility notes, sync changelog).

- Agent upstream: `https://github.com/rullerzhou-afk/clawd-on-desk`
- Agent baseline inspected: `a7283581f1d46421beba91ef10ffaa994bc0a52f`
- State semantics: upstream `docs/guides/state-mapping.md`
- Pet upstream: `https://github.com/jeremy-prt/bloub` (see
  `Upstream/bloub.json` for the synced commit)

When the agent upstream changes, update the adapter seams in this order:

1. Compare the upstream state-mapping and setup guides.
2. Update `EventStateMapper` and `SessionStore` for new lifecycle semantics.
3. Update the relevant `HookInstaller` adapter without changing the local event
   server or renderer interface.
4. Add a behavior test before changing the implementation.
5. Run `swift test` and `scripts/build-app.sh`.

When the pet upstream changes, compare against `Upstream/MAPPING.md`, update
`Pet/Bloub/` (geometry, states, engine, decorations) and the fixtures in
`Tests/Bloub/` — never the agent seams — then run the same verification.

## Native architecture

- `Domain/EventStateReducer.swift` is the stable state seam.
- `Infrastructure/LocalEventServer.swift` is the stable hook transport seam.
- `Infrastructure/HookInstaller.swift` is the replaceable integration seam.
- `Pet/BloubStateMapper.swift` is the only seam between `PetState` (agent
  semantics) and `BloubState` (pet appearance); the agent runtime never
  references bloub types.
- `Pet/Bloub/BloubEngine.swift` is a clock-less engine: `sample(at:)` is a pure
  function of time, and all inputs enter through timestamped setters.
- `UI/PetCanvasView.swift` is a low-memory CoreGraphics renderer; it does not
  decode a continuously running web animation timeline.
- `ClawdeskModel` is the main-actor coordinator used by AppKit and SwiftUI.

Keep the public interfaces small and keep agent-specific configuration inside
its adapter. Do not make UI code parse agent payloads directly.

## Verification

```sh
swift test
scripts/build-app.sh
```

The generated application is `dist/Clawdesk.app`. Build caches such as `.build`
are disposable and should not be committed.
