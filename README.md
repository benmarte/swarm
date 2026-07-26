# swarm

![CI](https://github.com/benmarte/swarm/actions/workflows/ci.yml/badge.svg)

Reusable GitHub Actions workflows + composite actions that turn any repo into a multi-agent development pipeline: issue in → validated → specced → implemented → QA/review/security-gated → documented → merged.

**Design thesis:** GitHub is the state machine (labels, PR states, checks, concurrency groups). AI agents are stateless decision oracles — they emit schema-validated `outcome.json`; deterministic workflow steps perform every transition. LLM-agnostic by contract (Claude default; any cloud or local model via adapters).

📋 Full specification: [SPEC.md](SPEC.md)

## Status

🚧 Under construction — being built by [Talos](https://github.com/benmarte/talos) working through this repo's issue backlog (dogfood). Prior art: Talos's `examples/github-actions/` variant and the Daedalus/Hermes pipeline swarm supersedes.

Scaffold (issue #1) and contracts layer (issue #2) are merged. CI runs `scripts/verify.sh` (shellcheck + actionlint + bats) on every push and PR. Issue #2 shipped `outcome`, `event`, and `config` JSON schemas plus the `validate-outcome` composite action that enforces schema-valid output on every agent job. Issue #3 shipped `actions/transition/` (atomic stage-label swap) and `actions/bump-attempts/` (escalation counter) with full bats test coverage. Issue #4 shipped `actions/notify/` — fan-out to four sinks (Slack, Discord, Teams, Buzz/Nostr) with loud-failure semantics and full bats coverage.

## Repository layout

```
workflows/      reusable workflow entry-points (one per pipeline stage)
actions/        composite actions called by those workflows
  agent-run/    runs a decision-role agent, validates outcome.json
  develop-run/  coding-agent contract (branch + PR)
  transition/   atomic label swap + comment + notify
  bump-attempts/ escalation counter
  notify/       event fan-out to Slack / Discord / Teams / Buzz
  validate-outcome/ schema validation for agent output
prompts/        versioned role prompts (one per agent role)
schemas/        JSON schemas + adapter interface contract
docs/           architecture docs and adoption guide (planned)
scripts/        local tooling (verify.sh)
tests/          bats smoke tests
```

## Verify

```bash
bash scripts/verify.sh   # shellcheck + actionlint + bats (used by CI and the Talos gate)
```
