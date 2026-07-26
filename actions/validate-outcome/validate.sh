#!/usr/bin/env bash
# validate.sh — validates an outcome JSON file against outcome.schema.json.
# Usage: validate.sh <outcome-file> <schema-file>
# Exit 0 = valid; exit 1 = invalid (actionable error to stderr).
# Never mutates state.
set -euo pipefail

OUTCOME_FILE="${1:?outcome-file argument is required}"
SCHEMA_FILE="${2:?schema-file argument is required}"

if [ ! -f "$OUTCOME_FILE" ]; then
  echo "validate-outcome: ERROR: outcome file not found: $OUTCOME_FILE" >&2
  echo "  The agent adapter must write outcome.json before exiting." >&2
  exit 1
fi

if [ ! -f "$SCHEMA_FILE" ]; then
  echo "validate-outcome: ERROR: schema file not found: $SCHEMA_FILE" >&2
  exit 1
fi

echo "validate-outcome: validating '$OUTCOME_FILE' against '$SCHEMA_FILE'"

if ! output=$(ajv validate -s "$SCHEMA_FILE" -d "$OUTCOME_FILE" 2>&1); then
  echo "" >&2
  echo "validate-outcome: FAILED — outcome.json did not pass schema validation." >&2
  echo "" >&2
  echo "Schema: $SCHEMA_FILE" >&2
  echo "File:   $OUTCOME_FILE" >&2
  echo "" >&2
  echo "Validation errors:" >&2
  echo "$output" >&2
  echo "" >&2
  echo "Fix the agent adapter so it emits a schema-valid outcome.json." >&2
  echo "See schemas/outcome.schema.json for required fields and per-role verdict enums." >&2
  exit 1
fi

echo "validate-outcome: OK — outcome.json is valid."
