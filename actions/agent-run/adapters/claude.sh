#!/usr/bin/env bash
# adapters/claude.sh — swarm agent-run adapter for Claude headless CLI.
# Invokes `claude -p` with --output-format json and read-only tool constraints.
# Extracts the model's JSON response (outcome.json) from Claude's envelope.
#
# Required env (set by agent-run.sh per runner-contract.md §1):
#   SWARM_PROMPT_FILE    — absolute path to the role prompt Markdown file
#   SWARM_CONTEXT_JSON   — JSON string with issue/PR context
#   SWARM_ROLE           — role name
#   SWARM_TIMEOUT        — max seconds for the agent call
#   OUTCOME_FILE         — absolute path to write outcome.json
#   GITHUB_WORKSPACE     — working directory
#
# Required secret (consumed from environment, never echoed):
#   ANTHROPIC_API_KEY    — must be set as a GitHub Actions secret
#
# Local smoke test:
#   ANTHROPIC_API_KEY=sk-ant-... \
#   SWARM_PROMPT_FILE=prompts/validator.md \
#   SWARM_CONTEXT_JSON='{"issue":1,"title":"test"}' \
#   SWARM_ROLE=validator \
#   SWARM_TIMEOUT=300 \
#   OUTCOME_FILE=/tmp/outcome.json \
#   GITHUB_WORKSPACE=/tmp \
#   bash actions/agent-run/adapters/claude.sh
set -euo pipefail

# ---------------------------------------------------------------------------
# Guard: ANTHROPIC_API_KEY must be present (never echo its value)
# ---------------------------------------------------------------------------
if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  echo "claude adapter: ERROR: ANTHROPIC_API_KEY is not set." >&2
  echo "  Set it as a GitHub Actions secret and expose it to this job." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Guard: required env vars
# ---------------------------------------------------------------------------
if [ -z "${SWARM_PROMPT_FILE:-}" ]; then
  echo "claude adapter: ERROR: SWARM_PROMPT_FILE is not set" >&2
  exit 1
fi

if [ ! -f "$SWARM_PROMPT_FILE" ]; then
  echo "claude adapter: ERROR: prompt file not found: $SWARM_PROMPT_FILE" >&2
  exit 1
fi

if [ -z "${OUTCOME_FILE:-}" ]; then
  echo "claude adapter: ERROR: OUTCOME_FILE is not set" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Build the full prompt: role prompt + context JSON
# ---------------------------------------------------------------------------
ROLE_PROMPT="$(cat "$SWARM_PROMPT_FILE")"

FULL_PROMPT="$ROLE_PROMPT

---

## Input Context

\`\`\`json
${SWARM_CONTEXT_JSON:-{}}
\`\`\`"

# ---------------------------------------------------------------------------
# Invoke Claude headless
# Decision roles must NOT execute code — read-only tools only.
# ---------------------------------------------------------------------------
TIMEOUT_SECS="${SWARM_TIMEOUT:-300}"

echo "claude adapter: invoking claude -p (role=${SWARM_ROLE:-unknown}, timeout=${TIMEOUT_SECS}s)"

if ! raw_response=$(claude -p "$FULL_PROMPT" \
  --output-format json \
  --allowedTools "Read,Glob,Grep" \
  --max-turns 1 \
  2>&1); then
  echo "claude adapter: ERROR: claude exited non-zero" >&2
  echo "$raw_response" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Extract the outcome JSON from Claude's response envelope.
# Claude --output-format json produces a JSON object with a "result" field
# containing the assistant's text response.
# ---------------------------------------------------------------------------
if ! outcome_text=$(echo "$raw_response" | jq -r '.result // empty' 2>/dev/null); then
  echo "claude adapter: ERROR: failed to parse Claude JSON envelope" >&2
  echo "  Raw response (first 500 chars):" >&2
  echo "$raw_response" | head -c 500 >&2
  exit 1
fi

if [ -z "$outcome_text" ]; then
  echo "claude adapter: ERROR: Claude response envelope missing 'result' field" >&2
  echo "  Raw response (first 500 chars):" >&2
  echo "$raw_response" | head -c 500 >&2
  exit 1
fi

# Validate that the extracted text is JSON (validate-outcome will do full schema
# validation, but we gate on parseable JSON here to give a clearer error)
if ! echo "$outcome_text" | jq empty 2>/dev/null; then
  echo "claude adapter: ERROR: Claude result is not valid JSON." >&2
  echo "  The model must output ONLY valid JSON matching the swarm/outcome@1 schema." >&2
  echo "  Result (first 500 chars):" >&2
  echo "$outcome_text" | head -c 500 >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Write outcome.json
# ---------------------------------------------------------------------------
echo "$outcome_text" > "$OUTCOME_FILE"
echo "claude adapter: outcome.json written to $OUTCOME_FILE"
