#!/usr/bin/env bats
# load-config.bats — unit tests for actions/load-config/load-config.sh
# Requires: ajv-cli@5.0.0 (npm install -g ajv-cli@5.0.0)

REPO_ROOT="$(git -C "$(dirname "$BATS_TEST_FILENAME")" rev-parse --show-toplevel)"
LOAD_CONFIG_SH="$REPO_ROOT/actions/load-config/load-config.sh"
SCHEMA="$REPO_ROOT/schemas/config.schema.json"
FIXTURES="$REPO_ROOT/tests/fixtures/config"

setup() {
  export GITHUB_WORKSPACE="$REPO_ROOT"
  # ACTION_PATH points to the composite action directory so the schema is
  # resolved via ACTION_PATH/../../schemas/config.schema.json.
  export ACTION_PATH="$REPO_ROOT/actions/load-config"
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
# Real-YAML fixture: not JSON-compatible — regression for issue #36
# (leading comments, unquoted strings, YAML boolean, em-dash in comment)
# ---------------------------------------------------------------------------

@test "real-YAML config passes validation and extraction" {
  export CONFIG_FILE="$FIXTURES/valid-real-yaml.yml"
  run bash "$LOAD_CONFIG_SH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"validation passed"* ]]
}

@test "real-YAML config extracts runner-label" {
  export CONFIG_FILE="$FIXTURES/valid-real-yaml.yml"
  run bash "$LOAD_CONFIG_SH"
  [ "$status" -eq 0 ]
  runner_label="$(get_output runner-label)"
  [ "$runner_label" = "swarm-agent" ]
}

@test "real-YAML config extracts notify-slack" {
  export CONFIG_FILE="$FIXTURES/valid-real-yaml.yml"
  run bash "$LOAD_CONFIG_SH"
  [ "$status" -eq 0 ]
  notify_slack="$(get_output notify-slack)"
  [ "$notify_slack" = "true" ]
}

@test "real-YAML config extracts notify-discord" {
  export CONFIG_FILE="$FIXTURES/valid-real-yaml.yml"
  run bash "$LOAD_CONFIG_SH"
  [ "$status" -eq 0 ]
  notify_discord="$(get_output notify-discord)"
  [ "$notify_discord" = "false" ]
}

@test "real-YAML config extracts notify-buzz-channel" {
  export CONFIG_FILE="$FIXTURES/valid-real-yaml.yml"
  run bash "$LOAD_CONFIG_SH"
  [ "$status" -eq 0 ]
  buzz_channel="$(get_output notify-buzz-channel)"
  [ "$buzz_channel" = "abc123-channel-uuid" ]
}

@test "real-YAML config extracts develop-adapter" {
  export CONFIG_FILE="$FIXTURES/valid-real-yaml.yml"
  run bash "$LOAD_CONFIG_SH"
  [ "$status" -eq 0 ]
  develop_adapter="$(get_output develop-adapter)"
  [ "$develop_adapter" = "claude-code-action" ]
}

@test "real-YAML config extracts sweeper-schedule" {
  export CONFIG_FILE="$FIXTURES/valid-real-yaml.yml"
  run bash "$LOAD_CONFIG_SH"
  [ "$status" -eq 0 ]
  sweeper_schedule="$(get_output sweeper-schedule)"
  [ "$sweeper_schedule" = "0 2 * * *" ]
}

@test "missing YAML converter: script contains loud error message (structural)" {
  # PATH-stripping both python3 and node is impractical (ajv is also node-based
  # and must remain working for the validation step that runs first).
  # Assert that the required error message text is present in the script source —
  # the execution path is covered by integration; this guards the message content.
  grep -q "python3 with PyYAML" "$LOAD_CONFIG_SH"
  grep -q "no YAML-to-JSON converter" "$LOAD_CONFIG_SH"
}

# ---------------------------------------------------------------------------
# Invalid config: secret key present → schema "not" block rejects it
# ---------------------------------------------------------------------------

@test "config with secret key SWARM_GITHUB_TOKEN fails schema" {
  export CONFIG_FILE="$FIXTURES/invalid-secret-key.yml"
  run bash "$LOAD_CONFIG_SH"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAILED"* ]] || [[ "$stderr" == *"FAILED"* ]]
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
    [[ "$runner_label" != "$(id -u)" ]] || [[ "$runner_label" = '$(id -u)' ]] || false
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

# ---------------------------------------------------------------------------
# ACTION_PATH required — fail loudly when missing
# ---------------------------------------------------------------------------

@test "missing ACTION_PATH exits with clear error" {
  tmp_out="$(mktemp)"
  run env -i \
    GITHUB_WORKSPACE="$REPO_ROOT" \
    CONFIG_FILE="$FIXTURES/valid-minimal.yml" \
    GITHUB_OUTPUT="$tmp_out" \
    HOME="${HOME:-/root}" \
    PATH="$PATH" \
    bash "$LOAD_CONFIG_SH"
  rm -f "$tmp_out"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ACTION_PATH"* ]]
}

# ---------------------------------------------------------------------------
# Regression: action dir outside workspace — schema must resolve via ACTION_PATH
# ---------------------------------------------------------------------------

@test "regression: action outside workspace succeeds (ACTION_PATH-relative schema)" {
  # Simulate a consumer repo: workspace has config but NO schemas/.
  # Engine dir (ACTION_PATH) lives outside the workspace.
  local engine_root workspace_dir tmp_out action_path
  engine_root="$(mktemp -d)"
  workspace_dir="$(mktemp -d)"
  tmp_out="$(mktemp)"

  # Lay out: engine_root/actions/load-config/ (ACTION_PATH)
  #          engine_root/schemas/              (ACTION_PATH/../../schemas)
  action_path="$engine_root/actions/load-config"
  mkdir -p "$action_path"
  mkdir -p "$engine_root/schemas"

  cp "$LOAD_CONFIG_SH" "$action_path/load-config.sh"
  cp "$SCHEMA" "$engine_root/schemas/config.schema.json"

  # Consumer workspace — has config but no schemas/ directory
  cp "$FIXTURES/valid-minimal.yml" "$workspace_dir/swarm.config.yml"

  run env \
    GITHUB_WORKSPACE="$workspace_dir" \
    ACTION_PATH="$action_path" \
    CONFIG_FILE="swarm.config.yml" \
    GITHUB_OUTPUT="$tmp_out" \
    bash "$action_path/load-config.sh"

  rm -rf "$engine_root" "$workspace_dir"
  rm -f "$tmp_out"
  [ "$status" -eq 0 ]
  [[ "$output" == *"validation passed"* ]]
}

# ---------------------------------------------------------------------------
# Structural: no engine-asset paths built from GITHUB_WORKSPACE in actions/
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# qa-required-checks output (issue #72)
# Tests below FAIL before the fix; pass after.
# ---------------------------------------------------------------------------

@test "load-config action.yml declares qa-required-checks output (issue #72)" {
  ACTION="$REPO_ROOT/actions/load-config/action.yml"
  run grep -q "qa-required-checks" "$ACTION"
  [ "$status" -eq 0 ]
}

@test "load-config.sh exports qa-required-checks output (issue #72)" {
  run grep -q "qa-required-checks\|qa_required_checks" "$LOAD_CONFIG_SH"
  [ "$status" -eq 0 ]
}

@test "valid full config exports qa-required-checks as comma-separated string (issue #72)" {
  # valid.yml has: qa: { required_checks: ["CI / ci", "actionlint"] }
  # Expected output: "CI / ci,actionlint"
  export CONFIG_FILE="$FIXTURES/valid.yml"
  run bash "$LOAD_CONFIG_SH"
  [ "$status" -eq 0 ]
  qa_checks="$(get_output qa-required-checks)"
  # Must be non-empty and contain both check names joined by comma
  [ -n "$qa_checks" ]
  printf '%s' "$qa_checks" | grep -q "CI / ci"
  printf '%s' "$qa_checks" | grep -q "actionlint"
}

@test "valid minimal config exports empty qa-required-checks (issue #72)" {
  # Minimal config has no qa section — output must be empty (AC4: degrade cleanly)
  export CONFIG_FILE="$FIXTURES/valid-minimal.yml"
  run bash "$LOAD_CONFIG_SH"
  [ "$status" -eq 0 ]
  qa_checks="$(get_output qa-required-checks)"
  [ -z "$qa_checks" ]
}

@test "structural: no GITHUB_WORKSPACE-relative engine-asset reads in actions/" {
  # schemas/, prompts/ are engine assets — must never be accessed via
  # GITHUB_WORKSPACE. Runtime output files (outcome.json, GITHUB_OUTPUT)
  # are allowed to remain workspace-relative.
  local violations
  violations="$(grep -rn 'GITHUB_WORKSPACE[^)]*schemas/\|GITHUB_WORKSPACE[^)]*prompts/' \
    "$REPO_ROOT/actions/" --include='*.sh' \
    | grep -v '^[[:space:]]*#' \
    | grep -v 'GITHUB_WORKSPACE.*://' \
    || true)"
  if [ -n "$violations" ]; then
    echo "Engine-asset reads via GITHUB_WORKSPACE found:" >&2
    echo "$violations" >&2
  fi
  [ -z "$violations" ]
}
