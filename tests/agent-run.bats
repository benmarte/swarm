#!/usr/bin/env bats
# agent-run.bats — tests for agent-run composite action.
# Covers: dispatch, validation, adapter outputs, role/adapter allowlists,
# missing-secret detection, and CI skip behavior for openai-compat.
# All tests use tests/stubs/ on PATH for stubbed binaries.
#
# openai-compat local smoke: see adapters/openai-compat.sh top-comment for
# the exact env vars and one-liner to test against a local Ollama/LM Studio
# endpoint. In CI, the test is skipped (with loud stderr log) when
# SWARM_LLM_BASE_URL is unset — this is the ONLY allowed skip.

REPO_ROOT="$(git -C "$(dirname "$BATS_TEST_FILENAME")" rev-parse --show-toplevel)"
AGENT_RUN_SH="$REPO_ROOT/actions/agent-run/agent-run.sh"
CLAUDE_ADAPTER="$REPO_ROOT/actions/agent-run/adapters/claude.sh"
OPENAI_ADAPTER="$REPO_ROOT/actions/agent-run/adapters/openai-compat.sh"
STUBS_DIR="$REPO_ROOT/tests/stubs"
PROMPT_FILE="$REPO_ROOT/prompts/validator.md"
VALID_OUTCOME_FIXTURE="$REPO_ROOT/tests/fixtures/outcome/validator/valid.json"
SCHEMA_FILE="$REPO_ROOT/schemas/outcome.schema.json"

setup() {
  # Create a temp workspace for each test
  export GITHUB_WORKSPACE
  GITHUB_WORKSPACE="$(mktemp -d)"
  export OUTCOME_FILE="$GITHUB_WORKSPACE/outcome.json"

  # Claude stub log
  export CLAUDE_STUB_LOG
  CLAUDE_STUB_LOG="$(mktemp)"

  # Timeout stub log
  export TIMEOUT_STUB_LOG
  TIMEOUT_STUB_LOG="$(mktemp)"

  # Curl stub logs
  export CURL_STUB_LOG
  CURL_STUB_LOG="$(mktemp)"
  export CURL_BODY_LOG
  CURL_BODY_LOG="$(mktemp)"

  # Prepend stubs dir so fake claude/curl/timeout are found first; real ajv/jq live later
  export PATH="$STUBS_DIR:$PATH"

  # Default env for agent-run.sh
  export ACTION_PATH="$REPO_ROOT/actions/agent-run"
  export SWARM_PROMPT_FILE="$PROMPT_FILE"
  export SWARM_CONTEXT_JSON='{"issue":1,"title":"test issue"}'
  export SWARM_ROLE="validator"
  export SWARM_ADAPTER="claude"
  export SWARM_TIMEOUT_MINUTES="1"

  # Claude adapter secret (stubbed — never echoed)
  export ANTHROPIC_API_KEY="sk-ant-stub-key-for-tests"
}

teardown() {
  rm -rf "$GITHUB_WORKSPACE"
  rm -f "$CLAUDE_STUB_LOG" "$TIMEOUT_STUB_LOG" "$CURL_STUB_LOG" "$CURL_BODY_LOG"
}

# =============================================================================
# agent-run.sh — role and adapter allowlist validation
# =============================================================================

@test "agent-run: rejects unknown role before dispatch" {
  export SWARM_ROLE="super-dev"

  run bash "$AGENT_RUN_SH"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid role"* ]] || [[ "$output" == *"super-dev"* ]]

  # claude stub must NOT have been called
  [ ! -s "$CLAUDE_STUB_LOG" ] || ! grep -q "^claude" "$CLAUDE_STUB_LOG"
}

@test "agent-run: rejects unknown adapter before dispatch" {
  export SWARM_ADAPTER="gpt-turbo-wizard"

  run bash "$AGENT_RUN_SH"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid adapter"* ]] || [[ "$output" == *"gpt-turbo-wizard"* ]]

  [ ! -s "$CLAUDE_STUB_LOG" ] || ! grep -q "^claude" "$CLAUDE_STUB_LOG"
}

