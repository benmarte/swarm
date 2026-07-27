# actions/notify/adapters/

Notification sink adapter scripts for the `notify` composite action.

Each script receives the canonical event JSON on stdin (or via `EVENT_JSON` env var) and posts to its respective platform. All adapters must be idempotent — re-running on the same event must not duplicate notifications (use a dedupe key derived from `event.repo + event.issue + event.stage_to`).

Required interface:
- Reads: `EVENT_JSON` (canonical event per `schemas/event.schema.json`), platform-specific credential env vars from GitHub Secrets
- Exits 0 on success; non-zero on delivery failure (logged but does not fail the pipeline job)

Implemented adapters (shipped in issue #4):
- `slack.sh` — `SWARM_SLACK_WEBHOOK` → POST `{"text": "..."}` to Slack Incoming Webhook
- `buzz.sh` — `SWARM_BUZZ_RELAY_URL` + `SWARM_BUZZ_PRIVATE_KEY` + `SWARM_BUZZ_CHANNEL` → `nak` CLI publishes signed `kind:9` NIP-29 event
- `discord.sh` — `SWARM_DISCORD_WEBHOOK` → POST to Discord webhook
- `teams.sh` — `SWARM_TEAMS_WEBHOOK` → POST Adaptive Card to Teams webhook
