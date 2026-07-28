#!/usr/bin/env bash
# Verify gate — run by CI and by the Talos pipeline before any PR opens.
# Each tool runs only over files that exist, so the gate works from the first
# scaffold commit onward. A missing TOOL is a hard failure, not a skip: a
# silently-skipped gate reads as "passed" and that class of bug is exactly
# what this project exists to kill.
# Portable to macOS bash 3.2 — no mapfile/arrays required.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "verify: '$1' is required but not installed (brew install $2)" >&2
    exit 1
  }
}

sh_files=$(git ls-files '*.sh' | grep -v '^\.claude/')
if [ -n "$sh_files" ]; then
  need shellcheck shellcheck
  echo "verify: shellcheck $(echo "$sh_files" | wc -l | tr -d ' ') file(s)"
  # shellcheck disable=SC2086  # repo policy: no spaces in tracked filenames
  shellcheck $sh_files
fi

wf_files=$(git ls-files '.github/workflows/*.yml' 'workflows/*.yml')
if [ -n "$wf_files" ]; then
  need actionlint actionlint
  echo "verify: actionlint $(echo "$wf_files" | wc -l | tr -d ' ') file(s)"
  # shellcheck disable=SC2086
  actionlint $wf_files
fi

if [ -d tests ] && git ls-files 'tests/*.bats' 'tests/**/*.bats' | grep -q .; then
  need bats bats-core
  echo "verify: bats"

  # Run bats through a tee so the plan line can be checked afterwards.
  #
  # A bats test that uses `trap ... EXIT` in its body VANISHES from TAP output
  # when it fails — no `ok`, no `not ok`. bats exits 0 and the only evidence is
  # a "Executed N instead of expected M" warning on stderr. Without this check
  # a failing test reads as a slightly shorter successful run. See #77.
  #
  # Rather than grep for that one warning string, compare the declared plan
  # (`1..N`) against the number of result lines. That catches any cause of a
  # missing result, including ones bats does not warn about.
  bats_log="$(mktemp)"
  bats_status=0
  # Redirect rather than pipe. With `cmd | tee`, `$?` is tee's status, and
  # reading PIPESTATUS afterwards does not work either: the `|| assignment`
  # that captures the failure is itself a simple command, which overwrites
  # PIPESTATUS with its own success. That silently masked genuine test
  # failures as "verify: OK" — caught by the deliberate-failure test below.
  bats -r tests > "$bats_log" 2>&1 || bats_status=$?
  cat "$bats_log"

  planned="$(grep -Eo '^1\.\.[0-9]+' "$bats_log" | head -1 | cut -d. -f3)"
  reported="$(grep -Ec '^(ok|not ok) ' "$bats_log" || true)"
  rm -f "$bats_log"

  # Check the plan mismatch BEFORE the exit status: bats also exits non-zero
  # when tests vanish, and the generic "bats exited N" message would bury the
  # far more useful diagnostic.
  if [ -n "$planned" ] && [ "$reported" -ne "$planned" ]; then
    echo "verify: FAILED — bats planned ${planned} test(s) but reported ${reported}." >&2
    echo "  $((planned - reported)) test(s) vanished from TAP output instead of failing." >&2
    echo "  Most likely cause: 'trap ... EXIT' inside a @test body (see #77)." >&2
    exit 1
  fi

  if [ "$bats_status" -ne 0 ]; then
    echo "verify: FAILED — bats exited $bats_status" >&2
    exit "$bats_status"
  fi

  if [ -z "$planned" ]; then
    echo "verify: FAILED — bats printed no TAP plan line; cannot confirm every test ran" >&2
    exit 1
  fi

  echo "verify: bats ${reported}/${planned} accounted for"
fi

echo "verify: OK"
