# actions/transition/

Composite action — **atomic label swap + transition comment + notify fan-out**.

This is the sole writer of `swarm:*` stage labels. No workflow or agent may apply/remove stage labels directly. Atomicity is enforced by GitHub's label API (last-write-wins within a concurrency group).

Behavior:
- Removes the `from` stage label from the issue
- Adds the `to` stage label
- Posts a transition comment (rendered from `templates/comments/`)
- Calls the `notify` composite action with a canonical event JSON

Inputs: `issue-number`, `from`, `to`, `summary`, `pr` (optional)

Re-entrant: if the `to` label is already present and `from` is absent, the action is a no-op (idempotency for re-runs).

**Not yet implemented** — scaffold placeholder for issue #1.
