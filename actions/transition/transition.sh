#!/usr/bin/env bash
# transition.sh — atomic swarm stage-label swap.
# Called by actions/transition/action.yml; all inputs arrive via env vars.
#
# Required env:
#   ISSUE_NUMBER       — GitHub issue number (integer)
#   FROM_STAGE         — stage label to remove  (must be in ALLOWED_STAGES)
#   TO_STAGE           — stage label to add     (must be in ALLOWED_STAGES)
#   GH_TOKEN           — GitHub token with issues:write scope (fallback)
#   GITHUB_REPOSITORY  — owner/repo
#
# Optional env:
#   SWARM_TOKEN        — fine-grained PAT (preferred over GH_TOKEN so that the
#                        label event is authored by a distinct actor and triggers
#                        the next stage workflow. When absent, GH_TOKEN is used
#                        but a cascade warning is emitted.)
#   POST_COMMENT       — "true" (default) or "false"
set -euo pipefail

# ---------------------------------------------------------------------------
# Token selection: prefer SWARM_TOKEN (PAT) so label writes trigger cascades.
# Fall back to GH_TOKEN (GITHUB_TOKEN) with a loud warning — GitHub suppresses
# workflow triggers for events caused by GITHUB_TOKEN (recursion guard), so
# stage cascade will stop without a PAT.
# ---------------------------------------------------------------------------
if [ -n "${SWARM_TOKEN:-}" ]; then
  GH_TOKEN="$SWARM_TOKEN"
else
  echo "transition: WARNING: SWARM_TOKEN not set — falling back to GITHUB_TOKEN for label writes." >&2
  echo "transition: WARNING: Stage cascade will NOT trigger the next workflow without a PAT." >&2
  echo "transition: WARNING: See docs/adopting.md#swarm-token for required scopes." >&2
fi
export GH_TOKEN

# ---------------------------------------------------------------------------
# Stage label allowlist — SPEC §2.1 / §6: no unvalidated interpolation
# ---------------------------------------------------------------------------
ALLOWED_STAGES="swarm:go swarm:spec swarm:develop swarm:qa swarm:docs swarm:done swarm:needs-human swarm:paused"

