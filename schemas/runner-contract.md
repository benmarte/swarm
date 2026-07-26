# Runner Contract

Swarm's adapter interfaces. Per SPEC §2.3.

Adding a new adapter means dropping one script into the correct adapters/ directory — no workflow changes needed.

---

## 1. `agent-run` — decision adapter interface

**Purpose:** Invokes an AI agent for a decision-role step (validator, pm, reviewer, security, docs, orchestrator). The engine never reads agent prose; the adapter must write a schema-valid `outcome.json`.

### Composite action inputs

| Input | Type | Required | Description |
|-------|------|----------|-------------|
| `prompt-file` | path | yes | Absolute path to the role prompt (Markdown). |
| `context-json` | string | yes | JSON string with issue/PR context injected into the prompt. |
| `role` | string | yes | One of: `validator`, `pm`, `reviewer`, `security`, `docs`, `orchestrator`. |
| `adapter` | string | yes | Adapter name. Default: `claude`. |
| `timeout` | integer | no | Max seconds to wait for the agent response. Default: 300. |

### Adapter contract

The engine calls `actions/agent-run/adapters/<adapter>.sh` with these environment variables set:

```
SWARM_PROMPT_FILE     absolute path to the prompt file
SWARM_CONTEXT_JSON    JSON string with issue/PR context
SWARM_ROLE            role name
SWARM_TIMEOUT         timeout in seconds
GITHUB_WORKSPACE      working directory (set by Actions)
```

The adapter **MUST**:

- Write a valid `outcome.json` to `$GITHUB_WORKSPACE/outcome.json` before exiting.
- The file must conform to `schemas/outcome.schema.json` with `schema: "swarm/outcome@1"` and `role` matching `$SWARM_ROLE`.
- Exit 0 on success; exit non-zero on unrecoverable error (e.g., API unreachable after retries).
- Never write outside `$GITHUB_WORKSPACE`.
- Never modify labels, PRs, issues, or any GitHub state.

The adapter **MUST NOT**:

- Apply or remove GitHub labels.
- Post comments or reviews.
- Approve or reject PRs.
- Write any files other than `outcome.json` (and optional artifacts in `$GITHUB_WORKSPACE/artifacts/`).

The engine validates `outcome.json` with `validate-outcome` immediately after the adapter exits. If validation fails, the job fails — triggering the Actions-level fix loop.

### V1 adapters (shipped reference implementations)

#### `claude` — Claude headless CLI adapter

**Status:** ✅ shipped (`actions/agent-run/adapters/claude.sh`)

**How it works:**

1. Builds a full prompt by concatenating `$SWARM_PROMPT_FILE` content with the
   `$SWARM_CONTEXT_JSON` block.
2. Invokes `claude -p "$FULL_PROMPT" --output-format json --allowedTools "Read,Glob,Grep" --max-turns 1`.
3. Parses Claude's JSON envelope: extracts `.result` (the assistant's text response).
4. Validates `.result` parses as JSON; writes it to `$OUTCOME_FILE`.

**Key flags:**
- `--output-format json` — wraps the response in a structured envelope (not raw text).
- `--allowedTools "Read,Glob,Grep"` — read-only tools; Bash is excluded so decision
  roles cannot execute code.
- `--max-turns 1` — single-shot; no multi-turn agentic loops for decision steps.

**Required env:**
```
ANTHROPIC_API_KEY    # GitHub Actions secret — must be mapped to the job environment
SWARM_PROMPT_FILE    # path to role prompt
SWARM_CONTEXT_JSON   # issue/PR context JSON string
SWARM_ROLE           # role name
SWARM_TIMEOUT        # max seconds (passed as shell context; claude honors its own limits)
OUTCOME_FILE         # write destination for outcome.json
GITHUB_WORKSPACE     # working directory
```

**Adding a third adapter based on `claude`:** copy `claude.sh`, replace the
`claude -p` invocation with your CLI of choice, ensure `.result` or equivalent
is extracted as JSON, and write it to `$OUTCOME_FILE`.

---

#### `openai-compat` — OpenAI-compatible REST endpoint adapter

**Status:** ✅ shipped (`actions/agent-run/adapters/openai-compat.sh`)

**Compatible endpoints:** Ollama, LM Studio, vLLM, OpenAI, Anthropic (via
compatibility layer), and any server implementing `/v1/chat/completions`.

**How it works:**

