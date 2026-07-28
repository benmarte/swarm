#!/usr/bin/env bash
# emit-role-event.sh — build and fan-out a ROLE event JSON to configured sinks.
#
# Emits a rich findings event (role, verdict, evidence) so that notification
# templates (templates/notifications/<role>.md) fire with evidence bullets.
# Failures are non-fatal — a WARNING is logged but the pipeline continues.
#
# Required env:
#   ROLE              — agent role: validator|pm|developer|qa|reviewer|security|docs|orchestrator
#   VERDICT           — outcome verdict string (e.g. confirmed, approved, pass)
#   GITHUB_REPOSITORY — owner/repo string
#   ISSUE_NUMBER      — GitHub issue number (positive integer)
#   URL               — full URL for the event (issue or PR)
#
# Optional env:
#   SUMMARY           — single-line summary (defaults to "ROLE VERDICT" if absent)
#   DETAILS           — newline-separated evidence lines (format: "- **key:** value")
#   PR_NUMBER         — PR number (integer); omit or empty for null
#   STAGE_FROM        — stage label before transition (default: "")
#   STAGE_TO          — stage label after transition (default: "")
#   ACTOR             — GitHub actor login (defaults to GITHUB_ACTOR env or "swarm")
#   ENABLED_SINKS     — comma-separated sinks (slack,buzz,discord,teams)
#   BUZZ_CHANNEL      — NIP-29 channel UUID for the buzz adapter
#   SLACK_CHANNEL     — Slack channel ID for bot-token mode
#   DISCORD_CHANNEL   — Discord channel ID for bot-token mode
#   NOTIFY_SCRIPT     — override path to notify.sh (auto-detected by default)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
_emit_err()  { printf 'emit-role-event: ERROR: %s\n' "$*" >&2; exit 1; }
_emit_warn() { printf 'emit-role-event: WARNING: %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# Input validation
# ---------------------------------------------------------------------------
[ -n "${ROLE:-}"              ] || _emit_err "ROLE is required"
[ -n "${VERDICT:-}"           ] || _emit_err "VERDICT is required"
[ -n "${GITHUB_REPOSITORY:-}" ] || _emit_err "GITHUB_REPOSITORY is required"
[ -n "${ISSUE_NUMBER:-}"      ] || _emit_err "ISSUE_NUMBER is required"
[ -n "${URL:-}"               ] || _emit_err "URL is required"

# ISSUE_NUMBER must be a positive integer (guards jq --argjson injection)
if ! printf '%s' "${ISSUE_NUMBER}" | grep -qE '^[1-9][0-9]*$'; then
  _emit_err "ISSUE_NUMBER must be a positive integer, got: '${ISSUE_NUMBER}'"
fi

ACTOR="${ACTOR:-${GITHUB_ACTOR:-swarm}}"
STAGE_FROM="${STAGE_FROM:-}"
STAGE_TO="${STAGE_TO:-}"
SUMMARY="${SUMMARY:-}"
DETAILS="${DETAILS:-}"

# PR_NUMBER: use integer value if valid, otherwise null
if [ -n "${PR_NUMBER:-}" ] && printf '%s' "${PR_NUMBER}" | grep -qE '^[0-9]+$'; then
  pr_json="${PR_NUMBER}"
else
  pr_json="null"
fi

# ---------------------------------------------------------------------------
# Build evidence array
#
# Each item is gsub-flattened (newlines → space) — security hardening that
# prevents crafted evidence values from injecting standalone forged signal
# lines into the rendered notification body (#50 / #66 findings).
#
# SUMMARY is prepended as the first bullet when non-empty.
# DETAILS lines are expected in "- **key:** value" format; the leading "- "
# prefix is stripped so templates receive clean, bullet-ready strings.
# ---------------------------------------------------------------------------
evidence_json="$(jq -n \
  --arg summary "${SUMMARY}" \
  --arg details "${DETAILS}" \
  '
  ($details | split("\n")
    | map(
        ltrimstr("  ") | ltrimstr(" ") |
        if startswith("- ") then .[2:] else . end |
        gsub("[\\n\\r\\t]+"; " ") |
        ltrimstr(" ") | rtrimstr(" ")
      )
    | map(select(length > 0))
  ) as $detail_items |

  (if ($summary | length) > 0
   then [($summary | gsub("[\\n\\r\\t]+"; " ") | ltrimstr(" ") | rtrimstr(" "))]
   else []
   end) as $summary_item |

  $summary_item + $detail_items
')"

# Fall back to a minimal non-empty evidence array so the event is schema-valid
if [ "${evidence_json}" = "[]" ]; then
  evidence_json="$(jq -n --arg role "${ROLE}" --arg verdict "${VERDICT}" \
    '["\($role) \($verdict)"]')"
fi

# ---------------------------------------------------------------------------
# Build the event JSON
# ---------------------------------------------------------------------------
_swarm_tmp="$(mktemp "${TMPDIR:-/tmp}/swarm-role-event.XXXXXX")"
EVENT_FILE="${_swarm_tmp}.json"
mv "$_swarm_tmp" "$EVENT_FILE"
trap 'rm -f "$EVENT_FILE"' EXIT

effective_summary="${SUMMARY:-${ROLE} ${VERDICT}}"

jq -n \
  --arg  event       "${ROLE}" \
  --arg  repo        "${GITHUB_REPOSITORY}" \
  --argjson issue    "${ISSUE_NUMBER}" \
  --argjson pr       "${pr_json}" \
  --arg  stage_from  "${STAGE_FROM}" \
  --arg  stage_to    "${STAGE_TO}" \
  --arg  actor       "${ACTOR}" \
  --arg  url         "${URL}" \
  --arg  summary     "${effective_summary}" \
  --arg  role        "${ROLE}" \
  --arg  verdict     "${VERDICT}" \
  --argjson evidence "${evidence_json}" \
  '{
    event:      $event,
    repo:       $repo,
    issue:      $issue,
    pr:         $pr,
    stage_from: $stage_from,
    stage_to:   $stage_to,
    actor:      $actor,
    url:        $url,
    summary:    $summary,
    role:       $role,
    verdict:    $verdict,
    evidence:   $evidence
  }' > "$EVENT_FILE"

printf 'emit-role-event: emitting %s event (verdict=%s, sinks=%s)\n' \
  "${ROLE}" "${VERDICT}" "${ENABLED_SINKS:-none}"

# ---------------------------------------------------------------------------
# Fan-out via notify.sh
# Failures are non-fatal — log a warning but never block the pipeline.
# ---------------------------------------------------------------------------
NOTIFY_SCRIPT="${NOTIFY_SCRIPT:-${SCRIPT_DIR}/../actions/notify/notify.sh}"

if [ ! -f "${NOTIFY_SCRIPT}" ]; then
  _emit_warn "notify script not found at ${NOTIFY_SCRIPT} — skipping fan-out"
  exit 0
fi

if ! EVENT_FILE="${EVENT_FILE}" \
   ENABLED_SINKS="${ENABLED_SINKS:-}" \
   BUZZ_CHANNEL="${BUZZ_CHANNEL:-}" \
   SLACK_CHANNEL="${SLACK_CHANNEL:-}" \
   DISCORD_CHANNEL="${DISCORD_CHANNEL:-}" \
   bash "${NOTIFY_SCRIPT}"; then
  _emit_warn "notify fan-out failed for ${ROLE} event (verdict=${VERDICT}) — pipeline not blocked"
fi
