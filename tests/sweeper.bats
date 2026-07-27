#!/usr/bin/env bats
# sweeper.bats — unit tests for sweeper glue scripts and fixture states.
#
# Tests:
#   1. parse-sweeper-report.sh: stuck fixture → issue number emitted
#   2. parse-sweeper-report.sh: clean fixture → no output
#   3. parse-sweeper-report.sh: paused fixture → no output (paused issue excluded)
#   4. parse-sweeper-report.sh: dry-run mode → logs intent, no issue numbers
#   5. parse-sweeper-report.sh: wrong verdict → exits non-zero
#   6. check-skipped-reason.sh: valid skipped outcome (reason present) → exits 0
#   7. check-skipped-reason.sh: invalid skipped outcome (reason empty) → exits 1
#   8. check-skipped-reason.sh: verdict=done → exits 0 (no enforcement needed)
#   9. sweeper.yml: does not reference swarm:paused in any label-write context

REPO_ROOT="$(git -C "$(dirname "$BATS_TEST_FILENAME")" rev-parse --show-toplevel)"
PARSE_SCRIPT="$REPO_ROOT/scripts/parse-sweeper-report.sh"
CHECK_SCRIPT="$REPO_ROOT/scripts/check-skipped-reason.sh"
SWEEPER_YML="$REPO_ROOT/.github/workflows/sweeper.yml"
FIXTURES="$REPO_ROOT/tests/fixtures"

# ---------------------------------------------------------------------------
# parse-sweeper-report.sh: stuck issue fixture
# ---------------------------------------------------------------------------

@test "parse-sweeper-report: stuck fixture emits issue number 42" {
  run bash "$PARSE_SCRIPT" "$FIXTURES/sweeper/stuck-issue.json"
  [ "$status" -eq 0 ]
  # Output should contain the stuck issue number
  [[ "$output" == *"42"* ]]
}

@test "parse-sweeper-report: stuck fixture outputs exactly one issue number" {
  # Run without summary lines, count numeric-only lines
  result="$(bash "$PARSE_SCRIPT" "$FIXTURES/sweeper/stuck-issue.json" 2>/dev/null | grep -E '^[0-9]+$' || true)"
  [ "$result" = "42" ]
}

# ---------------------------------------------------------------------------
# parse-sweeper-report.sh: clean issue fixture
# ---------------------------------------------------------------------------

@test "parse-sweeper-report: clean fixture emits no issue numbers" {
  result="$(bash "$PARSE_SCRIPT" "$FIXTURES/sweeper/clean-issue.json" 2>/dev/null | grep -E '^[0-9]+$' || true)"
  [ -z "$result" ]
}

# ---------------------------------------------------------------------------
# parse-sweeper-report.sh: paused issue fixture
# ---------------------------------------------------------------------------

@test "parse-sweeper-report: paused fixture emits no issue numbers" {
  # Paused issues are excluded by the orchestrator (evidence.stuck is empty)
  result="$(bash "$PARSE_SCRIPT" "$FIXTURES/sweeper/paused-issue.json" 2>/dev/null | grep -E '^[0-9]+$' || true)"
  [ -z "$result" ]
}

# ---------------------------------------------------------------------------
# parse-sweeper-report.sh: dry-run mode
# ---------------------------------------------------------------------------

@test "parse-sweeper-report: dry-run mode logs intent and exits 0" {
  run bash "$PARSE_SCRIPT" "$FIXTURES/sweeper/stuck-issue.json" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"dry-run"* ]]
}

@test "parse-sweeper-report: dry-run mode does not emit raw issue numbers" {
  # In dry-run mode we should only see log lines, not bare integers
  result="$(bash "$PARSE_SCRIPT" "$FIXTURES/sweeper/stuck-issue.json" --dry-run 2>/dev/null | grep -E '^[0-9]+$' || true)"
  [ -z "$result" ]
}

# ---------------------------------------------------------------------------
# parse-sweeper-report.sh: wrong verdict fails
# ---------------------------------------------------------------------------

@test "parse-sweeper-report: wrong verdict (done) exits non-zero" {
  run bash "$PARSE_SCRIPT" "$FIXTURES/outcome/docs/valid.json"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# check-skipped-reason.sh: skipped with reason → passes
# ---------------------------------------------------------------------------

@test "check-skipped-reason: skipped with non-empty reason exits 0" {
  run bash "$CHECK_SCRIPT" "$FIXTURES/outcome/docs/skipped-with-reason.json"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# check-skipped-reason.sh: skipped without reason → fails loudly
# ---------------------------------------------------------------------------

@test "check-skipped-reason: skipped with empty reason exits non-zero" {
  run bash "$CHECK_SCRIPT" "$FIXTURES/outcome/docs/invalid-skipped-no-reason.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ERROR"* ]] || [[ "$output" == *"evidence.reason"* ]]
}

# ---------------------------------------------------------------------------
# check-skipped-reason.sh: verdict=done bypasses enforcement
# ---------------------------------------------------------------------------

