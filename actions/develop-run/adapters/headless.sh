#!/usr/bin/env bash
# adapters/headless.sh — swarm develop-run adapter for any coding CLI.
#
# Wraps any coding CLI command (claude -p, aider, goose, codex, a local-model
# harness, etc.) so the engine can invoke it via a single env var.
#
# The engine calls this script after:
#   - creating the branch (swarm/issue-N)
#   - writing docs/specs/issue-N.md
#
# This adapter MUST:
#   - Edit files in $WORKTREE to implement the spec.
#   - Exit 0 when edits are complete.
#   - Exit non-zero on unrecoverable error.
#
# This adapter MUST NOT:
#   - Push to any branch.
#   - Open PRs, post comments, or apply labels.
#   - Write outside $WORKTREE.
#
# Required env (set by develop-run.sh per runner-contract.md §2):
#   ADAPTER_CMD    — the CLI command to invoke (e.g. "claude -p", "aider --yes-always")
#   WORKTREE       — working directory to edit (always "." from the engine)
#   ISSUE_NUMBER   — issue number (for context injection)
#   SPEC_FILE      — path to the spec file (docs/specs/issue-N.md)
#   SWARM_LLM_MODEL — model identifier (forwarded to adapter; may be empty)
#
# Optional env:
#   SWARM_FIX_CONTEXT — JSON: {check_name, conclusion, log_url, attempt_number}
#                       Set on fix-loop re-invocations; adapter should include
#                       in its prompt to focus on the failing check.
#
# Local smoke test:
#   ADAPTER_CMD="echo 'adapter ran'" \
#   WORKTREE=/tmp/test-repo \
#   ISSUE_NUMBER=42 \
#   SPEC_FILE=/tmp/spec.md \
#   SWARM_LLM_MODEL="" \
#   bash actions/develop-run/adapters/headless.sh
set -euo pipefail

# ---------------------------------------------------------------------------
# Guard: ADAPTER_CMD must be set
# ---------------------------------------------------------------------------
if [ -z "${ADAPTER_CMD:-}" ]; then
  echo "headless adapter: ERROR: ADAPTER_CMD is not set." >&2
  echo "  Set adapter-cmd in the develop.yml caller input to the coding CLI command." >&2
  echo "  Examples: 'claude -p', 'aider --yes-always', 'goose run'" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Guard: verify the first word of ADAPTER_CMD resolves to an executable
# ---------------------------------------------------------------------------
adapter_bin="${ADAPTER_CMD%% *}"
if ! command -v "$adapter_bin" >/dev/null 2>&1; then
  echo "headless adapter: ERROR: command not found: $adapter_bin" >&2
  echo "  ADAPTER_CMD='$ADAPTER_CMD' — install $adapter_bin on the runner." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Guard: SPEC_FILE must exist
# ---------------------------------------------------------------------------
if [ -z "${SPEC_FILE:-}" ]; then
  echo "headless adapter: ERROR: SPEC_FILE is not set" >&2
  exit 1
fi

if [ ! -f "${SPEC_FILE}" ]; then
  echo "headless adapter: ERROR: spec file not found: $SPEC_FILE" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Build the prompt: spec content + fix context (if fix-loop)
# ---------------------------------------------------------------------------
spec_content="$(cat "$SPEC_FILE")"

fix_section=""
if [ -n "${SWARM_FIX_CONTEXT:-}" ]; then
  fix_section="$(printf '\n\n---\n\n## Fix Context\n\nA required check failed. Apply the fix:\n\n```json\n%s\n```\n' "$SWARM_FIX_CONTEXT")"
fi

full_prompt="$(cat <<EOF
You are a coding agent implementing a GitHub issue. Edit files in the working
directory to satisfy the specification below. Do not push, create PRs, or
modify any labels — the pipeline engine handles all git operations.

## Specification

${spec_content}

## Context

- Issue number: ${ISSUE_NUMBER:-unknown}
- Working directory: ${WORKTREE:-.}
- Model: ${SWARM_LLM_MODEL:-not specified}
${fix_section}
EOF
)"

# ---------------------------------------------------------------------------
# Write the prompt to a temp file (some CLIs prefer --prompt-file to stdin)
# ---------------------------------------------------------------------------
tmp_prompt="$(mktemp)"
printf '%s\n' "$full_prompt" > "$tmp_prompt"

echo "headless adapter: invoking '$ADAPTER_CMD' (issue=$ISSUE_NUMBER)"
echo "headless adapter: spec=$SPEC_FILE worktree=${WORKTREE:-.}"

# ---------------------------------------------------------------------------
# Invoke the coding CLI
# ---------------------------------------------------------------------------
# The ADAPTER_CMD may contain arguments (e.g. "claude -p"), so we use eval
# with the prompt passed via a temp file available as SWARM_PROMPT_FILE env.
# CLIs that take a prompt as argument: pass $tmp_prompt content
# CLIs that take --prompt-file: callers should set ADAPTER_CMD to include it
#
# Default: append the prompt file path as the last argument.
# Override: set ADAPTER_CMD to end with a flag that expects the prompt file,
#   e.g. ADAPTER_CMD="aider --yes-always --message-file"
export SWARM_PROMPT_FILE="$tmp_prompt"
export ISSUE_NUMBER
export SPEC_FILE
export SWARM_LLM_MODEL

# Run in the worktree directory
cd "${WORKTREE:-.}"

if ! eval "$ADAPTER_CMD" "$tmp_prompt"; then
  echo "headless adapter: ERROR: '$ADAPTER_CMD' exited non-zero" >&2
  rm -f "$tmp_prompt"
  exit 1
fi

rm -f "$tmp_prompt"
echo "headless adapter: complete"
