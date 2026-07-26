# swarm

Reusable GitHub Actions workflows + composite actions that turn any repo into a multi-agent development pipeline: issue in → validated → specced → implemented → QA/review/security-gated → documented → merged.

**Design thesis:** GitHub is the state machine (labels, PR states, checks, concurrency groups). AI agents are stateless decision oracles — they emit schema-validated `outcome.json`; deterministic workflow steps perform every transition. LLM-agnostic by contract (Claude default; any cloud or local model via adapters).

📋 Full specification: [SPEC.md](SPEC.md)

## Status

🚧 Under construction — being built by [Talos](https://github.com/benmarte/talos) working through this repo's issue backlog (dogfood). Prior art: Talos's `examples/github-actions/` variant and the Daedalus/Hermes pipeline swarm supersedes.

## Verify

```bash
bash scripts/verify.sh   # shellcheck + actionlint + bats (used by CI and the Talos gate)
```
