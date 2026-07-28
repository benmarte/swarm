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
# Threading (bot-token mode only — webhook mode silently posts root messages,
# no warning emitted per AC3).
# Discord threading uses message_reference with fail_if_not_exists:false so a
# deleted root message silently falls back to a fresh root post (stale-anchor
# self-healing is handled transparently by the Discord API).
# ---------------------------------------------------------------------------
_discord_ref_id=""
if [ "$_MODE" = "bot" ]; then
  _ref_candidate="${SWARM_THREAD_ANCHOR_DISCORD:-}"
  if [ -n "$_ref_candidate" ]; then
    # Allowlist: Discord snowflake — 17-20 decimal digits
    if printf '%s' "$_ref_candidate" | grep -qE '^[0-9]{17,20}$'; then
      _discord_ref_id="$_ref_candidate"
    else
      echo "notify/discord: WARNING: SWARM_THREAD_ANCHOR_DISCORD has invalid format — posting as root" >&2
    fi
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
  # Per-item gsub flattens embedded newlines/CRs before bullet assembly,
  # preventing multi-line evidence values from injecting forged signal lines.
  _notify_text="$(jq -r \
    '.summary + "\nStage: `" + .stage_from + "` -> `" + .stage_to + "` | Actor: " + .actor +
     (if (.evidence // [] | length) > 0 then "\n" + (.evidence | map("• " + (. | gsub("[\\n\\r]+"; " "))) | join("\n")) else "" end)' \
    "$EVENT_FILE")"
fi

# ---------------------------------------------------------------------------
# Build Discord embed payload (talos-parity: title/url/description/color/footer)
# message_reference is added only in bot-token mode when a valid anchor exists.
# fail_if_not_exists:false means Discord silently posts as root if the anchored
# message was deleted — this is the stale-anchor self-healing mechanism (AC4).
# ---------------------------------------------------------------------------
payload=$(jq -n \
  --slurpfile ev "$EVENT_FILE" \
  --argjson color "$_color_int" \
  --arg desc "$_notify_text" \
  --arg ref_id "$_discord_ref_id" \
  '
  {
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
  } |
  if $ref_id != "" then
    . + {message_reference: {message_id: $ref_id, fail_if_not_exists: false}}
  else
    .
  end
  ')

if [ "$_MODE" = "webhook" ]; then
  # Webhook mode: no threading (Discord webhooks do not support message_reference).
  # No warning is emitted — webhook-mode users opted out of threading implicitly.
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
  if [ -n "$_discord_ref_id" ]; then
    echo "notify/discord: posting via bot token to channel $DISCORD_CHANNEL (thread: $_discord_ref_id)"
  else
    echo "notify/discord: posting via bot token to channel $DISCORD_CHANNEL"
  fi
  # Capture response to extract message id for anchor on first post.
  _tmp_discord_resp="$(mktemp)"
  trap 'rm -f "$_tmp_discord_resp"' EXIT
  if ! curl --silent --fail --show-error \
      -X POST \
      -H "Content-Type: application/json" \
      -H "Authorization: Bot $SWARM_DISCORD_BOT_TOKEN" \
      -d "$payload" \
      --output "$_tmp_discord_resp" \
      "https://discord.com/api/v10/channels/$DISCORD_CHANNEL/messages"; then
    echo "notify/discord: ERROR: Discord API returned non-2xx status" >&2
    exit 1
  fi
  _discord_resp="$(cat "$_tmp_discord_resp")"
  # Store message id as anchor on first post (when no anchor existed before).
  # Discord with fail_if_not_exists:false handles stale anchors transparently —
  # subsequent posts with a stale anchor silently become new root messages.
  if [ -z "$_discord_ref_id" ]; then
    _new_id="$(printf '%s' "$_discord_resp" | jq -r '.id // ""' 2>/dev/null | tr -d '\n\r')"
    if [ -n "$_new_id" ] && [ -n "${SWARM_ANCHOR_OUT:-}" ]; then
      printf '%s' "$_new_id" > "$SWARM_ANCHOR_OUT"
    fi
  fi
fi

echo "notify/discord: delivered"
