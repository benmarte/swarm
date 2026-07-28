#!/usr/bin/env bash
# bump-attempts.sh — reads/increments swarm:attempts:N; escalates at N=3.
# Called by actions/bump-attempts/action.yml; all inputs arrive via env vars.
#
# Required env:
#   ISSUE_NUMBER       — GitHub issue number (integer)
#   MAINTAINER         — GitHub username to assign at escalation
#   GH_TOKEN           — GitHub token with issues:write scope (fallback)
#   GITHUB_REPOSITORY  — owner/repo
#
# Optional env:
#   SWARM_TOKEN        — fine-grained PAT (preferred over GH_TOKEN so that
#                        label writes are authored by a distinct actor.
#                        When absent, GH_TOKEN is used with a warning.)
#   POST_COMMENT       — "true" (default) or "false"
#   ENABLED_SINKS      — comma-separated sink list (e.g. "slack,buzz"); empty disables notify
#   BUZZ_CHANNEL       — NIP-29 channel UUID (required when buzz is in ENABLED_SINKS)
#   SWARM_SLACK_WEBHOOK, SWARM_DISCORD_WEBHOOK, SWARM_TEAMS_WEBHOOK,
#   SWARM_BUZZ_RELAY_URL, SWARM_BUZZ_PRIVATE_KEY — per-sink credentials
set -euo pipefail

# ---------------------------------------------------------------------------
# Token selection: prefer SWARM_TOKEN (PAT) for a distinct actor on label
# writes and escalation. Fall back to GH_TOKEN (GITHUB_TOKEN) with a warning.
# ---------------------------------------------------------------------------
if [ -n "${SWARM_TOKEN:-}" ]; then
  GH_TOKEN="$SWARM_TOKEN"
else
  echo "bump-attempts: WARNING: SWARM_TOKEN not set — falling back to GITHUB_TOKEN." >&2
  echo "bump-attempts: WARNING: Stage cascade will NOT trigger the next workflow without a PAT." >&2
  echo "bump-attempts: WARNING: See docs/adopting.md#swarm-token for required scopes." >&2
fi
export GH_TOKEN

# ---------------------------------------------------------------------------
# Attempts config
# ---------------------------------------------------------------------------
ATTEMPT_LIMIT=3

# ---------------------------------------------------------------------------
# Validate inputs — hard-fail before any gh call (SPEC §6)
# ---------------------------------------------------------------------------
if [ -z "${ISSUE_NUMBER:-}" ]; then
  echo "bump-attempts: ERROR: ISSUE_NUMBER is required" >&2
  exit 1
fi

# ISSUE_NUMBER must be a positive integer (guards URL path injection)
if [[ ! "${ISSUE_NUMBER}" =~ ^[1-9][0-9]*$ ]]; then
  echo "bump-attempts: ERROR: ISSUE_NUMBER must be a positive integer, got: '${ISSUE_NUMBER}'" >&2
  exit 1
fi

if [ -z "${MAINTAINER:-}" ]; then
  echo "bump-attempts: ERROR: MAINTAINER is required" >&2
  exit 1
fi

# MAINTAINER must match GitHub username charset (guards --field body injection)
if [[ ! "${MAINTAINER}" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}$ ]]; then
  echo "bump-attempts: ERROR: MAINTAINER is not a valid GitHub username: '${MAINTAINER}'" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Fetch current labels
# ---------------------------------------------------------------------------
echo "bump-attempts: fetching labels for issue #${ISSUE_NUMBER}..."
current_labels=$(gh api \
  "/repos/${GITHUB_REPOSITORY}/issues/${ISSUE_NUMBER}/labels" \
  --jq '.[].name')

# Determine current attempt count and current stage from labels (0 / "unknown" if none found)
current_n=0
current_label=""
current_stage="unknown"

while IFS= read -r label; do
  case "$label" in
    swarm:attempts:1) current_n=1; current_label="swarm:attempts:1" ;;
    swarm:attempts:2) current_n=2; current_label="swarm:attempts:2" ;;
    swarm:attempts:3) current_n=3; current_label="swarm:attempts:3" ;;
    swarm:go|swarm:spec|swarm:develop|swarm:qa|swarm:docs|swarm:done|swarm:needs-human|swarm:paused)
      current_stage="$label" ;;
  esac
done <<< "$current_labels"

echo "bump-attempts: current attempts = ${current_n}"

# ---------------------------------------------------------------------------
# Already at limit — no further increment; escalation is terminal
# ---------------------------------------------------------------------------
if [ "$current_n" -ge "$ATTEMPT_LIMIT" ]; then
  echo "bump-attempts: already at attempt limit (${ATTEMPT_LIMIT}); escalation already applied."
  printf 'needs-human=true\n' >> "${GITHUB_OUTPUT:-/dev/null}"
  printf 'attempt-count=%s\n' "$ATTEMPT_LIMIT" >> "${GITHUB_OUTPUT:-/dev/null}"
  exit 0
fi

