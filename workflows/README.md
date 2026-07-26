# workflows/

Reusable GitHub Actions workflows (`on: workflow_call`) — the swarm product.

Each workflow here is a pipeline stage called from a thin caller workflow in the consumer repo. Consumers pin `benmarte/swarm/.github/workflows/<name>.yml@v1` and map their own triggers to the reusable entry-point.

Planned workflows (issues #2+):

| File | Stage | Agent? |
|------|-------|--------|
| `intake.yml` | Validate an issue before speccing | validator |
| `spec.yml` | PM agent produces a spec comment + artifact | PM |
| `develop.yml` | Coding agent opens a branch + PR | pluggable adapter |
| `pr-gates.yml` | Reviewer + security checks on swarm PRs | reviewer, security |
| `fix.yml` | Fix-loop on failed checks; bump attempts or escalate | via @claude |
| `docs.yml` | Docs agent after PR merge | docs |
| `sweeper.yml` | Nightly stuck-issue audit | orchestrator |

**None of the above are implemented yet** — this directory is the scaffold placeholder for issue #1.
