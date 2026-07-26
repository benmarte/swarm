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
  bats -r tests
fi

echo "verify: OK"
