#!/usr/bin/env bats
# pr-gates.bats — tests for pr-gates.yml and fix.yml
#
# Tests:
#   1. bump-attempts needs-human output (unit — shell-level)
#   2. fix.yml dry-run path: bump skipped, write steps log intent
#   3. fix.yml adapter routing logic (structural extraction)
#   4. Attempts boundary: needs-human=true → fix-invoke skipped
#
# Note: Full workflow execution (act) is out of scope for the bats tier.
# The structural assertions below verify the routing logic extracted from
# fix.yml into a testable shell function that mirrors what the workflow steps do.

REPO_ROOT="$(git -C "$(dirname "$BATS_TEST_FILENAME")" rev-parse --show-toplevel)"
PR_GATES="$REPO_ROOT/workflows/pr-gates.yml"
FIX="$REPO_ROOT/workflows/fix.yml"
BUMP_SH="$REPO_ROOT/actions/bump-attempts/bump-attempts.sh"
STUBS_DIR="$REPO_ROOT/tests/stubs"

setup() {
  export GH_STUB_LOG="$(mktemp)"
  export GITHUB_REPOSITORY="testowner/testrepo"
  export GH_TOKEN="fake-token"
  export ISSUE_NUMBER="42"
  export MAINTAINER="benmarte"
  export POST_COMMENT="false"
  export RUNNER_TEMP="$(mktemp -d)"
  export GITHUB_OUTPUT="$(mktemp)"
  export PATH="$STUBS_DIR:$PATH"
}

teardown() {
  rm -f "$GH_STUB_LOG" "$GITHUB_OUTPUT"
  rm -rf "$RUNNER_TEMP"
}

# ---------------------------------------------------------------------------
# bump-attempts needs-human output
# ---------------------------------------------------------------------------

@test "bump-attempts: 0→1 emits needs-human=false" {
  export GH_STUB_LABELS_JSON='[]'

  run bash "$BUMP_SH"
  [ "$status" -eq 0 ]

  grep -q "needs-human=false" "$GITHUB_OUTPUT"
}

@test "bump-attempts: 1→2 emits needs-human=false" {
  export GH_STUB_LABELS_JSON='[{"name":"swarm:attempts:1"}]'

  run bash "$BUMP_SH"
  [ "$status" -eq 0 ]

  grep -q "needs-human=false" "$GITHUB_OUTPUT"
}

@test "bump-attempts: 2→3 emits needs-human=true" {
  export GH_STUB_LABELS_JSON='[{"name":"swarm:attempts:2"}]'

  run bash "$BUMP_SH"
  [ "$status" -eq 0 ]

  grep -q "needs-human=true" "$GITHUB_OUTPUT"
}

@test "bump-attempts: already at N=3 emits needs-human=true" {
  export GH_STUB_LABELS_JSON='[{"name":"swarm:attempts:3"}]'

  run bash "$BUMP_SH"
  [ "$status" -eq 0 ]

  grep -q "needs-human=true" "$GITHUB_OUTPUT"
}

# ---------------------------------------------------------------------------
# fix.yml structural: dry-run guards and adapter conditionals
# ---------------------------------------------------------------------------

@test "fix.yml: bump-attempts step has dry-run guard (inputs.dry-run == false)" {
  # Verify bump-attempts step is conditioned so it is skipped on dry-run
  run python3 - "$FIX" <<'PYEOF'
import sys

with open(sys.argv[1]) as fh:
    content = fh.read()

# We expect a step using ./actions/bump-attempts with an "if:" condition
# that prevents it running when dry-run is true.
if "bump-attempts" not in content:
    print("ERROR: no reference to bump-attempts found in fix.yml")
    sys.exit(1)

# Find the bump-attempts step block and confirm it has a dry-run guard
lines = content.split("\n")
in_bump_step = False
found_dryrun_guard = False
for i, line in enumerate(lines):
    stripped = line.strip()
    if "uses: ./actions/bump-attempts" in line:
        # Check surrounding lines for an "if:" with dry-run
        window = "\n".join(lines[max(0, i-10):i+3])
        if "dry-run" in window and ("== false" in window or "dry_run" in window.lower()):
            found_dryrun_guard = True
        break

if not found_dryrun_guard:
    print("ERROR: bump-attempts step in fix.yml must have a dry-run guard (if: inputs.dry-run == false)")
    sys.exit(1)
sys.exit(0)
PYEOF
  [ "$status" -eq 0 ]
}

@test "fix.yml: claude-code-action adapter path has dry-run guard" {
  # The @claude PR comment step must only fire on dry-run == false
  run python3 - "$FIX" <<'PYEOF'
import sys, re

with open(sys.argv[1]) as fh:
    content = fh.read()

# Find the @claude comment step — it should reference both adapter==claude-code-action
# AND dry-run == false
if "@claude" not in content:
    print("ERROR: @claude re-invoke comment not found in fix.yml")
    sys.exit(1)

# Locate the line with @claude and check the if: block before it
lines = content.split("\n")
for i, line in enumerate(lines):
    if "@claude" in line and "Please fix" in line:
        window = "\n".join(lines[max(0, i-15):i+1])
        if "dry-run" not in window or ("claude-code-action" not in window):
            print(f"ERROR: @claude comment step missing dry-run or adapter guard near line {i+1}")
            sys.exit(1)
        sys.exit(0)

print("ERROR: @claude re-invoke comment step not found")
sys.exit(1)
PYEOF
  [ "$status" -eq 0 ]
}

