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
# NOTE: a non-empty DISCORD_CHANNEL enables bot-token mode even when
# notify.discord is false in swarm.config.yml — channel presence wins.
# This is intentional and consistent with buzz_channel behaviour.
#
# DISCORD_CHANNEL must be a Discord snowflake: 17-20 digits only.
# The value is interpolated directly into the API URL path; invalid values
# are rejected before any network call.
#
# Embed shape (talos-parity):
#   - title: "swarm: <event>"
#   - url: event url (clickable title)
#   - description: NOTIFY_TEXT if set; else built from event fields
#   - color: per-event integer (mirrors talos mapping)
#   - footer.text: "repo · event · #issue" context line
#
# Per-event color mapping (mirrors talos):
#   merged / issue-closed / qa / done → green  (3066993)
#   blocked / fail                    → red    (15158332)
#   security                          → orange (15105570)
#   reviewer                          → purple (10181046)
#   default                           → blue   (3447003)
#
# Required env (one of):
#   SWARM_DISCORD_WEBHOOK    — Discord incoming webhook URL (webhook mode)
#   SWARM_DISCORD_BOT_TOKEN  — Bot token (bot-token mode)
#
# Required env for bot-token mode:
#   DISCORD_CHANNEL          — Discord channel snowflake ID (17-20 digits)
#
# Optional env:
#   NOTIFY_TEXT — pre-rendered notification text (set by notify.sh template
#                 rendering). When present, used as the embed description.
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

# Defense-in-depth: validate DISCORD_CHANNEL before it is interpolated into the
# API URL path. Discord snowflakes are 17-20 decimal digits only.
# Rejects path-traversal attempts such as '123/../../x' or '../admin'.
if [ "$_MODE" = "bot" ]; then
  if ! printf '%s' "${DISCORD_CHANNEL}" | grep -qE '^[0-9]{17,20}$'; then
    echo "notify/discord: ERROR: DISCORD_CHANNEL is not a valid Discord snowflake." >&2
    echo "  Expected 17-20 digit channel ID (e.g. 123456789012345678)." >&2
    echo "  Got: $(printf '%s' "${DISCORD_CHANNEL}" | head -c 40)" >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Per-event color mapping (talos-parity integer values)
# ---------------------------------------------------------------------------
_event_type="$(jq -r '.event' "$EVENT_FILE")"
case "$_event_type" in
  merged|issue-closed|qa|done) _color_int=3066993  ;;
  blocked|fail)                _color_int=15158332 ;;
  security)                    _color_int=15105570 ;;
  reviewer)                    _color_int=10181046 ;;
  *)                           _color_int=3447003  ;;
esac

# ---------------------------------------------------------------------------
# Build embed description: NOTIFY_TEXT when available, else fallback
# including key event fields so the embed is self-contained.
# ---------------------------------------------------------------------------
_notify_text="${NOTIFY_TEXT:-}"
if [ -z "$_notify_text" ]; then
  _notify_text="$(jq -r \
    '.summary + "\nStage: `" + .stage_from + "` -> `" + .stage_to + "` | Actor: " + .actor' \
    "$EVENT_FILE")"
fi

# ---------------------------------------------------------------------------
# Build Discord embed payload (talos-parity: title/url/description/color/footer)
# ---------------------------------------------------------------------------
payload=$(jq -n \
  --slurpfile ev "$EVENT_FILE" \
  --argjson color "$_color_int" \
  --arg desc "$_notify_text" \
  '{
    embeds: [
      {
        title: ("swarm: " + $ev[0].event),
        url: $ev[0].url,
        description: $desc,
        color: $color,
        footer: {
          text: ($ev[0].repo + " · " + $ev[0].event + " · #" + ($ev[0].issue | tostring))
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
