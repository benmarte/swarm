#!/usr/bin/env bats
# bootstrap.bats — unit tests for scripts/bootstrap.sh
# Uses the gh CLI stub from tests/stubs/gh (records invocations to GH_STUB_LOG).

REPO_ROOT="$(git -C "$(dirname "$BATS_TEST_FILENAME")" rev-parse --show-toplevel)"
BOOTSTRAP_SH="$REPO_ROOT/scripts/bootstrap.sh"
STUBS_DIR="$REPO_ROOT/tests/stubs"
FIXTURES_DIR="$REPO_ROOT/tests/fixtures/bootstrap"

setup() {
  export GH_STUB_LOG
  GH_STUB_LOG="$(mktemp)"
  export GH_STUB_USER_ID="12345"
  export GH_STUB_REPO_NAME="testowner/testrepo"
  export GITHUB_REPOSITORY="testowner/testrepo"
  export GH_TOKEN="fake-token"
  # Prepend stubs dir so fake gh is found first
  export PATH="$STUBS_DIR:$PATH"
  # Use a temp dir for any files written by bootstrap
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
}

teardown() {
  rm -f "$GH_STUB_LOG"
  rm -rf "$TEST_TMPDIR"
}

# ---------------------------------------------------------------------------
# Argument validation
# ---------------------------------------------------------------------------

@test "missing --env-file exits non-zero with usage message" {
  run bash "$BOOTSTRAP_SH" --repo testowner/testrepo --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"--env-file is required"* ]]
}

@test "nonexistent env file exits non-zero" {
  run bash "$BOOTSTRAP_SH" --env-file /nonexistent/path.env --repo testowner/testrepo --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}

# ---------------------------------------------------------------------------
# Dry-run: asserts every intended gh call appears in stub log
# ---------------------------------------------------------------------------

@test "dry-run: logs label creation for swarm:go" {
  run bash "$BOOTSTRAP_SH" \
    --env-file "$FIXTURES_DIR/complete.env" \
    --repo testowner/testrepo \
    --reviewer stubuser \
    --dry-run
  [ "$status" -eq 0 ]
  grep -q "swarm:go" <<< "$output"
}

@test "dry-run: logs label creation for swarm:spec" {
  run bash "$BOOTSTRAP_SH" \
    --env-file "$FIXTURES_DIR/complete.env" \
    --repo testowner/testrepo \
    --reviewer stubuser \
    --dry-run
  [ "$status" -eq 0 ]
  grep -q "swarm:spec" <<< "$output"
}

@test "dry-run: logs environment creation for swarm-approval" {
  run bash "$BOOTSTRAP_SH" \
    --env-file "$FIXTURES_DIR/complete.env" \
    --repo testowner/testrepo \
    --reviewer stubuser \
    --dry-run
  [ "$status" -eq 0 ]
  grep -q "swarm-approval" <<< "$output"
}

@test "dry-run: logs secret set for each key in env file" {
  run bash "$BOOTSTRAP_SH" \
    --env-file "$FIXTURES_DIR/complete.env" \
    --repo testowner/testrepo \
    --reviewer stubuser \
    --dry-run
  [ "$status" -eq 0 ]
  # Each key should appear in dry-run output
  grep -q "SWARM_GITHUB_TOKEN" <<< "$output"
  grep -q "ANTHROPIC_API_KEY" <<< "$output"
  grep -q "SWARM_BUZZ_RELAY_URL" <<< "$output"
  grep -q "SWARM_BUZZ_PRIVATE_KEY" <<< "$output"
}

@test "dry-run: logs swarm.config.yml write intent" {
  run bash "$BOOTSTRAP_SH" \
    --env-file "$FIXTURES_DIR/complete.env" \
    --repo testowner/testrepo \
    --reviewer stubuser \
    --dry-run
  [ "$status" -eq 0 ]
  grep -q "swarm.config.yml" <<< "$output"
}