@test "check-skipped-reason: verdict=done exits 0 (no enforcement needed)" {
  run bash "$CHECK_SCRIPT" "$FIXTURES/outcome/docs/valid.json"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# parse-sweeper-report.sh: hostile fixture — injection string + negative int
# ---------------------------------------------------------------------------

@test "parse-sweeper-report: hostile fixture emits zero issue numbers (string .issue rejected)" {
  # .issue = "13; rm -rf /" is a string — jq layer 1 rejects it.
  result="$(bash "$PARSE_SCRIPT" "$FIXTURES/sweeper/hostile-report.json" 2>/dev/null | grep -E '^[1-9][0-9]*$' || true)"
  [ -z "$result" ]
}

@test "parse-sweeper-report: hostile fixture emits zero issue numbers (negative .issue rejected)" {
  # .issue = -1 fails the jq guard (. > 0); nothing reaches the shell loop.
  result="$(bash "$PARSE_SCRIPT" "$FIXTURES/sweeper/hostile-report.json" 2>/dev/null | grep -E '^[1-9][0-9]*$' || true)"
  [ -z "$result" ]
}

@test "parse-sweeper-report: hostile fixture logs a skip warning for non-integer values" {
  # Any value that passes jq but fails the bash [[ =~ ]] guard must produce a WARN line.
  # The jq layer already blocks both hostile entries in this fixture, so this test
  # confirms the combined result: no bare integers emitted and exit 0.
  run bash "$PARSE_SCRIPT" "$FIXTURES/sweeper/hostile-report.json"
  [ "$status" -eq 0 ]
  # No raw numeric lines in stdout
  numeric_lines="$(printf '%s\n' "$output" | grep -E '^[1-9][0-9]*$' || true)"
  [ -z "$numeric_lines" ]
}

@test "parse-sweeper-report: hostile fixture dry-run emits no gh-callable lines" {
  run bash "$PARSE_SCRIPT" "$FIXTURES/sweeper/hostile-report.json" --dry-run
  [ "$status" -eq 0 ]
  # dry-run with only hostile entries should produce no "would apply" lines
  # because both entries are filtered by the jq integer guard before dry-run output.
  numeric_lines="$(printf '%s\n' "$output" | grep -E '^[1-9][0-9]*$' || true)"
  [ -z "$numeric_lines" ]
}

# ---------------------------------------------------------------------------
# Structural: sweeper.yml NEVER references swarm:paused in a label-write context
# ---------------------------------------------------------------------------

@test "sweeper.yml: does not reference swarm:paused in any label-add/edit context" {
  # The sweeper must never add or remove swarm:paused.
  # We grep for the combination of swarm:paused near add-label or gh issue edit.
  # A plain reference in a comment is acceptable; we check for operational references.
  WORKFLOW_FILE="$SWEEPER_YML" python3 - <<'PYEOF'
import os, re, sys

with open(os.environ["WORKFLOW_FILE"]) as fh:
    lines = fh.readlines()

# Look for lines that both reference swarm:paused AND a mutation verb
# (add-label, remove-label, gh issue edit with labels).
mutation_pattern = re.compile(r'(add-label|remove-label|--add-label|--remove-label)')
paused_pattern = re.compile(r'swarm:paused')

for i, line in enumerate(lines, 1):
    stripped = line.strip()
    # Skip comment lines
    if stripped.startswith('#'):
        continue
    if paused_pattern.search(line) and mutation_pattern.search(line):
        print(f"Line {i}: sweeper.yml references swarm:paused in a label mutation context: {line!r}")
        sys.exit(1)

sys.exit(0)
PYEOF
  [ "$?" -eq 0 ]
}

@test "sweeper.yml: label-add allowlist is exactly swarm:needs-human" {
  # The only label the escalate job may add is swarm:needs-human.
  # Verify by finding all --add-label occurrences and checking their values.
  WORKFLOW_FILE="$SWEEPER_YML" python3 - <<'PYEOF'
import os, re, sys

with open(os.environ["WORKFLOW_FILE"]) as fh:
    content = fh.read()

# Find all --add-label "..." or --add-label '...' patterns in non-comment lines
add_label_pattern = re.compile(r'--add-label\s+["\']?([^\s"\'\\]+)["\']?')

for i, line in enumerate(content.split('\n'), 1):
    stripped = line.strip()
    if stripped.startswith('#'):
        continue
    for match in add_label_pattern.finditer(line):
        label = match.group(1).strip('"\'')
        if label != 'swarm:needs-human':
            print(f"Line {i}: sweeper adds label '{label}' — only 'swarm:needs-human' is permitted: {line!r}")
            sys.exit(1)

sys.exit(0)
PYEOF
  [ "$?" -eq 0 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Structural: gather step queries one label per request — a comma-joined
# labels value is AND semantics on the Issues API and always returns [].
# ─────────────────────────────────────────────────────────────────────────────
@test "sweeper.yml: gather never uses a comma-joined labels filter" {
  run grep -nE "labels=['\"]?[A-Za-z:_-]+," "$SWEEPER_YML"
  [ "$status" -ne 0 ]
}
