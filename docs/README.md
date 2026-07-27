# docs/

Architecture documentation and adoption guides for swarm.

| File | Purpose |
|------|---------|
| [adopting.md](adopting.md) | Step-by-step consumer adoption guide: prerequisites, bootstrap, caller workflow, branch protection, first-issue walkthrough, key rotation, troubleshooting. Target: a fresh repo in < 30 minutes. |
| [architecture.md](architecture.md) | Deep-dive on the stigmergy design thesis, the full state machine (mermaid diagram), workflow table, composite-action reference, the three contracts (outcome / event / config), adapter model, execution/auth model, and fix-loop behavior. |
| [security.md](security.md) | Threat model: eight security boundaries each with its enforcement file and mechanism named — human gate, fork-PR guard, prompt-injection mitigations, label-write restriction, schema validation, least-privilege permissions, SHA pinning, and secret hygiene. |

Per SPEC §8.1, PM spec artifacts for each issue are committed here as `specs/issue-N.md` on the feature branch, making them reviewable in the PR diff and durable after issue archival.

For the full product specification, see [SPEC.md](../SPEC.md).

For the adapter interface contract (how to add a new agent adapter or coding adapter), see [schemas/runner-contract.md](../schemas/runner-contract.md).
