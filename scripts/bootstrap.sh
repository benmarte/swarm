#!/usr/bin/env bash
# bootstrap.sh — one-time consumer-repo provisioning for swarm.
#
# Usage:
#   bash scripts/bootstrap.sh --env-file .env [--repo owner/name] \
#     [--reviewer login] [--dry-run] [--force]
#
# What it does:
#   1. Creates all swarm:* and pipeline:* labels (idempotent).
#   2. Creates the swarm-approval environment with required reviewer.
#   3. Seeds each secret found in --env-file via gh secret set (never logs values).
#   4. Reports keys present in .env.example but missing from --env-file, and
#      keys in --env-file that are unknown to .env.example (names only, no values).
#   5. Writes a starter swarm.config.yml if not already present (or --force).
#   6. Prints a caller-workflow snippet to stdout.
#
# Conventions (matching scripts/verify.sh):
#   set -euo pipefail, cd to git root, need() for dependency checks.
#   Zero secret values in any output, log, or process argument list.
#
# See SPEC §2.6 and §2.7.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

# ── Dependency guard ──────────────────────────────────────────────────────────
need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "bootstrap: '$1' is required but not installed (brew install $2)" >&2
    exit 1
  }
}

need gh gh
need jq jq

# ── Argument parsing ──────────────────────────────────────────────────────────
ENV_FILE=""
REPO=""
REVIEWER=""
DRY_RUN=false
FORCE=false

while [ $# -gt 0 ]; do
  case "$1" in
    --env-file)
      shift
      ENV_FILE="${1:?--env-file requires a path argument}"
      ;;
    --repo)
      shift
      REPO="${1:?--repo requires an owner/name argument}"
      ;;
    --reviewer)
      shift
      REVIEWER="${1:?--reviewer requires a GitHub login}"
      ;;
    --dry-run)
      DRY_RUN=true
      ;;
    --force)
      FORCE=true
      ;;
    *)
      echo "bootstrap: unknown argument: $1" >&2
      echo "Usage: $0 --env-file <path> [--repo owner/name] [--reviewer login] [--dry-run] [--force]" >&2
      exit 1
      ;;
  esac
  shift
done

if [ -z "$ENV_FILE" ]; then
  echo "bootstrap: --env-file is required" >&2
  echo "Usage: $0 --env-file <path> [--repo owner/name] [--reviewer login] [--dry-run] [--force]" >&2
  exit 1
fi

if [ ! -f "$ENV_FILE" ]; then
  echo "bootstrap: env file not found: $ENV_FILE" >&2
  exit 1
fi

# ── Resolve repository ────────────────────────────────────────────────────────
if [ -z "$REPO" ]; then
  REPO="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null)" || {
    echo "bootstrap: could not detect current repo; pass --repo owner/name" >&2
    exit 1
  }
fi

# Validate owner/name format (integer/format check before any gh call)
if ! printf '%s' "$REPO" | grep -qE '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'; then
  echo "bootstrap: --repo must be in owner/name format (got: [redacted])" >&2
  exit 1
fi

OWNER="${REPO%%/*}"

echo "bootstrap: targeting repository: $REPO"
if [ "$DRY_RUN" = "true" ]; then
  echo "bootstrap: DRY-RUN mode — no mutations will be performed"
fi

# ── Label definitions ─────────────────────────────────────────────────────────
# Format: "name|color|description"
LABELS="
swarm:go|0e8a16|Maintainer approval: issue is ready to enter the swarm pipeline
swarm:spec|1d76db|Swarm stage: PM agent is writing the spec
swarm:develop|5319e7|Swarm stage: developer agent is implementing
swarm:qa|e4e669|Swarm stage: QA / review / security gates running
swarm:docs|0075ca|Swarm stage: docs agent is writing documentation
swarm:done|6f42c1|Swarm stage: issue fully complete and closed
swarm:needs-human|b60205|Swarm stage: human intervention required
swarm:paused|d4c5f9|Swarm stage: sweeper or human has parked this issue
swarm:attempts:1|f9d0c4|Swarm fix-loop: first attempt
swarm:attempts:2|f9d0c4|Swarm fix-loop: second attempt
swarm:attempts:3|f9d0c4|Swarm fix-loop: third attempt (escalates on failure)
pipeline:dev|0052cc|Talos: issue assigned to developer agent
pipeline:review|0e8a16|Talos: PR in review stage
pipeline:blocked|b60205|Talos: pipeline blocked — requires manual action
p1|d73a4a|Priority 1 — urgent
p2|e4e669|Priority 2 — normal
p3|0075ca|Priority 3 — low
"

# ── Step 1: Create labels (idempotent) ───────────────────────────────────────
echo ""
echo "bootstrap: step 1/5 — creating swarm labels"

