#!/usr/bin/env bash
# adapters/openai-compat.sh — swarm agent-run adapter for any OpenAI-compatible endpoint.
# Supports Ollama, LM Studio, vLLM, OpenAI, and any other provider that exposes
# a /v1/chat/completions endpoint. Uses curl + jq; no additional dependencies.
#
# Required env (set by agent-run.sh per runner-contract.md §1):
#   SWARM_PROMPT_FILE    — absolute path to the role prompt Markdown file
#   SWARM_CONTEXT_JSON   — JSON string with issue/PR context
#   SWARM_ROLE           — role name
#   SWARM_TIMEOUT        — max seconds for the agent call (passed to curl -m)
#   OUTCOME_FILE         — absolute path to write outcome.json
#   GITHUB_WORKSPACE     — working directory
#
# Required runner vars (set in the consumer repo / GitHub Actions env):
#   SWARM_LLM_BASE_URL   — base URL of the OpenAI-compatible endpoint
#                          e.g. http://localhost:11434/v1  (Ollama)
#                               http://localhost:1234/v1   (LM Studio)
#                               https://api.openai.com/v1  (OpenAI)
#   SWARM_LLM_MODEL      — model name, e.g. llama3.2, mistral, gpt-4o
#
# Optional runner vars:
#   SWARM_LLM_API_KEY    — bearer token (omit for local endpoints that need none)
#
# Local smoke test (Ollama example):
#   ollama serve &
#   ollama pull llama3.2
#
#   SWARM_LLM_BASE_URL=http://localhost:11434/v1 \
#   SWARM_LLM_MODEL=llama3.2 \
#   SWARM_PROMPT_FILE=prompts/validator.md \
#   SWARM_CONTEXT_JSON='{"issue":1,"title":"test"}' \
#   SWARM_ROLE=validator \
#   SWARM_TIMEOUT=120 \
#   OUTCOME_FILE=/tmp/outcome.json \
#   GITHUB_WORKSPACE=/tmp \
#   bash actions/agent-run/adapters/openai-compat.sh
#
# Local smoke test (LM Studio example):
#   # Start LM Studio server on port 1234, load a model
#   SWARM_LLM_BASE_URL=http://localhost:1234/v1 \
#   SWARM_LLM_MODEL=local-model \
#   SWARM_PROMPT_FILE=prompts/validator.md \
#   SWARM_CONTEXT_JSON='{"issue":1,"title":"test"}' \
#   SWARM_ROLE=validator \
#   SWARM_TIMEOUT=120 \
#   OUTCOME_FILE=/tmp/outcome.json \
#   GITHUB_WORKSPACE=/tmp \
#   bash actions/agent-run/adapters/openai-compat.sh
set -euo pipefail

# ---------------------------------------------------------------------------
# CI skip gate: if running in CI with no endpoint configured, skip with a
# loud warning. This is the ONLY place skipping is allowed, and it must log.
# ---------------------------------------------------------------------------
if [ -z "${SWARM_LLM_BASE_URL:-}" ] && [ -n "${CI:-}" ]; then
  echo "openai-compat adapter: WARNING: SWARM_LLM_BASE_URL is not set." >&2
  echo "  Skipping openai-compat test in CI — no local endpoint available." >&2
  echo "  To run against a real endpoint, set SWARM_LLM_BASE_URL in your" >&2
  echo "  repository variables or environment." >&2
  exit 0
fi

# ---------------------------------------------------------------------------
# Guard: required env vars (loud failures with actionable messages)
# ---------------------------------------------------------------------------
if [ -z "${SWARM_LLM_BASE_URL:-}" ]; then
  echo "openai-compat adapter: ERROR: SWARM_LLM_BASE_URL is not set." >&2
  echo "  Set it as a repository variable (e.g. http://localhost:11434/v1)." >&2
  exit 1
fi

if [ -z "${SWARM_LLM_MODEL:-}" ]; then
  echo "openai-compat adapter: ERROR: SWARM_LLM_MODEL is not set." >&2
  echo "  Set it as a repository variable (e.g. llama3.2, gpt-4o)." >&2
  exit 1
fi

if [ -z "${SWARM_PROMPT_FILE:-}" ]; then
  echo "openai-compat adapter: ERROR: SWARM_PROMPT_FILE is not set" >&2
  exit 1
fi

if [ ! -f "$SWARM_PROMPT_FILE" ]; then
  echo "openai-compat adapter: ERROR: prompt file not found: $SWARM_PROMPT_FILE" >&2
  exit 1
fi

if [ -z "${OUTCOME_FILE:-}" ]; then
  echo "openai-compat adapter: ERROR: OUTCOME_FILE is not set" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Build request: system = role prompt, user = context JSON
