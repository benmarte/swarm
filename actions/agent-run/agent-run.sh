#!/usr/bin/env bash
# agent-run.sh — swarm decision-role runner.
# Called by actions/agent-run/action.yml; all inputs arrive via env vars.
#
# Required env:
#   SWARM_PROMPT_FILE      — absolute path to the role prompt Markdown file
#   SWARM_CONTEXT_JSON     — JSON string with issue/PR context
#   SWARM_ROLE             — role name (validated against allowlist below)
#   SWARM_ADAPTER          — adapter name (validated against allowlist below)
#   SWARM_TIMEOUT_MINUTES  — max minutes for the agent call (converted to seconds)
#   GITHUB_WORKSPACE       — working directory (set by Actions)
#   ACTION_PATH            — path to the action directory (set by action.yml env)
#
# Exit 0 = outcome.json written and schema-valid.
# Exit 1 = validation failure, adapter error, or schema-invalid outcome.
set -euo pipefail

# ---------------------------------------------------------------------------
# Role allowlist — SPEC §2.3 / §2.4
# ---------------------------------------------------------------------------
ALLOWED_ROLES="validator pm reviewer security docs orchestrator"

is_allowed_role() {
  local r="$1"
  local role
  for role in $ALLOWED_ROLES; do
    [ "$r" = "$role" ] && return 0
  done
  return 1
}

# ---------------------------------------------------------------------------
# Adapter allowlist — SPEC §2.3: v1 ships claude + openai-compat
# ---------------------------------------------------------------------------
ALLOWED_ADAPTERS="claude openai-compat"

is_allowed_adapter() {
  local a="$1"
  local adapter
  for adapter in $ALLOWED_ADAPTERS; do
    [ "$a" = "$adapter" ] && return 0
  done
  return 1
}

# ---------------------------------------------------------------------------
# Validate required inputs before any file path or command use
# ---------------------------------------------------------------------------
if [ -z "${SWARM_ROLE:-}" ]; then
  echo "agent-run: ERROR: SWARM_ROLE is required" >&2
  exit 1
fi

if ! is_allowed_role "$SWARM_ROLE"; then
  echo "agent-run: ERROR: invalid role '$SWARM_ROLE'." >&2
  echo "  Allowed: $ALLOWED_ROLES" >&2
  exit 1
fi

if [ -z "${SWARM_ADAPTER:-}" ]; then
  echo "agent-run: ERROR: SWARM_ADAPTER is required" >&2
  exit 1
fi

if ! is_allowed_adapter "$SWARM_ADAPTER"; then
  echo "agent-run: ERROR: invalid adapter '$SWARM_ADAPTER'." >&2
  echo "  Allowed: $ALLOWED_ADAPTERS" >&2
  exit 1
fi

if [ -z "${SWARM_PROMPT_FILE:-}" ]; then
  echo "agent-run: ERROR: SWARM_PROMPT_FILE is required" >&2
  exit 1
fi

if [ ! -f "$SWARM_PROMPT_FILE" ]; then
  echo "agent-run: ERROR: prompt file not found: $SWARM_PROMPT_FILE" >&2
  exit 1
fi

if [ -z "${SWARM_CONTEXT_JSON:-}" ]; then
  echo "agent-run: ERROR: SWARM_CONTEXT_JSON is required" >&2
  exit 1
fi

# Validate context JSON is parseable
if ! echo "$SWARM_CONTEXT_JSON" | jq empty 2>/dev/null; then
  echo "agent-run: ERROR: SWARM_CONTEXT_JSON is not valid JSON" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Derive paths (all from validated env vars — no interpolation of user input)
# ---------------------------------------------------------------------------
SCRIPT_DIR="${ACTION_PATH:?ACTION_PATH is not set}"
ADAPTER_SCRIPT="$SCRIPT_DIR/adapters/$SWARM_ADAPTER.sh"
VALIDATE_SH="$SCRIPT_DIR/../validate-outcome/validate.sh"
SCHEMA_FILE="$SCRIPT_DIR/../../schemas/outcome.schema.json"

if [ ! -f "$ADAPTER_SCRIPT" ]; then
  echo "agent-run: ERROR: adapter script not found: $ADAPTER_SCRIPT" >&2
  exit 1
fi

if [ ! -f "$VALIDATE_SH" ]; then
  echo "agent-run: ERROR: validate.sh not found: $VALIDATE_SH" >&2
  exit 1
fi

if [ ! -f "$SCHEMA_FILE" ]; then
  echo "agent-run: ERROR: schema not found: $SCHEMA_FILE" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Set adapter env contract (SPEC §2.3 / runner-contract.md §1)
# ---------------------------------------------------------------------------
export SWARM_PROMPT_FILE
export SWARM_CONTEXT_JSON
export SWARM_ROLE
# Convert minutes to seconds for the adapter
SWARM_TIMEOUT=$(( ${SWARM_TIMEOUT_MINUTES:-5} * 60 ))
export SWARM_TIMEOUT
export GITHUB_WORKSPACE="${GITHUB_WORKSPACE:-.}"
export OUTCOME_FILE="$GITHUB_WORKSPACE/outcome.json"

echo "agent-run: role=$SWARM_ROLE adapter=$SWARM_ADAPTER timeout=${SWARM_TIMEOUT}s"
echo "agent-run: prompt=$SWARM_PROMPT_FILE"
echo "agent-run: outcome=$OUTCOME_FILE"

# ---------------------------------------------------------------------------
# Dispatch to adapter
# ---------------------------------------------------------------------------
echo "agent-run: dispatching to $SWARM_ADAPTER adapter"
bash "$ADAPTER_SCRIPT"

# ---------------------------------------------------------------------------
# Validate outcome (engine NEVER parses agent prose — validate-outcome is the
# sole authority on whether the outcome is acceptable)
# ---------------------------------------------------------------------------
echo "agent-run: validating outcome.json"
bash "$VALIDATE_SH" "$OUTCOME_FILE" "$SCHEMA_FILE"

echo "agent-run: complete — outcome.json is valid"
