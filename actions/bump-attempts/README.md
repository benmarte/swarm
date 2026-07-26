# actions/bump-attempts/

Composite action — reads and increments the `swarm:attempts:N` label on an issue.

Behavior:
- Reads the current `swarm:attempts:N` label (N defaults to 0 if absent)
- Removes the current label, adds `swarm:attempts:<N+1>`
- If N+1 reaches the configured limit (default 3): applies `swarm:needs-human`, assigns the repo maintainer, and calls `notify` to alert configured sinks

Inputs: `issue-number`, `limit` (default 3), `assignee`

The limit boundary is: `< limit` → increment and re-enter the fix loop; `== limit` → escalate to human. The pipeline never makes more than `limit` automated fix attempts.

**Not yet implemented** — scaffold placeholder for issue #1.
