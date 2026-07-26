# docs/

Architecture documentation and adoption guides for swarm.

Files planned here (issues #2+):

| File | Purpose |
|------|---------|
| `architecture.md` | Deep-dive on the state machine, stigmergy design thesis, concurrency model, and supply-chain controls. |
| `adopting.md` | Step-by-step guide: a fresh repo adopts swarm in < 30 minutes without reading source. Covers bootstrap, caller workflow, `swarm.config.yml`, runner setup, and the first issue through `swarm:done`. |
| `security.md` | Threat model: prompt injection mitigations, least-privilege token scopes, supply-chain controls (SHA-pinned actions), secret hygiene, and the `swarm:go` human gate. |

Per SPEC §8, PM spec artifacts for each issue are also committed here as `specs/issue-N.md` on the feature branch, making them reviewable in the PR diff and durable after issue archival.

**Not yet implemented** — scaffold placeholder for issue #1.
