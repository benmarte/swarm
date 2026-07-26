#!/usr/bin/env bash
# check-skipped-reason.sh — enforce that a docs outcome with verdict=skipped
# carries a non-empty evidence.reason.
#
# Usage: check-skipped-reason.sh <outcome-file>
#   outcome-file: path to a validated outcome.json
#
# Exit codes:
#   0  — verdict is not skipped, OR verdict is skipped and reason is non-empty
#   1  — verdict is skipped AND reason is empty or absent (enforcement failure)
#
# This script is invoked from docs.yml after validate-outcome passes, and is
# also imported directly by tests/sweeper.bats for unit testing.
set -euo pipefail

OUTCOME_FILE="${1:-outcome.json}"

if [ ! -f "$OUTCOME_FILE" ]; then
  printf 'ERROR: outcome file not found: %s\n' "$OUTCOME_FILE" >&2
  exit 1
fi

verdict="$(jq -r '.verdict' "$OUTCOME_FILE" | tr -d '\n\r')"

if [ "$verdict" != "skipped" ]; then
  # Not a skipped verdict — nothing to enforce.
  exit 0
fi

reason="$(jq -r '.evidence.reason // ""' "$OUTCOME_FILE" | tr -d '\n\r')"

if [ -z "$reason" ]; then
  printf 'ERROR: docs verdict=skipped requires a non-empty evidence.reason.\n' >&2
  printf 'A skipped verdict without a reason is invalid — the docs agent must\n' >&2
  printf 'explain why documentation was not needed for this change.\n' >&2
  exit 1
fi

printf 'check-skipped-reason: verdict=skipped, reason present — OK\n'
exit 0
