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

### V1 adapters

- `claude` — runs `claude -p <prompt>` headless with `--output-format json` and constrained tools. Maps Claude's JSON output to `outcome.json`.
- `openai-compat` — calls any OpenAI-compatible REST endpoint via `curl` + `jq`. Endpoint and model from `SWARM_LLM_BASE_URL` / `SWARM_LLM_MODEL` consumer variables.

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