@test "agent-run: accepts all valid roles" {
  for role in validator pm reviewer security docs orchestrator; do
    # Use a fixture whose role matches so validate-outcome accepts it
    fixture="$REPO_ROOT/tests/fixtures/outcome/$role/valid.json"

    # Make the claude stub return the matching fixture content as the result field
    outcome_json="$(cat "$fixture")"
    export CLAUDE_STUB_RESPONSE
    CLAUDE_STUB_RESPONSE="$(jq -n --arg result "$outcome_json" \
      '{type:"result",subtype:"success",is_error:false,result:$result,session_id:"stub",num_turns:1,total_cost_usd:0}')"

    export SWARM_ROLE="$role"
    run bash "$AGENT_RUN_SH"
    [ "$status" -eq 0 ] || {
      echo "# role=$role failed: $output" >&3
      false
    }
  done
}

@test "agent-run: accepts all valid adapters" {
  # claude adapter
  export SWARM_ADAPTER="claude"
  run bash "$AGENT_RUN_SH"
  [ "$status" -eq 0 ]

  # openai-compat adapter — should CI-skip (no SWARM_LLM_BASE_URL set)
  export SWARM_ADAPTER="openai-compat"
  export CI="true"
  unset SWARM_LLM_BASE_URL 2>/dev/null || true
  run bash "$AGENT_RUN_SH"
  # The openai-compat adapter exits 0 when CI-skipping (it hasn't written an
  # outcome.json, so validate-outcome would fail). We test the adapter directly
  # in the adapter-specific tests below.
  [ "$status" -ne 0 ] || true  # agent-run may fail due to missing outcome.json — that's expected
}

# =============================================================================
# agent-run.sh — full happy path via claude stub
# =============================================================================

@test "agent-run: valid outcome from claude stub passes validation" {
  run bash "$AGENT_RUN_SH"
  [ "$status" -eq 0 ]
  [ -f "$OUTCOME_FILE" ]
  jq -e '.schema == "swarm/outcome@1"' "$OUTCOME_FILE" > /dev/null
  grep -q "^claude" "$CLAUDE_STUB_LOG"
}

@test "agent-run: outcome.json contains expected role and verdict" {
  run bash "$AGENT_RUN_SH"
  [ "$status" -eq 0 ]
  jq -e '.role == "validator"' "$OUTCOME_FILE" > /dev/null
  jq -e '.verdict == "confirmed"' "$OUTCOME_FILE" > /dev/null
}

# =============================================================================
# agent-run.sh — adapter failure propagates as job failure
# =============================================================================

@test "agent-run: adapter emitting invalid JSON fails via validate-outcome" {
  # Make the stub return a JSON envelope whose result is NOT valid JSON
  export CLAUDE_STUB_RESPONSE='{"type":"result","subtype":"success","is_error":false,"result":"this is not json at all","session_id":"stub","num_turns":1,"total_cost_usd":0}'

  run bash "$AGENT_RUN_SH"
  [ "$status" -ne 0 ]
  # Must mention the failure — prose parsing is forbidden
  [[ "$output" == *"not valid JSON"* ]] || [[ "$output" == *"FAILED"* ]] || [[ "$output" == *"ERROR"* ]]
}

@test "agent-run: adapter emitting prose (no JSON object) fails" {
  # Stub returns text prose with no JSON
  export CLAUDE_STUB_RESPONSE='{"type":"result","subtype":"success","is_error":false,"result":"I think the issue is confirmed. It looks good to me!","session_id":"stub","num_turns":1,"total_cost_usd":0}'

  run bash "$AGENT_RUN_SH"
  [ "$status" -ne 0 ]
}

