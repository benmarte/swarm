#!/usr/bin/env bash
# develop-run.sh — swarm coding-contract engine (develop stage + fix loop).
# Called by actions/develop-run/action.yml; all inputs arrive via env vars.
#
# Required env:
#   ISSUE_NUMBER      — positive integer, the issue to implement
#   BASE_BRANCH       — integration branch (default: main)
#   ADAPTER           — coding adapter: claude-code-action | headless
#   SPEC_BODY         — PM spec as a string (or empty if SPEC_FILE is set)
#   SPEC_FILE         — absolute path to spec file (takes precedence over SPEC_BODY)
#   DRY_RUN           — "true" | "false"
#   ADAPTER_CMD       — shell command for headless adapter (required when headless)
#   MODEL             — LLM model identifier (recorded in PR body)
#   MAINTAINER        — GitHub username for bump-attempts escalation
#   GH_TOKEN          — GitHub API token
#   GITHUB_REPOSITORY — owner/repo
#   ACTION_PATH       — path to the action directory (set by action.yml env)
#
# Exit 0: PR exists and transition succeeded (or dry-run completed).
# Exit 1: validation failure, adapter error, no-diff, PR verify failure.
set -euo pipefail

# ---------------------------------------------------------------------------
# Adapter allowlist — SPEC §2.3
# ---------------------------------------------------------------------------
ALLOWED_ADAPTERS="claude-code-action headless"

is_allowed_adapter() {
  local a="$1"
  local adapter
  for adapter in $ALLOWED_ADAPTERS; do
    [ "$a" = "$adapter" ] && return 0
  done
  return 1
}

# ---------------------------------------------------------------------------
# Input validation — before any file path or command use
# ---------------------------------------------------------------------------
if [ -z "${ISSUE_NUMBER:-}" ]; then
  echo "develop-run: ERROR: ISSUE_NUMBER is required" >&2
  exit 1
fi

if ! printf '%s' "$ISSUE_NUMBER" | grep -qE '^[1-9][0-9]*$'; then
  echo "develop-run: ERROR: ISSUE_NUMBER must be a positive integer; got: $ISSUE_NUMBER" >&2
  exit 1
fi

if [ -z "${ADAPTER:-}" ]; then
  echo "develop-run: ERROR: ADAPTER is required" >&2
  exit 1
fi

if ! is_allowed_adapter "$ADAPTER"; then
  echo "develop-run: ERROR: invalid adapter '$ADAPTER'." >&2
  echo "  Allowed: $ALLOWED_ADAPTERS" >&2
  exit 1
fi

BASE_BRANCH="${BASE_BRANCH:-main}"
DRY_RUN="${DRY_RUN:-false}"
MODEL="${MODEL:-}"
MAINTAINER="${MAINTAINER:-}"
BRANCH_NAME="swarm/issue-$ISSUE_NUMBER"

# ---------------------------------------------------------------------------
# Derive peer-action paths from ACTION_PATH
# ---------------------------------------------------------------------------
ACTION_ROOT="${ACTION_PATH:?ACTION_PATH is not set}"
TRANSITION_SH="$ACTION_ROOT/../transition/transition.sh"
BUMP_ATTEMPTS_SH="$ACTION_ROOT/../bump-attempts/bump-attempts.sh"

if [ ! -f "$TRANSITION_SH" ]; then
  echo "develop-run: ERROR: transition.sh not found at $TRANSITION_SH" >&2
  exit 1
fi

if [ ! -f "$BUMP_ATTEMPTS_SH" ]; then
  echo "develop-run: ERROR: bump-attempts.sh not found at $BUMP_ATTEMPTS_SH" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Resolve spec content
# ---------------------------------------------------------------------------
if [ -n "${SPEC_FILE:-}" ] && [ -f "$SPEC_FILE" ]; then
  spec_content="$(cat "$SPEC_FILE")"
  echo "develop-run: spec from file: $SPEC_FILE"
elif [ -n "${SPEC_BODY:-}" ]; then
  spec_content="$SPEC_BODY"
  echo "develop-run: spec from SPEC_BODY env var"
else
  echo "develop-run: WARNING: no spec provided; writing empty spec file" >&2
  spec_content=""
fi

echo "develop-run: issue=$ISSUE_NUMBER adapter=$ADAPTER branch=$BRANCH_NAME base=$BASE_BRANCH dry-run=$DRY_RUN"

