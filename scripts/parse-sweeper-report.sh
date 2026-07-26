#!/usr/bin/env bash
# parse-sweeper-report.sh — parse an orchestrator outcome.json and emit a
# newline-delimited list of issue numbers from evidence.stuck[] that have
# recommendation=escalate.
#
# Usage: parse-sweeper-report.sh <outcome-file> [--dry-run]
#   outcome-file: path to a validated orchestrator outcome.json
#   --dry-run:    log intent only, do not emit issue numbers for mutation
#
# Output (non-dry-run):
#   One integer per line — the issue number for each stuck issue with
#   recommendation=escalate.  Empty output means no issues to escalate.
#
# Output (dry-run):
#   Human-readable log lines only; exit 0.
#
# This script is imported by tests/sweeper.bats for unit testing of the
# parsing / filtering logic without running the full sweeper workflow.
set -euo pipefail

OUTCOME_FILE="${1:-outcome.json}"
DRY_RUN="${2:-}"

if [ ! -f "$OUTCOME_FILE" ]; then
  printf 'ERROR: outcome file not found: %s\n' "$OUTCOME_FILE" >&2
  exit 1
fi

verdict="$(jq -r '.verdict' "$OUTCOME_FILE" | tr -d '\n\r')"
if [ "$verdict" != "report" ]; then
  printf 'ERROR: expected orchestrator verdict=report, got: %s\n' "$verdict" >&2
  exit 1
fi

summary="$(jq -r '.evidence.summary // ""' "$OUTCOME_FILE" | tr -d '\n\r')"
printf 'sweeper: %s\n' "$summary"

stuck_count="$(jq '.evidence.stuck | length' "$OUTCOME_FILE")"
printf 'sweeper: %s stuck issue(s) in report\n' "$stuck_count"

if [ "$DRY_RUN" = "--dry-run" ]; then
  jq -r '.evidence.stuck[] | select(.recommendation == "escalate") |
    "dry-run: would apply swarm:needs-human to issue #\(.issue) " +
    "(stage=\(.stage_label), age=\(.age_hours)h)"' "$OUTCOME_FILE"
  exit 0
fi

# Emit issue numbers for escalation (recommendation=escalate only).
# One integer per line. Paused issues should never appear in evidence.stuck per
# prompt instructions; this is belt-and-suspenders only.
jq -r '.evidence.stuck[] |
  select(.recommendation == "escalate") |
  (.issue | tostring)' "$OUTCOME_FILE" || true
