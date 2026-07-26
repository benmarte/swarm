# actions/notify/

Composite action — **canonical event fan-out**. Takes a single event JSON and posts to each configured sink adapter.

Inputs: `event-json` (canonical event object per `schemas/event.schema.json`), `config` (path to `swarm.config.yml`)

Reads the `notify` section of `swarm.config.yml` to determine which adapters are enabled, then invokes each enabled adapter script in `adapters/`.

V1 adapters (see `adapters/`):
- `slack.sh` — outbound webhook POST
- `buzz.sh` — Nostr/NIP-29 relay via `nak` CLI (no incoming webhooks; signs a `kind:9` event tagged `["h", <channel-uuid>]`)
- `discord.sh` — outbound webhook POST
- `teams.sh` — outbound webhook POST

Each adapter maps the canonical event JSON to its own payload format. The same event in → deterministic payload out (golden-testable).

**Not yet implemented** — scaffold placeholder for issue #1.
