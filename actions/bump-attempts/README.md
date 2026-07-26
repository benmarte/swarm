# actions/bump-attempts/

Composite action — reads and increments the `swarm:attempts:N` label on an issue, escalating to human review at the limit.

Behavior:
- Reads the current `swarm:attempts:N` label (N=0 if absent)
- Removes the current label, adds `swarm:attempts:<N+1>`
- Labels are drawn from a fixed allowlist: `swarm:attempts:1`, `swarm:attempts:2`, `swarm:attempts:3`
- At N=3 (the hard limit): applies `swarm:needs-human`, assigns `maintainer`, posts an escalation comment, emits an escalation event JSON to `$RUNNER_TEMP/escalation-event.json`, and invokes the `notify` hook (stub until #4 lands)
- Already-at-limit calls exit 0 without further action (idempotent)

Inputs: `issue-number`, `maintainer`, `post-comment` (default `true`)

Outputs:

| Output | Value | Description |
|--------|-------|-------------|
| `needs-human` | `true` | Attempts reached the limit (escalation applied, or was already at limit). |
| `needs-human` | `false` | Counter incremented but limit not yet reached; fix re-invocation may proceed. |

The attempt limit is fixed at 3. The pipeline never makes more than 3 automated fix attempts per issue.

Required job permissions: `issues: write`, `contents: read`