# ---------------------------------------------------------------------------
# DRY-RUN path: log intended actions and exit 0
# ---------------------------------------------------------------------------
if [ "$DRY_RUN" = "true" ]; then
  printf 'dry-run: would create branch %s from %s\n' "$BRANCH_NAME" "$BASE_BRANCH"
  printf 'dry-run: would write docs/specs/issue-%s.md\n' "$ISSUE_NUMBER"
  if [ "$ADAPTER" = "headless" ]; then
    printf 'dry-run: would invoke headless adapter with ADAPTER_CMD=%s\n' "${ADAPTER_CMD:-<unset>}"
  else
    printf 'dry-run: claude-code-action step (in develop.yml) edits working tree; engine then commits\n'
  fi
  printf 'dry-run: would commit, push, and open PR on %s\n' "$GITHUB_REPOSITORY"
  printf 'dry-run: would transition issue #%s from swarm:develop to swarm:qa\n' "$ISSUE_NUMBER"
  exit 0
fi

# ---------------------------------------------------------------------------
# ENGINE: git identity, branch, spec write — same for both adapters
# ---------------------------------------------------------------------------

# -- git identity ----------------------------------------------------------
git config user.email "swarm-bot@users.noreply.github.com"
git config user.name "swarm-bot"
echo "develop-run: git identity configured as swarm-bot"

# -- create or resume branch -----------------------------------------------
# Check remote first (covers re-runs after a failed push where local ref may
# not yet exist, and cases where another runner pre-created the branch).
if git ls-remote --exit-code --heads origin "$BRANCH_NAME" >/dev/null 2>&1; then
  echo "develop-run: branch $BRANCH_NAME exists on origin; checking out from remote"
  git checkout -b "$BRANCH_NAME" "origin/$BRANCH_NAME" 2>/dev/null \
    || git checkout "$BRANCH_NAME"
elif git show-ref --verify --quiet "refs/heads/$BRANCH_NAME" 2>/dev/null; then
  echo "develop-run: branch $BRANCH_NAME exists locally; checking it out"
  git checkout "$BRANCH_NAME"
else
  echo "develop-run: creating branch $BRANCH_NAME from origin/$BASE_BRANCH"
  git checkout -b "$BRANCH_NAME" "origin/$BASE_BRANCH"
fi

# -- write spec file -------------------------------------------------------
spec_dir="docs/specs"
spec_md="$spec_dir/issue-$ISSUE_NUMBER.md"
mkdir -p "$spec_dir"
printf '%s\n' "$spec_content" > "$spec_md"
git add "$spec_md"
echo "develop-run: spec written to $spec_md"

# ---------------------------------------------------------------------------
# ADAPTER DISPATCH: invoke coding agent to edit the working tree
# ---------------------------------------------------------------------------
if [ "$ADAPTER" = "headless" ]; then

  # Validate headless-specific input
  if [ -z "${ADAPTER_CMD:-}" ]; then
    echo "develop-run: ERROR: ADAPTER_CMD is required for the headless adapter" >&2
    exit 1
  fi

  ADAPTER_SCRIPT="$ACTION_ROOT/adapters/headless.sh"
  if [ ! -f "$ADAPTER_SCRIPT" ]; then
    echo "develop-run: ERROR: headless adapter not found: $ADAPTER_SCRIPT" >&2
    exit 1
  fi

  echo "develop-run: invoking headless adapter"
  export WORKTREE="."
  export ISSUE_NUMBER
  export SPEC_FILE="$spec_md"
  export SWARM_LLM_MODEL="$MODEL"

  bash "$ADAPTER_SCRIPT"
  echo "develop-run: headless adapter completed"

else
  # claude-code-action: the action step in develop.yml already edited the
  # working tree (file-edit mode, create_pull_request=false).  The engine
  # now owns commit, push, and PR creation — same path as headless.
  echo "develop-run: claude-code-action edits applied; engine taking over git/PR steps"
fi

# ---------------------------------------------------------------------------
# DETECT DIFF, COMMIT, PUSH, PR CREATE — engine-owns-everything for all adapters
# ---------------------------------------------------------------------------

# -- detect diff -----------------------------------------------------------
# Stage all changes made by the adapter (spec file was already staged above).
# Exclude engine checkout from consumer commit — .swarm-engine/ is engine-only.
git add -A -- ':!.swarm-engine'

