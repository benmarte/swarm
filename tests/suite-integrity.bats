#!/usr/bin/env bats
# suite-integrity.bats — tests about the test suite itself.
#
# Everything here guards against tests that report success without testing
# anything. That class has bitten this repo three times: a stub invocation
# counter that miscounted when prompt text contained a matching line, an
# assertion of the form `[[ ... ]] || [[ ... ]] || true` that could never fail,
# and the trap-EXIT drop below. All three were invisible to a green suite.

REPO_ROOT="$(git -C "$(dirname "$BATS_TEST_FILENAME")" rev-parse --show-toplevel)"

@test "suite: no 'trap ... EXIT' inside a bats test body (#77)" {
  # bats 1.14 drops a FAILING test from TAP output entirely when its body sets
  # an EXIT trap — no 'ok', no 'not ok', just a trailing warning that is easy
  # to miss. The failure becomes a slightly shorter successful-looking run.
  #
  # Cleanup belongs in teardown(), which bats runs on both pass and fail.
  #
  # Matches executable lines only; the explanatory comments in teardown()
  # mention the pattern by name and must not trip this.
  run grep -rnE '^[[:space:]]*trap[[:space:]].*EXIT' "$REPO_ROOT"/tests/*.bats
  [ "$status" -ne 0 ] || {
    echo "# trap ... EXIT found in a test file — move cleanup to teardown():" >&3
    echo "$output" | sed 's/^/# /' >&3
    false
  }
}

@test "suite: verify.sh reconciles the bats plan against reported results (#77)" {
  # The durable half of #77. Without this reconciliation a vanished test is
  # indistinguishable from a shorter suite, so any future cause of a missing
  # result — not just trap-EXIT — would pass silently.
  run grep -q 'vanished from TAP output' "$REPO_ROOT/scripts/verify.sh"
  [ "$status" -eq 0 ]

  run grep -qE 'planned|1\\\.\\\.' "$REPO_ROOT/scripts/verify.sh"
  [ "$status" -eq 0 ]
}

@test "suite: no unfailable '|| true' tail on an assertion (#77)" {
  # `[[ cond ]] || true` always succeeds, so the assertion is decorative.
  # Legitimate uses of `|| true` exist for cleanup and command substitution,
  # so this only matches a `|| true` that terminates a [[ ]] or [ ] test.
  # Strip trailing comments before matching, so `|| true # reason` cannot slip
  # past; loop per file so the report names the file, not just a line number.
  run bash -c 'for f in "$1"/tests/*.bats; do sed -E "s/[[:space:]]+#.*\$//" "$f" | grep -nE "^[[:space:]]*(\[\[.*\]\]|\[.*\]).*\|\|[[:space:]]+true[[:space:]]*\$" | sed "s|^|$f:|"; done' _ "$REPO_ROOT"
  # Assert on OUTPUT, not exit status: each per-file pipeline ends in `sed`,
  # which succeeds whether or not grep matched, so the status is always 0.
  [ -z "$output" ] || {
    echo "# unfailable assertion(s) — the '|| true' makes these always pass:" >&3
    echo "$output" | sed 's/^/# /' >&3
    false
  }
}