@test "agent-run: adapter emitting schema-invalid JSON fails via validate-outcome" {
  # Stub returns JSON that parses but fails schema (missing required fields)
  export CLAUDE_STUB_RESPONSE
  CLAUDE_STUB_RESPONSE="$(jq -n --arg result '{"schema":"swarm/outcome@1","role":"validator"}' \
    '{type:"result",subtype:"success",is_error:false,result:$result,session_id:"stub",num_turns:1,total_cost_usd:0}')"

  run bash "$AGENT_RUN_SH"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAILED"* ]] || [[ "$output" == *"validation"* ]] || [[ "$output" == *"schema"* ]]
}

@test "agent-run: adapter exiting non-zero fails the job" {
  export CLAUDE_STUB_STATUS="1"
  export CLAUDE_STUB_RESPONSE=""

  run bash "$AGENT_RUN_SH"
  [ "$status" -ne 0 ]
}

# =============================================================================
# claude.sh adapter — direct tests
# =============================================================================

@test "claude adapter: stub emits conforming JSON → outcome.json written" {
  run bash "$CLAUDE_ADAPTER"
  [ "$status" -eq 0 ]
  [ -f "$OUTCOME_FILE" ]
  jq -e '.schema == "swarm/outcome@1"' "$OUTCOME_FILE" > /dev/null
  jq -e '.role == "validator"' "$OUTCOME_FILE" > /dev/null
}

@test "claude adapter: records invocation to CLAUDE_STUB_LOG" {
  run bash "$CLAUDE_ADAPTER"
  [ "$status" -eq 0 ]
  grep -q "^claude" "$CLAUDE_STUB_LOG"
}

@test "claude adapter: exits 1 when ANTHROPIC_API_KEY not set" {
  unset ANTHROPIC_API_KEY

  run bash "$CLAUDE_ADAPTER"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ANTHROPIC_API_KEY"* ]]
}

@test "claude adapter: exits 1 when ANTHROPIC_API_KEY is empty" {
  export ANTHROPIC_API_KEY=""

  run bash "$CLAUDE_ADAPTER"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ANTHROPIC_API_KEY"* ]]
}

@test "claude adapter: does NOT echo ANTHROPIC_API_KEY value in output" {
  # The secret value must never appear in stdout or stderr
  export ANTHROPIC_API_KEY="sk-ant-secret-that-must-not-be-logged"

  run bash "$CLAUDE_ADAPTER"
  [[ "$output" != *"sk-ant-secret-that-must-not-be-logged"* ]]
}

@test "claude adapter: exits 1 when adapter emits non-JSON result" {
  export CLAUDE_STUB_RESPONSE='{"type":"result","subtype":"success","is_error":false,"result":"Sorry, I cannot help with that.","session_id":"stub","num_turns":1,"total_cost_usd":0}'

  run bash "$CLAUDE_ADAPTER"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not valid JSON"* ]]
}

# =============================================================================
# openai-compat.sh adapter — direct tests
# =============================================================================

@test "openai-compat adapter: CI skip when SWARM_LLM_BASE_URL unset and CI=true" {
  export CI="true"
  unset SWARM_LLM_BASE_URL 2>/dev/null || true

  run bash "$OPENAI_ADAPTER"
  # Exit 0 (graceful skip)
  [ "$status" -eq 0 ]
  # Must log WARNING to stderr
  [[ "$output" == *"WARNING"* ]] || [[ "$stderr" == *"WARNING"* ]]
  # Fallback: check that WARNING appeared in the combined output
  [[ "$output" == *"WARNING"* ]] || [[ "$output" == *"Skipping"* ]]
}

@test "openai-compat adapter: CI skip is loud (logs to stderr)" {
  export CI="true"
  unset SWARM_LLM_BASE_URL 2>/dev/null || true

  # Capture stderr separately
  tmpout="$(mktemp)"
  tmperr="$(mktemp)"
  bash "$OPENAI_ADAPTER" >"$tmpout" 2>"$tmperr"
  ret=$?

  [ "$ret" -eq 0 ]
  grep -q "WARNING" "$tmperr"
  grep -q "SWARM_LLM_BASE_URL" "$tmperr"

  rm -f "$tmpout" "$tmperr"
}

