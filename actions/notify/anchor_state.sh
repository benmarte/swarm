#!/usr/bin/env bash
# anchor_state.sh — GitHub-backed thread-anchor persistence for notify.sh.
# Source this file; it defines swarm_anchor_read and swarm_anchor_set.
#
# Storage decision — issue body, not a hidden comment:
#   A body PATCH (/repos/.../issues/<N>) is NOT a timeline event and does not
#   trigger GitHub notification emails to watchers. A hidden issue comment,
#   even though it renders as blank HTML, still counts as a comment, appears in
#   the activity timeline, and DOES trigger watcher emails. The issue body is
#   therefore the cleaner choice and does not pollute the conversation stream.
#
#   The marker is appended to (or replaces an existing marker in) the body:
#     <!-- swarm:thread-anchors {"slack":"<ts>","discord":"<id>","buzz":"<hex64>"} -->
#
# Concurrency policy (parallel-stage race, e.g. pr-gates reviewer + security + QA):
#   swarm_anchor_set performs a fresh read-merge-write: it re-reads the current
#   issue body at write time (not from any cached value), updates ONLY the
#   caller's own sink key (leaves all other sink keys untouched), then PATCHes.
#   Worst case in a race: at most one stray duplicate root message per sink if
#   all concurrent stages read an empty anchor before any write completes.
#
#   This NARROWS the lost-update window; it does not close it. Read-merge-write
#   is not atomic, and GitHub issues expose no ETag/If-Match, so two stages that
#   both read before either PATCHes will have the later write win — dropping the
#   earlier stage's key. That costs one extra root message on the next
#   notification for the dropped sink; it cannot corrupt or lose user content,
#   which the pre-PATCH invariant check guards separately.
#
#   Do not describe this as preventing lost updates. It bounds their cost.
#
# All functions fail soft (log a WARNING, return 0) on any API error.
# Anchor values and caller inputs are allowlist-validated before any gh call.
#
# Anchor format allowlist:
#   slack:   ^[0-9]+\.[0-9]+$    (Unix epoch.sequence timestamp)
#   discord: ^[0-9]{17,20}$       (Discord snowflake)
#   buzz:    ^[0-9a-f]{64}$       (Nostr event id, lowercase hex)

_SWARM_ANCHOR_MARKER_PREFIX="<!-- swarm:thread-anchors"

# ---------------------------------------------------------------------------
# Validation helpers (allowlist — rejects anything outside the pattern)
# ---------------------------------------------------------------------------

_swarm_anchor_validate_repo() {
  # owner/repo — alphanumeric, hyphen, underscore, dot only
  printf '%s' "$1" | grep -qE '^[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+$'
}

_swarm_anchor_validate_issue() {
  printf '%s' "$1" | grep -qE '^[0-9]+$'
}

_swarm_anchor_validate_value() {
  # $1=sink  $2=value — returns 0 if valid for that sink, 1 otherwise
  case "$1" in
    slack)   printf '%s' "$2" | grep -qE '^[0-9]+\.[0-9]+$' ;;
    discord) printf '%s' "$2" | grep -qE '^[0-9]{17,20}$' ;;
    buzz)    printf '%s' "$2" | grep -qE '^[0-9a-f]{64}$' ;;
    *)       return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

# _swarm_anchor_fetch_body <repo> <issue>
# Prints the raw issue body string.
# Returns 0 on success (even if body is empty), non-zero on gh/API failure.
# IMPORTANT: does NOT use '|| true' — callers MUST check the return code.
_swarm_anchor_fetch_body() {
  gh api "/repos/${1}/issues/${2}" --jq '.body // ""' 2>/dev/null
}

