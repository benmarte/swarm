# actions/notify/

Composite action — **canonical event fan-out**. Validates a swarm event JSON against `schemas/event.schema.json` then delivers it to each enabled sink adapter.

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `event-file` | yes | — | Path to a canonical event JSON file |
| `enabled-sinks` | no | `""` | Comma-separated list of sinks: `slack`, `buzz`, `discord`, `teams`. Empty = no-op |
| `buzz-channel` | no | `""` | NIP-29 channel UUID for Buzz (from `swarm.config.yml notify.buzz_channel`) |
| `slack-channel` | no | `""` | Slack channel ID for bot-token mode (from `swarm.config.yml notify.slack_channel`) |
| `discord-channel` | no | `""` | Discord channel ID for bot-token mode (from `swarm.config.yml notify.discord_channel`) |

## Sinks

| Sink | Mechanism | Required secret(s) |
|------|-----------|-------------------|
| `slack` | Webhook POST **or** bot-token POST (see below) | `SWARM_SLACK_WEBHOOK` (webhook mode) **or** `SWARM_SLACK_BOT_TOKEN` + `slack-channel` (bot-token mode) |
| `discord` | Webhook POST **or** bot-token POST (see below) | `SWARM_DISCORD_WEBHOOK` (webhook mode) **or** `SWARM_DISCORD_BOT_TOKEN` + `discord-channel` (bot-token mode) |
| `teams` | Outbound webhook POST (Adaptive Card) | `SWARM_TEAMS_WEBHOOK` |
| `buzz` | Nostr/NIP-29 relay via `nak` CLI — **not a webhook** | `SWARM_BUZZ_RELAY_URL`, `SWARM_BUZZ_PRIVATE_KEY` |

Secrets are read from the job environment (`env:` in the calling workflow). Channel inputs (`buzz-channel`, `slack-channel`, `discord-channel`) are behavioural config, not secrets.

## Slack and Discord: two authentication modes

Both the Slack and Discord adapters support two mutually exclusive authentication modes:

| Mode | When to use | Required credentials |
|------|------------|---------------------|
| **Webhook** | Simplest setup; no channel ID needed | `SWARM_SLACK_WEBHOOK` / `SWARM_DISCORD_WEBHOOK` incoming webhook URL |
| **Bot-token** | Posts as the bot's own identity (name + avatar); requires a channel ID | `SWARM_SLACK_BOT_TOKEN` / `SWARM_DISCORD_BOT_TOKEN` + `slack-channel` / `discord-channel` input |

**Precedence:** webhook wins when both `SWARM_SLACK_WEBHOOK` and `SWARM_SLACK_BOT_TOKEN` are set (same rule for Discord). Configure only one mode per platform.

**Identity caveat:** bot-token mode posts messages as the bot application's identity (its registered name and avatar). Webhook mode posts as the webhook's configured name/icon, which may differ.

## Buzz / Nostr mechanism

Buzz is a Nostr/NIP-29 relay, not an HTTP webhook. `adapters/buzz.sh` publishes a signed `kind:9` event tagged `["h", <channel-uuid>]` using the `nak` CLI (`nak event --auth`). `nak` handles NIP-42 AUTH challenges automatically. The runner must have `nak` on `PATH` (e.g. install via `brew install nak` or add a `go install` step before this action).

**One-time channel setup (NIP-29):** the bot keypair must be admitted as a group member before it can post — without membership the relay returns `restricted: not a member`. Add the bot via a `kind:9000` event signed by a group admin key. Additionally, publish a `kind:0` profile event for the bot so it appears by name in the relay's member picker (otherwise it shows as an opaque hex pubkey). See `docs/adopting.md` → "Enabling notification sinks" for the full procedure.

## Loud-failure semantics

A missing required secret for a configured sink is a **hard job failure**. Partial delivery is not attempted — the adapter exits non-zero and the job fails loudly so the misconfiguration is visible immediately. Sinks not listed in `enabled-sinks` are silently skipped.

## Runner dependency

`ajv-cli@5.0.0` is required for schema validation and is installed automatically by this action (`npm install -g ajv-cli@5.0.0`). `nak` must be pre-installed on the runner when the `buzz` sink is enabled.

## Example

```yaml
- uses: ./.github/actions/notify
  env:
    SWARM_SLACK_WEBHOOK: ${{ secrets.SWARM_SLACK_WEBHOOK }}
    SWARM_BUZZ_RELAY_URL: ${{ secrets.SWARM_BUZZ_RELAY_URL }}
    SWARM_BUZZ_PRIVATE_KEY: ${{ secrets.SWARM_BUZZ_PRIVATE_KEY }}
  with:
    event-file: event.json
    enabled-sinks: slack,buzz
    buzz-channel: ${{ vars.BUZZ_CHANNEL }}
```
