# .github/workflows/ — reusable workflows

> **GitHub cross-repo constraint:** reusable workflows (`on: workflow_call`) MUST live in
> `.github/workflows/` of the called repo — GitHub does not resolve `uses:` references to
> any other directory or subdirectory. All seven swarm product workflows live here alongside
> `ci.yml`. The `workflows/` directory at the repo root is retained as a pointer only.

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

### `develop.yml` — Coding agent (SPEC §2.3)

Runs the coding-agent contract: given an issue in `swarm:develop`, opens a feature branch `swarm/issue-N`, commits the PM spec, invokes the coding adapter, opens a PR with `Closes #N`, verifies the PR via `gh api`, and transitions the issue to `swarm:qa`.

Key design decisions: **engine-owns-everything** (see `actions/develop-run/README.md`); `claude-code-action` adapter runs as a conditional step before the engine; SHA-pinned third-party action; `concurrency: swarm-${{ inputs.issue }}` at workflow level.

**Caller-input surface:**

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `issue` | number | *(required)* | Issue number to implement. |
| `runner-label` | string | `swarm-agent` | Runner label for the coding job. |
| `dry-run` | boolean | `false` | Log all mutations without executing GitHub API writes. |
| `adapter` | string | `claude-code-action` | Coding adapter. One of: `claude-code-action`, `headless`. |
| `adapter-cmd` | string | `""` | CLI command for the `headless` adapter (e.g. `claude -p`). |
| `model` | string | `""` | LLM model identifier recorded in the PR body. |
| `base-branch` | string | `main` | Integration branch for branch creation and PR target. |
| `maintainer` | string | `""` | GitHub username to assign when `bump-attempts` escalates. |

**Caller example:**

```yaml
# .github/workflows/swarm.yml (consumer repo)
on:
  issues:
    types: [labeled]

jobs:
  develop:
    if: github.event.label.name == 'swarm:develop' && github.event.issue.pull_request == null
    uses: benmarte/swarm/.github/workflows/develop.yml@v1
    with:
      issue: ${{ github.event.issue.number }}
      runner-label: swarm-agent
      adapter: claude-code-action
    secrets: inherit
```

---

---

### `pr-gates.yml` — PR reviewer + security gate (SPEC §2.2)

Runs **reviewer** and **security** agents in parallel on a swarm PR. Posts a
real GitHub PR review (approve / request-changes) authenticated via
`SWARM_TOKEN`, and posts a PR comment on security advisory or fail.

> **QA note:** `pr-gates.yml` does NOT run a swarm QA agent. QA = the
> consumer's own CI checks declared as required status checks via branch
> protection. The swarm pipeline gates on those external checks; no redundant
> QA agent job is included here. Full wiring via `qa-required-checks` input is
> planned for #10.

> **SWARM_TOKEN requirement:** Consumers MUST provision a `SWARM_TOKEN` secret
> pointing to a fine-grained PAT with `pull-requests: write` scope for a
> **distinct actor** (not the same identity that opened the PR). This is
> required because `GITHUB_TOKEN` cannot approve a PR it opened (SPEC §6).
> On `dry-run: true`, `SWARM_TOKEN` is not required.

**Caller-input surface:**

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `pr` | number | *(required)* | PR number to review. |
| `issue` | number | *(required)* | Issue number being implemented. |
| `runner-label` | string | `swarm-agent` | Runner label for agent jobs. Glue jobs use `ubuntu-latest`. |
| `dry-run` | boolean | `false` | Log intended mutations without executing any GitHub API writes. |
| `adapter` | string | `claude` | Agent adapter forwarded to `agent-run`. One of: `claude`, `openai-compat`. |
| `model` | string | `""` | LLM model identifier. |
| `maintainer` | string | `""` | Reserved; unused in this workflow. |
| `qa-required-checks` | string | `""` | Reserved — comma-separated check names; pending #10. |

**Required secret:**

| Secret | Description |
|--------|-------------|
| `SWARM_TOKEN` | Fine-grained PAT with `pull-requests: write` scope for a distinct actor. Required when `dry-run: false`. |

**Caller example:**

```yaml
# .github/workflows/swarm.yml (consumer repo)
on:
  pull_request:
    types: [opened, synchronize, reopened]
    branches: ['swarm/issue-*']

jobs:
  pr-gates:
    uses: benmarte/swarm/.github/workflows/pr-gates.yml@v1
    with:
      pr: ${{ github.event.pull_request.number }}
      issue: ${{ github.event.pull_request.number }}  # adjust to your issue extraction
      runner-label: swarm-agent
      dry-run: false
      adapter: claude
    secrets:
      SWARM_TOKEN: ${{ secrets.SWARM_TOKEN }}
```

---

### `fix.yml` — Gate-failure fix loop (SPEC §2.2)

Triggered when a PR's required checks fail. Bumps the fix attempt counter and
— if the limit has not been reached — re-invokes the develop adapter with
failing-check context so it can address the failures automatically.

**Escalation:** at attempt 3, `actions/bump-attempts` applies
`swarm:needs-human`, assigns the configured maintainer, and the fix-invoke job
is skipped. No additional escalation steps are needed in `fix.yml`.

**dry-run semantics:** `dry-run: true` → `bump-attempts` step is **skipped**
(counter not incremented — safe for testing). All write steps log intent only.

