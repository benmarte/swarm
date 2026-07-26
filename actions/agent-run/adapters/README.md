# actions/agent-run/adapters/

Adapter scripts for the `agent-run` composite action. Each adapter translates the standardized runner contract into a specific LLM invocation.

Required adapter interface (see `schemas/runner-contract.md`):
- Reads: `SWARM_PROMPT_FILE`, `SWARM_CONTEXT_JSON`, `SWARM_ROLE`, `SWARM_TIMEOUT`, `OUTCOME_FILE` env vars (set by `agent-run`)
- Writes: `outcome.json` to `$OUTCOME_FILE` (path in `$GITHUB_WORKSPACE`) conforming to `schemas/outcome.schema.json`
- Exit 0 on success; non-zero causes the job to fail

V1 adapters (shipped with issue #5):
- `claude.sh` — Claude Code headless (`claude -p`, `--output-format json`, read-only tools); requires `ANTHROPIC_API_KEY` secret
- `openai-compat.sh` — any OpenAI-compatible endpoint via `curl` + `jq`; endpoint/model from `SWARM_LLM_BASE_URL` / `SWARM_LLM_MODEL`; CI-skips with a loud stderr warning when `SWARM_LLM_BASE_URL` is unset

See `schemas/runner-contract.md` for the full env-variable contract and local smoke-test commands.
