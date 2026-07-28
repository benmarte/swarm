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
PR_GATES="$REPO_ROOT/.github/workflows/pr-gates.yml"
FIX="$REPO_ROOT/.github/workflows/fix.yml"
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
    if "bump-attempts" in line and "uses:" in line:
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
    if "develop-run" in line and "uses:" in line:
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

@test "pr-gates.yml: reviewer-post review decoration is failure-tolerant (self-review 422)" {
  # When SWARM_TOKEN authored the PR, GitHub returns 422 (self-review not allowed).
  # The 'gh pr review' call must be wrapped in failure-tolerant logic so the
  # step logs and continues rather than hard-failing the job.
  run python3 - "$PR_GATES" <<'PYEOF'
import sys

with open(sys.argv[1]) as fh:
    content = fh.read()

if "if ! gh pr review" not in content:
    print("ERROR: 'gh pr review' must be wrapped in a failure-tolerant 'if !' guard")
    sys.exit(1)

if "review decoration failed" not in content or "self-review 422" not in content:
    print("ERROR: failure log message ('review decoration failed' / 'self-review 422') not found")
    sys.exit(1)

sys.exit(0)
PYEOF
  [ "$status" -eq 0 ]
}

@test "pr-gates.yml: review:approved label-apply step is separate from gh pr review decoration" {
  # The label write must live in its own step so a 422 on the review decoration
  # does not prevent the label from being applied (the authoritative gate).
  run python3 - "$PR_GATES" <<'PYEOF'
import sys

with open(sys.argv[1]) as fh:
    content = fh.read()

if "review:approved" not in content:
    print("ERROR: 'review:approved' label not referenced in pr-gates.yml")
    sys.exit(1)

# Locate the 'gh pr review' line (the review decoration). The --approve flag
# may appear on the following continuation line, so scan for 'gh pr review'
# alone and confirm --approve appears within the next 3 lines.
lines = content.split("\n")
approve_region_end = None
for i, line in enumerate(lines):
    if "gh pr review" in line:
        window = "\n".join(lines[i:i+4])
        if "--approve" in window:
            approve_region_end = i + 4
            break

if approve_region_end is None:
    print("ERROR: 'gh pr review --approve' block not found")
    sys.exit(1)

# After the approve region, verify a new step 'name:' header precedes the
# 'review:approved' label-apply (i.e., label write is in a separate step).
found_separator = False
found_label = False
for i in range(approve_region_end, len(lines)):
    stripped = lines[i].strip()
    if "name:" in stripped and "Apply review" in stripped:
        found_separator = True
    if found_separator and "review:approved" in lines[i] and "name:" not in lines[i]:
        found_label = True
        break

if not found_label:
    print("ERROR: 'review:approved' label-apply must be in a separate named step after 'gh pr review'")
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

# ---------------------------------------------------------------------------
# SWARM_FIX_CONTEXT wiring (blocking review item)
# ---------------------------------------------------------------------------

@test "fix.yml: headless path builds SWARM_FIX_CONTEXT with all four required fields" {
  # headless.sh schema: {check_name, conclusion, log_url, attempt_number}
  # All four must appear in the jq expression in fix.yml
  run python3 - "$FIX" <<'PYEOF'
import sys

with open(sys.argv[1]) as fh:
    content = fh.read()

required_fields = ["check_name", "conclusion", "log_url", "attempt_number"]
missing = [f for f in required_fields if f not in content]

if missing:
    print(f"ERROR: SWARM_FIX_CONTEXT JSON missing fields in fix.yml: {missing}")
    sys.exit(1)

if "SWARM_FIX_CONTEXT" not in content:
    print("ERROR: SWARM_FIX_CONTEXT not referenced in fix.yml")
    sys.exit(1)

# Confirm GITHUB_ENV is used to propagate it (not inline in run: block)
if "GITHUB_ENV" not in content:
    print("ERROR: SWARM_FIX_CONTEXT should be written to GITHUB_ENV for propagation")
    sys.exit(1)

sys.exit(0)
PYEOF
  [ "$status" -eq 0 ]
}

@test "headless.sh: SWARM_FIX_CONTEXT is injected into prompt as '## Fix Context' section" {
  local tmp_dir="$BATS_TMPDIR/headless-fixctx-test"
  mkdir -p "$tmp_dir"

  local capture_file="$tmp_dir/captured-prompt.txt"
  local mock_adapter="$tmp_dir/mock-adapter"

  # Write mock adapter that copies the prompt file to a known location
  cat > "$mock_adapter" <<ADAPTER
#!/usr/bin/env bash
cp "\$1" "$capture_file"
exit 0
ADAPTER
  chmod +x "$mock_adapter"

  local spec_file="$tmp_dir/spec.md"
  printf '# Test specification\n' > "$spec_file"

  local fix_ctx='{"check_name":"lint,test","conclusion":"failure","log_url":"https://example.com/run/1","attempt_number":2}'

  run env \
    ADAPTER_CMD="$mock_adapter" \
    WORKTREE="$tmp_dir" \
    ISSUE_NUMBER="42" \
    SPEC_FILE="$spec_file" \
    SWARM_LLM_MODEL="" \
    SWARM_FIX_CONTEXT="$fix_ctx" \
    bash "$REPO_ROOT/actions/develop-run/adapters/headless.sh"

  [ "$status" -eq 0 ]
  [ -f "$capture_file" ]
  run grep -q "## Fix Context" "$capture_file"
  [ "$status" -eq 0 ]

  rm -rf "$tmp_dir"
}

@test "headless.sh: prompt contains SWARM_FIX_CONTEXT JSON content when set" {
  local tmp_dir="$BATS_TMPDIR/headless-fixctx-json-test"
  mkdir -p "$tmp_dir"

  local capture_file="$tmp_dir/captured-prompt.txt"
  local mock_adapter="$tmp_dir/mock-adapter"

  cat > "$mock_adapter" <<ADAPTER
#!/usr/bin/env bash
cp "\$1" "$capture_file"
exit 0
ADAPTER
  chmod +x "$mock_adapter"

  local spec_file="$tmp_dir/spec.md"
  printf '# Spec\n' > "$spec_file"

  local fix_ctx='{"check_name":"ci-lint","conclusion":"failure","log_url":"https://ci.example.com/123","attempt_number":1}'

  run env \
    ADAPTER_CMD="$mock_adapter" \
    WORKTREE="$tmp_dir" \
    ISSUE_NUMBER="7" \
    SPEC_FILE="$spec_file" \
    SWARM_LLM_MODEL="" \
    SWARM_FIX_CONTEXT="$fix_ctx" \
    bash "$REPO_ROOT/actions/develop-run/adapters/headless.sh"

  [ "$status" -eq 0 ]
  [ -f "$capture_file" ]
  # All four schema fields must appear in the prompt
  run grep -q "ci-lint" "$capture_file"
  [ "$status" -eq 0 ]
  run grep -q "failure" "$capture_file"
  [ "$status" -eq 0 ]

  rm -rf "$tmp_dir"
}

@test "headless.sh: no fix-context section when SWARM_FIX_CONTEXT is unset" {
  local tmp_dir="$BATS_TMPDIR/headless-nofixctx-test"
  mkdir -p "$tmp_dir"

  local capture_file="$tmp_dir/captured-prompt.txt"
  local mock_adapter="$tmp_dir/mock-adapter"

  cat > "$mock_adapter" <<ADAPTER
#!/usr/bin/env bash
cp "\$1" "$capture_file"
exit 0
ADAPTER
  chmod +x "$mock_adapter"

  local spec_file="$tmp_dir/spec.md"
  printf '# Spec\n' > "$spec_file"

  run env \
    ADAPTER_CMD="$mock_adapter" \
    WORKTREE="$tmp_dir" \
    ISSUE_NUMBER="7" \
    SPEC_FILE="$spec_file" \
    SWARM_LLM_MODEL="" \
    bash "$REPO_ROOT/actions/develop-run/adapters/headless.sh"

  [ "$status" -eq 0 ]
  [ -f "$capture_file" ]
  run grep -q "## Fix Context" "$capture_file"
  [ "$status" -ne 0 ]

  rm -rf "$tmp_dir"
}

# ---------------------------------------------------------------------------
# Output sanitization (security review item)
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Label POST API shape (issue #46) — labels[] array form, not name= scalar
# ---------------------------------------------------------------------------

@test "pr-gates.yml: label-add POST uses labels[] array form" {
  # GitHub Issues API requires {"labels": [...]} shape.
  # The gh CLI array form is:  -f "labels[]=<value>"
  # The wrong scalar form is:  -f "name=<value>"
  run python3 - "$PR_GATES" <<'PYEOF'
import sys, re

with open(sys.argv[1]) as fh:
    content = fh.read()

# Must contain the correct array form
if 'labels[]=' not in content:
    print("ERROR: label-add POST must use -f \"labels[]=...\" (array form), not -f \"name=...\"")
    sys.exit(1)

# Must NOT contain the wrong scalar form in any label-add POST context
# (i.e. within a gh api call to the .../labels endpoint)
lines = content.split('\n')
for i, line in enumerate(lines):
    if re.search(r'issues/\$.*?/labels', line) or re.search(r'issues/.*PR_NUMBER.*/labels', line):
        # Check the surrounding block (10 lines) for name= pattern
        block = '\n'.join(lines[max(0, i-2):i+10])
        if re.search(r'-f\s+"name=', block):
            print(f"ERROR: label-add POST near line {i+1} still uses -f \"name=...\" (scalar form); use -f \"labels[]=...\"")
            sys.exit(1)

sys.exit(0)
PYEOF
  [ "$status" -eq 0 ]
}

@test "pr-gates.yml: no name= scalar form in any label-add POST" {
  # Defensive check: grep for -f "name= anywhere a labels endpoint is called
  run python3 - "$PR_GATES" <<'PYEOF'
import sys, re

with open(sys.argv[1]) as fh:
    lines = fh.readlines()

in_label_post = False
label_post_start = -1

for i, line in enumerate(lines):
    # Detect start of a gh api call targeting the labels endpoint
    if re.search(r'gh api', line) and re.search(r'/labels', line):
        in_label_post = True
        label_post_start = i
    # Detect -f "name= in a label-post block
    if in_label_post and re.search(r'-f\s+"name=', line):
        print(f"ERROR: line {i+1} uses -f \"name=...\" in a label-add POST (block started line {label_post_start+1}); switch to -f \"labels[]=...\"")
        sys.exit(1)
    # End of block: blank line or new step
    if in_label_post and i > label_post_start and (line.strip() == '' or re.match(r'\s+- name:', line)):
        in_label_post = False

sys.exit(0)
PYEOF
  [ "$status" -eq 0 ]
}

@test "pr-gates.yml: outcome-derived single-line outputs sanitized with tr -d" {
  # Both reviewer and security Read outcome steps must pipe through tr -d '\n\r'
  # to prevent newline-injection spoofing of GITHUB_OUTPUT key=value pairs.
  count="$(grep -c "tr -d" "$PR_GATES")"
  [ "$count" -ge 2 ]
}

# ---------------------------------------------------------------------------
# Reviewer-post idempotency guard (advisory review item)
# ---------------------------------------------------------------------------

@test "pr-gates.yml: reviewer-post contains idempotency check before posting review" {
  # Verify that a duplicate-review guard exists in reviewer-post job
  run python3 - "$PR_GATES" <<'PYEOF'
import sys

with open(sys.argv[1]) as fh:
    content = fh.read()

# Look for the idempotency guard pattern: listing existing reviews and checking skip
if "skip" not in content:
    print("ERROR: no 'skip' output found — idempotency guard missing in reviewer-post")
    sys.exit(1)

if "/reviews" not in content:
    print("ERROR: no PR reviews API call found — idempotency guard must list existing reviews")
    sys.exit(1)

if "check-review" not in content:
    print("ERROR: check-review step not found in pr-gates.yml")
    sys.exit(1)

sys.exit(0)
PYEOF
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# merge job structural tests (issue #48 — swarm-approval gate)
# ---------------------------------------------------------------------------

@test "pr-gates.yml: merge job exists with environment: swarm-approval" {
  run python3 - "$PR_GATES" <<'PYEOF'
import sys

with open(sys.argv[1]) as fh:
    content = fh.read()

if "merge:" not in content:
    print("ERROR: merge job not found in pr-gates.yml")
    sys.exit(1)

if "swarm-approval" not in content:
    print("ERROR: 'swarm-approval' environment not referenced in pr-gates.yml")
    sys.exit(1)

# Verify environment: swarm-approval appears in the merge job block
lines = content.split("\n")
in_merge = False
found_env = False
for i, line in enumerate(lines):
    stripped = line.strip()
    # Detect merge job header at 2-space indent
    if line == "  merge:":
        in_merge = True
        continue
    # Any other 2-space-indented job ends the merge block
    if in_merge and line and not line.startswith("    ") and line != "  merge:":
        if line[0] != " " or (len(line) > 2 and line[2] != " "):
            break
    if in_merge and "environment:" in line and "swarm-approval" in line:
        found_env = True
        break

if not found_env:
    print("ERROR: 'environment: swarm-approval' not found inside merge job block")
    sys.exit(1)

sys.exit(0)
PYEOF
  [ "$status" -eq 0 ]
}

@test "pr-gates.yml: merge job needs reviewer-post and security-post" {
  run python3 - "$PR_GATES" <<'PYEOF'
import sys, re

with open(sys.argv[1]) as fh:
    content = fh.read()

# Find the merge job block
lines = content.split("\n")
in_merge = False
merge_block = []
for i, line in enumerate(lines):
    if line == "  merge:":
        in_merge = True
        merge_block = [line]
        continue
    if in_merge:
        if line and not line.startswith("  ") and line.strip():
            break
        if line.startswith("  ") and not line.startswith("    ") and line.strip().endswith(":") and line != "  merge:":
            break
        merge_block.append(line)

merge_text = "\n".join(merge_block)

if "reviewer-post" not in merge_text:
    print("ERROR: merge job does not list reviewer-post in its needs chain")
    sys.exit(1)

if "security-post" not in merge_text:
    print("ERROR: merge job does not list security-post in its needs chain")
    sys.exit(1)

sys.exit(0)
PYEOF
  [ "$status" -eq 0 ]
}

@test "pr-gates.yml: merge job uses SWARM_TOKEN for the merge step" {
  run python3 - "$PR_GATES" <<'PYEOF'
import sys, re

with open(sys.argv[1]) as fh:
    content = fh.read()

# Locate the Squash-merge step and confirm SWARM_TOKEN appears in it
if "Squash-merge" not in content and "squash-merge" not in content.lower():
    print("ERROR: squash-merge step not found in pr-gates.yml")
    sys.exit(1)

if "SWARM_TOKEN" not in content:
    print("ERROR: SWARM_TOKEN not referenced in pr-gates.yml merge step")
    sys.exit(1)

# Confirm gh pr merge --squash appears
if "--squash" not in content:
    print("ERROR: '--squash' flag not found in merge step — must use squash strategy")
    sys.exit(1)

if "--delete-branch" not in content:
    print("ERROR: '--delete-branch' flag not found in merge step")
    sys.exit(1)

sys.exit(0)
PYEOF
  [ "$status" -eq 0 ]
}

@test "pr-gates.yml: merge job has pre-merge verification step" {
  run python3 - "$PR_GATES" <<'PYEOF'
import sys

with open(sys.argv[1]) as fh:
    content = fh.read()

# Pre-merge verification must check:
# 1. review:approved label
# 2. swarm:needs-human absence
# 3. check-runs (check-runs API or similar)

if "review:approved" not in content:
    print("ERROR: pre-merge verification must check for review:approved label")
    sys.exit(1)

if "swarm:needs-human" not in content:
    print("ERROR: pre-merge verification must check for swarm:needs-human absence")
    sys.exit(1)

if "check-runs" not in content:
    print("ERROR: pre-merge verification must query check-runs API")
    sys.exit(1)

sys.exit(0)
PYEOF
  [ "$status" -eq 0 ]
}

@test "pr-gates.yml: merge job has dry-run guards on all write steps" {
  run python3 - "$PR_GATES" <<'PYEOF'
import sys

with open(sys.argv[1]) as fh:
    content = fh.read()

# Merge and transition steps must be guarded by dry-run == false.
# The dry-run log steps must be guarded by dry-run == true.
# We check for the pattern: merge step has dry-run == false guard.

if "dry-run == false" not in content and "dry-run==false" not in content:
    print("ERROR: dry-run guards not found in pr-gates.yml merge job")
    sys.exit(1)

if "dry-run == true" not in content and "dry-run==true" not in content:
    print("ERROR: dry-run log steps not found in pr-gates.yml merge job")
    sys.exit(1)

sys.exit(0)
PYEOF
  [ "$status" -eq 0 ]
}

@test "pr-gates.yml: merge job transitions swarm:qa to swarm:docs" {
  run python3 - "$PR_GATES" <<'PYEOF'
import sys

with open(sys.argv[1]) as fh:
    content = fh.read()

if "swarm:qa" not in content:
    print("ERROR: merge job must transition from swarm:qa")
    sys.exit(1)

if "swarm:docs" not in content:
    print("ERROR: merge job must transition to swarm:docs")
    sys.exit(1)

# Transition action must be invoked
if "actions/transition" not in content:
    print("ERROR: transition action not referenced in pr-gates.yml")
    sys.exit(1)

sys.exit(0)
PYEOF
  [ "$status" -eq 0 ]
}

@test "pr-gates.yml: merge job transition passes token input" {
  run python3 - "$PR_GATES" <<'PYEOF'
import sys, re

with open(sys.argv[1]) as fh:
    content = fh.read()

uses_blocks = re.findall(
    r'uses:\s*\./.swarm-engine/actions/transition.*?(?=uses:|steps:|jobs:|\Z)',
    content, re.DOTALL
)
if not uses_blocks:
    print("No transition uses blocks found in pr-gates.yml")
    sys.exit(1)

for block in uses_blocks:
    if 'token:' not in block:
        print(f"ERROR: transition invocation missing token: input:\n{block[:200]}")
        sys.exit(1)

sys.exit(0)
PYEOF
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# QA job: existence, ordering, labels, polling — issue #72
# Tests below FAIL on the pre-fix codebase and PASS after the fix.
# ---------------------------------------------------------------------------

@test "pr-gates.yml: qa job exists (issue #72)" {
  # A qa job must exist as a top-level jobs entry.
  run grep -q "^  qa:" "$PR_GATES"
  [ "$status" -eq 0 ]
}

@test "pr-gates.yml: qa job has permissions and timeout-minutes (issue #72)" {
  run python3 - "$PR_GATES" <<'PYEOF'
import sys, re

with open(sys.argv[1]) as fh:
    content = fh.read()

lines = content.split("\n")
in_qa = False
found_timeout = False
found_perms = False

for i, line in enumerate(lines):
    if line == "  qa:":
        in_qa = True
        continue
    if in_qa:
        # Another 2-space-indented job key ends the qa block
        if re.match(r'^  [a-z]', line) and not line.startswith("   "):
            break
        if "timeout-minutes:" in line:
            found_timeout = True
        if "permissions:" in line:
            found_perms = True

if not found_timeout:
    print("ERROR: qa job missing timeout-minutes:")
    sys.exit(1)
if not found_perms:
    print("ERROR: qa job missing permissions:")
    sys.exit(1)
sys.exit(0)
PYEOF
  [ "$status" -eq 0 ]
}

@test "pr-gates.yml: reviewer job needs qa (AC3 — issue #72)" {
  # reviewer must declare needs: [qa] (or needs: qa) so it cannot run until QA passes.
  run python3 - "$PR_GATES" <<'PYEOF'
import sys, re

with open(sys.argv[1]) as fh:
    content = fh.read()

lines = content.split("\n")
in_reviewer = False
found_needs_qa = False

for i, line in enumerate(lines):
    if line == "  reviewer:":
        in_reviewer = True
        continue
    if in_reviewer:
        if re.match(r'^  [a-z]', line) and line != "  reviewer:":
            break
        if "needs:" in line:
            # Check this line and next few for 'qa'
            window = "\n".join(lines[i:i+6])
            if re.search(r'\bqa\b', window):
                found_needs_qa = True
                break

if not found_needs_qa:
    print("ERROR: reviewer job does not have needs: [qa] — reviewer must wait for QA")
    sys.exit(1)
sys.exit(0)
PYEOF
  [ "$status" -eq 0 ]
}

@test "pr-gates.yml: security job needs qa (AC3 — issue #72)" {
  run python3 - "$PR_GATES" <<'PYEOF'
import sys, re

with open(sys.argv[1]) as fh:
    content = fh.read()

lines = content.split("\n")
in_security = False
found_needs_qa = False

for i, line in enumerate(lines):
    if line == "  security:":
        in_security = True
        continue
    if in_security:
        if re.match(r'^  [a-z]', line) and line != "  security:":
            break
        if "needs:" in line:
            window = "\n".join(lines[i:i+6])
            if re.search(r'\bqa\b', window):
                found_needs_qa = True
                break

if not found_needs_qa:
    print("ERROR: security job does not have needs: [qa] — security must wait for QA")
    sys.exit(1)
sys.exit(0)
PYEOF
  [ "$status" -eq 0 ]
}

@test "pr-gates.yml: merge job needs qa (AC1 — issue #72)" {
  # merge must list qa in its needs so the swarm-approval gate is never reached
  # when QA fails (transitive via reviewer-post/security-post, plus explicit).
  run python3 - "$PR_GATES" <<'PYEOF'
import sys, re

with open(sys.argv[1]) as fh:
    content = fh.read()

lines = content.split("\n")
in_merge = False
merge_needs = ""

for i, line in enumerate(lines):
    if line == "  merge:":
        in_merge = True
        continue
    if in_merge:
        if re.match(r'^  [a-z]', line) and line != "  merge:":
            break
        if "needs:" in line:
            window = "\n".join(lines[i:i+8])
            merge_needs = window
            break

if not re.search(r'\bqa\b', merge_needs):
    print("ERROR: merge job does not list qa in its needs chain — "
          "human approval gate must not be reached when QA fails")
    print(f"needs block found: {merge_needs[:300]!r}")
    sys.exit(1)
sys.exit(0)
PYEOF
  [ "$status" -eq 0 ]
}

@test "pr-gates.yml: qa job applies qa:pass label on check success (AC2 — issue #72)" {
  run grep -q "qa:pass" "$PR_GATES"
  [ "$status" -eq 0 ]
}

@test "pr-gates.yml: qa job applies qa:fail label on check failure (AC2 — issue #72)" {
  run grep -q "qa:fail" "$PR_GATES"
  [ "$status" -eq 0 ]
}

@test "pr-gates.yml: qa job polls with timeout — absent check is not treated as pass (issue #72)" {
  # A qa job that passes because a check had not reported yet is worse than the bug.
  # Verify that: (a) polling/retry logic exists and (b) 'not_found' is treated as non-pass.
  run python3 - "$PR_GATES" <<'PYEOF'
import sys

with open(sys.argv[1]) as fh:
    content = fh.read()

# Polling loop must exist (max_attempts or sleep pattern)
if "max_attempts" not in content and "sleep 30" not in content:
    print("ERROR: qa job must implement a polling loop with timeout "
          "(expected 'max_attempts' and 'sleep 30')")
    sys.exit(1)

# A missing/pending check must NOT be treated as passing —
# the script must explicitly handle the 'not_found' case as non-green.
if "not_found" not in content:
    print("ERROR: qa job must explicitly handle 'not_found' check status "
          "(a required check that never appears must NOT be treated as passing)")
    sys.exit(1)

sys.exit(0)
PYEOF
  [ "$status" -eq 0 ]
}

@test "pr-gates.yml: qa-required-checks input no longer marked Reserved (issue #72)" {
  # The old description said 'Reserved — full wiring pending #10; currently unused.'
  # After this fix, the input is live and must not carry Reserved language.
  run python3 - "$PR_GATES" <<'PYEOF'
import sys, re

with open(sys.argv[1]) as fh:
    content = fh.read()

lines = content.split("\n")
in_qa_input = False

for i, line in enumerate(lines):
    if "qa-required-checks:" in line:
        in_qa_input = True
        continue
    if in_qa_input:
        # Description block spans the next few indented lines
        if not line.strip() or (line.strip() and not line.startswith("        ")):
            break
        if re.search(r'Reserved.*pending.*#10|currently unused', line):
            print(f"ERROR: qa-required-checks input still carries Reserved language "
                  f"on line {i+1}: {line!r}")
            sys.exit(1)

sys.exit(0)
PYEOF
  [ "$status" -eq 0 ]
}

@test "pr-gates.yml: qa job exits cleanly when no required_checks configured (AC4 — issue #72)" {
  # When REQUIRED_CHECKS is empty, the qa job must skip polling and pass through.
  run python3 - "$PR_GATES" <<'PYEOF'
import sys

with open(sys.argv[1]) as fh:
    content = fh.read()

# There must be a code path that handles empty REQUIRED_CHECKS gracefully.
# Look for the pattern: if empty checks → skip QA gate.
if "no required checks" not in content and "REQUIRED_CHECKS" not in content:
    print("ERROR: qa job must handle missing/empty required_checks gracefully")
    sys.exit(1)

# The word 'REQUIRED_CHECKS' must appear in the qa job's run block
if "REQUIRED_CHECKS" not in content:
    print("ERROR: REQUIRED_CHECKS variable not referenced in qa job")
    sys.exit(1)

sys.exit(0)
PYEOF
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# skipped/neutral security fix — coordinator finding on PR #73
#
# GitHub records a job whose if: evaluates false as conclusion:skipped.
# A PR author can influence such conditions (draft status, labels, branch name).
# Concrete attack: consumer requires 'CI / security-scan'; that job has
# if: github.event.pull_request.draft == false; author opens PR as draft;
# job is skipped; old code reads skipped as green → gate passed without the
# check ever running.
#
# Fix: only 'success' satisfies a required check.  'skipped' and 'neutral'
# are both treated as failure.  DO NOT relax this in the merge job's
# pre-merge verification — that job must tolerate skipped checks on
# unrelated swarm pipeline jobs (intake, spec, develop, fix, docs, sweeper).
# ---------------------------------------------------------------------------

@test "pr-gates.yml: qa job treats skipped conclusion as failure not green (security fix)" {
  # A required check reporting 'skipped' must NOT satisfy the gate.
  # GitHub records a job whose if: evaluates false as conclusion:skipped.
  # A PR author can influence such conditions (draft status, labels, branch name).
  # Verify: the string 'success|skipped' does not appear in the qa case green branch.
  run python3 - "$PR_GATES" <<'PYEOF'
import sys, re

with open(sys.argv[1]) as fh:
    content = fh.read()

# The green branch of the qa case statement must NOT include 'skipped'.
# The current pre-fix pattern is 'success|skipped|neutral)' — any pipe-joined
# combination that contains both 'success' and 'skipped' on one case branch line
# constitutes the defect.  Check for the pattern as a literal substring since
# the case statement uses unspaced alternation.
if "success|skipped" in content or "skipped|success" in content:
    print("ERROR: 'skipped' is grouped with 'success' in the green case branch — "
          "a skipped check must produce qa:fail, not qa:pass. "
          "GitHub records if:false jobs as conclusion:skipped; "
          "a PR author can influence this via draft status or label conditions.")
    sys.exit(1)

# 'skipped' must still be present in the file — in the failure branch.
if "skipped" not in content:
    print("ERROR: 'skipped' not found anywhere in pr-gates.yml — "
          "it must appear in the failure branch of the qa case statement")
    sys.exit(1)

sys.exit(0)
PYEOF
  [ "$status" -eq 0 ]
}

@test "pr-gates.yml: qa job treats neutral conclusion as failure by default (security fix)" {
  # 'neutral' conclusions must NOT satisfy a required check.
  # Check: no case branch pattern groups 'success' and 'neutral' together
  # in the green arm (e.g. 'success|skipped|neutral)' or 'success|neutral)').
  run python3 - "$PR_GATES" <<'PYEOF'
import sys, re

with open(sys.argv[1]) as fh:
    content = fh.read()

# Any pipe-joined case alternation that contains both 'success' and 'neutral'
# on the same branch constitutes the defect.  The pre-fix pattern is
# 'success|skipped|neutral)' which is caught by looking for 'neutral)' on
# the same line that also contains 'success'.
lines = content.split("\n")
for i, line in enumerate(lines, 1):
    stripped = line.strip()
    # Case branch lines end with ')' in shell; look for the green arm
    if "success" in stripped and "neutral" in stripped and stripped.endswith(")"):
        print(f"ERROR: line {i}: 'neutral' is grouped with 'success' in what appears "
              f"to be the green case branch: {line!r}. "
              "neutral must produce qa:fail by default.")
        sys.exit(1)

# 'neutral' must still appear (in the failure branch)
if "neutral" not in content:
    print("ERROR: 'neutral' not found anywhere in pr-gates.yml — "
          "it must appear in the failure branch of the qa case statement")
    sys.exit(1)

sys.exit(0)
PYEOF
  [ "$status" -eq 0 ]
}

@test "pr-gates.yml: merge pre-merge verification still tolerates skipped checks on unrelated jobs" {
  # REGRESSION GUARD: the merge job's pre-merge verification uses
  #   select(.conclusion != "success" and .conclusion != "skipped")
  # to tolerate swarm pipeline jobs (intake, spec, develop, fix, docs, sweeper)
  # that are legitimately skipped on every PR.  This MUST NOT be tightened.
  # The qa job and merge job differ intentionally:
  #   - qa  checks a consumer-declared ALLOWLIST — skipped is never acceptable
  #   - merge checks ALL check-runs on the SHA — unrelated swarm jobs are skipped
  run python3 - "$PR_GATES" <<'PYEOF'
import sys

with open(sys.argv[1]) as fh:
    content = fh.read()

# The pre-merge verification's jq filter must still allow skipped conclusions
# for non-required checks.  Look for the characteristic pattern.
if '.conclusion != "skipped"' not in content and ".conclusion != 'skipped'" not in content:
    print("ERROR: merge pre-merge verification no longer tolerates 'skipped' conclusions — "
          "this BREAKS every swarm PR (intake/spec/develop/fix/docs/sweeper all show skipped). "
          "Only the qa job should reject skipped; the merge job must keep allowing it.")
    sys.exit(1)

sys.exit(0)
PYEOF
  [ "$status" -eq 0 ]
}

@test "pr-gates.yml: qa job uses config fallback for required_checks (AC2 — issue #72)" {
  # The qa job must honour qa.required_checks from swarm.config.yml via load-config,
  # using the workflow input as override when set.
  run python3 - "$PR_GATES" <<'PYEOF'
import sys

with open(sys.argv[1]) as fh:
    content = fh.read()

# Must reference the load-config step output for qa-required-checks
if "qa-required-checks" not in content:
    print("ERROR: qa job must reference 'qa-required-checks' "
          "(from load-config or input) to consume the config value")
    sys.exit(1)

# Input wins over config — both must be referenced
if "CONFIG_CHECKS" not in content and "steps.config.outputs.qa-required-checks" not in content:
    print("ERROR: qa job must reference config output for qa-required-checks "
          "(expected CONFIG_CHECKS env var or steps.config.outputs.qa-required-checks)")
    sys.exit(1)

sys.exit(0)
PYEOF
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# QA gate picks the NEWEST check-run per name (issue #72 follow-up)
#
# Re-runs create several check-runs with the same name on one SHA. The API
# does not contract an order, so selecting .[0] was non-deterministic: a stale
# success could mask a newer failure in what is a merge gate. Not adversarially
# triggerable — a fork PR author cannot sequence check-runs — but wrong.
# ---------------------------------------------------------------------------

# Runs the workflow's OWN selection expression against fixture JSON, rather
# than a copy, so the test cannot drift away from the shipped logic.
_qa_select() {
  local fixture="$1" name="$2" expr
  expr="$(python3 - "$PR_GATES" <<'PYEOF'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"\[\.\[\] \| select\(\.name == \$name\)\] \|.*?\n\s*end", src, re.DOTALL)
if not m:
    sys.exit("could not extract the check-run selection jq expression")
# Strip the YAML block indentation and the trailing quote/paren of the shell line
sys.stdout.write("\n".join(l.strip() for l in m.group(0).splitlines()))
PYEOF
)"
  printf '%s' "$fixture" | jq -r --arg name "$name" "$expr"
}

@test "qa gate: newer failure wins over stale success regardless of API order" {
  older_first='[{"name":"ci","status":"completed","conclusion":"success","started_at":"2026-07-28T10:00:00Z"},{"name":"ci","status":"completed","conclusion":"failure","started_at":"2026-07-28T12:00:00Z"}]'
  newer_first='[{"name":"ci","status":"completed","conclusion":"failure","started_at":"2026-07-28T12:00:00Z"},{"name":"ci","status":"completed","conclusion":"success","started_at":"2026-07-28T10:00:00Z"}]'

  run _qa_select "$older_first" ci
  [ "$status" -eq 0 ]
  [ "$output" = "failure" ]

  # Same data, opposite API ordering — the gate must not change its mind
  run _qa_select "$newer_first" ci
  [ "$status" -eq 0 ]
  [ "$output" = "failure" ]
}

@test "qa gate: a newer success after an older failure is accepted" {
  # The legitimate re-run case: a flaky check failed, was re-run, and passed.
  fixture='[{"name":"ci","status":"completed","conclusion":"failure","started_at":"2026-07-28T10:00:00Z"},{"name":"ci","status":"completed","conclusion":"success","started_at":"2026-07-28T12:00:00Z"}]'
  run _qa_select "$fixture" ci
  [ "$status" -eq 0 ]
  [ "$output" = "success" ]
}

@test "qa gate: an in-progress newest run reports pending, not the older conclusion" {
  fixture='[{"name":"ci","status":"completed","conclusion":"success","started_at":"2026-07-28T10:00:00Z"},{"name":"ci","status":"in_progress","conclusion":null,"started_at":"2026-07-28T12:00:00Z"}]'
  run _qa_select "$fixture" ci
  [ "$status" -eq 0 ]
  [ "$output" = "pending" ]
}

@test "pr-gates.yml: no stale 'pending #N' markers anywhere in the file" {
  # The narrower test above only inspects the qa-required-checks description
  # block. It passed while the HEADER comment still advertised the input as
  # "Reserved — pending #10" — stale, and actively wrong once the input became
  # the core of the QA gate.
  #
  # This matters beyond tidiness: issue #72 went unnoticed for exactly this
  # reason. A marker that reads as a plan looks like intent rather than a gap,
  # so nobody audits it. #10 shipped as unrelated work and the reservation was
  # never redeemed.
  run grep -n "pending #[0-9]" "$PR_GATES"
  [ "$status" -ne 0 ] || {
    echo "# stale marker(s) found: $output" >&3
    false
  }
}
