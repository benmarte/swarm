#!/usr/bin/env bash
# adapters/teams.sh — Microsoft Teams Adaptive Card notification adapter.
# Reads a canonical swarm event JSON, renders a Teams "message" attachment
# Adaptive Card payload, and POSTs it to $SWARM_TEAMS_WEBHOOK.
#
# Required env:
#   SWARM_TEAMS_WEBHOOK  — Teams incoming webhook URL
#
# Argument:
#   $1 — path to the canonical event JSON file
set -euo pipefail

EVENT_FILE="${1:?event-file argument is required}"

if [ ! -f "$EVENT_FILE" ]; then
  echo "notify/teams: ERROR: event file not found: $EVENT_FILE" >&2
  exit 1
fi

if [ -z "${SWARM_TEAMS_WEBHOOK:-}" ]; then
  echo "notify/teams: ERROR: SWARM_TEAMS_WEBHOOK not set" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Build Teams Adaptive Card payload from canonical event fields
# ---------------------------------------------------------------------------
payload=$(jq -n \
  --slurpfile ev "$EVENT_FILE" \
  '{
    type: "message",
    attachments: [
      {
        contentType: "application/vnd.microsoft.card.adaptive",
        contentUrl: null,
        content: {
          "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
          type: "AdaptiveCard",
          version: "1.4",
          body: [
            {
              type: "TextBlock",
              size: "Medium",
              weight: "Bolder",
              text: ("swarm: " + $ev[0].event)
            },
            {
              type: "FactSet",
              facts: [
                {
                  title: "Repo",
                  value: $ev[0].repo
                },
                {
                  title: "Issue",
                  value: ("#" + ($ev[0].issue | tostring))
                },
                {
                  title: "Stage",
                  value: ($ev[0].stage_from + " → " + $ev[0].stage_to)
                },
                {
                  title: "Actor",
                  value: $ev[0].actor
                }
              ]
            },
            {
              type: "TextBlock",
              text: $ev[0].summary,
              wrap: true
            }
          ],
          actions: [
            {
              type: "Action.OpenUrl",
              title: "View on GitHub",
              url: $ev[0].url
            }
          ]
        }
      }
    ]
  }')

echo "notify/teams: posting to Teams webhook"
if ! curl --silent --fail --show-error \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "$SWARM_TEAMS_WEBHOOK"; then
  echo "notify/teams: ERROR: POST to Teams webhook failed" >&2
  exit 1
fi

echo "notify/teams: delivered"
