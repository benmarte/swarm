#!/usr/bin/env bats
# develop-run.bats — tests for actions/develop-run/develop-run.sh (engine)
#                   and actions/develop-run/adapters/headless.sh.
#
# Strategy:
#   - Real git with a temporary bare file:// remote for push testing.
#     (Stubbing git push would hide actual branch/commit logic.)
#   - PATH-stubbed gh recording pr-create + api verify calls.
#   - Stub adapter scripts written per-test to control working-tree edits.
#   - GITHUB_OUTPUT captured to a temp file.
#
# Test types covered: unit (input validation, adapter dispatch, PR body,
# dry-run, no-diff), integration (end-to-end headless path through the engine).

REPO_ROOT="$(git -C "$(dirname "$BATS_TEST_FILENAME")" rev-parse --show-toplevel)"
ENGINE_SH="$REPO_ROOT/actions/develop-run/develop-run.sh"
HEADLESS_ADAPTER="$REPO_ROOT/actions/develop-run/adapters/headless.sh"
STUBS_DIR="$REPO_ROOT/tests/stubs"

# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

# Create a bare git remote and a clone of it; sets WORK_DIR and BARE_DIR.
# The clone has an initial commit so the branch history is non-empty.
_setup_git_repos() {
  BARE_DIR="$(mktemp -d)"
  git init --bare "$BARE_DIR" --initial-branch main -q

  WORK_DIR="$(mktemp -d)"
  git clone "file://$BARE_DIR" "$WORK_DIR" -q
  git -C "$WORK_DIR" config user.email "swarm-bot@users.noreply.github.com"
  git -C "$WORK_DIR" config user.name "swarm-bot"
  # Initial commit so origin/main exists
  printf 'init\n' > "$WORK_DIR/README.md"
  git -C "$WORK_DIR" add README.md
  git -C "$WORK_DIR" commit -m "init" -q
  git -C "$WORK_DIR" push origin main -q
}

# ---------------------------------------------------------------------------
# setup / teardown
# ---------------------------------------------------------------------------

setup() {
  # Set up real git repos
  _setup_git_repos

  # Stub logs
  export GH_STUB_LOG
  GH_STUB_LOG="$(mktemp)"
  export GH_PR_BODY_LOG
  GH_PR_BODY_LOG="$(mktemp)"

  # GITHUB_OUTPUT capture
  export GITHUB_OUTPUT
  GITHUB_OUTPUT="$(mktemp)"

  # RUNNER_TEMP for bump-attempts escalation event
  export RUNNER_TEMP
  RUNNER_TEMP="$(mktemp -d)"

  # Default env for develop-run.sh
  export ISSUE_NUMBER="42"
  export BASE_BRANCH="main"
  export ADAPTER="headless"
  export SPEC_BODY="# Test Spec

## Acceptance Criteria
- Implement something
"
  export SPEC_FILE=""
  export DRY_RUN="false"
  export MODEL="test-model"
  export MAINTAINER="benmarte"
  export POST_COMMENT="false"
  export GH_TOKEN="fake-token"
  export GITHUB_REPOSITORY="testowner/testrepo"
  export ACTION_PATH="$REPO_ROOT/actions/develop-run"

  # Stub PR URL
  export GH_PR_URL_STUB="https://github.com/testowner/testrepo/pull/99"

  # Stub adapter command: writes a known implementation file and exits
  STUB_ADAPTER_CMD_FILE="$(mktemp)"
  cat > "$STUB_ADAPTER_CMD_FILE" <<'STUB'
#!/usr/bin/env bash
# Stub coding adapter: writes a sentinel file to prove the engine invoked us.
printf 'stub implementation\n' > implementation.txt
exit 0
STUB
  chmod +x "$STUB_ADAPTER_CMD_FILE"
  export ADAPTER_CMD="bash $STUB_ADAPTER_CMD_FILE"

  # Prepend stubs dir so our fake gh is found first; real git + openssl live after
  export PATH="$STUBS_DIR:$PATH"

  # Change into working directory so git commands run in the right repo
  cd "$WORK_DIR"
}

teardown() {
  rm -rf "$BARE_DIR" "$WORK_DIR" "$RUNNER_TEMP"
  rm -f "$GH_STUB_LOG" "$GH_PR_BODY_LOG" "$GITHUB_OUTPUT"
  rm -f "$STUB_ADAPTER_CMD_FILE" 2>/dev/null || true
}

