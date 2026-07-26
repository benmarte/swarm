#!/usr/bin/env bats
# validate-outcome.bats — schema accept/reject tests for outcome, event, and config schemas.
# Requires: ajv-cli@5.0.0 installed (npm install -g ajv-cli@5.0.0).

REPO_ROOT="$(git -C "$(dirname "$BATS_TEST_FILENAME")" rev-parse --show-toplevel)"
OUTCOME_SCHEMA="$REPO_ROOT/schemas/outcome.schema.json"
EVENT_SCHEMA="$REPO_ROOT/schemas/event.schema.json"
CONFIG_SCHEMA="$REPO_ROOT/schemas/config.schema.json"
VALIDATE_SH="$REPO_ROOT/actions/validate-outcome/validate.sh"
FIXTURES="$REPO_ROOT/tests/fixtures"

# ---------------------------------------------------------------------------
# Helper
# ---------------------------------------------------------------------------
validate_passes() {
  local schema="$1" data="$2"
  run ajv validate -s "$schema" -d "$data"
  [ "$status" -eq 0 ]
}

validate_fails() {
  local schema="$1" data="$2"
  run ajv validate -s "$schema" -d "$data"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# outcome — validator role
# ---------------------------------------------------------------------------

@test "outcome/validator valid.json passes schema" {
  validate_passes "$OUTCOME_SCHEMA" "$FIXTURES/outcome/validator/valid.json"
}

@test "outcome/validator invalid-missing-field.json fails schema" {
  validate_fails "$OUTCOME_SCHEMA" "$FIXTURES/outcome/validator/invalid-missing-field.json"
}

@test "outcome/validator invalid-bad-verdict.json fails schema" {
  validate_fails "$OUTCOME_SCHEMA" "$FIXTURES/outcome/validator/invalid-bad-verdict.json"
}

# ---------------------------------------------------------------------------
# outcome — pm role
# ---------------------------------------------------------------------------

@test "outcome/pm valid.json passes schema" {
  validate_passes "$OUTCOME_SCHEMA" "$FIXTURES/outcome/pm/valid.json"
}

@test "outcome/pm invalid-missing-field.json fails schema" {
  validate_fails "$OUTCOME_SCHEMA" "$FIXTURES/outcome/pm/invalid-missing-field.json"
}

@test "outcome/pm invalid-bad-verdict.json fails schema" {
  validate_fails "$OUTCOME_SCHEMA" "$FIXTURES/outcome/pm/invalid-bad-verdict.json"
}

# ---------------------------------------------------------------------------
# outcome — reviewer role
# ---------------------------------------------------------------------------

@test "outcome/reviewer valid.json passes schema" {
  validate_passes "$OUTCOME_SCHEMA" "$FIXTURES/outcome/reviewer/valid.json"
}

@test "outcome/reviewer invalid-missing-field.json fails schema" {
  validate_fails "$OUTCOME_SCHEMA" "$FIXTURES/outcome/reviewer/invalid-missing-field.json"
}

@test "outcome/reviewer invalid-bad-verdict.json fails schema" {
  validate_fails "$OUTCOME_SCHEMA" "$FIXTURES/outcome/reviewer/invalid-bad-verdict.json"
}

# ---------------------------------------------------------------------------
# outcome — security role
# ---------------------------------------------------------------------------

@test "outcome/security valid.json passes schema" {
  validate_passes "$OUTCOME_SCHEMA" "$FIXTURES/outcome/security/valid.json"
}

@test "outcome/security invalid-missing-field.json fails schema" {
  validate_fails "$OUTCOME_SCHEMA" "$FIXTURES/outcome/security/invalid-missing-field.json"
}

@test "outcome/security invalid-bad-verdict.json fails schema" {
  validate_fails "$OUTCOME_SCHEMA" "$FIXTURES/outcome/security/invalid-bad-verdict.json"
}

# ---------------------------------------------------------------------------
# outcome — docs role
# ---------------------------------------------------------------------------

@test "outcome/docs valid.json passes schema" {
  validate_passes "$OUTCOME_SCHEMA" "$FIXTURES/outcome/docs/valid.json"
}

@test "outcome/docs invalid-missing-field.json fails schema" {
  validate_fails "$OUTCOME_SCHEMA" "$FIXTURES/outcome/docs/invalid-missing-field.json"
}

@test "outcome/docs invalid-bad-verdict.json fails schema" {
  validate_fails "$OUTCOME_SCHEMA" "$FIXTURES/outcome/docs/invalid-bad-verdict.json"
}

# ---------------------------------------------------------------------------
# outcome — orchestrator role
# ---------------------------------------------------------------------------

@test "outcome/orchestrator valid.json passes schema" {
  validate_passes "$OUTCOME_SCHEMA" "$FIXTURES/outcome/orchestrator/valid.json"
}

@test "outcome/orchestrator invalid-missing-field.json fails schema" {
  validate_fails "$OUTCOME_SCHEMA" "$FIXTURES/outcome/orchestrator/invalid-missing-field.json"
}

@test "outcome/orchestrator invalid-bad-verdict.json fails schema" {
  validate_fails "$OUTCOME_SCHEMA" "$FIXTURES/outcome/orchestrator/invalid-bad-verdict.json"
}

# ---------------------------------------------------------------------------
# event schema
# ---------------------------------------------------------------------------

@test "event/valid.json passes event schema" {
  validate_passes "$EVENT_SCHEMA" "$FIXTURES/event/valid.json"
}

@test "event/invalid-missing-field.json fails event schema" {
  validate_fails "$EVENT_SCHEMA" "$FIXTURES/event/invalid-missing-field.json"
}

@test "event/invalid-bad-type.json fails event schema" {
  validate_fails "$EVENT_SCHEMA" "$FIXTURES/event/invalid-bad-type.json"
}

# ---------------------------------------------------------------------------
# config schema (fixtures stored as JSON-formatted .yml files)
# ---------------------------------------------------------------------------

@test "config/valid.yml passes config schema" {
  validate_passes "$CONFIG_SCHEMA" "$FIXTURES/config/valid.yml"
}

@test "config/invalid-missing-channel.yml fails config schema (buzz_channel not a string)" {
  validate_fails "$CONFIG_SCHEMA" "$FIXTURES/config/invalid-missing-channel.yml"
}

@test "config/invalid-extra-secret.yml fails config schema (secrets forbidden in config)" {
  validate_fails "$CONFIG_SCHEMA" "$FIXTURES/config/invalid-extra-secret.yml"
}

# ---------------------------------------------------------------------------
# validate.sh script — accepts valid, rejects invalid, emits actionable output
# ---------------------------------------------------------------------------

@test "validate.sh exits 0 on valid outcome" {
  run bash "$VALIDATE_SH" \
    "$FIXTURES/outcome/validator/valid.json" \
    "$OUTCOME_SCHEMA"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "validate.sh exits non-zero on invalid outcome and prints actionable error" {
  run bash "$VALIDATE_SH" \
    "$FIXTURES/outcome/validator/invalid-bad-verdict.json" \
    "$OUTCOME_SCHEMA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAILED"* ]] || [[ "$output" == *"validation errors"* ]] || [[ "$output" == *"Validation errors"* ]]
}

@test "validate.sh exits non-zero when outcome file does not exist" {
  run bash "$VALIDATE_SH" \
    "/tmp/nonexistent-outcome-file.json" \
    "$OUTCOME_SCHEMA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}
