# Clawdesk project notes

Clawdesk is a native macOS Swift implementation of the behavior of
[clawd-on-desk](https://github.com/rullerzhou-afk/clawd-on-desk). The upstream
repository is the product specification; this repository deliberately keeps a
native implementation instead of embedding its Electron renderer.

## Upstream tracking

- Upstream: `https://github.com/rullerzhou-afk/clawd-on-desk`
- Baseline inspected: `a7283581f1d46421beba91ef10ffaa994bc0a52f`
- State semantics: upstream `docs/guides/state-mapping.md`

When upstream changes, update the adapter seams in this order:

1. Compare the upstream state-mapping and setup guides.
2. Update `EventStateMapper` and `SessionStore` for new lifecycle semantics.
3. Update the relevant `HookInstaller` adapter without changing the local event
   server or renderer interface.
4. Add a behavior test before changing the implementation.
5. Run `swift test` and `scripts/build-app.sh`.

## Native architecture

- `Domain/EventStateReducer.swift` is the stable state seam.
- `Infrastructure/LocalEventServer.swift` is the stable hook transport seam.
- `Infrastructure/HookInstaller.swift` is the replaceable integration seam.
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