# =============================================================================
# Input validation
# =============================================================================

@test "engine: rejects missing ISSUE_NUMBER" {
  unset ISSUE_NUMBER

  run bash "$ENGINE_SH"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ISSUE_NUMBER"* ]]
}

@test "engine: rejects non-numeric ISSUE_NUMBER" {
  export ISSUE_NUMBER="foo"

  run bash "$ENGINE_SH"
  [ "$status" -ne 0 ]
  [[ "$output" == *"positive integer"* ]] || [[ "$output" == *"ISSUE_NUMBER"* ]]
}

@test "engine: rejects zero ISSUE_NUMBER" {
  export ISSUE_NUMBER="0"

  run bash "$ENGINE_SH"
  [ "$status" -ne 0 ]
}

@test "engine: rejects path-traversal ISSUE_NUMBER" {
  export ISSUE_NUMBER="1/../etc/passwd"

  run bash "$ENGINE_SH"
  [ "$status" -ne 0 ]
}

@test "engine: rejects unknown adapter" {
  export ADAPTER="gpt-wizard"

  run bash "$ENGINE_SH"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid adapter"* ]] || [[ "$output" == *"gpt-wizard"* ]]
}

@test "engine: accepts claude-code-action adapter" {
  export ADAPTER="claude-code-action"
  # Stub PR verify to return an open PR (so engine doesn't fail at verify)
  export GH_STUB_PR_JSON='[{"html_url":"https://github.com/testowner/testrepo/pull/99","number":99,"state":"open","head":{"ref":"swarm/issue-42"}}]'
  # Stub labels for transition (already at swarm:develop)
  export GH_STUB_LABELS_JSON='[{"name":"swarm:develop"}]'

  run bash "$ENGINE_SH"
  [ "$status" -eq 0 ] || {
    echo "# output: $output" >&3
    false
  }
}

@test "engine: rejects missing ADAPTER_CMD for headless" {
  unset ADAPTER_CMD

  run bash "$ENGINE_SH"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ADAPTER_CMD"* ]]
}

# =============================================================================
# dry-run path
# =============================================================================

@test "engine: dry-run exits 0 without any git or gh writes" {
  export DRY_RUN="true"

  run bash "$ENGINE_SH"
  [ "$status" -eq 0 ]

  # gh stub must not have been called (no API writes in dry-run)
  [ ! -s "$GH_STUB_LOG" ] || ! grep -q "gh pr" "$GH_STUB_LOG"

  # No branch created in the bare remote
  ! git -C "$BARE_DIR" show-ref --verify --quiet "refs/heads/swarm/issue-42" 2>/dev/null
}

@test "engine: dry-run logs intended actions" {
  export DRY_RUN="true"

  run bash "$ENGINE_SH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"dry-run"* ]]
  [[ "$output" == *"swarm/issue-42"* ]] || [[ "$output" == *"issue-42"* ]]
}

# =============================================================================
# Happy path — headless adapter
# =============================================================================

@test "engine: creates branch swarm/issue-N in remote on success" {
  export GH_STUB_LABELS_JSON='[{"name":"swarm:develop"}]'

  run bash "$ENGINE_SH"
  [ "$status" -eq 0 ]

  # Branch must exist in the bare remote after push
  git -C "$BARE_DIR" show-ref --verify --quiet "refs/heads/swarm/issue-42"
}

@test "engine: writes docs/specs/issue-N.md on the branch" {
  export GH_STUB_LABELS_JSON='[{"name":"swarm:develop"}]'

  run bash "$ENGINE_SH"
  [ "$status" -eq 0 ]

  # Spec file must be committed on the swarm branch
  git -C "$WORK_DIR" show "swarm/issue-42:docs/specs/issue-42.md" > /dev/null
}

@test "engine: commits adapter output alongside spec file" {
  export GH_STUB_LABELS_JSON='[{"name":"swarm:develop"}]'

  run bash "$ENGINE_SH"
  [ "$status" -eq 0 ]

  # implementation.txt (written by stub adapter) must be committed
  git -C "$WORK_DIR" show "swarm/issue-42:implementation.txt" > /dev/null
}

@test "engine: calls gh pr create" {
  export GH_STUB_LABELS_JSON='[{"name":"swarm:develop"}]'

  run bash "$ENGINE_SH"
  [ "$status" -eq 0 ]

  grep -q "gh pr create" "$GH_STUB_LOG"
}

