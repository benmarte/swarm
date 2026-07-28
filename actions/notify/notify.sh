#!/usr/bin/env bash
# notify.sh — fan-out a canonical event JSON to configured sink adapters.
# Called by actions/notify/action.yml; all inputs arrive via env vars.
#
# Required env:
#   EVENT_FILE        — path to a validated canonical event JSON file
#   ENABLED_SINKS     — comma-separated list of sinks: slack,buzz,discord,teams
#
# Optional env (per-sink, read by adapter scripts):
#   SWARM_SLACK_WEBHOOK      — required when slack is enabled
#   SWARM_DISCORD_WEBHOOK    — required when discord is enabled
#   SWARM_TEAMS_WEBHOOK      — required when teams is enabled
#   SWARM_BUZZ_RELAY_URL     — required when buzz is enabled
#   SWARM_BUZZ_PRIVATE_KEY   — required when buzz is enabled
#   BUZZ_CHANNEL             — NIP-29 channel UUID (from swarm.config.yml notify.buzz_channel)
#
# Threading: anchors are read from / written to the issue body via GitHub API.
# Adapters read SWARM_THREAD_ANCHOR_<SINK> and report new anchors via the
# SWARM_ANCHOR_OUT temp file.  All anchor operations fail soft (never abort
# the notification path).
#
# Exits 1 on any validation or adapter failure.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ADAPTERS_DIR="$SCRIPT_DIR/adapters"
SCHEMAS_DIR="$SCRIPT_DIR/../../schemas"
TEMPLATES_DIR="$SCRIPT_DIR/../../templates/notifications"

# Source thread-anchor state helper (defines swarm_anchor_read / swarm_anchor_set)
# shellcheck disable=SC1091
. "$SCRIPT_DIR/anchor_state.sh"

# ---------------------------------------------------------------------------
# Input validation
# ---------------------------------------------------------------------------
if [ -z "${EVENT_FILE:-}" ]; then
  echo "notify: ERROR: EVENT_FILE is required" >&2
  exit 1
fi

if [ ! -f "$EVENT_FILE" ]; then
  echo "notify: ERROR: event file not found: $EVENT_FILE" >&2
  exit 1
fi

if [ -z "${ENABLED_SINKS:-}" ]; then
  echo "notify: no sinks enabled — nothing to do"
  exit 0
fi

SCHEMA_FILE="$SCHEMAS_DIR/event.schema.json"
if [ ! -f "$SCHEMA_FILE" ]; then
  echo "notify: ERROR: event schema not found: $SCHEMA_FILE" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Validate event JSON against schema BEFORE any fan-out
# ---------------------------------------------------------------------------
echo "notify: validating event JSON against $SCHEMA_FILE"
if ! validation_output=$(ajv validate -s "$SCHEMA_FILE" -d "$EVENT_FILE" 2>&1); then
  echo "" >&2
  echo "notify: ERROR — event JSON failed schema validation." >&2
  echo "" >&2
  echo "Schema: $SCHEMA_FILE" >&2
  echo "File:   $EVENT_FILE" >&2
  echo "" >&2
  echo "Validation errors:" >&2
  echo "$validation_output" >&2
  echo "" >&2
  echo "Fix the caller so it emits a schema-valid event JSON." >&2
  echo "See schemas/event.schema.json for required fields." >&2
  exit 1
fi
echo "notify: event JSON is valid"

# ---------------------------------------------------------------------------
# Render notification template (optional enrichment for adapters)
# Adapters read NOTIFY_TEXT from the environment to get pre-rendered content
# including verdict and evidence bullets.  Falls back to .summary when no
# matching template exists.
# ---------------------------------------------------------------------------
_ev_event="$(jq -r '.event' "$EVENT_FILE")"
_tmpl_file="$TEMPLATES_DIR/${_ev_event}.md"
# Fall back to transition.md for stage-transition events with no specific template
if [ ! -f "$_tmpl_file" ]; then
  _tmpl_file="$TEMPLATES_DIR/transition.md"
fi

if [ -f "$_tmpl_file" ]; then
  _role="$(jq -r '.role // .event' "$EVENT_FILE")"
  _verdict="$(jq -r '.verdict // ""' "$EVENT_FILE")"
  _evidence="$(jq -r 'if (.evidence // [] | length) > 0 then (.evidence | map("• " + (. | gsub("[\\n\\r]+"; " "))) | join("\n")) else "" end' "$EVENT_FILE")"
  _repo="$(jq -r '.repo' "$EVENT_FILE")"
  _issue="$(jq -r '.issue | tostring' "$EVENT_FILE")"
  _pr="$(jq -r 'if .pr != null then (.pr | tostring) else "" end' "$EVENT_FILE")"
  _url="$(jq -r '.url' "$EVENT_FILE")"
  _summary="$(jq -r '.summary' "$EVENT_FILE")"
  _stage_from="$(jq -r '.stage_from' "$EVENT_FILE")"
  _stage_to="$(jq -r '.stage_to' "$EVENT_FILE")"
  _actor="$(jq -r '.actor' "$EVENT_FILE")"
  NOTIFY_TEXT="$(ROLE="$_role" VERDICT="$_verdict" EVIDENCE="$_evidence" \
    REPO="$_repo" ISSUE="$_issue" PR="$_pr" URL="$_url" SUMMARY="$_summary" \
    STAGE_FROM="$_stage_from" STAGE_TO="$_stage_to" ACTOR="$_actor" \
    EVENT="$_ev_event" \
    python3 -c '