while IFS='|' read -r label_name label_color label_desc; do
  # Skip blank lines
  [ -z "$label_name" ] && continue

  if [ "$DRY_RUN" = "true" ]; then
    echo "  dry-run: gh label create '$label_name' --color '$label_color' --repo '$REPO'"
    continue
  fi

  # Check if label already exists
  existing="$(gh api "repos/$REPO/labels/$label_name" --jq '.name' 2>/dev/null || true)"
  if [ -n "$existing" ]; then
    echo "  skip (exists): $label_name"
  else
    gh api "repos/$REPO/labels" \
      --method POST \
      --field "name=$label_name" \
      --field "color=$label_color" \
      --field "description=$label_desc" \
      --silent 2>/dev/null || {
        echo "  warning: could not create label '$label_name' (may already exist)" >&2
      }
    echo "  created: $label_name"
  fi
done <<EOF
$(printf '%s' "$LABELS")
EOF

# ── Step 2: Create swarm-approval environment ─────────────────────────────────
echo ""
echo "bootstrap: step 2/5 — creating swarm-approval environment"

if [ -z "$REVIEWER" ]; then
  # Try to get the repo owner as default reviewer
  REVIEWER="$OWNER"
  echo "  using repo owner as reviewer: $REVIEWER"
fi

# Validate reviewer format
if ! printf '%s' "$REVIEWER" | grep -qE '^[A-Za-z0-9._-]+$'; then
  echo "bootstrap: invalid reviewer login format" >&2
  exit 1
fi

# Look up reviewer user ID
REVIEWER_ID=""
if [ "$DRY_RUN" = "false" ]; then
  REVIEWER_ID="$(gh api "users/$REVIEWER" --jq '.id' 2>/dev/null)" || {
    echo "bootstrap: could not look up reviewer '$REVIEWER' — check the login" >&2
    exit 1
  }
fi

if [ "$DRY_RUN" = "true" ]; then
  echo "  dry-run: gh api repos/$REPO/environments/swarm-approval --method PUT"
  echo "  dry-run: set required reviewer: $REVIEWER"
else
  # Create/update the environment with required reviewer
  # Build the reviewers JSON payload using the resolved user ID
  reviewers_json="[{\"type\":\"User\",\"id\":$REVIEWER_ID}]"

  gh api "repos/$REPO/environments/swarm-approval" \
    --method PUT \
    --field "prevent_self_review=false" \
    --field "reviewers=$reviewers_json" \
    --silent 2>/dev/null || true

  echo "  created/updated: swarm-approval (reviewer: $REVIEWER)"
fi

# ── Step 3: Parse env file and seed secrets ───────────────────────────────────
echo ""
echo "bootstrap: step 3/5 — seeding secrets from env file"

# Parse .env.example for the known key list (names only)
ENV_EXAMPLE="$(git rev-parse --show-toplevel)/.env.example"
if [ ! -f "$ENV_EXAMPLE" ]; then
  echo "bootstrap: .env.example not found at repo root" >&2
  exit 1
fi

known_keys=""
while IFS= read -r line; do
  # Match lines like KEY= or KEY=value (ignore comments and blanks)
  if printf '%s' "$line" | grep -qE '^[A-Z_][A-Z0-9_]*='; then
    key="${line%%=*}"
    known_keys="${known_keys}${key}
"
  fi
done < "$ENV_EXAMPLE"

# Parse the provided env file for present keys (names and values separately)
present_keys=""
while IFS= read -r line; do
  # Skip comments and blank lines
  case "$line" in
    '#'*|'') continue ;;
  esac
  if printf '%s' "$line" | grep -qE '^[A-Z_][A-Z0-9_]*='; then
    key="${line%%=*}"
    value="${line#*=}"
    # Only count keys that have non-empty values
    if [ -n "$value" ]; then
      present_keys="${present_keys}${key}
"
    fi
  fi
done < "$ENV_FILE"

# Seed each present key via gh secret set using --body (value via stdin flag)
# Values never appear in args (avoiding ps aux exposure) or in any output.
seeded=0
while IFS= read -r key; do
  [ -z "$key" ] && continue

  # Extract the value inline without storing in a variable that could leak
  secret_value=""
  while IFS= read -r line; do
    case "$line" in '#'*|'') continue ;; esac
    if printf '%s' "$line" | grep -qE "^${key}="; then
      secret_value="${line#*=}"
      break
    fi
  done < "$ENV_FILE"

  [ -z "$secret_value" ] && continue

  if [ "$DRY_RUN" = "true" ]; then
    echo "  dry-run: gh secret set $key --repo $REPO [value redacted]"
  else
    # Pass value via stdin to gh secret set — never in argv
    printf '%s' "$secret_value" | gh secret set "$key" \
      --repo "$REPO" \
      --body-file /dev/stdin 2>/dev/null || {
        echo "  warning: could not set secret '$key'" >&2
      }
    echo "  seeded: $key"
  fi
  seeded=$((seeded + 1))
  # Scrub from memory
  secret_value=""
