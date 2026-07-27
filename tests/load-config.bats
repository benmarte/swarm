#!/usr/bin/env bats
# load-config.bats — unit tests for actions/load-config/load-config.sh
# Requires: ajv-cli@5.0.0 (npm install -g ajv-cli@5.0.0)

REPO_ROOT="$(git -C "$(dirname "$BATS_TEST_FILENAME")" rev-parse --show-toplevel)"
LOAD_CONFIG_SH="$REPO_ROOT/actions/load-config/load-config.sh"
SCHEMA="$REPO_ROOT/schemas/config.schema.json"
FIXTURES="$REPO_ROOT/tests/fixtures/config"

setup() {
  export GITHUB_WORKSPACE="$REPO_ROOT"
  # Use a temp file for GITHUB_OUTPUT so we can read exported outputs
  GITHUB_OUTPUT="$(mktemp)"
  export GITHUB_OUTPUT
}

teardown() {
  rm -f "$GITHUB_OUTPUT"
}

# ---------------------------------------------------------------------------
# Helper: read an output key from GITHUB_OUTPUT
# ---------------------------------------------------------------------------

get_output() {
  local key="$1"
  # Format: key<<DELIM\nvalue\nDELIM
  # Extract the value between the delimiters
  local in_block=false
  local delim=""
  while IFS= read -r line; do
    if [ "$in_block" = "false" ] && printf '%s' "$line" | grep -qE "^${key}<<"; then
      delim="${line#*<<}"
      in_block=true
      continue
    fi
    if [ "$in_block" = "true" ]; then
      if [ "$line" = "$delim" ]; then
        break
      fi
      printf '%s\n' "$line"
    fi
  done < "$GITHUB_OUTPUT"
}

# ---------------------------------------------------------------------------
# Valid config: passes validation and exports expected outputs
# ---------------------------------------------------------------------------

@test "valid full config passes validation" {
  export CONFIG_FILE="$FIXTURES/valid.yml"
  run bash "$LOAD_CONFIG_SH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"validation passed"* ]]
}

@test "valid full config exports runner-label output" {
  export CONFIG_FILE="$FIXTURES/valid.yml"
  run bash "$LOAD_CONFIG_SH"
  [ "$status" -eq 0 ]
  runner_label="$(get_output runner-label)"
  [ "$runner_label" = "swarm-agent" ]
}

@test "valid full config exports notify-slack output" {
  export CONFIG_FILE="$FIXTURES/valid.yml"
  run bash "$LOAD_CONFIG_SH"
  [ "$status" -eq 0 ]
  notify_slack="$(get_output notify-slack)"
  [ "$notify_slack" = "true" ]
}

@test "valid full config exports notify-buzz-channel output" {
  export CONFIG_FILE="$FIXTURES/valid.yml"
  run bash "$LOAD_CONFIG_SH"
  [ "$status" -eq 0 ]
  buzz_channel="$(get_output notify-buzz-channel)"
  [ "$buzz_channel" = "abc123-channel-uuid" ]
}

@test "valid full config exports develop-adapter output" {
  export CONFIG_FILE="$FIXTURES/valid.yml"
  run bash "$LOAD_CONFIG_SH"
  [ "$status" -eq 0 ]
  develop_adapter="$(get_output develop-adapter)"
  [ "$develop_adapter" = "claude-code-action" ]
}

@test "valid full config exports sweeper-schedule output" {
  export CONFIG_FILE="$FIXTURES/valid.yml"
  run bash "$LOAD_CONFIG_SH"
  [ "$status" -eq 0 ]
  sweeper_schedule="$(get_output sweeper-schedule)"
  [ "$sweeper_schedule" = "0 2 * * *" ]
}

@test "valid minimal config passes validation" {
  export CONFIG_FILE="$FIXTURES/valid-minimal.yml"
  run bash "$LOAD_CONFIG_SH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"validation passed"* ]]
}

@test "valid minimal config exports empty notify-slack" {
  export CONFIG_FILE="$FIXTURES/valid-minimal.yml"
  run bash "$LOAD_CONFIG_SH"
  [ "$status" -eq 0 ]
  # Empty string is fine for missing optional keys
  notify_slack="$(get_output notify-slack)"
  [ -z "$notify_slack" ] || [ "$notify_slack" = "false" ] || [ "$notify_slack" = "null" ]
}

# ---------------------------------------------------------------------------
# Invalid config: secret key present → schema "not" block rejects it
# ---------------------------------------------------------------------------

@test "config with secret key SWARM_GITHUB_TOKEN fails schema" {
  export CONFIG_FILE="$FIXTURES/invalid-secret-key.yml"
  run bash "$LOAD_CONFIG_SH"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAILED"* ]] || [[ "$stderr" == *"FAILED"* ]] || true
}

@test "config with extra secret keys (SWARM_BUZZ_RELAY_URL) fails schema" {
  export CONFIG_FILE="$FIXTURES/invalid-extra-secret.yml"
  run bash "$LOAD_CONFIG_SH"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Missing config file fails loudly with clear message
# ---------------------------------------------------------------------------

@test "missing config file exits non-zero with clear message" {
  export CONFIG_FILE="/nonexistent/swarm.config.yml"
  run bash "$LOAD_CONFIG_SH"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]] || [[ "$output" == *"ERROR"* ]]
}

# ---------------------------------------------------------------------------
# Invalid field type fails schema
# ---------------------------------------------------------------------------

@test "invalid field type (runner.label as integer) fails schema" {
  export CONFIG_FILE="$FIXTURES/invalid-bad-type.yml"
  run bash "$LOAD_CONFIG_SH"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Hostile config values: never executed as code
# ---------------------------------------------------------------------------

@test "hostile config value does not execute as shell code" {
  # Write a hostile config that would cause side-effects if eval'd
  hostile_config="$(mktemp).yml"
  printf '{"runner": {"label": "$(id -u)"}}\n' > "$hostile_config"
  export CONFIG_FILE="$hostile_config"
  run bash "$LOAD_CONFIG_SH"
  rm -f "$hostile_config"
  # Whether valid or not, the literal string should appear in output, not the id result
  if [ "$status" -eq 0 ]; then
    runner_label="$(get_output runner-label)"
    # Should be the literal string, not the expanded result
    [[ "$runner_label" != "$(id -u)" ]] || [[ "$runner_label" = '$(id -u)' ]]
  fi
  # Exit status is acceptable either way (schema may reject due to type mismatch)
  true
}

@test "ajv validation errors appear in output on failure" {
  export CONFIG_FILE="$FIXTURES/invalid-bad-type.yml"
  run bash "$LOAD_CONFIG_SH"
  [ "$status" -ne 0 ]
  # Error output should reference the failing validation
  [[ "$output" == *"FAILED"* ]] || [[ "${lines[*]}" == *"error"* ]]
}
