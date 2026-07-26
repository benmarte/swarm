# actions/transition/

Composite action — **atomic label swap + transition comment + notify fan-out**.

This is the sole writer of `swarm:*` stage labels. No workflow or agent may apply/remove stage labels directly. Atomicity is enforced by GitHub's label API (last-write-wins within a concurrency group).

Behavior:
- Validates `from-stage` and `to-stage` against a hard-coded allowlist before any API call
- Removes the `from-stage` label from the issue
- Adds the `to-stage` label
- Posts a transition comment when `post-comment` is `true` (default)
- Invokes the `notify` hook (stub until #4 lands)

Inputs: `issue-number`, `from-stage`, `to-stage`, `post-comment` (default `true`)

Valid stage labels: `swarm:go`, `swarm:spec`, `swarm:develop`, `swarm:qa`, `swarm:docs`, `swarm:done`, `swarm:needs-human`, `swarm:paused`

Re-entrant: if `to-stage` is already present and `from-stage` is absent, the action exits 0 as a no-op (idempotency for re-runs).

Required job permissions: `issues: write`, `contents: read`
