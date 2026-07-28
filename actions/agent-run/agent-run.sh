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
# Dispatch to adapter, with a bounded schema-repair loop (#69)
#
# Models — especially smaller local ones — routinely return a semantically
# correct outcome in a slightly wrong shape (notes as an array, a verdict with
# odd casing). A one-shot contract turns that into a dead pipeline stage that
# no other workflow can recover, because the fix workflow only triggers on
# failed CI for an existing branch.
#
# The repair path feeds the validator's own error back to the adapter and
# retries, rather than coercing types. Coercion would silently reinterpret
# model output and could only ever fix the deviations someone anticipated;
# error feedback is general and keeps validate-outcome the sole authority on
# what is acceptable.
# ---------------------------------------------------------------------------
SWARM_OUTCOME_ATTEMPTS="${SWARM_OUTCOME_ATTEMPTS:-3}"
if ! printf '%s' "$SWARM_OUTCOME_ATTEMPTS" | grep -qE '^[1-9][0-9]*$'; then
  echo "agent-run: ERROR: SWARM_OUTCOME_ATTEMPTS must be a positive integer, got '$SWARM_OUTCOME_ATTEMPTS'" >&2
  exit 1
fi

validation_log="$(mktemp)"
trap 'rm -f "$validation_log"' EXIT

attempt=1
while : ; do
  echo "agent-run: dispatching to $SWARM_ADAPTER adapter (attempt ${attempt}/${SWARM_OUTCOME_ATTEMPTS})"
  bash "$ADAPTER_SCRIPT"

  # Engine NEVER parses agent prose — validate-outcome is the sole authority
  # on whether the outcome is acceptable.
  echo "agent-run: validating outcome.json"
  if bash "$VALIDATE_SH" "$OUTCOME_FILE" "$SCHEMA_FILE" >"$validation_log" 2>&1; then
    cat "$validation_log"
    echo "agent-run: complete — outcome.json is valid (attempt ${attempt}/${SWARM_OUTCOME_ATTEMPTS})"
    exit 0
  fi

  # Always surface the validator's output, so a genuinely broken adapter stays
  # loud instead of being quietly retried.
  cat "$validation_log" >&2

  if [ "$attempt" -ge "$SWARM_OUTCOME_ATTEMPTS" ]; then
    echo "agent-run: ERROR: outcome.json still schema-invalid after ${SWARM_OUTCOME_ATTEMPTS} attempt(s)" >&2
    echo "  The last validation error is shown above." >&2
    echo "  Raise SWARM_OUTCOME_ATTEMPTS, or check that the model can honour schemas/outcome.schema.json." >&2
    exit 1
  fi

  # Corrective context for the next attempt. The validator's output is trusted
  # machine text, but it is bounded here anyway: it is echoed into a model
  # prompt, and an unbounded error dump would crowd out the role prompt.
  #
  # ajv's "strict mode:" lines are schema lint about our own schema, not about
  # the model's output. They are dropped: they say nothing the model can act
  # on, and left in they consume the truncation budget ahead of the one line
  # that actually matters.
  #
  # The `|| true` is load-bearing: grep exits 1 when it selects no lines, and
  # under `set -e` that would abort here — skipping the loud exhaustion error
  # below and killing the stage with a bare exit 1 and no explanation. That is
  # precisely the silent failure this loop exists to prevent.
  repair_detail="$( { grep -v 'strict mode:' "$validation_log" || true; } | head -c 4000 )"
  if [ -z "$repair_detail" ]; then
    repair_detail="(validator produced no output — the outcome did not satisfy schemas/outcome.schema.json)"
  fi

  SWARM_REPAIR_HINT="Your previous response was rejected: it did not satisfy the required outcome JSON schema.

Validator output:
${repair_detail}

Emit a corrected outcome JSON object that fixes exactly these problems. Change only what the errors require — do not alter your verdict, findings, or evidence."
  export SWARM_REPAIR_HINT

  echo "agent-run: schema validation failed — retrying with corrective context"
  # Drop the rejected file so a later adapter failure cannot leave a stale
  # invalid outcome.json behind for a subsequent step to read.
  rm -f "$OUTCOME_FILE"
  attempt=$(( attempt + 1 ))
done
