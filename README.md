# swarm

![CI](https://github.com/benmarte/swarm/actions/workflows/ci.yml/badge.svg)

Reusable GitHub Actions workflows + composite actions that turn any repo into a multi-agent development pipeline: issue in → validated → specced → implemented → QA/review/security-gated → documented → merged.

**Design thesis:** GitHub is the state machine (labels, PR states, checks, concurrency groups). AI agents are stateless decision oracles — they emit schema-validated `outcome.json`; deterministic workflow steps perform every transition. LLM-agnostic by contract (Claude default; any cloud or local model via adapters).

📋 Full specification: [SPEC.md](SPEC.md)

## Status

🚧 Under construction — being built by [Talos](https://github.com/benmarte/talos) working through this repo's issue backlog (dogfood). Prior art: Talos's `examples/github-actions/` variant and the Daedalus/Hermes pipeline swarm supersedes.

Scaffold (issue #1) and contracts layer (issue #2) are merged. CI runs `scripts/verify.sh` (shellcheck + actionlint + bats) on every push and PR. Issue #2 shipped `outcome`, `event`, and `config` JSON schemas plus the `validate-outcome` composite action that enforces schema-valid output on every agent job. Issue #3 shipped `actions/transition/` (atomic stage-label swap) and `actions/bump-attempts/` (escalation counter) with full bats test coverage. Issue #4 shipped `actions/notify/` — fan-out to four sinks (Slack, Discord, Teams, Buzz/Nostr) with loud-failure semantics and full bats coverage. Issue #5 shipped `actions/agent-run` — the runner contract — with two v1 adapters (`claude`, `openai-compat`) and role prompts `validator.md` / `pm.md`. Issue #6 shipped `workflows/intake.yml` and `workflows/spec.yml` — the first two reusable pipeline-stage workflows (validator routing and PM spec generation) with 16 new bats tests; see `workflows/README.md` for caller-input docs and examples. Issue #7 shipped `actions/develop-run/` (coding-contract engine with engine-owns-everything contract), `adapters/headless.sh` (any-CLI wrapper), `adapters/claude-code-action/` (SHA-pinned wrapper pattern), and `workflows/develop.yml` with 29 unit+integration bats tests; see `workflows/README.md` for `develop.yml` caller-input docs. Issue #8 shipped `workflows/pr-gates.yml` (parallel reviewer + security agents; reviewer posts a real GitHub PR review via `SWARM_TOKEN`), `workflows/fix.yml` (gate-failure fix loop with attempt counter; skips re-invocation when `needs-human=true`), role prompts `reviewer.md` / `security.md`, and the `needs-human` output for `actions/bump-attempts` with 51 new bats tests; see `workflows/README.md` for caller-input docs and `SWARM_TOKEN` requirements. Issue #9 shipped `workflows/docs.yml` (terminal docs stage — audit-only agent, transitions swarm:docs → swarm:done, closes issue), `workflows/sweeper.yml` (nightly orchestrator audit, escalates stuck issues via `swarm:needs-human`), role prompts `prompts/docs.md` / `prompts/orchestrator.md`, and enforcement scripts `scripts/check-skipped-reason.sh` / `scripts/parse-sweeper-report.sh`; see `workflows/README.md` for caller-input docs and the sweeper cron example. Issue #10 shipped `scripts/bootstrap.sh` (idempotent repo setup — creates all swarm labels, the `swarm-approval` environment, and seeds secrets from `.env.example` without values ever appearing in argv or logs) and `actions/load-config/` (composite action that validates `swarm.config.yml` against the JSON schema and exports pipeline config values as step outputs; wired as the first step in `intake.yml`).

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
  load-config/  validates swarm.config.yml, exports pipeline config as step outputs
prompts/        versioned role prompts (one per agent role)
schemas/        JSON schemas + adapter interface contract
docs/           architecture docs and adoption guide (planned)
scripts/        local tooling (verify.sh, bootstrap.sh)
tests/          bats smoke tests
```

## Quickstart

> Full adopting guide is tracked in issue #11.

```bash
cp .env.example .env          # document your credential names; fill in values
bash scripts/bootstrap.sh --env-file .env --repo owner/repo --reviewer @handle
```

`bootstrap.sh` creates all `swarm:*` and `pipeline:*` labels, the `swarm-approval` environment with the required reviewer, and seeds secrets via `gh secret set` (values never appear in argv or logs). It also writes a starter `swarm.config.yml` and prints the caller-workflow snippet. Run it again at any time — it is idempotent.

## Verify

```bash
bash scripts/verify.sh   # shellcheck + actionlint + bats (used by CI and the Talos gate)
```