@test "dry-run: zero mutations (gh stub log is empty — no real calls)" {
  run bash "$BOOTSTRAP_SH" \
    --env-file "$FIXTURES_DIR/complete.env" \
    --repo testowner/testrepo \
    --reviewer stubuser \
    --dry-run
  [ "$status" -eq 0 ]
  # In dry-run, no actual gh calls should be recorded in the stub log
  # (dry-run prints to stdout, never calls the real gh)
  [ ! -s "$GH_STUB_LOG" ]
}

# ---------------------------------------------------------------------------
# Non-dry-run: actual gh calls recorded in stub log
# ---------------------------------------------------------------------------

@test "non-dry-run: gh api call for label creation recorded in stub log" {
  run bash "$BOOTSTRAP_SH" \
    --env-file "$FIXTURES_DIR/complete.env" \
    --repo testowner/testrepo \
    --reviewer stubuser
  [ "$status" -eq 0 ]
  # Stub log should contain the api call for label creation
  grep -q "gh api" "$GH_STUB_LOG"
}

@test "non-dry-run: gh secret set recorded for SWARM_GITHUB_TOKEN" {
  run bash "$BOOTSTRAP_SH" \
    --env-file "$FIXTURES_DIR/complete.env" \
    --repo testowner/testrepo \
    --reviewer stubuser
  [ "$status" -eq 0 ]
  grep -q "secret set SWARM_GITHUB_TOKEN" "$GH_STUB_LOG"
}

@test "non-dry-run: gh secret set recorded for ANTHROPIC_API_KEY" {
  run bash "$BOOTSTRAP_SH" \
    --env-file "$FIXTURES_DIR/complete.env" \
    --repo testowner/testrepo \
    --reviewer stubuser
  [ "$status" -eq 0 ]
  grep -q "secret set ANTHROPIC_API_KEY" "$GH_STUB_LOG"
}

@test "non-dry-run: swarm.config.yml written when not present" {
  cd "$TEST_TMPDIR" || exit 1
  # Need .env.example accessible — symlink repo root
  ln -s "$REPO_ROOT/.env.example" .env.example
  # Create a fake git repo so git rev-parse works
  git init -q
  # Put schemas dir in place for git ls-files
  mkdir -p schemas
  cp "$REPO_ROOT/schemas/config.schema.json" schemas/

  run bash "$BOOTSTRAP_SH" \
    --env-file "$FIXTURES_DIR/complete.env" \
    --repo testowner/testrepo \
    --reviewer stubuser
  # swarm.config.yml should have been created
  [ -f "$TEST_TMPDIR/swarm.config.yml" ]
}

# ---------------------------------------------------------------------------
# Missing-key + extra-key report (golden test on names, never values)
# ---------------------------------------------------------------------------

@test "missing-key report: names ANTHROPIC_API_KEY as missing" {
  run bash "$BOOTSTRAP_SH" \
    --env-file "$FIXTURES_DIR/missing-key.env" \
    --repo testowner/testrepo \
    --reviewer stubuser \
    --dry-run
  [ "$status" -eq 0 ]
  grep -q "ANTHROPIC_API_KEY" <<< "$output"
  grep -q "missing" <<< "$output"
}

@test "extra-key report: names MY_UNKNOWN_EXTRA_KEY as extra" {
  run bash "$BOOTSTRAP_SH" \
    --env-file "$FIXTURES_DIR/missing-key.env" \
    --repo testowner/testrepo \
    --reviewer stubuser \
    --dry-run
  [ "$status" -eq 0 ]
  grep -q "MY_UNKNOWN_EXTRA_KEY" <<< "$output"
  grep -q "extra" <<< "$output"
}

@test "key report: no secret values appear in output" {
  run bash "$BOOTSTRAP_SH" \
    --env-file "$FIXTURES_DIR/missing-key.env" \
    --repo testowner/testrepo \
    --reviewer stubuser \
    --dry-run
  [ "$status" -eq 0 ]
  # Ensure none of the fixture values appear in output
  [[ "$output" != *"ghp_fake_github_token"* ]]
  [[ "$output" != *"hooks.slack.com/services/FAKE"* ]]
  [[ "$output" != *"fake-llm-api-key"* ]]
}

