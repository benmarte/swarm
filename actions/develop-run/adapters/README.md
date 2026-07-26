# actions/develop-run/adapters/

Adapter scripts/directories for the `develop-run` composite action.

An adapter is a pure working-tree editor: it reads the spec and edits files. All git and GitHub operations are owned by the engine (`develop-run.sh`).

## Adapter env contract (set by `develop-run.sh`)

See `schemas/runner-contract.md` §2 for the full specification. Key variables:

| Variable | Description |
|----------|-------------|
| `ADAPTER_CMD` | CLI command to invoke (headless adapter only) |
| `WORKTREE` | Working directory to edit (always `.` from the engine) |
| `ISSUE_NUMBER` | Issue number for context injection |
| `SPEC_FILE` | Path to `docs/specs/issue-N.md` written by the engine |
| `SWARM_LLM_MODEL` | Model identifier forwarded to the adapter |
| `SWARM_FIX_CONTEXT` | JSON `{check_name, conclusion, log_url, attempt_number}` on fix-loop re-invocations |

Adapter rules:
- Must edit files under `WORKTREE` to implement the spec.
- Must NOT push, create PRs, post comments, or apply labels.
- Exit 0 on success; non-zero triggers the fix loop.

## Shipped adapters

### `headless.sh`

Wraps any coding CLI (`claude -p`, `aider --yes-always`, `goose run`, etc.) via `ADAPTER_CMD`. Guards: validates `ADAPTER_CMD` is set, the binary exists on `PATH`, and `SPEC_FILE` exists. On fix-loop re-invocations, appends `SWARM_FIX_CONTEXT` JSON to the prompt.

### `claude-code-action/`

Documentation for using `anthropics/claude-code-action` as the develop-run adapter. Because composite actions cannot call third-party actions from `run:` blocks, `develop.yml` invokes the action as a separate step before the engine. See `claude-code-action/README.md` for the pattern and `develop.yml` snippet.
