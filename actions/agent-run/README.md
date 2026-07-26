# actions/agent-run/

Composite action — the **agent runner contract**.

Inputs: `prompt-file`, `context-json`, `role`, `adapter`, `timeout`.

Invokes `actions/agent-run/adapters/<adapter>.sh`, which writes `outcome.json` (schema-validated by `validate-outcome`). The workflow engine never reads agent prose — only the structured `outcome.json`.

V1 adapters (see `adapters/`):
- `claude` — Claude Code headless (`claude -p`, `--output-format json`, constrained tools)
- `openai-compat` — any OpenAI-compatible endpoint (Ollama, LM Studio, vLLM, or cloud) via `curl` + `jq`; endpoint/model configured via consumer-repo variables `SWARM_LLM_BASE_URL` / `SWARM_LLM_MODEL`

See `schemas/runner-contract.md` for the full adapter interface specification, env-variable contract, and local smoke-test commands for each adapter.