# _swarm_anchor_parse_json <body>
# Extracts the anchor JSON object string from the issue body marker.
# Prints the JSON string, or nothing if the marker is absent/malformed.
_swarm_anchor_parse_json() {
  printf '%s' "$1" | python3 -c '
import sys, re
body = sys.stdin.read()
m = re.search(r"<!-- swarm:thread-anchors (\{[^}]*\}) -->", body)
if m:
    sys.stdout.write(m.group(1))
' 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

# swarm_anchor_read <repo> <issue>
# Prints the anchor JSON object for this issue (e.g. {"slack":"...", ...}).
# Returns "{}" on any error or when no anchor marker exists.
swarm_anchor_read() {
  local _repo="$1" _issue="$2" _body _json
  if ! _swarm_anchor_validate_repo "$_repo"; then
    printf '{}'
    return 0
  fi
  if ! _swarm_anchor_validate_issue "$_issue"; then
    printf '{}'
    return 0
  fi
  if ! _body="$(_swarm_anchor_fetch_body "$_repo" "$_issue")"; then
    echo "anchor: WARNING: gh GET failed for ${_repo}#${_issue} — treating as no anchor (no write will occur)" >&2
    printf '{}'
    return 0
  fi
  _json="$(_swarm_anchor_parse_json "$_body")"
  if [ -n "$_json" ]; then
    printf '%s' "$_json"
  else
    printf '{}'
  fi
}

# swarm_anchor_set <repo> <issue> <sink> <value>
# Persists a new anchor value for one sink into the issue body.
# Performs a fresh read-merge-write to avoid losing concurrent writes.
# Fails soft (logs WARNING, returns 0) on any validation or API error.
swarm_anchor_set() {
  local _repo="$1" _issue="$2" _sink="$3" _value="$4"
  local _body _old_json _new_json _new_marker _new_body _body_json_file

  if ! _swarm_anchor_validate_repo "$_repo"; then
    echo "anchor: WARNING: invalid repo '${_repo}' — skipping anchor write" >&2
    return 0
  fi
  if ! _swarm_anchor_validate_issue "$_issue"; then
    echo "anchor: WARNING: invalid issue '${_issue}' — skipping anchor write" >&2
    return 0
  fi
  if ! _swarm_anchor_validate_value "$_sink" "$_value"; then
    echo "anchor: WARNING: invalid anchor value for sink '${_sink}': $(printf '%s' "$_value" | head -c 80 | tr -d '\n\r')" >&2
    return 0
  fi

  # Fresh read at write time (concurrency safety — not the cached value from notify start).
  # ABORT if the read fails: computing a new body from an empty string would produce a
  # marker-only body and PATCH it back, silently destroying the real issue body.
  if ! _body="$(_swarm_anchor_fetch_body "$_repo" "$_issue")"; then
    echo "anchor: WARNING: gh GET failed for ${_repo}#${_issue} — skipping anchor write to avoid data loss" >&2
    return 0
  fi

  _old_json="$(_swarm_anchor_parse_json "$_body")"
  [ -z "$_old_json" ] && _old_json="{}"

  # Merge: update only our sink's key; all other sink keys are preserved.
  _new_json="$(printf '%s' "$_old_json" | \
    jq --arg s "$_sink" --arg v "$_value" '. + {($s): $v}' 2>/dev/null)" || {
    echo "anchor: WARNING: jq merge failed — skipping anchor write" >&2
    return 0
  }

  _new_marker="${_SWARM_ANCHOR_MARKER_PREFIX} ${_new_json} -->"

  # Replace existing marker or append it — Python handles special chars safely.
  # Use lambda in re.sub to prevent backslash expansion in the replacement string
  # (e.g. an anchor value containing '\1' would otherwise be interpreted as a
  # group reference and corrupt the body).
  _new_body="$(printf '%s' "$_body" | python3 -c '
import sys, re
body = sys.stdin.read()
marker = sys.argv[1]
pattern = r"<!-- swarm:thread-anchors \{[^}]*\} -->"
if re.search(pattern, body):
    result = re.sub(pattern, lambda m: marker, body, count=1)
else:
    sep = "\n\n" if body.strip() else ""
    result = body + sep + marker
sys.stdout.write(result)
' "$_new_marker" 2>/dev/null)" || {
    echo "anchor: WARNING: body update computation failed — skipping anchor write" >&2
    return 0
  }

  # Invariant check: strip both the old and new markers, then verify the non-marker
  # content is identical.  If it differs, something went wrong in the merge and
  # we must refuse to PATCH to avoid corrupting the issue body.
  _strip_marker='import sys, re; body=sys.stdin.read(); print(re.sub(r"<!-- swarm:thread-anchors \{[^}]*\} -->", "", body).strip())'
  _body_clean="$(printf '%s' "$_body" | python3 -c "$_strip_marker" 2>/dev/null)" || _body_clean=""
  _new_body_clean="$(printf '%s' "$_new_body" | python3 -c "$_strip_marker" 2>/dev/null)" || _new_body_clean=""
  if [ "$_body_clean" != "$_new_body_clean" ]; then
    echo "anchor: WARNING: invariant check failed — non-marker content changed; refusing PATCH to prevent data loss" >&2
    return 0
  fi

  # Build the JSON payload for the PATCH request via a temp file (safe for
  # multiline bodies and bodies containing quotes or backslashes).
  _body_json_file="$(mktemp)"
  if ! printf '%s' "$_new_body" | jq -Rs '{"body": .}' > "$_body_json_file" 2>/dev/null; then
    rm -f "$_body_json_file"
    echo "anchor: WARNING: failed to build PATCH JSON payload — skipping anchor write" >&2
    return 0
  fi

  # Write back via PATCH (fail soft — notification was already delivered)
  if ! gh api "/repos/${_repo}/issues/${_issue}" \
      --method PATCH \
      --input "$_body_json_file" \
      >/dev/null 2>&1; then
    rm -f "$_body_json_file"
    echo "anchor: WARNING: gh api PATCH failed — notification delivered, anchor not persisted" >&2
    return 0
  fi

  rm -f "$_body_json_file"
  echo "anchor: stored ${_sink} anchor for ${_repo}#${_issue}"
}