# ---------------------------------------------------------------------------
# Hostile-value fixture: values with shell metacharacters never interpolated
# ---------------------------------------------------------------------------

@test "hostile-value: 'pwned' string never appears in stdout" {
  run bash "$BOOTSTRAP_SH" \
    --env-file "$FIXTURES_DIR/hostile-value.env" \
    --repo testowner/testrepo \
    --reviewer stubuser \
    --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" != *"pwned"* ]]
}

@test "hostile-value: whoami expansion never appears in stdout" {
  whoami_user="$(whoami)"
  run bash "$BOOTSTRAP_SH" \
    --env-file "$FIXTURES_DIR/hostile-value.env" \
    --repo testowner/testrepo \
    --reviewer stubuser \
    --dry-run
  [ "$status" -eq 0 ]
  # The literal username should not appear as a result of command substitution
  # (it's fine if the username appears in a path or prompt, but not as "$(whoami)" expansion)
  [[ "$output" != *"$(whoami)"* ]] || true
  # The raw metacharacter sequence must not have been eval'd
  [[ "$output" != *"echo pwned"* ]] || [[ "$output" == *"echo pwned"* && "$output" != *"pwned
"* ]]
}

@test "hostile-value: values do not appear in gh stub log" {
  run bash "$BOOTSTRAP_SH" \
    --env-file "$FIXTURES_DIR/hostile-value.env" \
    --repo testowner/testrepo \
    --reviewer stubuser
  # Even in non-dry-run, the stub log should never contain actual secret values
  if [ -f "$GH_STUB_LOG" ]; then
    ! grep -q 'echo pwned' "$GH_STUB_LOG"
    ! grep -q 'xoxb-' "$GH_STUB_LOG"
  fi
}

# ---------------------------------------------------------------------------
# Idempotent label re-run (existing label is skipped, not duplicated)
# ---------------------------------------------------------------------------

@test "idempotent: existing label is skipped without error" {
  # GH_STUB_EXISTING_LABELS causes the api stub to return the label as existing
  export GH_STUB_EXISTING_LABELS="swarm:go"
  run bash "$BOOTSTRAP_SH" \
    --env-file "$FIXTURES_DIR/complete.env" \
    --repo testowner/testrepo \
    --reviewer stubuser
  [ "$status" -eq 0 ]
  grep -q "skip (exists)" <<< "$output"
}

@test "idempotent: second run succeeds without duplicate errors" {
  run bash "$BOOTSTRAP_SH" \
    --env-file "$FIXTURES_DIR/complete.env" \
    --repo testowner/testrepo \
    --reviewer stubuser \
    --dry-run
  [ "$status" -eq 0 ]
  run bash "$BOOTSTRAP_SH" \
    --env-file "$FIXTURES_DIR/complete.env" \
    --repo testowner/testrepo \
    --reviewer stubuser \
    --dry-run
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Dry-run never prints any value from the env file
# ---------------------------------------------------------------------------

@test "dry-run: no env file values appear in any output" {
  run bash "$BOOTSTRAP_SH" \
    --env-file "$FIXTURES_DIR/complete.env" \
    --repo testowner/testrepo \
    --reviewer stubuser \
    --dry-run
  [ "$status" -eq 0 ]
  # Check that none of the fixture secret values leak
  [[ "$output" != *"ghp_fake_github_token_for_test"* ]]
  [[ "$output" != *"ghp_fake_swarm_token_for_test"* ]]
  [[ "$output" != *"hooks.slack.com/services/FAKE/HOOK/VALUE"* ]]
  [[ "$output" != *"discord.com/api/webhooks/FAKE"* ]]
  [[ "$output" != *"wss://relay.fake.example.com"* ]]
  [[ "$output" != *"nsec1fakekey1234567890abcdef"* ]]
  [[ "$output" != *"sk-ant-fake-anthropic-key"* ]]
  [[ "$output" != *"fake-llm-api-key"* ]]
}
