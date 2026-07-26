#!/usr/bin/env bash
# transition.sh — atomic swarm stage-label swap.
# Called by actions/transition/action.yml; all inputs arrive via env vars.
#
# Required env:
#   ISSUE_NUMBER       — GitHub issue number (integer)
#   FROM_STAGE         — stage label to remove  (must be in ALLOWED_STAGES)
#   TO_STAGE           — stage label to add     (must be in ALLOWED_STAGES)
#   GH_TOKEN           — GitHub token with issues:write scope
#   GITHUB_REPOSITORY  — owner/repo
#
# Optional env:
#   POST_COMMENT       — "true" (default) or "false"
set -euo pipefail

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
# Notify hook (stub until #4 lands)
# ---------------------------------------------------------------------------
if [ -d "${GITHUB_ACTION_PATH:-}/../notify" ] || command -v notify >/dev/null 2>&1; then
  notify \
    --event "stage_transition" \
    --issue "${ISSUE_NUMBER}" \
    --from "${FROM_STAGE}" \
    --to "${TO_STAGE}" \
    --repo "${GITHUB_REPOSITORY}" || true
else
  echo "transition: notify: stub (#4 pending)"
fi

echo "transition: done — issue #${ISSUE_NUMBER} transitioned '${FROM_STAGE}' → '${TO_STAGE}'."
