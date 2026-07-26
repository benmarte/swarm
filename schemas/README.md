# schemas/

Versioned JSON schemas and interface contracts for swarm.

Files planned here (issues #2+):

| File | Purpose |
|------|---------|
| `outcome.schema.json` | Schema for agent output: `{schema, role, verdict, refs, evidence, notes}`. Per-role verdict enums enforced here. |
| `event.schema.json` | Schema for notify payloads: `{event, repo, issue, pr, stage_from, stage_to, actor, url, summary}`. |
| `config.schema.json` | Schema for `swarm.config.yml` in consumer repos. Validated by the caller workflow on every run. |
| `runner-contract.md` | Human-readable adapter interface spec for both `agent-run` (decision roles) and `develop-run` (coding role). |

All schemas are versioned (`swarm/outcome@1`, etc.). Breaking schema changes require a major version bump and a migration path for existing consumers.

`validate-outcome` uses `ajv-cli` (pinned) to enforce `outcome.schema.json` on every agent job — no prose parsing, ever.

**Not yet implemented** — scaffold placeholder for issue #1.