if git diff --cached --quiet; then
  echo "develop-run: ERROR: adapter produced no changes in the working tree" >&2
  echo "develop-run: bumping attempts (no-diff failure)" >&2
  export GITHUB_REPOSITORY
  export GH_TOKEN
  export ISSUE_NUMBER
  export MAINTAINER
  export POST_COMMENT="true"
  export RUNNER_TEMP="${RUNNER_TEMP:-/tmp}"
  bash "$BUMP_ATTEMPTS_SH"
  exit 1
fi

echo "develop-run: diff detected — committing"

# -- commit ----------------------------------------------------------------
model_tag="${MODEL:+ model=$MODEL}"
git commit -m "feat: implement issue #$ISSUE_NUMBER [adapter=$ADAPTER${model_tag}]"

# -- push ------------------------------------------------------------------
echo "develop-run: pushing branch $BRANCH_NAME"
git push -u origin "$BRANCH_NAME"

# -- derive PR title from spec ---------------------------------------------
# Use the first h1 heading if present; fall back to generic title
pr_title=""
if [ -n "$spec_content" ]; then
  pr_title="$(printf '%s' "$spec_content" | grep -m1 '^# ' | sed 's/^# //' || true)"
fi
if [ -z "$pr_title" ]; then
  pr_title="feat: implement issue #$ISSUE_NUMBER"
fi

# -- gh pr create ----------------------------------------------------------
pr_body="$(cat <<EOF
Automated implementation of issue #${ISSUE_NUMBER} by the swarm develop pipeline.

**Adapter:** ${ADAPTER}
**Model:** ${MODEL:-not specified}

Closes #${ISSUE_NUMBER}
EOF
)"

echo "develop-run: creating PR on $GITHUB_REPOSITORY"
gh_pr_url="$(gh pr create \
  --base "$BASE_BRANCH" \
  --head "$BRANCH_NAME" \
  --title "$pr_title" \
  --body "$pr_body" \
  --repo "$GITHUB_REPOSITORY" 2>&1 || true)"

echo "develop-run: gh pr create output: $gh_pr_url"

# ---------------------------------------------------------------------------
# VERIFY PR EXISTS via gh api (never trust adapter/gh-pr-create output)
# ---------------------------------------------------------------------------
echo "develop-run: verifying PR via gh api"

repo_owner="${GITHUB_REPOSITORY%%/*}"
encoded_head="${repo_owner}:${BRANCH_NAME}"

verify_json="$(gh api \
  "repos/$GITHUB_REPOSITORY/pulls" \
  --method GET \
  -f "head=$encoded_head" \
  -f "state=open" \
  2>/dev/null || echo "[]")"

pr_count="$(printf '%s' "$verify_json" | jq 'if type == "array" then length else 0 end')"

if [ "$pr_count" -eq 0 ]; then
  echo "develop-run: ERROR: no open PR found for $BRANCH_NAME — PR verification failed" >&2
  echo "develop-run: bumping attempts (PR verify failure)" >&2
  export GITHUB_REPOSITORY
  export GH_TOKEN
  export ISSUE_NUMBER
  export MAINTAINER
  export POST_COMMENT="true"
  export RUNNER_TEMP="${RUNNER_TEMP:-/tmp}"
  bash "$BUMP_ATTEMPTS_SH"
  exit 1
fi

pr_url="$(printf '%s' "$verify_json" | jq -r '.[0].html_url')"
echo "develop-run: PR verified: $pr_url"

# Write PR URL to GITHUB_OUTPUT (multiline-safe random delimiter)
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  delim="develop_$(openssl rand -hex 16)"
  {
    printf 'pr-url<<%s\n' "$delim"
    printf '%s\n' "$pr_url"
    printf '%s\n' "$delim"
  } >> "$GITHUB_OUTPUT"
fi

# ---------------------------------------------------------------------------
# TRANSITION: swarm:develop → swarm:qa
# ---------------------------------------------------------------------------
echo "develop-run: transitioning issue #$ISSUE_NUMBER from swarm:develop to swarm:qa"

export ISSUE_NUMBER
export FROM_STAGE="swarm:develop"
export TO_STAGE="swarm:qa"
export POST_COMMENT="true"
export GH_TOKEN
export GITHUB_REPOSITORY
export ACTION_PATH="$ACTION_ROOT/../transition"
bash "$TRANSITION_SH"

echo "develop-run: complete — PR at $pr_url"
