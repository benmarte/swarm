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
  # Layer 1 (jq): only emit entries whose .issue is a positive integer.
  # select(type == "number" and . > 0 and . == floor) rejects strings,
  # floats, negatives, and zero before they ever reach the shell.
  jq -r '.evidence.stuck[] |
    select(.recommendation == "escalate") |
    select(.issue | type == "number" and . > 0 and . == floor) |
    "dry-run: would apply swarm:needs-human to issue #\(.issue) " +
    "(stage=\(.stage_label), age=\(.age_hours)h)"' "$OUTCOME_FILE"
  exit 0
fi

# Emit issue numbers for escalation (recommendation=escalate only).
# Layer 1 (jq): select(type == "number" and . > 0 and . == floor) — rejects
#   strings (injection payloads), floats, negatives, and zero.
# Layer 2 (bash): [[ =~ ^[1-9][0-9]*$ ]] — belt-and-suspenders; skips
#   anything that slipped through or was produced by an unexpected jq path,
#   with a loud log so the anomaly is never silent.
jq -r '.evidence.stuck[] |
  select(.recommendation == "escalate") |
  select(.issue | type == "number" and . > 0 and . == floor) |
  (.issue | tostring)' "$OUTCOME_FILE" | while IFS= read -r raw_num; do
  if [[ "$raw_num" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s\n' "$raw_num"
  else
    printf 'WARN: parse-sweeper-report: skipping non-integer issue value: %s\n' "$raw_num" >&2
  fi
done