**Caller-input surface:**

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `pr` | number | *(required)* | PR number on which checks failed. |
| `issue` | number | *(required)* | Issue number being implemented. |
| `maintainer` | string | *(required)* | GitHub username to assign on escalation. |
| `runner-label` | string | `swarm-agent` | Runner label for fix-invoke job. Bump job uses `ubuntu-latest`. |
| `dry-run` | boolean | `false` | Skip bump-attempts; log all writes without executing. |
| `adapter` | string | `claude-code-action` | Adapter to re-invoke. One of: `claude-code-action`, `headless`. |
| `adapter-cmd` | string | `""` | CLI command for headless adapter. Required when `adapter: headless`. |
| `model` | string | `""` | LLM model identifier forwarded to the adapter. |
| `failing-checks` | string | `""` | Comma-separated failing check names forwarded as context. |

**Caller example:**

```yaml
# .github/workflows/swarm.yml (consumer repo)
on:
  check_suite:
    types: [completed]

jobs:
  fix:
    if: github.event.check_suite.conclusion == 'failure'
    uses: benmarte/swarm/.github/workflows/fix.yml@v1
    with:
      pr: ${{ github.event.check_suite.pull_requests[0].number }}
      issue: 42  # extract from PR branch name
      maintainer: your-github-username
      adapter: claude-code-action
      failing-checks: ${{ join(github.event.check_suite.check_runs.*.name, ',') }}
    secrets: inherit
```

---

### `docs.yml` — Post-merge documentation stage (SPEC §2.1/§2.2)

Called after a swarm PR is merged. Runs the **docs** agent to assess what should
be documented; posts a docs summary comment; transitions the issue `swarm:docs →
swarm:done`; closes the issue; notifies.

> **v1 simplification:** The docs agent is a decision role (audit-only). It emits
> `verdict + evidence` describing what needs documentation. Actual doc commits land
> via a normal human-authored or automation PR in a follow-up workflow (v1.1).

> **Skipped-reason enforcement:** A `verdict=skipped` outcome with an empty or
> absent `evidence.reason` causes the job to fail loudly. The schema cannot express
> this constraint — a deterministic step owns it via `scripts/check-skipped-reason.sh`.

**Caller-input surface:**

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `issue` | number | *(required)* | Issue number being documented. |
| `pr` | number | *(required)* | Merged PR number. |
| `runner-label` | string | `swarm-agent` | Runner label for the agent job. Glue jobs use `ubuntu-latest`. |
| `dry-run` | boolean | `false` | Log intended mutations without executing any GitHub API writes. |
| `adapter` | string | `claude` | Agent adapter forwarded to `agent-run`. One of: `claude`, `openai-compat`. |
| `model` | string | `""` | LLM model identifier. |
| `enabled-sinks` | string | `""` | Comma-separated notify sinks passthrough. |
| `buzz-channel` | string | `""` | Buzz/Nostr channel UUID passthrough. |

**Caller example:**

```yaml
# .github/workflows/swarm.yml (consumer repo)
on:
  pull_request:
    types: [closed]
    branches: ['swarm/issue-*']

jobs:
  docs:
    if: github.event.pull_request.merged == true
    uses: benmarte/swarm/.github/workflows/docs.yml@v1
    with:
      issue: 42  # extract from PR branch name
      pr: ${{ github.event.pull_request.number }}
      runner-label: swarm-agent
      dry-run: false
      adapter: claude
    secrets: inherit
```

---

### `sweeper.yml` — Nightly fleet auditor (SPEC §2.1/§2.2/§8.2)

Per SPEC §2.2, all swarm reusable workflows use `on: workflow_call` — consumers
pin `@v1` and own their own cron trigger. Gathers all open issues with `swarm:*`
labels, runs the **orchestrator** agent to audit for stalls, and applies
`swarm:needs-human` to stuck issues.

> **IMPORTANT (SPEC §8.2):** The sweeper NEVER touches `swarm:paused`. The only
> label the escalate job may add is `swarm:needs-human`. This constraint is
> structurally enforced by the workflow and verified by `tests/sweeper.bats`.

> **`workflow_dispatch` is also declared** for manual triggering inside the swarm
> repo itself (development / one-shot audits). The `schedule:` trigger lives
> **only in the caller workflow** — it is not declared here.

**Inputs (workflow_dispatch + schedule env defaults):**

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `stall-threshold-hours` | number | `48` | Hours of inactivity before an issue is considered stuck. |
| `runner-label` | string | `swarm-agent` | Runner label for the agent job. |
| `dry-run` | boolean | `false` | Log intended mutations without executing any GitHub API writes. |
| `adapter` | string | `claude` | Agent adapter forwarded to `agent-run`. |
| `model` | string | `""` | LLM model identifier. |
| `enabled-sinks` | string | `""` | Comma-separated notify sinks passthrough. |
| `buzz-channel` | string | `""` | Buzz/Nostr channel UUID passthrough. |

**Caller example (cron + dispatch):**

```yaml
# .github/workflows/swarm-sweep.yml (consumer repo)
on:
  schedule:
    - cron: '0 2 * * *'
  workflow_dispatch:
    inputs:
      stall-threshold-hours:
        description: Hours before an issue is stuck
        default: '48'
      dry-run:
        description: Log only, no mutations
        default: 'false'

jobs:
  sweeper:
    uses: benmarte/swarm/.github/workflows/sweeper.yml@v1
    with:
      stall-threshold-hours: ${{ fromJson(inputs.stall-threshold-hours || '48') }}
      dry-run: ${{ fromJson(inputs.dry-run || 'false') }}
      runner-label: swarm-agent
      adapter: claude
    secrets: inherit
```

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
