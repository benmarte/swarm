#!/usr/bin/env bash
# adapters/buzz.sh — Buzz (Nostr/NIP-29) notification adapter.
# Reads a canonical swarm event JSON, renders a plain markdown message,
# and publishes a signed kind:9 event tagged ["h", <channel-uuid>] via
# the `nak` CLI.
#
# SPEC §2.3 / §2.6: Buzz is NOT a webhook. It is a Nostr/NIP-29 relay.
# `nak` answers the relay's NIP-42 AUTH challenge automatically with --auth.
# Threading (NIP-10 reply tags) is not used in v1 — root posts only.
#
# Message content (talos-parity):
#   Uses NOTIFY_TEXT if set (pre-rendered by notify.sh with verdict/evidence).
#   Falls back to building the message from raw event JSON fields, including
#   role, verdict, evidence bullets, and all standard fields.
#
# Required env:
#   SWARM_BUZZ_RELAY_URL    — wss:// relay URL for the buzz instance
#   SWARM_BUZZ_PRIVATE_KEY  — hex or nsec Nostr private key for the bot
#   BUZZ_CHANNEL            — NIP-29 channel UUID (from swarm.config.yml)
#
# Optional env:
#   NOTIFY_TEXT — pre-rendered notification text (set by notify.sh template
#                 rendering). When present, used as the message body.
#
# Argument:
#   $1 — path to the canonical event JSON file
set -euo pipefail

EVENT_FILE="${1:?event-file argument is required}"

if [ ! -f "$EVENT_FILE" ]; then
  echo "notify/buzz: ERROR: event file not found: $EVENT_FILE" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Loud failures for every missing dependency (name each)
# ---------------------------------------------------------------------------
if [ -z "${SWARM_BUZZ_RELAY_URL:-}" ]; then
  echo "notify/buzz: ERROR: SWARM_BUZZ_RELAY_URL not set" >&2
  exit 1
fi

if [ -z "${SWARM_BUZZ_PRIVATE_KEY:-}" ]; then
  echo "notify/buzz: ERROR: SWARM_BUZZ_PRIVATE_KEY not set" >&2
  exit 1
fi

if [ -z "${BUZZ_CHANNEL:-}" ]; then
  echo "notify/buzz: ERROR: BUZZ_CHANNEL not set (set notify.buzz_channel in swarm.config.yml)" >&2
  exit 1
fi

NAK_BIN="${NAK_BIN:-nak}"
if ! command -v "$NAK_BIN" >/dev/null 2>&1; then
  echo "notify/buzz: ERROR: 'nak' CLI not found — install it (brew install nak) and ensure it is on PATH" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Build plain markdown message: use NOTIFY_TEXT when available (preferred),
# else build from raw event fields including optional role/verdict/evidence.
# ---------------------------------------------------------------------------
_notify_text="${NOTIFY_TEXT:-}"
if [ -n "$_notify_text" ]; then
  TEXT="$_notify_text"
else
  TEXT=$(jq -r \
    '"**swarm: " + .event + "**\n" +
     "**Repo:** " + .repo + " · " +
     "**Issue:** #" + (.issue | tostring) +
     (if .pr != null then " · **PR:** #" + (.pr | tostring) else "" end) + "\n" +
     (if .role then "**Role:** " + .role + (if .verdict then " | **Verdict:** " + .verdict else "" end) + "\n" else "" end) +
     "**Stage:** `" + .stage_from + "` -> `" + .stage_to + "`\n" +
     "**Actor:** " + .actor + "\n" +
     (if (.evidence // [] | length) > 0 then (.evidence | map("• " + .) | join("\n")) + "\n" else "" end) +
     .summary + "\n" +
     .url' \
    "$EVENT_FILE")
fi

# ---------------------------------------------------------------------------
# Publish kind:9 event to the buzz relay (root post, no threading in v1)
# ---------------------------------------------------------------------------
echo "notify/buzz: publishing kind:9 event to relay $SWARM_BUZZ_RELAY_URL"
if ! "$NAK_BIN" event --auth \
    --sec "$SWARM_BUZZ_PRIVATE_KEY" \
    -k 9 \
    -c "$TEXT" \
    -t "h=$BUZZ_CHANNEL" \
    "$SWARM_BUZZ_RELAY_URL"; then
  echo "notify/buzz: ERROR: nak failed to publish event" >&2
  exit 1
fi

echo "notify/buzz: delivered"