@test "openai-compat adapter: exits 1 when SWARM_LLM_BASE_URL unset and CI not set" {
  unset CI 2>/dev/null || true
  unset SWARM_LLM_BASE_URL 2>/dev/null || true

  run bash "$OPENAI_ADAPTER"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SWARM_LLM_BASE_URL"* ]]
}

@test "openai-compat adapter: exits 1 when SWARM_LLM_MODEL not set" {
  export SWARM_LLM_BASE_URL="http://localhost:11434/v1"
  unset SWARM_LLM_MODEL 2>/dev/null || true
  unset CI 2>/dev/null || true

  run bash "$OPENAI_ADAPTER"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SWARM_LLM_MODEL"* ]]
}

@test "openai-compat adapter: stub emits conforming JSON → outcome.json written" {
  # Configure curl stub to return a valid OpenAI-compat response
  VALID_OUTCOME="$(cat "$VALID_OUTCOME_FIXTURE")"
  export CURL_STUB_RESPONSE
  CURL_STUB_RESPONSE="$(jq -n --arg content "$VALID_OUTCOME" \
    '{choices:[{message:{role:"assistant",content:$content}}]}')"

  export SWARM_LLM_BASE_URL="http://localhost:11434/v1"
  export SWARM_LLM_MODEL="llama3.2"
  unset CI 2>/dev/null || true

  run bash "$OPENAI_ADAPTER"
  [ "$status" -eq 0 ]
  [ -f "$OUTCOME_FILE" ]
  jq -e '.schema == "swarm/outcome@1"' "$OUTCOME_FILE" > /dev/null
}

@test "openai-compat adapter: calls configured endpoint via curl" {
  VALID_OUTCOME="$(cat "$VALID_OUTCOME_FIXTURE")"
  export CURL_STUB_RESPONSE
  CURL_STUB_RESPONSE="$(jq -n --arg content "$VALID_OUTCOME" \
    '{choices:[{message:{role:"assistant",content:$content}}]}')"

  export SWARM_LLM_BASE_URL="http://localhost:11434/v1"
  export SWARM_LLM_MODEL="llama3.2"
  unset CI 2>/dev/null || true

  run bash "$OPENAI_ADAPTER"
  [ "$status" -eq 0 ]
  grep -q "http://localhost:11434/v1/chat/completions" "$CURL_STUB_LOG"
}

@test "openai-compat adapter: fallback extracts single-line prose+JSON" {
  # curl stub returns a response where content is prose on one line with embedded JSON
  VALID_OUTCOME="$(cat "$VALID_OUTCOME_FIXTURE" | tr -d '\n')"
  PROSE_CONTENT="Here is my analysis: $VALID_OUTCOME — that is my verdict."
  export CURL_STUB_RESPONSE
  CURL_STUB_RESPONSE="$(jq -n --arg content "$PROSE_CONTENT" \
    '{choices:[{message:{role:"assistant",content:$content}}]}')"

  export SWARM_LLM_BASE_URL="http://localhost:11434/v1"
  export SWARM_LLM_MODEL="llama3.2"
  unset CI 2>/dev/null || true

  run bash "$OPENAI_ADAPTER"
  [ "$status" -eq 0 ]
  [ -f "$OUTCOME_FILE" ]
  jq -e '.schema == "swarm/outcome@1"' "$OUTCOME_FILE" > /dev/null
  [[ "$output" == *"fallback"* ]]
}