done <<EOF
$(printf '%s' "$present_keys")
EOF

echo "  total seeded: $seeded key(s)"

# ── Step 4: Report missing and extra keys ─────────────────────────────────────
echo ""
echo "bootstrap: step 4/5 — key report"

missing_keys=""
while IFS= read -r key; do
  [ -z "$key" ] && continue
  if ! printf '%s' "$present_keys" | grep -qxF "$key"; then
    missing_keys="${missing_keys}${key}
"
  fi
done <<EOF
$(printf '%s' "$known_keys")
EOF

extra_keys=""
while IFS= read -r key; do
  [ -z "$key" ] && continue
  if ! printf '%s' "$known_keys" | grep -qxF "$key"; then
    extra_keys="${extra_keys}${key}
"
  fi
done <<EOF
$(printf '%s' "$present_keys")
EOF

if [ -n "$missing_keys" ]; then
  echo "  missing keys (in .env.example, absent or blank in env file):"
  while IFS= read -r key; do
    [ -z "$key" ] && continue
    echo "    - $key"
  done <<EOF
$(printf '%s' "$missing_keys")
EOF
else
  echo "  all .env.example keys are present"
fi

if [ -n "$extra_keys" ]; then
  echo "  extra keys (in env file, unknown to .env.example):"
  while IFS= read -r key; do
    [ -z "$key" ] && continue
    echo "    - $key"
  done <<EOF
$(printf '%s' "$extra_keys")
EOF
fi

# ── Step 5: Write starter swarm.config.yml ────────────────────────────────────
echo ""
echo "bootstrap: step 5/5 — starter swarm.config.yml"

CONFIG_FILE="swarm.config.yml"
if [ -f "$CONFIG_FILE" ] && [ "$FORCE" = "false" ]; then
  echo "  $CONFIG_FILE already exists — skipping (use --force to overwrite)"
else
  if [ "$DRY_RUN" = "true" ]; then
    echo "  dry-run: would write $CONFIG_FILE"
  else
    cat > "$CONFIG_FILE" <<'CONFIGEOF'
# swarm.config.yml — behavior config committed in your consumer repo.
# Validate with: ajv validate -s schemas/config.schema.json -d swarm.config.yml
# Secrets (SWARM_GITHUB_TOKEN, ANTHROPIC_API_KEY, etc.) must NOT appear here.
# See .env.example for all secret names. See SPEC §2.6 for the full model.

notify:
  # Uncomment the sinks you have configured in your .env / GitHub Secrets:
  # slack: true
  # discord: true
  # teams: true
  # buzz_channel: "your-nostr-channel-uuid-here"

# adapters:
#   validator:
#     adapter: claude
#     model: claude-opus-4-5
#   pm:
#     adapter: claude
#     model: claude-opus-4-5

develop:
  adapter: claude-code-action

# SWARM_LLM_BASE_URL: "http://localhost:11434/v1"  # openai-compat only

qa:
  required_checks:
    - CI

runner:
  label: swarm-agent

sweeper:
  schedule: "0 2 * * *"
CONFIGEOF
    echo "  wrote: $CONFIG_FILE"
  fi
fi

# ── Caller workflow snippet ────────────────────────────────────────────────────
echo ""
echo "bootstrap: caller workflow snippet"
echo "──────────────────────────────────────────────────────────────────────────"
cat <<'SNIPPETEOF'
# .github/workflows/swarm.yml — caller workflow for benmarte/swarm
# Pin @v1 to a full SHA in production; see https://github.com/benmarte/swarm/releases
name: swarm
on:
  issues:
    types: [labeled]
  pull_request:
    types: [opened, synchronize]

jobs:
  intake:
    if: github.event_name == 'issues' && contains(github.event.issue.labels.*.name, 'swarm:go')
    uses: benmarte/swarm/.github/workflows/intake.yml@main
    with:
      issue: ${{ github.event.issue.number }}
      # runner-label: swarm-agent   # default; override if your runner uses a different label
      # adapter: claude             # or: openai-compat
      # dry-run: false
    secrets: inherit

  # Add spec, develop, pr-gates, fix, docs, sweeper callers following the same
  # pattern once those workflows are published. See docs/adopting.md.
SNIPPETEOF
echo "──────────────────────────────────────────────────────────────────────────"

echo ""
echo "bootstrap: done."
