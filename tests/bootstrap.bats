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

@test "hostile-value: command substitution in a secret value is never executed" {
  # Was `[[ "$output" != *"$(whoami)"* ]]`, which cannot hold: the expansion is
  # a username that legitimately appears via the engine repo slug and in runner
  # paths (whoami is "runner" on GitHub-hosted runners, paths /home/runner/...).
  # It had been silenced with `|| true`. The fixture now carries a sentinel that
  # can only appear if the value was actually executed.
  run bash "$BOOTSTRAP_SH" \
    --env-file "$FIXTURES_DIR/hostile-value.env" \
    --repo testowner/testrepo \
    --reviewer stubuser \
    --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" != *"swarm_expanded_9c41f2"* ]]
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
# Regression #31: label existence check must use exit code, not stdout.
# Real gh api prints a JSON error body to stdout on 404, so [ -n "$existing" ]
# would always be true and every label would be falsely skipped on a fresh repo.
# ---------------------------------------------------------------------------

@test "regression #31: fresh repo — all labels reported created, not skipped" {
  # GH_STUB_EXISTING_LABELS is unset → stub exits 1 + prints JSON on every label GET
  unset GH_STUB_EXISTING_LABELS
  run bash "$BOOTSTRAP_SH" \
    --env-file "$FIXTURES_DIR/complete.env" \
    --repo testowner/testrepo \
    --reviewer stubuser
  [ "$status" -eq 0 ]
  # At least one "created:" line must appear
  grep -q "  created:" <<< "$output"
  # No "skip (exists)" must appear when no labels exist
  ! grep -q "skip (exists)" <<< "$output"
}

@test "regression #31: fresh repo — stub log shows POST for label creation" {
  unset GH_STUB_EXISTING_LABELS
  run bash "$BOOTSTRAP_SH" \
    --env-file "$FIXTURES_DIR/complete.env" \
    --repo testowner/testrepo \
    --reviewer stubuser
  [ "$status" -eq 0 ]
  # Stub log must contain at least one POST (label creation)
  grep -q "POST" "$GH_STUB_LOG"
}

@test "regression #31: existing label is skipped — only exact match skipped" {
  export GH_STUB_EXISTING_LABELS="swarm:go"
  run bash "$BOOTSTRAP_SH" \
    --env-file "$FIXTURES_DIR/complete.env" \
    --repo testowner/testrepo \
    --reviewer stubuser
  [ "$status" -eq 0 ]
  grep -q "skip (exists): swarm:go" <<< "$output"
  # Other labels must still be created
  grep -q "  created:" <<< "$output"
}

# ---------------------------------------------------------------------------
# Regression #52: secret seeding must use stdin (no --body-file), and failure
# must be loud: no "seeded" line, non-zero exit, failures summarised.
# ---------------------------------------------------------------------------

@test "regression #52: secret set success — key appears in seeded output" {
  run bash "$BOOTSTRAP_SH" \
    --env-file "$FIXTURES_DIR/complete.env" \
    --repo testowner/testrepo \
    --reviewer stubuser
  [ "$status" -eq 0 ]
  grep -q "seeded: SWARM_GITHUB_TOKEN" <<< "$output"
  grep -q "total seeded:" <<< "$output"
}

@test "regression #52: secret set failure — exits non-zero, no false seeded line" {
  export GH_STUB_SECRET_FAIL="SWARM_GITHUB_TOKEN"
  run bash "$BOOTSTRAP_SH" \
    --env-file "$FIXTURES_DIR/complete.env" \
    --repo testowner/testrepo \
    --reviewer stubuser
  # Must exit non-zero when a secret fails
  [ "$status" -ne 0 ]
  # Must NOT report the failed key as seeded
  ! grep -q "seeded: SWARM_GITHUB_TOKEN" <<< "$output"
}

@test "regression #52: secret set failure — warning appears for failed key" {
  export GH_STUB_SECRET_FAIL="ANTHROPIC_API_KEY"
  run bash "$BOOTSTRAP_SH" \
    --env-file "$FIXTURES_DIR/complete.env" \
    --repo testowner/testrepo \
    --reviewer stubuser
  [ "$status" -ne 0 ]
  # Warning must mention the failing key (goes to stderr, captured in output by bats)
  [[ "$output" == *"ANTHROPIC_API_KEY"* ]] || [[ "$stderr" == *"ANTHROPIC_API_KEY"* ]]
}

@test "regression #52: no secret value appears in output on success" {
  run bash "$BOOTSTRAP_SH" \
    --env-file "$FIXTURES_DIR/complete.env" \
    --repo testowner/testrepo \
    --reviewer stubuser
  [ "$status" -eq 0 ]
  # None of the fixture secret values may appear in stdout
  [[ "$output" != *"ghp_fake_github_token_for_test"* ]]
  [[ "$output" != *"sk-ant-fake-anthropic-key"* ]]
  [[ "$output" != *"fake-llm-api-key"* ]]
}

@test "regression #52: no secret value appears in stub log on success" {
  run bash "$BOOTSTRAP_SH" \
    --env-file "$FIXTURES_DIR/complete.env" \
    --repo testowner/testrepo \
    --reviewer stubuser
  [ "$status" -eq 0 ]
  [ -f "$GH_STUB_LOG" ]
  ! grep -q "ghp_fake_github_token_for_test" "$GH_STUB_LOG"
  ! grep -q "sk-ant-fake-anthropic-key" "$GH_STUB_LOG"
}

@test "regression #52: hostile fixture — no value in output (non-dry-run)" {
  run bash "$BOOTSTRAP_SH" \
    --env-file "$FIXTURES_DIR/hostile-value.env" \
    --repo testowner/testrepo \
    --reviewer stubuser
  # Status 0 or non-zero is allowed (hostile values may fail secret set)
  # What must NOT happen: hostile value leaks into stdout
  ! grep -q "xoxb-" <<< "$output"
  ! grep -q "echo pwned" <<< "$output"
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

# ---------------------------------------------------------------------------
# Shipped config template must conform to the shipped schema (issue #75)
#
# The template and the schema live in different files and are edited by
# different changes, with nothing tying them together. They drifted: the
# template's `notify:` block has every key commented out, which YAML parses as
# null, while the schema demanded an object — so an adopter who followed the
# documented onboarding and changed nothing hit a hard validation failure on
# every pipeline stage. These tests are the tie.
# ---------------------------------------------------------------------------

@test "config template: shipped swarm.config.yml validates against config.schema.json" {
  run ajv validate -s "$REPO_ROOT/schemas/config.schema.json" -d "$REPO_ROOT/swarm.config.yml"
  [ "$status" -eq 0 ]
}

@test "config template: bootstrap-generated config validates against config.schema.json" {
  # Extract the heredoc bootstrap writes, rather than trusting that the repo
  # root copy and the generated one stayed identical.
  _gd="$(mktemp -d)"; generated="$_gd/generated.yml"
  python3 - "$REPO_ROOT/scripts/bootstrap.sh" > "$generated" <<'PYEOF'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"cat\s*>\s*[\"']?\$?\{?[A-Za-z_]*CONFIG[A-Za-z_]*\}?[\"']?\s*<<\s*'?([A-Z_]+)'?\n(.*?)\n\1\n",
              src, re.DOTALL)
if not m:
    m = re.search(r"<<\s*'([A-Z_]+)'\n(notify:.*?)\n\1\n", src, re.DOTALL)
if not m:
    sys.exit("could not locate the generated config heredoc in bootstrap.sh")
sys.stdout.write(m.group(2))
PYEOF
  run ajv validate -s "$REPO_ROOT/schemas/config.schema.json" -d "$generated"
  rm -rf "$_gd"
  [ "$status" -eq 0 ]
}

@test "config template: uncommenting a sink keeps the config valid" {
  # The template instructs adopters to uncomment sinks. That edit must produce
  # valid YAML and a valid config — a `notify: {}` placeholder would satisfy
  # the schema while making this exact edit a YAML syntax error.
  _d="$(mktemp -d)"; uncommented="$_d/uncommented.yml"
  sed 's/^  # slack: true/  slack: true/' "$REPO_ROOT/swarm.config.yml" > "$uncommented"

  run python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$uncommented"
  [ "$status" -eq 0 ]

  run ajv validate -s "$REPO_ROOT/schemas/config.schema.json" -d "$uncommented"
  rm -rf "$_d"
  [ "$status" -eq 0 ]
}

@test "config template: every optional top-level object tolerates being commented out" {
  # A user may legitimately comment out any optional section. Each must accept
  # null, or that user gets a hard schema failure on every stage.
  for key in notify adapters develop qa runner sweeper comments; do
    _cd="$(mktemp -d)"; cfg="$_cd/c.yml"
    printf '%s:\n  # everything commented out\n' "$key" > "$cfg"
    run ajv validate -s "$REPO_ROOT/schemas/config.schema.json" -d "$cfg"
    rm -rf "$_cd"
    [ "$status" -eq 0 ] || {
      echo "# key '$key' rejects null: $output" >&3
      false
    }
  done
}
