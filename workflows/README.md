# workflows/

Reusable GitHub Actions workflows (`on: workflow_call`) — the swarm product.

Each workflow is a pipeline stage called from a thin caller workflow in the consumer repo.
Consumers pin `benmarte/swarm/.github/workflows/<name>.yml@v1` and map their own triggers
to the reusable entry-points.

---

## Implemented workflows

### `intake.yml` — Issue validation (SPEC §2.1)

Runs the **validator** agent on a newly-queued issue and routes the verdict:

| Verdict | Action |
|---------|--------|
| `confirmed` | `actions/transition` swarm:go → swarm:spec |
| `duplicate` | Comment explaining duplicate + `gh issue close` |
| `invalid` | Comment explaining invalid + `gh issue close` |
| `needs-info` | Clarification comment + `actions/transition` swarm:go → swarm:needs-human |

**Caller-input surface:**

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `issue` | number | *(required)* | Issue number to validate. |
| `runner-label` | string | `swarm-agent` | Runner label for the agent job. Glue jobs always use `ubuntu-latest`. |
| `dry-run` | boolean | `false` | When `true`, logs intended transitions/mutations without executing any GitHub API writes. |
| `adapter` | string | `claude` | Agent adapter forwarded to `agent-run`. One of: `claude`, `openai-compat`. |
| `model` | string | `""` | LLM model identifier set as `SWARM_LLM_MODEL`. Consumed by `openai-compat`; ignored by `claude`. |
| `enabled-sinks` | string | `""` | *Reserved* — comma-separated notify sinks. Wired when `transition` exposes the input. |
| `buzz-channel` | string | `""` | *Reserved* — Buzz/Nostr channel UUID. Wired when `notify` passthrough is added. |

**Caller example:**

```yaml
# .github/workflows/swarm.yml (consumer repo)
on:
  issues:
    types: [labeled]

jobs:
  intake:
    if: github.event.label.name == 'swarm:go' && github.event.issue.pull_request == null
    uses: benmarte/swarm/.github/workflows/intake.yml@v1
    with:
      issue: ${{ github.event.issue.number }}
      runner-label: swarm-agent
      dry-run: false
      adapter: claude
    secrets: inherit
```

---

### `spec.yml` — PM spec generation (SPEC §2.2 + §8)

Runs the **PM** agent on a confirmed issue and posts the resulting spec:

1. PM agent produces `outcome.json` (uploaded as artifact `outcome-<issue>`).
2. Glue job posts `evidence.spec_body` as an issue comment.
3. Glue job calls `actions/transition` swarm:spec → swarm:develop.

> **§8 decision:** `spec.yml` owns the issue comment and artifact only.
> Committing `docs/specs/issue-N.md` to the feature branch is `develop.yml`'s responsibility (#7)
> — the feature branch does not exist at spec stage.

**Caller-input surface:**

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `issue` | number | *(required)* | Issue number to spec. |
| `runner-label` | string | `swarm-agent` | Runner label for the agent job. Glue jobs always use `ubuntu-latest`. |
| `dry-run` | boolean | `false` | When `true`, logs intended comment/transition without executing any GitHub API writes. |
| `adapter` | string | `claude` | Agent adapter forwarded to `agent-run`. One of: `claude`, `openai-compat`. |
| `model` | string | `""` | LLM model identifier set as `SWARM_LLM_MODEL`. Consumed by `openai-compat`; ignored by `claude`. |
| `enabled-sinks` | string | `""` | *Reserved* — comma-separated notify sinks. Wired when `transition` exposes the input. |
| `buzz-channel` | string | `""` | *Reserved* — Buzz/Nostr channel UUID. Wired when `notify` passthrough is added. |

**Caller example:**

```yaml
# .github/workflows/swarm.yml (consumer repo)
on:
  issues:
    types: [labeled]

jobs:
  spec:
    if: github.event.label.name == 'swarm:spec' && github.event.issue.pull_request == null
    uses: benmarte/swarm/.github/workflows/spec.yml@v1
    with:
      issue: ${{ github.event.issue.number }}
      runner-label: swarm-agent
      dry-run: false
      adapter: claude
    secrets: inherit
```

---

## Planned workflows (issues #7+)

| File | Stage | Agent? |
|------|-------|--------|
| `develop.yml` | Coding agent opens a branch + PR | pluggable adapter |
| `pr-gates.yml` | Reviewer + security checks on swarm PRs | reviewer, security |
| `fix.yml` | Fix-loop on failed checks; bump attempts or escalate | via @claude |
| `docs.yml` | Docs agent after PR merge | docs |
| `sweeper.yml` | Nightly stuck-issue audit | orchestrator |

---

## Common design invariants (all workflows)

- `on: workflow_call` — all workflows are reusable; never triggered directly.
- `concurrency: swarm-${{ inputs.issue }}` with `cancel-in-progress: false` — deduplicates rapid re-triggers without cancelling an in-flight run for the same issue.
- **Least-privilege permissions per job:**
  - Agent jobs: `contents: read` + `issues: read`
  - Glue jobs: `contents: read` + `issues: write`
- `timeout-minutes` on every job.
- All third-party actions pinned to full SHAs (supply-chain rule; SPEC §4).
- `${{ }}` expressions are used only in `with:`, `env:`, `if:`, and `concurrency:`; never inside `run:` blocks (untrusted input guard).
- Agent jobs run on `${{ inputs.runner-label }}`; all glue/routing jobs run on `ubuntu-latest`.
