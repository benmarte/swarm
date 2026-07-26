#!/usr/bin/env bash
# adapters/discord.sh — Discord embed notification adapter.
# Reads a canonical swarm event JSON, renders a Discord embed payload,
# and POSTs it to $SWARM_DISCORD_WEBHOOK.
#
# Required env:
#   SWARM_DISCORD_WEBHOOK  — Discord incoming webhook URL
#
# Argument:
#   $1 — path to the canonical event JSON file
set -euo pipefail

EVENT_FILE="${1:?event-file argument is required}"

if [ ! -f "$EVENT_FILE" ]; then
  echo "notify/discord: ERROR: event file not found: $EVENT_FILE" >&2
  exit 1
fi

if [ -z "${SWARM_DISCORD_WEBHOOK:-}" ]; then
  echo "notify/discord: ERROR: SWARM_DISCORD_WEBHOOK not set" >&2
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

echo "notify/discord: posting to Discord webhook"
if ! curl --silent --fail --show-error \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "$SWARM_DISCORD_WEBHOOK"; then
  echo "notify/discord: ERROR: POST to Discord webhook failed" >&2
  exit 1
fi

echo "notify/discord: delivered"