import os, string, sys
with open(sys.argv[1]) as f:
    t = string.Template(f.read())
rendered = t.safe_substitute(os.environ).strip()
print(rendered)
' "$_tmpl_file" 2>/dev/null)" || NOTIFY_TEXT="$(jq -r '.summary' "$EVENT_FILE")"
  export NOTIFY_TEXT
  echo "notify: rendered notification template for event: $_ev_event"
fi

# ---------------------------------------------------------------------------
# Thread-anchor read — load existing per-sink anchors for this issue.
# Fails soft: if gh is unavailable or the issue has no anchor, starts fresh.
# ---------------------------------------------------------------------------
_ev_repo="$(jq -r '.repo' "$EVENT_FILE")"
_ev_issue="$(jq -r '.issue | tostring' "$EVENT_FILE")"

_anchors_json="{}"
_anchors_json="$(swarm_anchor_read "$_ev_repo" "$_ev_issue")" || _anchors_json="{}"
echo "notify: thread anchors for ${_ev_repo}#${_ev_issue}: ${_anchors_json}"

# Export per-sink anchors so adapters can thread replies to the root message.
SWARM_THREAD_ANCHOR_SLACK=""
SWARM_THREAD_ANCHOR_SLACK="$(printf '%s' "$_anchors_json" | jq -r '.slack // ""' 2>/dev/null)" \
  || SWARM_THREAD_ANCHOR_SLACK=""
SWARM_THREAD_ANCHOR_DISCORD=""
SWARM_THREAD_ANCHOR_DISCORD="$(printf '%s' "$_anchors_json" | jq -r '.discord // ""' 2>/dev/null)" \
  || SWARM_THREAD_ANCHOR_DISCORD=""
SWARM_THREAD_ANCHOR_BUZZ=""
SWARM_THREAD_ANCHOR_BUZZ="$(printf '%s' "$_anchors_json" | jq -r '.buzz // ""' 2>/dev/null)" \
  || SWARM_THREAD_ANCHOR_BUZZ=""
export SWARM_THREAD_ANCHOR_SLACK SWARM_THREAD_ANCHOR_DISCORD SWARM_THREAD_ANCHOR_BUZZ

# ---------------------------------------------------------------------------
# Fan-out to enabled sinks
# ---------------------------------------------------------------------------
IFS=',' read -ra sinks <<< "$ENABLED_SINKS"
for sink in "${sinks[@]}"; do
  # strip whitespace
  sink="${sink#"${sink%%[![:space:]]*}"}"
  sink="${sink%"${sink##*[![:space:]]}"}"

  if [ -z "$sink" ]; then
    continue
  fi

  adapter="$ADAPTERS_DIR/${sink}.sh"
  if [ ! -f "$adapter" ]; then
    echo "notify: ERROR: unknown sink '$sink' — no adapter at $adapter" >&2
    exit 1
  fi

  # Provide a temp file for the adapter to report a new anchor value.
  # The adapter writes the new root anchor (first post only, or stale-anchor
  # recovery) to this file; notify.sh persists it to the issue body.
  _anchor_out="$(mktemp)"
  export SWARM_ANCHOR_OUT="$_anchor_out"

  echo "notify: dispatching to sink: $sink"
  if ! bash "$adapter" "$EVENT_FILE"; then
    rm -f "$_anchor_out"
    unset SWARM_ANCHOR_OUT
    echo "notify: ERROR: sink '$sink' failed — aborting" >&2
    exit 1
  fi

  # Persist new anchor if the adapter reported one (fail soft)
  if [ -s "$_anchor_out" ]; then
    _new_anchor="$(tr -d '\n\r' < "$_anchor_out")"
    if [ -n "$_new_anchor" ]; then
      swarm_anchor_set "$_ev_repo" "$_ev_issue" "$sink" "$_new_anchor" || true
      # Update cached anchor so remaining sinks in this run see the fresh value
      case "$sink" in
        slack)   SWARM_THREAD_ANCHOR_SLACK="$_new_anchor" ;;
        discord) SWARM_THREAD_ANCHOR_DISCORD="$_new_anchor" ;;
        buzz)    SWARM_THREAD_ANCHOR_BUZZ="$_new_anchor" ;;
      esac
    fi
  fi
  rm -f "$_anchor_out"
  unset SWARM_ANCHOR_OUT

  echo "notify: sink '$sink' delivered"
done

echo "notify: done — delivered to: $ENABLED_SINKS"
