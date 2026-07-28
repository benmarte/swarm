#!/usr/bin/env bash
# adapters/slack.sh — Slack blocks notification adapter.
# Reads a canonical swarm event JSON, renders a Slack blocks payload,
# and POSTs it to the configured Slack endpoint.
#
# Delivery mode (first match wins):
#   1. Webhook mode  — SWARM_SLACK_WEBHOOK set → POST to the webhook URL.
#   2. Bot-token mode — SWARM_SLACK_BOT_TOKEN + SLACK_CHANNEL both set →
#                       POST https://slack.com/api/chat.postMessage with
#                       Authorization: Bearer <token>.
#                       A 200 response containing '"ok":false' is treated
#                       as a hard failure; the Slack error field is printed.
#                       curl network failure also exits non-zero loudly.
#   Neither set      → loud exit 1 naming both options.
#
# NOTE: a non-empty SLACK_CHANNEL enables bot-token mode even when
# notify.slack is false in swarm.config.yml — channel presence wins.
# This is intentional and consistent with buzz_channel behaviour.
#
# Required env (one of):
#   SWARM_SLACK_WEBHOOK   — Slack incoming webhook URL (webhook mode)
#   SWARM_SLACK_BOT_TOKEN — Bot token (bot-token mode)
#
# Required env for bot-token mode:
#   SLACK_CHANNEL         — Slack channel ID (alphanumeric, e.g. C0123456789)
#
# Argument:
#   $1 — path to the canonical event JSON file
set -euo pipefail

EVENT_FILE="${1:?event-file argument is required}"

if [ ! -f "$EVENT_FILE" ]; then
  echo "notify/slack: ERROR: event file not found: $EVENT_FILE" >&2
  exit 1
fi

# Determine delivery mode
if [ -n "${SWARM_SLACK_WEBHOOK:-}" ]; then
  _MODE="webhook"
elif [ -n "${SWARM_SLACK_BOT_TOKEN:-}" ] && [ -n "${SLACK_CHANNEL:-}" ]; then
  _MODE="bot"
else
  echo "notify/slack: ERROR: no Slack credentials configured." >&2
  echo "  Set SWARM_SLACK_WEBHOOK (webhook mode) or" >&2
  echo "  SWARM_SLACK_BOT_TOKEN + SLACK_CHANNEL (bot-token mode)." >&2
  exit 1
fi

# Defense-in-depth: validate SLACK_CHANNEL before it enters any payload or URL.
# Allowed pattern: alphanumeric only (matches Slack's C/G/D/W-prefixed IDs).
# This rejects path-traversal attempts such as '../../etc' or 'C123/evil'.
if [ "$_MODE" = "bot" ]; then
  if ! printf '%s' "${SLACK_CHANNEL}" | grep -qE '^[A-Za-z0-9]+$'; then
    echo "notify/slack: ERROR: SLACK_CHANNEL contains invalid characters." >&2
    echo "  Expected alphanumeric Slack channel ID (e.g. C0123456789)." >&2
    echo "  Got: $(printf '%s' "${SLACK_CHANNEL}" | head -c 40)" >&2
    exit 1
  fi
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

if [ "$_MODE" = "webhook" ]; then
  echo "notify/slack: posting via webhook"
  if ! curl --silent --fail --show-error \
      -X POST \
      -H "Content-Type: application/json" \
      -d "$payload" \
      "$SWARM_SLACK_WEBHOOK"; then
    echo "notify/slack: ERROR: POST to Slack webhook failed" >&2
    exit 1
  fi
else
  # Bot-token mode: include "channel" in the payload
  payload="$(printf '%s' "$payload" | jq --arg ch "$SLACK_CHANNEL" '. + {channel: $ch}')"
  echo "notify/slack: posting via bot token to channel $SLACK_CHANNEL"
  # Capture response body and curl exit code separately.
  # curl can fail (network, DNS, timeout) and return empty body — must not treat
  # that as success (would produce false-negative: empty body has no ok:false).
  _tmp_response="$(mktemp)"
  trap 'rm -f "$_tmp_response"' EXIT
  if ! curl --silent --show-error \
      -X POST \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer $SWARM_SLACK_BOT_TOKEN" \
      -d "$payload" \
      --output "$_tmp_response" \
      "https://slack.com/api/chat.postMessage"; then
    echo "notify/slack: ERROR: curl failed to reach Slack API (network/DNS/timeout)" >&2
    exit 1
  fi
  _response="$(cat "$_tmp_response")"
  # Slack always returns HTTP 200; check the ok field for the real API result
  if printf '%s' "$_response" | grep -q '"ok":false'; then
    _slack_err="$(printf '%s' "$_response" | grep -o '"error":"[^"]*"' | head -1)"
    echo "notify/slack: ERROR: Slack API returned ok:false — $_slack_err" >&2
    exit 1
  fi
fi

echo "notify/slack: delivered"
