# actions/notify/

Composite action — **canonical event fan-out**. Validates a swarm event JSON against `schemas/event.schema.json` then delivers it to each enabled sink adapter.

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `event-file` | yes | — | Path to a canonical event JSON file |
| `enabled-sinks` | no | `""` | Comma-separated list of sinks: `slack`, `buzz`, `discord`, `teams`. Empty = no-op |
| `buzz-channel` | no | `""` | NIP-29 channel UUID for Buzz (from `swarm.config.yml notify.buzz_channel`) |

## Sinks

| Sink | Mechanism | Required secret(s) |
|------|-----------|-------------------|
| `slack` | Outbound webhook POST | `SWARM_SLACK_WEBHOOK` |
| `discord` | Outbound webhook POST | `SWARM_DISCORD_WEBHOOK` |
| `teams` | Outbound webhook POST (Adaptive Card) | `SWARM_TEAMS_WEBHOOK` |
| `buzz` | Nostr/NIP-29 relay via `nak` CLI — **not a webhook** | `SWARM_BUZZ_RELAY_URL`, `SWARM_BUZZ_PRIVATE_KEY` |

Secrets are read from the job environment (`env:` in the calling workflow). The `buzz-channel` input is behavioural config, not a secret.

## Buzz / Nostr mechanism

Buzz is a Nostr/NIP-29 relay, not an HTTP webhook. `adapters/buzz.sh` publishes a signed `kind:9` event tagged `["h", <channel-uuid>]` using the `nak` CLI (`nak event --auth`). `nak` handles NIP-42 AUTH challenges automatically. The runner must have `nak` on `PATH` (e.g. install via `brew install nak` or add a `go install` step before this action).

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