# ---------------------------------------------------------------------------
SYSTEM_PROMPT="$(cat "$SWARM_PROMPT_FILE")"
USER_CONTENT="## Input Context

\`\`\`json
${SWARM_CONTEXT_JSON:-{}}
\`\`\`

Output ONLY valid JSON matching the swarm/outcome@1 schema."

TIMEOUT_SECS="${SWARM_TIMEOUT:-300}"

# Build auth header (empty string if no API key)
AUTH_HEADER=""
if [ -n "${SWARM_LLM_API_KEY:-}" ]; then
  AUTH_HEADER="Authorization: Bearer ${SWARM_LLM_API_KEY}"
fi

# Build request body with jq to ensure proper JSON escaping
REQUEST_BODY="$(jq -n \
  --arg model "$SWARM_LLM_MODEL" \
  --arg system "$SYSTEM_PROMPT" \
  --arg user "$USER_CONTENT" \
  '{
    model: $model,
    messages: [
      {role: "system",    content: $system},
      {role: "user",      content: $user}
    ],
    response_format: {type: "json_object"},
    temperature: 0.1
  }')"

# ---------------------------------------------------------------------------
# Call the endpoint
# ---------------------------------------------------------------------------
ENDPOINT="${SWARM_LLM_BASE_URL%/}/chat/completions"
echo "openai-compat adapter: calling $ENDPOINT (model=${SWARM_LLM_MODEL}, timeout=${TIMEOUT_SECS}s)"

curl_args=(
  -s
  -m "$TIMEOUT_SECS"
  -X POST
  "$ENDPOINT"
  -H "Content-Type: application/json"
  -d "$REQUEST_BODY"
)

if [ -n "$AUTH_HEADER" ]; then
  curl_args+=(-H "$AUTH_HEADER")
fi

if ! raw_response=$(curl "${curl_args[@]}" 2>&1); then
  echo "openai-compat adapter: ERROR: curl failed (endpoint unreachable or timed out)" >&2
  echo "  Endpoint: $ENDPOINT" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Check for API-level error in the response
# ---------------------------------------------------------------------------
if echo "$raw_response" | jq -e '.error' >/dev/null 2>&1; then
  err_msg="$(echo "$raw_response" | jq -r '.error.message // .error | tostring')"
  echo "openai-compat adapter: ERROR: API returned an error: $err_msg" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Extract the assistant message content
# ---------------------------------------------------------------------------
if ! assistant_content=$(echo "$raw_response" | jq -r '.choices[0].message.content // empty' 2>/dev/null); then
  echo "openai-compat adapter: ERROR: failed to parse API response" >&2
  echo "  Raw response (first 500 chars):" >&2
  echo "$raw_response" | head -c 500 >&2
  exit 1
fi

if [ -z "$assistant_content" ]; then
  echo "openai-compat adapter: ERROR: API response missing choices[0].message.content" >&2
  echo "  Raw response (first 500 chars):" >&2
  echo "$raw_response" | head -c 500 >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Validate the content parses as JSON.
# Primary path: response_format was honored and content IS the JSON object.
# Fallback path: extract the first {...} block from the content if it's prose
#                with embedded JSON.
# In both cases, validate-outcome performs full schema validation.
# ---------------------------------------------------------------------------
if echo "$assistant_content" | jq empty 2>/dev/null; then
  outcome_json="$assistant_content"
else
  echo "openai-compat adapter: response_format not honored; attempting JSON extraction fallback"
  # Extract the first {...} block from the content
  if ! outcome_json=$(echo "$assistant_content" | grep -o '{.*}' | head -1); then
    echo "openai-compat adapter: ERROR: cannot extract JSON from model response." >&2
    echo "  The model must output a JSON object matching swarm/outcome@1." >&2
    echo "  Content (first 500 chars):" >&2
    echo "$assistant_content" | head -c 500 >&2
    exit 1
  fi
  # Validate the extracted block is parseable JSON
  if ! echo "$outcome_json" | jq empty 2>/dev/null; then
    echo "openai-compat adapter: ERROR: extracted content is not valid JSON." >&2
    echo "  Content (first 500 chars):" >&2
    echo "$assistant_content" | head -c 500 >&2
    exit 1
  fi
  echo "openai-compat adapter: JSON extracted via fallback (response_format not honored)"
fi

# ---------------------------------------------------------------------------
# Write outcome.json
# ---------------------------------------------------------------------------
echo "$outcome_json" > "$OUTCOME_FILE"
echo "openai-compat adapter: outcome.json written to $OUTCOME_FILE"
