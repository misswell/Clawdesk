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

## Scope and upstream tracking

The upstream behavior map and the current native parity boundary are recorded
in [docs/UPSTREAM_PARITY.md](docs/UPSTREAM_PARITY.md). Project-specific update
instructions live in [AGENTS.md](AGENTS.md).

Upstream artwork is not bundled: its separate artwork license does not permit
redistribution outside the original application. The built-in themes here are
native CoreGraphics renderers. Custom themes can be imported from a validated
folder or ZIP using PNG/GIF/APNG/WebP/JPEG and static SVG states; animated
raster frames are cached and capped to keep idle memory use low. Themes with
multiple idle visuals can select and persist one per theme. Full upstream Codex
Pet atlas conversion is intentionally not claimed, and custom themes remain an
isolated renderer seam.