# ---------------------------------------------------------------------------
# Compute next attempt
# ---------------------------------------------------------------------------
next_n=$((current_n + 1))
next_label="swarm:attempts:${next_n}"

# Remove current attempts label (if any)
if [ -n "$current_label" ]; then
  echo "bump-attempts: removing label '${current_label}' from issue #${ISSUE_NUMBER}..."
  gh api \
    --method DELETE \
    "/repos/${GITHUB_REPOSITORY}/issues/${ISSUE_NUMBER}/labels/${current_label}"
fi

# Add next attempts label
echo "bump-attempts: adding label '${next_label}' to issue #${ISSUE_NUMBER}..."
gh api \
  --method POST \
  "/repos/${GITHUB_REPOSITORY}/issues/${ISSUE_NUMBER}/labels" \
  --field "labels[]=${next_label}"

echo "bump-attempts: attempts now at ${next_n}."

# ---------------------------------------------------------------------------
# Escalation at limit
# ---------------------------------------------------------------------------
if [ "$next_n" -lt "$ATTEMPT_LIMIT" ]; then
  printf 'needs-human=false\n' >> "${GITHUB_OUTPUT:-/dev/null}"
  printf 'attempt-count=%s\n' "$next_n" >> "${GITHUB_OUTPUT:-/dev/null}"
fi

if [ "$next_n" -eq "$ATTEMPT_LIMIT" ]; then
  echo "bump-attempts: limit reached — escalating issue #${ISSUE_NUMBER}..."

  # Apply swarm:needs-human
  gh api \
    --method POST \
    "/repos/${GITHUB_REPOSITORY}/issues/${ISSUE_NUMBER}/labels" \
    --field "labels[]=swarm:needs-human"

  # Assign the maintainer
  gh api \
    --method POST \
    "/repos/${GITHUB_REPOSITORY}/issues/${ISSUE_NUMBER}/assignees" \
    --field "assignees[]=${MAINTAINER}"

  # Emit escalation event JSON
  event_json=$(jq -n \
    --arg event "escalation" \
    --arg repo "${GITHUB_REPOSITORY}" \
    --argjson issue "${ISSUE_NUMBER}" \
    --argjson pr "null" \
    --arg stage_from "${current_stage}" \
    --arg stage_to "swarm:needs-human" \
    --arg actor "${MAINTAINER}" \
    --arg url "https://github.com/${GITHUB_REPOSITORY}/issues/${ISSUE_NUMBER}" \
    --arg summary "Attempt limit (${ATTEMPT_LIMIT}) reached — human intervention required." \
    '{event: $event, repo: $repo, issue: $issue, pr: $pr, stage_from: $stage_from, stage_to: $stage_to, actor: $actor, url: $url, summary: $summary}')

  echo "bump-attempts: escalation event:"
  echo "$event_json"

  # Write event to file for notify to consume
  _escalation_event_file="${RUNNER_TEMP:-/tmp}/escalation-event.json"
  echo "$event_json" > "$_escalation_event_file"

  # Post escalation comment
  POST_COMMENT="${POST_COMMENT:-true}"
  if [ "$POST_COMMENT" = "true" ]; then
    comment_body="**swarm escalation:** attempt limit (${ATTEMPT_LIMIT}) reached. @${MAINTAINER} — human intervention required. Label: \`swarm:needs-human\`."
    echo "bump-attempts: posting escalation comment..."
    gh api \
      --method POST \
      "/repos/${GITHUB_REPOSITORY}/issues/${ISSUE_NUMBER}/comments" \
      --field "body=${comment_body}"
  fi

  # Notify fan-out (wired via ENABLED_SINKS; no-op when empty)
  # NOTIFY_SCRIPT defaults to the notify.sh sitting next to this action.
  # Tests can override it via NOTIFY_SCRIPT=<stub-path> to keep bats hermetic.
  NOTIFY_SCRIPT="${NOTIFY_SCRIPT:-${GITHUB_ACTION_PATH:-$(cd "$(dirname "$0")" && pwd)}/../notify/notify.sh}"

  if [ -n "${ENABLED_SINKS:-}" ] && [ -f "$NOTIFY_SCRIPT" ]; then
    echo "bump-attempts: notify: fanning out to sinks: ${ENABLED_SINKS}"
    # Notify failures must NEVER block the pipeline — log a warning and continue.
    if ! EVENT_FILE="$_escalation_event_file" bash "$NOTIFY_SCRIPT"; then
      echo "bump-attempts: WARNING: notify fan-out failed (sinks: ${ENABLED_SINKS}) — escalation complete, notifications not delivered" >&2
    fi
  else
    echo "bump-attempts: notify: no sinks configured (ENABLED_SINKS not set)"
  fi

  printf 'needs-human=true\n' >> "${GITHUB_OUTPUT:-/dev/null}"
  printf 'attempt-count=%s\n' "$next_n" >> "${GITHUB_OUTPUT:-/dev/null}"
  echo "bump-attempts: escalation complete — issue #${ISSUE_NUMBER} needs human attention."
fi
