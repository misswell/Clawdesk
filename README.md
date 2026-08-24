# Clawdesk

Clawdesk is a native Swift macOS desktop companion for coding agents. It
mirrors agent lifecycle events as a low-overhead floating pet, session dashboard,
and permission bubble without embedding Electron or a browser runtime.

## Build

```sh
swift test
scripts/build-app.sh
open dist/Clawdesk.app
```

The 0.1.17 release keeps the native Session HUD and upstream theme-driven sleep sequence: after the
configured mouse-sleep timeout, full themes transition through yawning, dozing,
collapsing, and sleeping, while direct themes can skip straight to sleeping.
Wake assets, DND yawn skipping, DND-specific transition artwork, and bounded
theme timing values are honored without adding a continuously running web
renderer. It also retains the 0.1.9 idle animation cycle and 0.1.8 startup
integration sync. The Session HUD can be disabled or pinned open, uses a small
pet-to-HUD hot zone, and the transparent pet canvas clears interaction states
without leaving the former hover/drag corner bars behind. Pointer interaction
states also ignore optional theme interaction artwork and flush the transparent
canvas immediately, so hover and drag cannot reintroduce corner-line artifacts.
Pointer interaction assets are now rejected at the theme boundary, and the
transparent pet surface disables AppKit focus decoration and replaces its
entire backing surface on each transition, preventing stale upper-corner lines.
The HUD can show per-session context-window usage as a compact percentage chip
(with token-count fallback), refreshed by Claude's status-line metadata without
changing session lifecycle state; the display can be disabled independently in
Settings.

The local bridge listens on `127.0.0.1` and writes its current port to
`~/Library/Application Support/Clawdesk/runtime.json`.

```sh
curl http://127.0.0.1:37777/health
curl -X POST http://127.0.0.1:37777/state \
  -H 'Content-Type: application/json' \
  -d '{"agent_id":"demo","session_id":"demo-1","event":"UserPromptSubmit","title":"Demo task"}'
```

Install Claude Code or Codex hooks from Settings → Agents. The installer
merges only Clawdesk-owned entries, preserves existing hooks, and leaves a
backup before changing a configuration file.

The same installer seam also covers the registered JSON/TOML and plugin-based
agent integrations. Generated plugins read the current local port from
`~/Library/Application Support/Clawdesk/runtime.json`, so a port collision does
not require reinstalling hooks.

Codex JSONL is monitored as a bounded fallback when official hooks miss an
event. Codex `request_user_input` produces a read-only question card; answers
remain in Codex and the matching output closes the card. Claude Code's
official status-line payload and Codex rollout metadata feed the quota rings
without retaining transcripts.

Remote SSH profiles deploy Claude/Codex/Copilot hooks through the system `ssh` client.
Each connection gets a loopback-only, profile-bound ingress and nonce, an
atomic remote configuration repair, and an `ssh -R` tunnel; passwords and key
passphrases remain with `ssh-agent` or Terminal. Automatic transport detection
handles Codespaces-style stdio proxies, and an optional remote Codex fallback
monitor can be started per profile. Deploy/Repair Hooks must be run again after
changing the remote target or forward port.

Permission requests can be mirrored to Telegram or Feishu/Lark interactive
cards, while Slack, Telegram, and Feishu/Lark support notifications. The local
permission bubble remains the source of truth and remote delivery failures do
not silently deny a request.

Enable the read-only mobile companion in Settings to expose the token-gated
LAN page and v1 WebSocket stream. The companion publishes sanitized session
snapshots only; `/api/connection-info` intentionally never returns the token.
Click the pet while sessions are active to reveal the low-overhead native HUD;
click a session row to focus its terminal, or the overflow row to open the full
Dashboard.

## Scope and upstream tracking

The upstream behavior map and the current native parity boundary are recorded
in [docs/UPSTREAM_PARITY.md](docs/UPSTREAM_PARITY.md). Project-specific update
instructions live in [AGENTS.md](AGENTS.md).

The desktop pet renders the **bloub** character — a filled round body with two
spherical white eyes that track the pointer, blink, and close when asleep —
ported from [jeremy-prt/bloub](https://github.com/jeremy-prt/bloub) (MIT).
See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for attribution. The
upstream clawd-on-desk artwork is not bundled: its separate artwork license
does not permit redistribution, and its character names are not reused.
Custom themes can be imported from a validated folder or ZIP using
PNG/GIF/APNG/WebP/JPEG and static SVG states; animated raster frames are
cached and capped to keep idle memory use low. Themes with multiple idle
visuals can select and persist one per theme.

Settings → General includes a continuous pet-size slider (40%–200%) that
resizes the floating pet in place, and an interface-language picker that
switches the UI immediately (English, 简体中文, 繁體中文, 日本語, 한국어,
Español, or system default). Free Roam can be enabled so the pet periodically
walks to a random spot, optionally confined to an activity area you drag out
in Settings (stored in `~/.clawd/roam-area.json`).
