#!/usr/bin/env bash
# adapters/slack.sh — Slack blocks notification adapter.
# Reads a canonical swarm event JSON, renders a Slack blocks payload,
# and POSTs it to $SWARM_SLACK_WEBHOOK.
#
# Required env:
#   SWARM_SLACK_WEBHOOK  — Slack incoming webhook URL
#
# Argument:
#   $1 — path to the canonical event JSON file
set -euo pipefail

EVENT_FILE="${1:?event-file argument is required}"

if [ ! -f "$EVENT_FILE" ]; then
  echo "notify/slack: ERROR: event file not found: $EVENT_FILE" >&2
  exit 1
fi

if [ -z "${SWARM_SLACK_WEBHOOK:-}" ]; then
  echo "notify/slack: ERROR: SWARM_SLACK_WEBHOOK not set" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Build Slack blocks payload from canonical event fields
# ---------------------------------------------------------------------------
payload=$(jq -n \
  --slurpfile ev "$EVENT_FILE" \
  '{
    blocks: [
      {
        type: "header",
        text: {
          type: "plain_text",
          text: ("swarm: " + $ev[0].event),
          emoji: true
        }
      },
      {
        type: "section",
        fields: [
          {
            type: "mrkdwn",
            text: ("*Repo:*\n" + $ev[0].repo)
          },
          {
            type: "mrkdwn",
            text: ("*Issue:*\n#" + ($ev[0].issue | tostring))
          },
          {
            type: "mrkdwn",
            text: ("*Stage:*\n`" + $ev[0].stage_from + "` → `" + $ev[0].stage_to + "`")
          },
          {
            type: "mrkdwn",
            text: ("*Actor:*\n" + $ev[0].actor)
          }
        ]
      },
      {
        type: "section",
        text: {
          type: "mrkdwn",
          text: $ev[0].summary
        },
        accessory: {
          type: "button",
          text: {
            type: "plain_text",
            text: "View",
            emoji: false
          },
          url: $ev[0].url,
          action_id: "view_link"
        }
      }
    ]
  }')

echo "notify/slack: posting to Slack webhook"
if ! curl --silent --fail --show-error \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "$SWARM_SLACK_WEBHOOK"; then
  echo "notify/slack: ERROR: POST to Slack webhook failed" >&2
  exit 1
fi

echo "notify/slack: delivered"
