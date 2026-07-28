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

@test "engine: does NOT transition internally — notify job in develop.yml owns transition" {
  # develop-run.sh no longer calls transition.sh directly; the separate notify
  # job in develop.yml handles it so sink secrets never share a job with the
  # LLM adapter (security: issue #40 class).
  export GH_STUB_LABELS_JSON='[{"name":"swarm:develop"}]'

  run bash "$ENGINE_SH"
  [ "$status" -eq 0 ]

  # Verify PR was created (core engine work)
  grep -q "pr-url" "$GITHUB_OUTPUT"

  # Transition (swarm:qa label) must NOT be set by develop-run itself
  if grep -q "swarm:qa" "$GH_STUB_LOG" 2>/dev/null; then
    echo "ERROR: develop-run.sh called transition — that is the notify job's responsibility"
    exit 1
  fi
  true
}

# =============================================================================
# No-diff path (adapter makes no changes)
# =============================================================================

@test "engine: calls bump-attempts when adapter produces no changes" {
  # Set up: spec committed to origin/main so branch starts at base (ahead=0).
  # Engine re-writes spec (same content → nothing staged) + NOOP adapter → bump.
  mkdir -p "$WORK_DIR/docs/specs"
  printf '%s\n' "$SPEC_BODY" > "$WORK_DIR/docs/specs/issue-42.md"
  git -C "$WORK_DIR" add .
  git -C "$WORK_DIR" commit -m "spec-on-main" -q
  git -C "$WORK_DIR" push origin main -q
  # Push swarm branch at same level as main (ahead=0 relative to origin/main)
  git -C "$WORK_DIR" push origin main:"refs/heads/swarm/issue-42"

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
  # Branch at base level (ahead=0) + NOOP adapter → bump, no PR.
  mkdir -p "$WORK_DIR/docs/specs"
  printf '%s\n' "$SPEC_BODY" > "$WORK_DIR/docs/specs/issue-42.md"
  git -C "$WORK_DIR" add .
  git -C "$WORK_DIR" commit -m "spec-on-main" -q
  git -C "$WORK_DIR" push origin main -q
  git -C "$WORK_DIR" push origin main:"refs/heads/swarm/issue-42"

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

@test "headless adapter: multi-word ADAPTER_CMD (with flags) works without eval" {
  # Verifies that word-split via read -ra correctly handles multi-word commands
  # like "bash /path/to/script" or "claude -p --model gpt-4".
  spec_file="$(mktemp)"
  printf '# Spec\n\nMulti-word test.\n' > "$spec_file"

  # A script that just exits 0 — it will be called as "bash <script>"
  stub_script="$(mktemp)"
  printf '#!/usr/bin/env bash\nprintf "multi-word-stub ran\n"\nexit 0\n' > "$stub_script"
  chmod +x "$stub_script"

  export SPEC_FILE="$spec_file"
  export WORKTREE="$WORK_DIR"
  export ADAPTER_CMD="bash $stub_script"
  export ISSUE_NUMBER="42"
  export SWARM_LLM_MODEL=""

  run bash "$HEADLESS_ADAPTER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"multi-word-stub ran"* ]] || [[ "$output" == *"complete"* ]]

  rm -f "$spec_file" "$stub_script"
}

@test "headless adapter: shell metacharacters in ADAPTER_CMD are NOT interpreted" {
  # A malicious ADAPTER_CMD containing shell metacharacters must NOT cause
  # execution of the injected command.  With array expansion (no eval), the
  # semicolon and everything after it is passed as a literal argument, not
  # interpreted by the shell.  The first word ("echo") is not a real adapter
  # binary path, so the binary-check guard catches it first — verify that the
  # sentinel file is NOT created.
  sentinel="/tmp/swarm-test-pwned-$$"
  rm -f "$sentinel"

  spec_file="$(mktemp)"
  printf '# Spec\n' > "$spec_file"

  export SPEC_FILE="$spec_file"
  export WORKTREE="$WORK_DIR"
  # Attempt injection: if eval were used, "touch $sentinel" would execute
  export ADAPTER_CMD="echo hi; touch $sentinel"
  export ISSUE_NUMBER="42"
  export SWARM_LLM_MODEL=""

  run bash "$HEADLESS_ADAPTER"
  # Adapter must fail (either binary-check rejects "echo" or it doesn't write anything)
  # Critically: the sentinel file must NOT be created
  [ ! -f "$sentinel" ]

  rm -f "$spec_file" "$sentinel"
}

# =============================================================================
# Security: repo credentials stripped from adapter subprocess env (#40)
# =============================================================================

@test "headless adapter: SWARM_TOKEN absent from adapter subprocess env" {
  spec_file="$(mktemp)"
  printf '# Spec\n\nDo something.\n' > "$spec_file"

  # Env-dumping stub: writes its environment to a log file
  env_log="$(mktemp)"
  env_dump="$(mktemp)"
  cat > "$env_dump" <<STUB
#!/usr/bin/env bash
env > "$env_log"
exit 0
STUB
  chmod +x "$env_dump"

  export SPEC_FILE="$spec_file"
  export WORKTREE="$WORK_DIR"
  export ADAPTER_CMD="bash $env_dump"
  export ISSUE_NUMBER="42"
  export SWARM_LLM_MODEL=""
  export SWARM_TOKEN="super-secret-pat"
  export GH_TOKEN="runner-github-token"
  export GITHUB_TOKEN="runner-github-token-2"

  run bash "$HEADLESS_ADAPTER"
  [ "$status" -eq 0 ]

  # None of the three credential vars may appear in the adapter's env
  ! grep -q "^SWARM_TOKEN=" "$env_log"
  ! grep -q "^GH_TOKEN=" "$env_log"
  ! grep -q "^GITHUB_TOKEN=" "$env_log"

  rm -f "$spec_file" "$env_log" "$env_dump"
}

@test "headless adapter: GH_TOKEN absent from adapter subprocess env" {
  spec_file="$(mktemp)"
  printf '# Spec\n\nDo something.\n' > "$spec_file"

  env_log="$(mktemp)"
  env_dump="$(mktemp)"
  cat > "$env_dump" <<STUB
#!/usr/bin/env bash
env > "$env_log"
exit 0
STUB
  chmod +x "$env_dump"

  export SPEC_FILE="$spec_file"
  export WORKTREE="$WORK_DIR"
  export ADAPTER_CMD="bash $env_dump"
  export ISSUE_NUMBER="42"
  export SWARM_LLM_MODEL=""
  export GH_TOKEN="sensitive-gh-token"

  run bash "$HEADLESS_ADAPTER"
  [ "$status" -eq 0 ]

  ! grep -q "^GH_TOKEN=" "$env_log"

  rm -f "$spec_file" "$env_log" "$env_dump"
}

@test "headless adapter: engine still completes git/PR steps after credential unset" {
  # Full engine run — verifies that unsetting creds in headless.sh does NOT
  # break the engine's own gh calls (which happen after adapter returns).
  export GH_STUB_LABELS_JSON='[{"name":"swarm:develop"}]'
  export SWARM_TOKEN="test-pat-value"
  export GH_TOKEN="fake-token"

  run bash "$ENGINE_SH"
  [ "$status" -eq 0 ]

  # Engine must still have created the branch and invoked gh pr create
  git -C "$BARE_DIR" show-ref --verify --quiet "refs/heads/swarm/issue-42"
  grep -q "gh pr create" "$GH_STUB_LOG"
}

# =============================================================================
# engine: claude-code-action path — engine commits/pushes/creates PR
# =============================================================================

@test "engine: claude-code-action path commits and creates PR (engine-owns-everything)" {
  # Simulate the claude-code-action step having already edited the working tree:
  # pre-create the swarm/issue-42 branch on remote and checkout a working copy
  # that has uncommitted files (as if claude-code-action just edited them).
  git -C "$WORK_DIR" checkout -b "swarm/issue-42" "origin/main" -q
  git -C "$WORK_DIR" push origin "swarm/issue-42" -q
  # Write an implementation file as if claude-code-action did it (uncommitted)
  printf 'cca implementation\n' > "$WORK_DIR/cca-output.txt"
  # Return to main so engine can handle branch switching
  git -C "$WORK_DIR" checkout main -q

  export ADAPTER="claude-code-action"
  unset ADAPTER_CMD
  export GH_STUB_LABELS_JSON='[{"name":"swarm:develop"}]'

  run bash "$ENGINE_SH"
  [ "$status" -eq 0 ] || {
    echo "# output: $output" >&3
    false
  }

  # Engine must have called gh pr create
  grep -q "gh pr create" "$GH_STUB_LOG"
  # PR body must contain Closes #42
  grep -q "Closes #42" "$GH_PR_BODY_LOG"
  # Transition is the notify job's responsibility — NOT called by develop-run
  if grep -q "swarm:qa" "$GH_STUB_LOG" 2>/dev/null; then
    echo "ERROR: develop-run.sh called transition — that is the notify job's responsibility"
    exit 1
  fi
  true
}

# =============================================================================
# engine: re-run when branch already exists on remote
# =============================================================================

# =============================================================================
# SWARM_TOKEN → GH_TOKEN for PR operations (#42)
# =============================================================================

@test "engine: uses SWARM_TOKEN (not GH_TOKEN) for gh pr create when SWARM_TOKEN is set" {
  export GH_STUB_LABELS_JSON='[{"name":"swarm:develop"}]'
  export SWARM_TOKEN="swarm-pat-value"
  export GH_TOKEN="default-gh-token"

  run bash "$ENGINE_SH"
  [ "$status" -eq 0 ]

  # Stub summary line must record TOKEN_SOURCE=swarm for the pr create call.
  grep -q "gh-summary pr create TOKEN_SOURCE=swarm" "$GH_STUB_LOG"
}

@test "engine: uses SWARM_TOKEN for gh api PR verify when SWARM_TOKEN is set" {
  export GH_STUB_LABELS_JSON='[{"name":"swarm:develop"}]'
  export SWARM_TOKEN="swarm-pat-value"
  export GH_TOKEN="default-gh-token"

  run bash "$ENGINE_SH"
  [ "$status" -eq 0 ]

  # Stub summary line for gh api must carry TOKEN_SOURCE=swarm.
  grep -q "gh-summary api.*TOKEN_SOURCE=swarm" "$GH_STUB_LOG"
}

@test "engine: emits loud warning naming both failure modes when SWARM_TOKEN absent" {
  export GH_STUB_LABELS_JSON='[{"name":"swarm:develop"}]'
  unset SWARM_TOKEN

  run bash "$ENGINE_SH"
  # Engine may succeed (GH_TOKEN fallback) — we only care about the warning
  [[ "$output" == *"SWARM_TOKEN"* ]]
  [[ "$output" == *"policy"* ]] || [[ "$output" == *"not permitted"* ]]
  [[ "$output" == *"pull_request"* ]] || [[ "$output" == *"pr-gates"* ]] || [[ "$output" == *"recursion"* ]]
}

@test "engine: falls back to default GH_TOKEN for PR when SWARM_TOKEN absent (TOKEN_SOURCE=default in log)" {
  export GH_STUB_LABELS_JSON='[{"name":"swarm:develop"}]'
  unset SWARM_TOKEN

  run bash "$ENGINE_SH"
  [ "$status" -eq 0 ]

  grep -q "gh-summary pr create TOKEN_SOURCE=default" "$GH_STUB_LOG"
}

@test "engine: SWARM_TOKEN still available to engine PR step after headless adapter strips credentials" {
  # The headless adapter unsets GH_TOKEN/SWARM_TOKEN in its child env only.
  # After adapter returns, develop-run.sh must still read SWARM_TOKEN from
  # its own env and use it for PR create/verify.
  export GH_STUB_LABELS_JSON='[{"name":"swarm:develop"}]'
  export SWARM_TOKEN="post-adapter-pat"
  export GH_TOKEN="fake-gh-token"

  run bash "$ENGINE_SH"
  [ "$status" -eq 0 ]

  # Engine must have completed the branch push and PR creation
  git -C "$BARE_DIR" show-ref --verify --quiet "refs/heads/swarm/issue-42"
  # PR must have been created using the swarm token, not the default
  grep -q "gh-summary pr create TOKEN_SOURCE=swarm" "$GH_STUB_LOG"
}

@test "engine: re-runs cleanly when swarm branch already exists on remote" {
  # Pre-push the branch as if a prior attempt partially succeeded
  git -C "$WORK_DIR" checkout -b "swarm/issue-42" "origin/main" -q
  git -C "$WORK_DIR" push origin "swarm/issue-42" -q
  git -C "$WORK_DIR" checkout main -q

  export GH_STUB_LABELS_JSON='[{"name":"swarm:develop"}]'

  # Engine must detect remote branch, resume it, and succeed
  run bash "$ENGINE_SH"
  [ "$status" -eq 0 ] || {
    echo "# output: $output" >&3
    false
  }

  # Branch must still exist (checked out from remote, not re-created)
  git -C "$BARE_DIR" show-ref --verify --quiet "refs/heads/swarm/issue-42"
  grep -q "gh pr create" "$GH_STUB_LOG"
}

# =============================================================================
# Issue #44: clean-but-ahead resume must proceed to PR, not burn attempts
# =============================================================================

@test "engine: clean-but-ahead resume reaches PR creation without bump" {
  # Simulate a prior run that succeeded through push but died before PR creation:
  # the branch is ahead of base with implementation already committed.
  git -C "$WORK_DIR" checkout -b "swarm/issue-42" "origin/main" -q
  mkdir -p "$WORK_DIR/docs/specs"
  printf '%s\n' "$SPEC_BODY" > "$WORK_DIR/docs/specs/issue-42.md"
  printf 'prior implementation\n' > "$WORK_DIR/implementation.txt"
  git -C "$WORK_DIR" add .
  git -C "$WORK_DIR" commit -m "feat: implement issue #42 [adapter=headless]" -q
  git -C "$WORK_DIR" push origin "swarm/issue-42" -q
  git -C "$WORK_DIR" checkout main -q

  # No-op adapter — makes no new changes
  NOOP_CMD_FILE="$(mktemp)"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$NOOP_CMD_FILE"
  chmod +x "$NOOP_CMD_FILE"
  export ADAPTER_CMD="bash $NOOP_CMD_FILE"

  export GH_STUB_LABELS_JSON='[{"name":"swarm:develop"}]'

  run bash "$ENGINE_SH"
  [ "$status" -eq 0 ] || {
    echo "# output: $output" >&3
    false
  }

  # Must log resume message
  [[ "$output" == *"resuming existing implementation"* ]]

  # PR must have been created
  grep -q "gh pr create" "$GH_STUB_LOG"

  # Transition is the notify job's responsibility — NOT called by develop-run
  if grep -q "swarm:qa" "$GH_STUB_LOG" 2>/dev/null; then
    echo "ERROR: develop-run.sh called transition — that is the notify job's responsibility"
    exit 1
  fi

  # bump-attempts must NOT have been called
  ! grep -q "swarm:attempts" "$GH_STUB_LOG"

  rm -f "$NOOP_CMD_FILE"
}

@test "engine: no-edit adapter at base level still bumps attempts (regression guard)" {
  # Regression guard: branch NOT ahead of base (spec committed to main, branch
  # pushed at same level) + NOOP adapter → genuine no-work → bump, no PR.
  mkdir -p "$WORK_DIR/docs/specs"
  printf '%s\n' "$SPEC_BODY" > "$WORK_DIR/docs/specs/issue-42.md"
  git -C "$WORK_DIR" add .
  git -C "$WORK_DIR" commit -m "spec-on-main" -q
  git -C "$WORK_DIR" push origin main -q
  git -C "$WORK_DIR" push origin main:"refs/heads/swarm/issue-42"

  # No-op adapter
  NOOP_CMD_FILE="$(mktemp)"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$NOOP_CMD_FILE"
  chmod +x "$NOOP_CMD_FILE"
  export ADAPTER_CMD="bash $NOOP_CMD_FILE"

  export GH_STUB_LABELS_JSON='[{"name":"swarm:attempts:1"},{"name":"swarm:develop"}]'

  run bash "$ENGINE_SH"
  [ "$status" -ne 0 ]

  # bump-attempts must have been invoked
  grep -q "swarm:attempts" "$GH_STUB_LOG"

  # PR must NOT have been created
  ! grep -q "gh pr create" "$GH_STUB_LOG"

  rm -f "$NOOP_CMD_FILE"
}

@test "engine: dirty-state check excludes .swarm-engine from commit" {
  # .swarm-engine/ changes are never staged (excluded via ':!.swarm-engine').
  # When only .swarm-engine/ is written and the branch is not ahead, the engine
  # correctly treats it as no-diff and bumps attempts.
  # Set up: spec committed to main so branch starts at base level (ahead=0).
  mkdir -p "$WORK_DIR/docs/specs"
  printf '%s\n' "$SPEC_BODY" > "$WORK_DIR/docs/specs/issue-42.md"
  git -C "$WORK_DIR" add .
  git -C "$WORK_DIR" commit -m "spec-on-main" -q
  git -C "$WORK_DIR" push origin main -q
  git -C "$WORK_DIR" push origin main:"refs/heads/swarm/issue-42"

  # Adapter that only writes to .swarm-engine/ (excluded from staging)
  SWARM_ENGINE_ONLY_CMD="$(mktemp)"
  cat > "$SWARM_ENGINE_ONLY_CMD" <<'STUB'
#!/usr/bin/env bash
mkdir -p .swarm-engine
printf 'engine-only content\n' > .swarm-engine/state.json
exit 0
STUB
  chmod +x "$SWARM_ENGINE_ONLY_CMD"
  export ADAPTER_CMD="bash $SWARM_ENGINE_ONLY_CMD"

  export GH_STUB_LABELS_JSON='[{"name":"swarm:attempts:1"},{"name":"swarm:develop"}]'

  run bash "$ENGINE_SH"
  [ "$status" -ne 0 ]

  # bump-attempts must have been called (.swarm-engine not counted as a diff)
  grep -q "swarm:attempts" "$GH_STUB_LOG"

  rm -f "$SWARM_ENGINE_ONLY_CMD"
}
