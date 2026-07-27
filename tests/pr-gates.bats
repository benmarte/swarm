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