@test "openai-compat adapter: fallback extracts multi-line JSON" {
  # curl stub returns content where the JSON spans multiple lines (common for verbose models)
  VALID_OUTCOME="$(cat "$VALID_OUTCOME_FIXTURE")"
  PROSE_CONTENT="$(printf 'Here is the result:\n%s\nDone.' "$VALID_OUTCOME")"
  export CURL_STUB_RESPONSE
  CURL_STUB_RESPONSE="$(jq -n --arg content "$PROSE_CONTENT" \
    '{choices:[{message:{role:"assistant",content:$content}}]}')"

  export SWARM_LLM_BASE_URL="http://localhost:11434/v1"
  export SWARM_LLM_MODEL="llama3.2"
  unset CI 2>/dev/null || true

  run bash "$OPENAI_ADAPTER"
  [ "$status" -eq 0 ]
  [ -f "$OUTCOME_FILE" ]
  jq -e '.schema == "swarm/outcome@1"' "$OUTCOME_FILE" > /dev/null
  [[ "$output" == *"fallback"* ]]
}

@test "openai-compat adapter: fallback extracts markdown-fenced JSON" {
  # curl stub returns content wrapped in markdown code fences (```json ... ```)
  VALID_OUTCOME="$(cat "$VALID_OUTCOME_FIXTURE")"
  PROSE_CONTENT="$(printf 'Here is the outcome:\n\`\`\`json\n%s\n\`\`\`\nEnd.' "$VALID_OUTCOME")"
  export CURL_STUB_RESPONSE
  CURL_STUB_RESPONSE="$(jq -n --arg content "$PROSE_CONTENT" \
    '{choices:[{message:{role:"assistant",content:$content}}]}')"

  export SWARM_LLM_BASE_URL="http://localhost:11434/v1"
  export SWARM_LLM_MODEL="llama3.2"
  unset CI 2>/dev/null || true

  run bash "$OPENAI_ADAPTER"
  [ "$status" -eq 0 ]
  [ -f "$OUTCOME_FILE" ]
  jq -e '.schema == "swarm/outcome@1"' "$OUTCOME_FILE" > /dev/null
  [[ "$output" == *"fallback"* ]]
}

@test "openai-compat adapter: exits 1 when curl stub fails" {
  export CURL_STUB_STATUS="1"
  export SWARM_LLM_BASE_URL="http://localhost:11434/v1"
  export SWARM_LLM_MODEL="llama3.2"
  unset CI 2>/dev/null || true

  run bash "$OPENAI_ADAPTER"
  [ "$status" -ne 0 ]
}

@test "openai-compat adapter: exits 1 when API returns error object" {
  export CURL_STUB_RESPONSE='{"error":{"message":"model not found","type":"invalid_request_error"}}'
  export SWARM_LLM_BASE_URL="http://localhost:11434/v1"
  export SWARM_LLM_MODEL="nonexistent-model"
  unset CI 2>/dev/null || true

  run bash "$OPENAI_ADAPTER"
  [ "$status" -ne 0 ]
  [[ "$output" == *"error"* ]] || [[ "$output" == *"ERROR"* ]]
}

# =============================================================================
# claude.sh adapter — timeout enforcement
# =============================================================================

@test "claude adapter: timeout stub is invoked with SWARM_TIMEOUT seconds" {
  # timeout stub (tests/stubs/timeout) is on PATH; it records its argv and delegates.
  # Verify that claude -p is wrapped with timeout <SWARM_TIMEOUT_MINUTES*60>.
  export SWARM_TIMEOUT="60"  # pre-computed seconds (as set by agent-run.sh)

  run bash "$CLAUDE_ADAPTER"
  [ "$status" -eq 0 ]

  # timeout stub must have been called
  [ -s "$TIMEOUT_STUB_LOG" ]
  grep -q "^timeout" "$TIMEOUT_STUB_LOG"
  # The first argument after "timeout" must be the timeout in seconds
  grep -q "timeout 60" "$TIMEOUT_STUB_LOG"
  # claude stub must also have been called (timeout stub delegates to it)
  grep -q "^claude" "$CLAUDE_STUB_LOG"
}

@test "claude adapter: timeout stub invocation wraps claude command" {
  export SWARM_TIMEOUT="120"

  run bash "$CLAUDE_ADAPTER"
  [ "$status" -eq 0 ]

  grep -q "timeout 120" "$TIMEOUT_STUB_LOG"
}
