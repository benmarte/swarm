# swarm

![CI](https://github.com/benmarte/swarm/actions/workflows/ci.yml/badge.svg)

Swarm is a collection of reusable GitHub Actions workflows and composite actions that turns any GitHub repository into a multi-agent software development pipeline: an issue goes in, gets validated, specced by a PM agent, implemented by a coding agent, reviewed and security-checked in parallel, documented, and merged — with humans gating only the merge environment and contested escalations.

**Design thesis.** The central lesson from Daedalus/Hermes was that AI agents must never own pipeline state and must never coordinate through free text. Swarm makes GitHub the state machine: labels and PR/check states carry state, Actions events drive transitions, and concurrency groups provide deduplication. AI agents are stateless decision oracles — invoked at a decision point, each emits a schema-validated `outcome.json`; a deterministic workflow step performs the transition. An agent can be wrong; it can never wedge the pipeline. The biology term for this pattern is *stigmergy* — coordination through traces left in a shared environment — hence the name.

**LLM-agnostic by contract.** Every decision role (`validator`, `pm`, `reviewer`, `security`, `docs`, `orchestrator`) is wired through the `agent-run` composite action, which dispatches to an adapter script. Two adapters ship: `claude` (Claude headless CLI, `--output-format json`, read-only tools) and `openai-compat` (any OpenAI-compatible endpoint — Ollama, LM Studio, vLLM, or cloud — via `curl` + jq). The develop stage similarly ships two adapters: `claude-code-action` (SHA-pinned, default) and `headless` (wraps any coding CLI: `claude -p`, aider, goose, codex, or a local model harness). Adapter selection is a caller input; no workflow code changes.

**What ships with swarm.** Seven reusable workflows (`intake`, `spec`, `develop`, `pr-gates`, `fix`, `docs`, `sweeper`) plus six composite actions (`agent-run`, `develop-run`, `validate-outcome`, `transition`, `bump-attempts`, `notify`). A one-time `bootstrap.sh` script provisions labels, the merge environment, and GitHub Secrets in the consumer repo. Configuration is split: behavior in a committed `swarm.config.yml`; credentials in a gitignored `.env` that bootstrap reads once.

---

## Quickstart

```bash
# 1. Copy the credential template and fill in your values.
cp .env.example .env
$EDITOR .env

# 2. Provision the consumer repo (idempotent — safe to re-run).
bash scripts/bootstrap.sh --env-file .env --repo owner/repo --reviewer @yourgithubhandle
```

`bootstrap.sh` creates all `swarm:*` and `pipeline:*` labels, the `swarm-approval` environment with a required human reviewer, seeds GitHub Secrets via `gh secret set` (values are never passed through argv or logged), writes a starter `swarm.config.yml`, and prints the caller-workflow snippet. Run it again after rotating any key.

```bash
# 3. Commit the generated swarm.config.yml and add the caller workflow.
git add swarm.config.yml .github/workflows/swarm.yml
git commit -m "chore: adopt swarm pipeline"
git push
```

See [docs/adopting.md](docs/adopting.md) for the full step-by-step guide, including branch protection setup, the complete pinned caller-workflow example, and the first-issue walkthrough.

---

## Feature matrix

| Feature | Status |
|---|---|
| Issue validation (duplicate / invalid / needs-info routing) | Shipped |
| PM spec generation (comment + branch artifact) | Shipped |
| Code development (claude-code-action + headless adapters) | Shipped |
| PR review agent (real GitHub review via SWARM_TOKEN) | Shipped |
| Security scan agent (advisory / fail / pass verdicts) | Shipped |
| Fix loop (3 attempts → escalate to `swarm:needs-human`) | Shipped |
| Docs agent (transition to `swarm:done`, close issue) | Shipped |
| Nightly sweeper (stuck-issue audit + escalation) | Shipped |
| Bootstrap script (idempotent label + secret provisioning) | Shipped |
| Config validation (ajv against `schemas/config.schema.json`) | Shipped |
| Schema-validated agent output (no prose parsing ever) | Shipped |

---

## Adapter table

### Decision-role adapter (`agent-run`)

| Adapter | How it works | When to use |
|---|---|---|
| `claude` | Runs `claude -p` headless CLI with `--output-format json --allowedTools "Read,Glob,Grep" --max-turns 1`. Requires `ANTHROPIC_API_KEY`. | Default. Best quality on spec, review, security roles. |
| `openai-compat` | POSTs to `$SWARM_LLM_BASE_URL/v1/chat/completions` via `curl`. Supports Ollama, LM Studio, vLLM, OpenAI, or any compatible endpoint. Requires `SWARM_LLM_BASE_URL` + `SWARM_LLM_MODEL`. | Local models, cost control, provider portability. |

### Develop-stage adapter (`develop-run`)

| Adapter | How it works | When to use |
|---|---|---|
| `claude-code-action` | Delegates to `anthropics/claude-code-action` (SHA-pinned). Runs in file-edit mode (`create_pull_request=false`); engine always creates the PR. Fix loop via `@claude` PR comment. | Default. Full Claude Code tool suite. |
| `headless` | Invokes any coding CLI (`claude -p`, aider, goose, codex, or a local model harness). Engine owns git identity, branch naming (`swarm/issue-N`), commit, push, and `gh pr create`. Fix loop re-invokes adapter with `SWARM_FIX_CONTEXT` JSON. | Non-Claude coding agents, local model experiments. |

### Notify adapter (`notify`)

| Adapter | Transport | Required secrets |
|---|---|---|
| `slack` | Outbound webhook POST | `SWARM_SLACK_WEBHOOK` |
| `discord` | Outbound webhook POST | `SWARM_DISCORD_WEBHOOK` |
| `teams` | Outbound webhook POST | `SWARM_TEAMS_WEBHOOK` |
| `buzz` | Nostr NIP-29, `kind:9` event via `nak` CLI | `SWARM_BUZZ_RELAY_URL`, `SWARM_BUZZ_PRIVATE_KEY`; channel UUID in `swarm.config.yml notify.buzz_channel` |

---

## Repository layout

```
workflows/          reusable workflow entry-points (one per pipeline stage)
actions/
  agent-run/        decision-role runner contract; adapters/claude.sh + openai-compat.sh
  develop-run/      coding-agent contract; adapters/claude-code-action/ + headless.sh
  transition/       atomic label swap + comment + notify fan-out
  bump-attempts/    fix-loop attempt counter + escalation to swarm:needs-human
  notify/           event fan-out; adapters/slack.sh + discord.sh + teams.sh + buzz.sh
  validate-outcome/ schema validation for agent output (ajv-cli@5.0.0)
  load-config/      validates swarm.config.yml, exports config as step outputs
prompts/            versioned role prompts (one per agent role)
schemas/            outcome.schema.json, event.schema.json, config.schema.json,
                    runner-contract.md (adapter interface spec)
docs/               architecture.md, adopting.md, security.md
scripts/            bootstrap.sh (provisioning), verify.sh (CI gate)
tests/              bats test suite for all composite actions
```

---

## Documentation

- [docs/adopting.md](docs/adopting.md) — step-by-step consumer adoption guide (< 30 minutes)
- [docs/architecture.md](docs/architecture.md) — state machine, stigmergy thesis, contracts, execution model
- [docs/security.md](docs/security.md) — threat model and boundary enforcement
- [schemas/runner-contract.md](schemas/runner-contract.md) — adapter interface spec for `agent-run` and `develop-run`
- [SPEC.md](SPEC.md) — full product specification

---

## Verify

```bash
bash scripts/verify.sh   # shellcheck + actionlint + bats (same gate as CI)
```
