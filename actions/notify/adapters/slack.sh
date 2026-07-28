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
# Payload shape (talos-parity):
#   - top-level "text" field (notification/fallback)
#   - blocks[0]: section with mrkdwn body (NOTIFY_TEXT if set; else built from
#                event fields) + "View" button accessory
#   - blocks[1]: context block "repo · event · #issue"
#   - attachments[0]: {"color": "<per-event hex>", "fallback": "swarm: <event>"}
#
# Per-event color mapping (mirrors talos):
#   merged / issue-closed / qa / done → green  (#2ecc71)
#   blocked / fail                    → red    (#e74c3c)
#   security                          → orange (#e67e22)
#   reviewer                          → purple (#9b59b6)
#   default                           → blue   (#3498db)
#
# Required env (one of):
#   SWARM_SLACK_WEBHOOK   — Slack incoming webhook URL (webhook mode)
#   SWARM_SLACK_BOT_TOKEN — Bot token (bot-token mode)
#
# Required env for bot-token mode:
#   SLACK_CHANNEL         — Slack channel ID (alphanumeric, e.g. C0123456789)
#
# Optional env:
#   NOTIFY_TEXT — pre-rendered notification text (set by notify.sh template
#                 rendering). When present, used as the section body instead
#                 of the fallback built from raw event fields.
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
# Threading (bot-token mode only — webhook mode silently posts root messages,
# no warning emitted per AC3).
# ---------------------------------------------------------------------------
# _thread_ts is the Slack thread_ts to reply to, or empty for a root post.
_thread_ts=""
if [ "$_MODE" = "bot" ]; then
  _ts_candidate="${SWARM_THREAD_ANCHOR_SLACK:-}"
  if [ -n "$_ts_candidate" ]; then
    # Allowlist: Slack thread_ts is <epoch>.<sequence> (all digits)
    if printf '%s' "$_ts_candidate" | grep -qE '^[0-9]+\.[0-9]+$'; then
      _thread_ts="$_ts_candidate"
    else
      echo "notify/slack: WARNING: SWARM_THREAD_ANCHOR_SLACK has invalid format — posting as root" >&2
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Per-event color mapping (talos-parity)
# ---------------------------------------------------------------------------
_event_type="$(jq -r '.event' "$EVENT_FILE")"
case "$_event_type" in
  merged|issue-closed|qa|done) _color="#2ecc71" ;;
  blocked|fail)                _color="#e74c3c" ;;
  security)                    _color="#e67e22" ;;
  reviewer)                    _color="#9b59b6" ;;
  *)                           _color="#3498db" ;;
esac