1. Builds a `chat/completions` request with `response_format: {type: "json_object"}`.
2. Role prompt → `system` message; context JSON → `user` message.
3. Calls `$SWARM_LLM_BASE_URL/chat/completions` via `curl -m $SWARM_TIMEOUT`.
4. Extracts `choices[0].message.content`.
5. Validates content parses as JSON; if not, attempts to extract the first `{…}`
   block (fallback for models that ignore `response_format`).
6. Writes the JSON to `$OUTCOME_FILE`.

**Required env:**
```
SWARM_LLM_BASE_URL   # e.g. http://localhost:11434/v1 (Ollama)
                     #      http://localhost:1234/v1  (LM Studio)
                     #      https://api.openai.com/v1 (OpenAI)
SWARM_LLM_MODEL      # e.g. llama3.2, mistral, gpt-4o
SWARM_PROMPT_FILE    # path to role prompt
SWARM_CONTEXT_JSON   # issue/PR context JSON string
SWARM_ROLE           # role name
SWARM_TIMEOUT        # max seconds (passed to curl -m)
OUTCOME_FILE         # write destination for outcome.json
GITHUB_WORKSPACE     # working directory
```

**Optional env:**
```
SWARM_LLM_API_KEY    # bearer token; omit for local endpoints that need none
```

**Local smoke test (Ollama):**
```bash
ollama serve &
ollama pull llama3.2

SWARM_LLM_BASE_URL=http://localhost:11434/v1 \
SWARM_LLM_MODEL=llama3.2 \
SWARM_PROMPT_FILE=prompts/validator.md \
SWARM_CONTEXT_JSON='{"issue":1,"title":"test issue","body":"smoke test"}' \
SWARM_ROLE=validator \
SWARM_TIMEOUT=120 \
OUTCOME_FILE=/tmp/outcome.json \
GITHUB_WORKSPACE=/tmp \
bash actions/agent-run/adapters/openai-compat.sh

cat /tmp/outcome.json | jq .
```

**CI behavior:** when `CI=true` and `SWARM_LLM_BASE_URL` is unset, the adapter
exits 0 with a loud `WARNING:` to stderr and skips the live call. This is the
ONLY allowed skip — it must always log.

---

## 2. `develop-run` — coding adapter interface

**Purpose:** Implements an issue on a branch and opens a PR. The engine verifies the PR exists (via GitHub API) rather than trusting adapter output — an adapter cannot fake completion.

### Composite action inputs

| Input | Type | Required | Description |
|-------|------|----------|-------------|
| `issue` | integer | yes | Issue number to implement. |
| `spec-comment-id` | string | yes | ID of the PM spec comment to inject as context. |
| `adapter` | string | yes | Adapter name. Default: `claude-code-action`. |
| `timeout` | integer | no | Max seconds. Default: 1800. |

### Adapter contract

The engine calls `actions/develop-run/adapters/<adapter>.sh` (or delegates to a sub-action) with:

```
SWARM_ISSUE           issue number
SWARM_BRANCH          branch name the engine pre-created: swarm/issue-N
SWARM_SPEC_BODY       full PM spec comment body
GITHUB_WORKSPACE      working directory (set by Actions)
GITHUB_REPOSITORY     owner/repo
```

The adapter **MUST**:

- Edit files in `$GITHUB_WORKSPACE` to implement the issue.
- The engine owns git identity configuration, commits, branch creation (`swarm/issue-N`), push, and `gh pr create`.
- For the `headless` adapter: the adapter only edits the working tree; the engine performs all git operations.
- For `claude-code-action`: the action itself handles git + PR; the engine skips its own git steps.
- Exit 0 when the working tree edits are complete (headless) or when the PR is open (claude-code-action).

The adapter **MUST NOT**:

- Push to branches other than `swarm/issue-N`.
- Open PRs targeting branches other than the integration branch.
- Modify `swarm:*` labels.
- Write outside `$GITHUB_WORKSPACE`.

### Fix loop behavior

On a failed required check, the engine re-invokes the adapter with additional environment:

```
SWARM_FIX_CONTEXT     JSON: {check_name, conclusion, log_url, attempt_number}
```

The adapter receives the same branch (already exists), applies fixes, and exits. The engine commits, pushes, and updates the PR. The `bump-attempts` action increments the counter; at 3 attempts the issue is escalated to `swarm:needs-human`.

### V1 adapters

- `claude-code-action` — delegates to `anthropics/claude-code-action` (SHA-pinned). Fix loop via `@claude` PR comment trigger.
- `headless` — wraps any coding CLI (`claude -p`, codex, goose, aider, or a local model harness). The adapter only edits the working tree; the engine handles all git operations. Selected via consumer `swarm.config.yml develop.adapter: headless`.
