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
# Exits 1 on any validation or adapter failure.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ADAPTERS_DIR="$SCRIPT_DIR/adapters"
SCHEMAS_DIR="$SCRIPT_DIR/../../schemas"

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

  echo "notify: dispatching to sink: $sink"
  if ! bash "$adapter" "$EVENT_FILE"; then
    echo "notify: ERROR: sink '$sink' failed — aborting" >&2
    exit 1
  fi
  echo "notify: sink '$sink' delivered"
done

echo "notify: done — delivered to: $ENABLED_SINKS"