# ---------------------------------------------------------------------------
# Build section body: use pre-rendered NOTIFY_TEXT when available (preferred),
# else build from raw event fields (backward-compatible fallback).
# ---------------------------------------------------------------------------
_notify_text="${NOTIFY_TEXT:-}"
if [ -z "$_notify_text" ]; then
  # Per-item gsub flattens embedded newlines/CRs before bullet assembly,
  # preventing multi-line evidence values from injecting forged signal lines.
  _notify_text="$(jq -r \
    '"swarm: " + .event + "\n" +
     "Repo: " + .repo + " | Issue: #" + (.issue | tostring) + "\n" +
     "Stage: `" + .stage_from + "` -> `" + .stage_to + "` | Actor: " + .actor + "\n" +
     (if (.evidence // [] | length) > 0 then (.evidence | map("• " + (. | gsub("[\\n\\r]+"; " "))) | join("\n")) + "\n" else "" end) +
     .summary' \
    "$EVENT_FILE")"
fi

# ---------------------------------------------------------------------------
# Build Slack blocks payload (talos-parity: section + context + color attachment)
# _base_payload has no channel and no thread_ts — those are added per mode below.
# ---------------------------------------------------------------------------
_base_payload=$(jq -n \
  --slurpfile ev "$EVENT_FILE" \
  --arg color "$_color" \
  --arg body "$_notify_text" \
  '{
    text: ("swarm: " + $ev[0].event),
    blocks: [
      {
        type: "section",
        text: {
          type: "mrkdwn",
          text: $body
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
      },
      {
        type: "context",
        elements: [
          {
            type: "mrkdwn",
            text: ($ev[0].repo + " · " + $ev[0].event + " · #" + ($ev[0].issue | tostring))
          }
        ]
      }
    ],
    attachments: [
      {
        color: $color,
        fallback: ("swarm: " + $ev[0].event)
      }
    ]
  }')

if [ "$_MODE" = "webhook" ]; then
  # Webhook mode: no threading (Slack incoming webhooks have no thread_ts).
  # No warning is emitted — webhook-mode users opted out of threading implicitly.
  echo "notify/slack: posting via webhook"
  if ! curl --silent --fail --show-error \
      -X POST \
      -H "Content-Type: application/json" \
      -d "$_base_payload" \
      "$SWARM_SLACK_WEBHOOK"; then
    echo "notify/slack: ERROR: POST to Slack webhook failed" >&2
    exit 1
  fi
else
  # Bot-token mode: add channel; optionally add thread_ts for threading.
  payload="$(printf '%s' "$_base_payload" | jq --arg ch "$SLACK_CHANNEL" '. + {channel: $ch}')"
  if [ -n "$_thread_ts" ]; then
    payload="$(printf '%s' "$payload" | jq --arg ts "$_thread_ts" '. + {thread_ts: $ts}')"
    echo "notify/slack: posting via bot token to channel $SLACK_CHANNEL (thread: $_thread_ts)"
  else
    echo "notify/slack: posting via bot token to channel $SLACK_CHANNEL"
  fi

  # Capture response body; curl can fail (network/DNS/timeout) — must not treat
  # an empty body as success (empty body has no ok:false to catch).
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

  # Slack always returns HTTP 200; check the ok field for the real result.
  if printf '%s' "$_response" | grep -q '"ok":false'; then
    # Stale-anchor self-healing: if the root message was deleted, Slack returns
    # thread_not_found.  Clear the stale anchor and retry as a fresh root post.
    if printf '%s' "$_response" | grep -q '"error":"thread_not_found"'; then
      echo "notify/slack: stale thread anchor — retrying as fresh root post" >&2
      _retry_payload="$(printf '%s' "$_base_payload" | jq --arg ch "$SLACK_CHANNEL" '. + {channel: $ch}')"
      _tmp_response2="$(mktemp)"
      if ! curl --silent --show-error \
          -X POST \
          -H "Content-Type: application/json" \
          -H "Authorization: Bearer $SWARM_SLACK_BOT_TOKEN" \
          -d "$_retry_payload" \
          --output "$_tmp_response2" \
          "https://slack.com/api/chat.postMessage"; then
        rm -f "$_tmp_response2"
        echo "notify/slack: ERROR: stale-anchor recovery request failed (network/DNS/timeout)" >&2
        exit 1
      fi
      _response2="$(cat "$_tmp_response2")"
      rm -f "$_tmp_response2"
      if printf '%s' "$_response2" | grep -q '"ok":false'; then
        _slack_err2="$(printf '%s' "$_response2" | grep -o '"error":"[^"]*"' | head -1)"
        echo "notify/slack: ERROR: stale-anchor recovery failed — $_slack_err2" >&2
        exit 1
      fi
      # Recovery succeeded: store the new root message ts as the fresh anchor.
      _new_ts="$(printf '%s' "$_response2" | jq -r '.ts // ""' 2>/dev/null | tr -d '\n\r')"
      if [ -n "$_new_ts" ] && [ -n "${SWARM_ANCHOR_OUT:-}" ]; then
        printf '%s' "$_new_ts" > "$SWARM_ANCHOR_OUT"
      fi
    else
      _slack_err="$(printf '%s' "$_response" | grep -o '"error":"[^"]*"' | head -1)"
      echo "notify/slack: ERROR: Slack API returned ok:false — $_slack_err" >&2
      exit 1
    fi
  else
    # Success: if this was the first post (no existing anchor), store the ts.
    if [ -z "$_thread_ts" ]; then
      _new_ts="$(printf '%s' "$_response" | jq -r '.ts // ""' 2>/dev/null | tr -d '\n\r')"
      if [ -n "$_new_ts" ] && [ -n "${SWARM_ANCHOR_OUT:-}" ]; then
        printf '%s' "$_new_ts" > "$SWARM_ANCHOR_OUT"
      fi
    fi
  fi
fi

echo "notify/slack: delivered"