@test "engine: PR body contains Closes #N" {
  export GH_STUB_LABELS_JSON='[{"name":"swarm:develop"}]'

  run bash "$ENGINE_SH"
  [ "$status" -eq 0 ]

  grep -q "Closes #42" "$GH_PR_BODY_LOG"
}

@test "engine: PR body records adapter name" {
  export GH_STUB_LABELS_JSON='[{"name":"swarm:develop"}]'

  run bash "$ENGINE_SH"
  [ "$status" -eq 0 ]

  grep -q "headless" "$GH_PR_BODY_LOG"
}

@test "engine: PR body records model" {
  export GH_STUB_LABELS_JSON='[{"name":"swarm:develop"}]'

  run bash "$ENGINE_SH"
  [ "$status" -eq 0 ]

  grep -q "test-model" "$GH_PR_BODY_LOG"
}

@test "engine: verifies PR via gh api after creation" {
  export GH_STUB_LABELS_JSON='[{"name":"swarm:develop"}]'

  run bash "$ENGINE_SH"
  [ "$status" -eq 0 ]

  # gh api call for PR verification must appear in the log
  grep -q "gh api.*pulls\|gh api" "$GH_STUB_LOG" || grep -q "pulls" "$GH_STUB_LOG"
}

@test "engine: writes pr-url to GITHUB_OUTPUT on success" {
  export GH_STUB_LABELS_JSON='[{"name":"swarm:develop"}]'

  run bash "$ENGINE_SH"
  [ "$status" -eq 0 ]

  grep -q "pr-url" "$GITHUB_OUTPUT"
  grep -q "github.com" "$GITHUB_OUTPUT"
}

@test "engine: transitions issue from swarm:develop to swarm:qa on success" {
  export GH_STUB_LABELS_JSON='[{"name":"swarm:develop"}]'

  run bash "$ENGINE_SH"
  [ "$status" -eq 0 ]

  # Transition calls: remove swarm:develop + add swarm:qa
  grep -q "swarm:qa" "$GH_STUB_LOG"
}

# =============================================================================
# No-diff path (adapter makes no changes)
# =============================================================================

@test "engine: calls bump-attempts when adapter produces no changes" {
  # Set up: pre-commit the spec file so the working tree starts clean
  git -C "$WORK_DIR" checkout -b "swarm/issue-42" "origin/main" -q
  mkdir -p "$WORK_DIR/docs/specs"
  printf '%s\n' "$SPEC_BODY" > "$WORK_DIR/docs/specs/issue-42.md"
  git -C "$WORK_DIR" add .
  git -C "$WORK_DIR" commit -m "spec" -q
  git -C "$WORK_DIR" push origin "swarm/issue-42" -q
  git -C "$WORK_DIR" checkout main -q

  # No-op adapter (writes nothing)
  NOOP_CMD_FILE="$(mktemp)"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$NOOP_CMD_FILE"
  chmod +x "$NOOP_CMD_FILE"
  export ADAPTER_CMD="bash $NOOP_CMD_FILE"

  export GH_STUB_LABELS_JSON='[{"name":"swarm:attempts:1"},{"name":"swarm:develop"}]'

  run bash "$ENGINE_SH"
  [ "$status" -ne 0 ]

  # bump-attempts must have been invoked — it adds swarm:attempts:N
  grep -q "swarm:attempts" "$GH_STUB_LOG"

  rm -f "$NOOP_CMD_FILE"
}

@test "engine: does NOT create PR when adapter produces no changes" {
  git -C "$WORK_DIR" checkout -b "swarm/issue-42" "origin/main" -q
  mkdir -p "$WORK_DIR/docs/specs"
  printf '%s\n' "$SPEC_BODY" > "$WORK_DIR/docs/specs/issue-42.md"
  git -C "$WORK_DIR" add .
  git -C "$WORK_DIR" commit -m "spec" -q
  git -C "$WORK_DIR" push origin "swarm/issue-42" -q
  git -C "$WORK_DIR" checkout main -q

  NOOP_CMD_FILE="$(mktemp)"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$NOOP_CMD_FILE"
  chmod +x "$NOOP_CMD_FILE"
  export ADAPTER_CMD="bash $NOOP_CMD_FILE"

  export GH_STUB_LABELS_JSON='[{"name":"swarm:attempts:1"},{"name":"swarm:develop"}]'

  run bash "$ENGINE_SH"
  [ "$status" -ne 0 ]

  ! grep -q "gh pr create" "$GH_STUB_LOG"

  rm -f "$NOOP_CMD_FILE"
}

