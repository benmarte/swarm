# actions/develop-run/

Composite action — the **coding contract** (develop stage + fix loop).

Given issue context + spec, the engine produces a pushed branch and an open PR linking the issue. The engine verifies the PR exists via `gh api` rather than trusting adapter output.

## Engine-owns-everything contract

For both adapters the engine owns all GitHub state mutations:

- git identity, branch naming (`swarm/issue-N`)
- writing `docs/specs/issue-N.md` and committing it
- invoking the adapter (pure working-tree edit)
- detecting the diff, committing adapter changes, pushing
- `gh pr create` with `Closes #N`, adapter name, and model in the body (uses `SWARM_TOKEN` when set; falls back to `GH_TOKEN` with a loud warning — see token selection below)
- `gh api` PR verification (same token as `gh pr create`)
- `swarm:develop → swarm:qa` label transition on success
- `bump-attempts` call on failure (no diff or PR verify failure)

The adapter only edits the working tree. It must not push, create PRs, or mutate labels.

## Token selection for PR operations

`gh pr create` and the `gh api` PR-verify call use `SWARM_TOKEN` when set (env-prefix per call — no global reassignment, so `git push` keeps its checkout credentials). When `SWARM_TOKEN` is absent, the engine falls back to `GH_TOKEN` and emits a loud warning naming both failure modes: the repository policy that blocks Actions from creating PRs, and the `pull_request` workflow suppression (PRs opened by `GITHUB_TOKEN` do not trigger `pull_request` events, which would stall `pr-gates`).

## V1 adapters (see `adapters/`)

- `claude-code-action` (default) — `anthropics/claude-code-action` runs as a **separate step** in `develop.yml` before this action in file-edit mode only (`create_pull_request: "false"`); the action edits the working tree. The engine then runs its full git/push/PR plumbing (same as headless). Fix loop: `@claude` PR comment trigger (native to the action).
- `headless` — wraps any coding CLI via `ADAPTER_CMD` env (`claude -p`, `aider --yes-always`, `goose run`, etc.). The engine owns all git/gh operations; the adapter only edits files. Fix loop: engine re-invokes `headless.sh` with `SWARM_FIX_CONTEXT` JSON.

Adapter selection is a caller input to `develop.yml` — no engine changes required to switch adapters.

See `schemas/runner-contract.md` for the full adapter env contract.
