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

@test "suite: no unbound mid-body '[[ ]]' assertion (#78)" {
  # A `[[ ]]` that is not the final command of its test body can be FALSE and
  # the test still reports ok. `[ ]`, `false` and failing commands all abort
  # correctly — the exemption is specific to `[[ ]]`.
  #
  #   @test "x" { [[ "abc" == "xyz" ]]; true; }   ->  ok
  #
  # 118 of 242 assertions in this suite were in that state. Binding them found
  # exactly one that was actually false (a whoami check that could never hold),
  # which is the point: an assertion that cannot fail also cannot tell you it
  # is wrong.
  #
  # Mid-body `[[ ]]` must therefore end with `|| false` or `|| return 1`.
  run python3 - "$REPO_ROOT" <<'PYEOF'
import re, sys, glob, os
root = sys.argv[1]
bad = []
for path in sorted(glob.glob(os.path.join(root, 'tests', '*.bats'))):
    lines = open(path).read().split('\n')
    i = 0
    while i < len(lines):
        if lines[i].startswith('@test '):
            j = i + 1
            body = []
            while j < len(lines) and lines[j] != '}':
                body.append((j, lines[j])); j += 1
            ex = [(n, l) for n, l in body if l.strip() and not l.strip().startswith('#')]
            last = ex[-1][0] if ex else None
            for n, l in ex:
                if not re.match(r'^\s*\[\[', l) or n == last:
                    continue
                # A line continuing into the next (|| \ or trailing &&) is part
                # of a larger construct; judge that construct by its final line.
                if l.rstrip().endswith('\\') or not l.rstrip().endswith((']]', 'false', 'return 1')):
                    continue
                if re.search(r'\|\|\s*(false|return 1)\s*$', l):
                    continue
                bad.append(f"{os.path.relpath(path, root)}:{n+1}: {l.strip()[:80]}")
            i = j
        i += 1
if bad:
    print("unbound mid-body [[ ]] assertion(s) — append '|| false':")
    print("\n".join(bad))
    sys.exit(1)
PYEOF
  [ "$status" -eq 0 ] || {
    echo "$output" | sed 's/^/# /' >&3
    false
  }
}
