# adapters/claude-code-action/

Wrapper documentation for using `anthropics/claude-code-action` as the
develop-run adapter in `workflows/develop.yml`.

## Why not a composite action?

`anthropics/claude-code-action` is a **workflow-level action** — it must be
invoked as a `uses:` step, not from inside a composite action's `run:` block.
A pure-composite wrapper is not feasible because composite actions cannot call
other third-party actions (only shell, script, and Docker actions).

## Pattern: engine-owns-everything

`develop.yml` implements the two-step pattern:

1. **Claude Code Action step** (conditional on `adapter == 'claude-code-action'`):
   Calls the SHA-pinned action in **file-edit mode** (no auto-PR).  The action
   edits the working tree, commits, and pushes, but does NOT create the PR.
   The PR is created by the engine so the body always contains
   `Closes #N`, adapter, and model metadata.

   > NOTE (v1): Because `anthropics/claude-code-action` manages its own
   > git operations, the engine detects the branch state after the action
   > completes rather than running its own git steps.  The engine skips its
   > own branch-creation / commit / push / PR-create flow and goes straight
   > to PR verification + transition.

2. **Develop engine step** (always runs, via `./actions/develop-run`):
   Verifies the PR exists via `gh api`, then transitions the issue from
   `swarm:develop` to `swarm:qa`.

## develop.yml snippet

```yaml
# SHA-pinned to anthropics/claude-code-action v1.0.183
# Verified: git ls-remote https://github.com/anthropics/claude-code-action refs/tags/v1.0.183^{}
# Commit SHA: be7b93b1907a4abad570368f3c74b6fe3807510b
- name: Run claude-code-action adapter
  if: inputs.adapter == 'claude-code-action' && inputs.dry-run == false
  uses: anthropics/claude-code-action@be7b93b1907a4abad570368f3c74b6fe3807510b # v1.0.183
  with:
    prompt: ${{ steps.ctx.outputs.develop-prompt }}
    anthropic_api_key: ${{ secrets.ANTHROPIC_API_KEY }}
    github_token: ${{ secrets.GITHUB_TOKEN }}
    branch_name: swarm/issue-${{ inputs.issue }}
    base_branch: ${{ inputs.base-branch }}
    create_pull_request: "false"   # engine creates the PR for uniform body
  env:
    CLAUDE_MODEL: ${{ inputs.model }}
```

## Inputs used

| Input | Value | Notes |
|-------|-------|-------|
| `prompt` | Spec content rendered as a coding prompt | From `steps.ctx.outputs.develop-prompt` |
| `anthropic_api_key` | `${{ secrets.ANTHROPIC_API_KEY }}` | Required GitHub Actions secret |
| `github_token` | `${{ secrets.GITHUB_TOKEN }}` | With `contents: write` |
| `branch_name` | `swarm/issue-N` | Engine naming convention |
| `base_branch` | Caller input | Integration branch |
| `create_pull_request` | `"false"` | Engine owns PR creation for consistent body |

## Fix loop

For the `claude-code-action` adapter, the fix loop works via `@claude` PR
comment trigger (native to `anthropics/claude-code-action`), not via engine
re-invocation.  The `fix.yml` workflow posts a comment; the action picks it up
and pushes a new commit; the `bump-attempts` action tracks the counter.

## Upgrading the SHA pin

```bash
# List latest v1 tags and their commit SHAs
git ls-remote https://github.com/anthropics/claude-code-action 'refs/tags/v1*' \
  | grep -v '\^{}' | sort -V | tail -5

# Get commit SHA for a specific tag (use the ^{} dereferenced SHA)
git ls-remote https://github.com/anthropics/claude-code-action 'refs/tags/v1.0.183^{}'
```

Update the SHA in `workflows/develop.yml` and this file together.
