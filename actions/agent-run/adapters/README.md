# actions/agent-run/adapters/

Adapter scripts for the `agent-run` composite action. Each adapter translates the standardized runner contract into a specific LLM invocation.

Required adapter interface (see `schemas/runner-contract.md`):
- Reads: `PROMPT_FILE`, `CONTEXT_JSON`, `ROLE`, `TIMEOUT` environment variables (set by `agent-run`)
- Writes: `outcome.json` to `$GITHUB_WORKSPACE` in the schema defined by `schemas/outcome.schema.json`
- Exit 0 on success; non-zero causes the engine to enter the fix loop

Planned adapters (issues #2+):
- `claude.sh` — Claude Code headless via `claude -p`
- `openai-compat.sh` — any OpenAI-compatible endpoint via `curl` + `jq`

**Not yet implemented** — scaffold placeholder for issue #1.
