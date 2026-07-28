#!/usr/bin/env bash
# adapters/discord.sh — Discord embed notification adapter.
# Reads a canonical swarm event JSON, renders a Discord embed payload,
# and POSTs it to the configured Discord endpoint.
#
# Delivery mode (first match wins):
#   1. Webhook mode  — SWARM_DISCORD_WEBHOOK set → POST to the webhook URL.
#   2. Bot-token mode — SWARM_DISCORD_BOT_TOKEN + DISCORD_CHANNEL both set →
#                       POST https://discord.com/api/v10/channels/<id>/messages
#                       with 'Authorization: Bot <token>'.
#                       Non-2xx HTTP status codes are treated as hard failures.
#   Neither set      → loud exit 1 naming both options.
#
# Required env (one of):
#   SWARM_DISCORD_WEBHOOK    — Discord incoming webhook URL (webhook mode)
#   SWARM_DISCORD_BOT_TOKEN  — Bot token (bot-token mode)
#
# Required env for bot-token mode:
#   DISCORD_CHANNEL          — Discord channel ID the bot will post to
#
# Argument:
#   $1 — path to the canonical event JSON file
set -euo pipefail

EVENT_FILE="${1:?event-file argument is required}"

if [ ! -f "$EVENT_FILE" ]; then
  echo "notify/discord: ERROR: event file not found: $EVENT_FILE" >&2
  exit 1
fi

# Determine delivery mode
if [ -n "${SWARM_DISCORD_WEBHOOK:-}" ]; then
  _MODE="webhook"
elif [ -n "${SWARM_DISCORD_BOT_TOKEN:-}" ] && [ -n "${DISCORD_CHANNEL:-}" ]; then
  _MODE="bot"
else
  echo "notify/discord: ERROR: no Discord credentials configured." >&2
  echo "  Set SWARM_DISCORD_WEBHOOK (webhook mode) or" >&2
  echo "  SWARM_DISCORD_BOT_TOKEN + DISCORD_CHANNEL (bot-token mode)." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Build Discord embed payload from canonical event fields
# ---------------------------------------------------------------------------
payload=$(jq -n \
  --slurpfile ev "$EVENT_FILE" \
  '{
    embeds: [
      {
        title: ("swarm: " + $ev[0].event),
        url: $ev[0].url,
        description: $ev[0].summary,
        color: 5814783,
        fields: [
          {
            name: "Repo",
            value: $ev[0].repo,
            inline: true
          },
          {
            name: "Issue",
            value: ("#" + ($ev[0].issue | tostring)),
            inline: true
          },
          {
            name: "Stage",
            value: ("`" + $ev[0].stage_from + "` → `" + $ev[0].stage_to + "`"),
            inline: false
          },
          {
            name: "Actor",
            value: $ev[0].actor,
            inline: true
          }
        ],
        footer: {
          text: "swarm pipeline"
        }
      }
    ]
  }')

if [ "$_MODE" = "webhook" ]; then
  echo "notify/discord: posting via webhook"
  if ! curl --silent --fail --show-error \
      -X POST \
      -H "Content-Type: application/json" \
      -d "$payload" \
      "$SWARM_DISCORD_WEBHOOK"; then
    echo "notify/discord: ERROR: POST to Discord webhook failed" >&2
    exit 1
  fi
else
  echo "notify/discord: posting via bot token to channel $DISCORD_CHANNEL"
  if ! curl --silent --fail --show-error \
      -X POST \
      -H "Content-Type: application/json" \
      -H "Authorization: Bot $SWARM_DISCORD_BOT_TOKEN" \
      -d "$payload" \
      "https://discord.com/api/v10/channels/$DISCORD_CHANNEL/messages"; then
    echo "notify/discord: ERROR: Discord API returned non-2xx status" >&2
    exit 1
  fi
fi

echo "notify/discord: delivered"
