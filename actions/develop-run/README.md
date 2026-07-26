# actions/develop-run/

Composite action — the **coding contract** (develop stage + fix loop).

Given issue context + spec, the engine produces a pushed branch and an open PR linking the issue. The engine verifies the PR exists via `gh api` rather than trusting adapter output.

## Engine-owns-everything contract

For both adapters the engine owns all GitHub state mutations:

- git identity, branch naming (`swarm/issue-N`)
- writing `docs/specs/issue-N.md` and committing it
- invoking the adapter (pure working-tree edit)
- detecting the diff, committing adapter changes, pushing
- `gh pr create` with `Closes #N`, adapter name, and model in the body
- `gh api` PR verification
- `swarm:develop → swarm:qa` label transition on success
- `bump-attempts` call on failure (no diff or PR verify failure)

The adapter only edits the working tree. It must not push, create PRs, or mutate labels.

## V1 adapters (see `adapters/`)

- `claude-code-action` (default) — `anthropics/claude-code-action` runs as a **separate step** in `develop.yml` before this action in file-edit mode only (`create_pull_request: "false"`); the action edits the working tree. The engine then runs its full git/push/PR plumbing (same as headless). Fix loop: `@claude` PR comment trigger (native to the action).
- `headless` — wraps any coding CLI via `ADAPTER_CMD` env (`claude -p`, `aider --yes-always`, `goose run`, etc.). The engine owns all git/gh operations; the adapter only edits files. Fix loop: engine re-invokes `headless.sh` with `SWARM_FIX_CONTEXT` JSON.

Adapter selection is a caller input to `develop.yml` — no engine changes required to switch adapters.

See `schemas/runner-contract.md` for the full adapter env contract.