is_allowed_stage() {
  local label="$1"
  local stage
  for stage in $ALLOWED_STAGES; do
    if [ "$label" = "$stage" ]; then
      return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# Validate inputs before any gh call (SPEC §6)
# ---------------------------------------------------------------------------
if [ -z "${ISSUE_NUMBER:-}" ]; then
  echo "transition: ERROR: ISSUE_NUMBER is required" >&2
  exit 1
fi

# ISSUE_NUMBER must be a positive integer (guards URL path injection)
if [[ ! "${ISSUE_NUMBER}" =~ ^[1-9][0-9]*$ ]]; then
  echo "transition: ERROR: ISSUE_NUMBER must be a positive integer, got: '${ISSUE_NUMBER}'" >&2
  exit 1
fi

if [ -z "${FROM_STAGE:-}" ]; then
  echo "transition: ERROR: FROM_STAGE is required" >&2
  exit 1
fi

if [ -z "${TO_STAGE:-}" ]; then
  echo "transition: ERROR: TO_STAGE is required" >&2
  exit 1
fi

if ! is_allowed_stage "$FROM_STAGE"; then
  echo "transition: ERROR: '$FROM_STAGE' is not a valid swarm stage label." >&2
  echo "  Allowed: $ALLOWED_STAGES" >&2
  exit 1
fi

if ! is_allowed_stage "$TO_STAGE"; then
  echo "transition: ERROR: '$TO_STAGE' is not a valid swarm stage label." >&2
  echo "  Allowed: $ALLOWED_STAGES" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Fetch current labels for idempotency check
# ---------------------------------------------------------------------------
echo "transition: fetching labels for issue #${ISSUE_NUMBER}..."
current_labels=$(gh api \
  "/repos/${GITHUB_REPOSITORY}/issues/${ISSUE_NUMBER}/labels" \
  --jq '.[].name')

has_from=false
has_to=false

while IFS= read -r label; do
  if [ "$label" = "$FROM_STAGE" ]; then has_from=true; fi
  if [ "$label" = "$TO_STAGE" ]; then has_to=true; fi
done <<< "$current_labels"

# ---------------------------------------------------------------------------
# Idempotency: already in to-stage (and from-stage gone) → no-op
# ---------------------------------------------------------------------------
if [ "$has_to" = "true" ] && [ "$has_from" = "false" ]; then
  echo "transition: no-op — issue #${ISSUE_NUMBER} already has '${TO_STAGE}' and '${FROM_STAGE}' is absent."
  exit 0
fi

# ---------------------------------------------------------------------------
# Atomic swap: remove old, add new
# ---------------------------------------------------------------------------
if [ "$has_from" = "true" ]; then
  echo "transition: removing label '${FROM_STAGE}' from issue #${ISSUE_NUMBER}..."
  gh api \
    --method DELETE \
    "/repos/${GITHUB_REPOSITORY}/issues/${ISSUE_NUMBER}/labels/${FROM_STAGE}"
else
  echo "transition: WARNING: '${FROM_STAGE}' was not found on issue #${ISSUE_NUMBER}; skipping remove."
fi

echo "transition: adding label '${TO_STAGE}' to issue #${ISSUE_NUMBER}..."
gh api \
  --method POST \
  "/repos/${GITHUB_REPOSITORY}/issues/${ISSUE_NUMBER}/labels" \
  --field "labels[]=${TO_STAGE}"

# ---------------------------------------------------------------------------
# Post transition comment
# ---------------------------------------------------------------------------
POST_COMMENT="${POST_COMMENT:-true}"
if [ "$POST_COMMENT" = "true" ]; then
  comment_body="**swarm transition:** \`${FROM_STAGE}\` → \`${TO_STAGE}\`"
  echo "transition: posting transition comment..."
  gh api \
    --method POST \
    "/repos/${GITHUB_REPOSITORY}/issues/${ISSUE_NUMBER}/comments" \
    --field "body=${comment_body}"
fi

# ---------------------------------------------------------------------------
# Notify fan-out
# ---------------------------------------------------------------------------
# NOTIFY_SCRIPT defaults to the real notify.sh sitting next to this action.
# Tests can override it via NOTIFY_SCRIPT=<stub-path> to keep bats hermetic.
NOTIFY_SCRIPT="${NOTIFY_SCRIPT:-${GITHUB_ACTION_PATH:-$(cd "$(dirname "$0")" && pwd)}/../notify/notify.sh}"

if [ -n "${ENABLED_SINKS:-}" ] && [ -f "$NOTIFY_SCRIPT" ]; then
  # Build the canonical event JSON and pass it to the notify action script.
  EVENT_FILE="$(mktemp)"
  jq -n \
    --arg event "stage_transition" \
    --arg repo "${GITHUB_REPOSITORY}" \
    --argjson issue "${ISSUE_NUMBER}" \
    --arg stage_from "${FROM_STAGE}" \
    --arg stage_to "${TO_STAGE}" \
    --arg actor "${GITHUB_ACTOR:-swarm}" \
    --arg url "https://github.com/${GITHUB_REPOSITORY}/issues/${ISSUE_NUMBER}" \
    --arg summary "Issue #${ISSUE_NUMBER}: ${FROM_STAGE} → ${TO_STAGE}" \
    '{
      event: $event,
      repo: $repo,
      issue: $issue,
      pr: null,
      stage_from: $stage_from,
      stage_to: $stage_to,
      actor: $actor,
      url: $url,
      summary: $summary
    }' > "$EVENT_FILE"
  EVENT_FILE="$EVENT_FILE" bash "$NOTIFY_SCRIPT"
  rm -f "$EVENT_FILE"
else
  echo "transition: notify: no sinks configured (ENABLED_SINKS not set)"
fi

echo "transition: done — issue #${ISSUE_NUMBER} transitioned '${FROM_STAGE}' → '${TO_STAGE}'."