# =============================================================================
# PR verify failure path
# =============================================================================

@test "engine: calls bump-attempts when PR verify returns empty" {
  export GH_STUB_LABELS_JSON='[{"name":"swarm:develop"}]'
  # Override PR verify to return empty (PR not found)
  export GH_STUB_PR_JSON="[]"

  run bash "$ENGINE_SH"
  [ "$status" -ne 0 ]

  # bump-attempts must have been called
  grep -q "swarm:attempts" "$GH_STUB_LOG"
}

# =============================================================================
# headless.sh adapter — direct tests
# =============================================================================

@test "headless adapter: exits 1 when ADAPTER_CMD is unset" {
  unset ADAPTER_CMD

  export WORKTREE="."
  export SPEC_FILE="/dev/null"

  run bash "$HEADLESS_ADAPTER"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ADAPTER_CMD"* ]]
}

@test "headless adapter: exits 1 when ADAPTER_CMD binary not found" {
  export ADAPTER_CMD="no-such-command-xyz-12345"
  export WORKTREE="."
  export SPEC_FILE="/dev/null"

  run bash "$HEADLESS_ADAPTER"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]] || [[ "$output" == *"no-such-command"* ]]
}

@test "headless adapter: exits 1 when SPEC_FILE is unset" {
  unset SPEC_FILE

  export WORKTREE="."
  # ADAPTER_CMD is a no-op to get past the binary check
  export ADAPTER_CMD="true"

  run bash "$HEADLESS_ADAPTER"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SPEC_FILE"* ]]
}

@test "headless adapter: exits 1 when SPEC_FILE does not exist" {
  export SPEC_FILE="/tmp/no-such-spec-file-for-test.md"
  export WORKTREE="."
  export ADAPTER_CMD="true"

  run bash "$HEADLESS_ADAPTER"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]] || [[ "$output" == *"SPEC_FILE"* ]]
}

@test "headless adapter: invokes ADAPTER_CMD and succeeds on exit 0" {
  spec_file="$(mktemp)"
  printf '# Spec\n\nDo something.\n' > "$spec_file"

  export SPEC_FILE="$spec_file"
  export WORKTREE="$WORK_DIR"
  export ADAPTER_CMD="bash $STUB_ADAPTER_CMD_FILE"
  export ISSUE_NUMBER="42"
  export SWARM_LLM_MODEL="test-model"

  run bash "$HEADLESS_ADAPTER"
  [ "$status" -eq 0 ]

  rm -f "$spec_file"
}

@test "headless adapter: exits 1 when ADAPTER_CMD exits non-zero" {
  spec_file="$(mktemp)"
  printf '# Spec\n\nDo something.\n' > "$spec_file"

  fail_cmd="$(mktemp)"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fail_cmd"
  chmod +x "$fail_cmd"

  export SPEC_FILE="$spec_file"
  export WORKTREE="$WORK_DIR"
  export ADAPTER_CMD="bash $fail_cmd"
  export ISSUE_NUMBER="42"
  export SWARM_LLM_MODEL=""

  run bash "$HEADLESS_ADAPTER"
  [ "$status" -ne 0 ]
  [[ "$output" == *"exited non-zero"* ]] || [[ "$output" == *"ERROR"* ]]

  rm -f "$spec_file" "$fail_cmd"
}

@test "headless adapter: sets SWARM_PROMPT_FILE env for the coding CLI" {
  spec_file="$(mktemp)"
  printf '# Spec\n\nImplement x.\n' > "$spec_file"

  # Adapter that echoes its env for inspection
  env_probe="$(mktemp)"
  cat > "$env_probe" <<'PROBE'
#!/usr/bin/env bash
printf 'SWARM_PROMPT_FILE=%s\n' "$SWARM_PROMPT_FILE"
exit 0
PROBE
  chmod +x "$env_probe"

  export SPEC_FILE="$spec_file"
  export WORKTREE="$WORK_DIR"
  export ADAPTER_CMD="bash $env_probe"
  export ISSUE_NUMBER="42"
  export SWARM_LLM_MODEL=""

  run bash "$HEADLESS_ADAPTER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SWARM_PROMPT_FILE="* ]]

  rm -f "$spec_file" "$env_probe"
}