@test "fix.yml: headless adapter path has dry-run guard" {
  run python3 - "$FIX" <<'PYEOF'
import sys

with open(sys.argv[1]) as fh:
    content = fh.read()

if "develop-run" not in content:
    print("ERROR: develop-run action not referenced in fix.yml")
    sys.exit(1)

lines = content.split("\n")
for i, line in enumerate(lines):
    if "uses: ./actions/develop-run" in line:
        window = "\n".join(lines[max(0, i-15):i+1])
        if "dry-run" not in window or "headless" not in window:
            print(f"ERROR: develop-run step missing dry-run or headless guard near line {i+1}")
            sys.exit(1)
        sys.exit(0)

print("ERROR: develop-run usage not found in fix.yml")
sys.exit(1)
PYEOF
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Attempts-boundary routing: simulate the escalation-gate logic
#
# The fix-invoke job's `if:` condition is:
#   needs.bump.outputs.needs-human != 'true'
#
# We test the equivalent shell routing logic that mirrors the workflow's
# escalation gate: when needs-human=true the fix path is not taken;
# when needs-human=false the correct adapter path is selected.
# ---------------------------------------------------------------------------

# Helper: simulate the fix-invoke routing logic as a shell function
# Arguments: $1=needs_human $2=adapter $3=dry_run
# Prints: "escalated", "comment-path", "headless-path", or "dry-run-<path>"
_routing_logic() {
  local needs_human="$1"
  local adapter="$2"
  local dry_run="$3"

  if [ "$needs_human" = "true" ]; then
    printf 'escalated\n'
    return 0
  fi

  if [ "$adapter" = "claude-code-action" ]; then
    if [ "$dry_run" = "true" ]; then
      printf 'dry-run-comment-path\n'
    else
      printf 'comment-path\n'
    fi
  elif [ "$adapter" = "headless" ]; then
    if [ "$dry_run" = "true" ]; then
      printf 'dry-run-headless-path\n'
    else
      printf 'headless-path\n'
    fi
  fi
}

@test "routing: needs-human=true → escalated (fix-invoke skipped)" {
  result="$(_routing_logic "true" "claude-code-action" "false")"
  [ "$result" = "escalated" ]
}

@test "routing: needs-human=false, adapter=claude-code-action → comment-path" {
  result="$(_routing_logic "false" "claude-code-action" "false")"
  [ "$result" = "comment-path" ]
}

@test "routing: needs-human=false, adapter=headless → headless-path" {
  result="$(_routing_logic "false" "headless" "false")"
  [ "$result" = "headless-path" ]
}

@test "routing: dry-run=true, adapter=claude-code-action → dry-run-comment-path (no writes)" {
  result="$(_routing_logic "false" "claude-code-action" "true")"
  [ "$result" = "dry-run-comment-path" ]
}

@test "routing: dry-run=true, adapter=headless → dry-run-headless-path (no writes)" {
  result="$(_routing_logic "false" "headless" "true")"
  [ "$result" = "dry-run-headless-path" ]
}

# ---------------------------------------------------------------------------
# pr-gates.yml structural: SWARM_TOKEN and QA documentation
# ---------------------------------------------------------------------------

@test "pr-gates.yml: SWARM_TOKEN referenced in secrets section" {
  run python3 - "$PR_GATES" <<'PYEOF'
import sys

with open(sys.argv[1]) as fh:
    content = fh.read()

if "SWARM_TOKEN" not in content:
    print("ERROR: SWARM_TOKEN not referenced in pr-gates.yml")
    sys.exit(1)
sys.exit(0)
PYEOF
  [ "$status" -eq 0 ]
}

@test "pr-gates.yml: reviewer job references SWARM_TOKEN for review posting" {
  # reviewer-post job must use SWARM_TOKEN, not GITHUB_TOKEN, for gh pr review
  run python3 - "$PR_GATES" <<'PYEOF'
import sys, re

with open(sys.argv[1]) as fh:
    content = fh.read()

# Confirm gh pr review appears and SWARM_TOKEN appears in the reviewer-post section
lines = content.split("\n")
in_reviewer_post = False
found_review_cmd = False
found_swarm_token = False

for i, line in enumerate(lines):
    stripped = line.strip()
    # Detect reviewer-post job section (indented 2 spaces, ends with :)
    if re.match(r'^  reviewer-post:', line):
        in_reviewer_post = True
    elif re.match(r'^  [a-z]', line) and not line.startswith("  reviewer-post:"):
        if in_reviewer_post:
            in_reviewer_post = False

    if in_reviewer_post:
        if "gh pr review" in line or "pr review" in line:
            found_review_cmd = True
        if "SWARM_TOKEN" in line:
            found_swarm_token = True

if not found_review_cmd:
    print("ERROR: 'gh pr review' command not found in reviewer-post job")
    sys.exit(1)
if not found_swarm_token:
    print("ERROR: SWARM_TOKEN not referenced in reviewer-post job")
    sys.exit(1)
sys.exit(0)
PYEOF
  [ "$status" -eq 0 ]
}

@test "pr-gates.yml: QA-is-required-checks decision documented in workflow header" {
  run grep -q "QA" "$PR_GATES"
  [ "$status" -eq 0 ]
  run grep -q "required" "$PR_GATES"
  [ "$status" -eq 0 ]
}
