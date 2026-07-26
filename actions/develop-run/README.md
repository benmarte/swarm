# actions/develop-run/

Composite action — the **coding contract** (develop stage + fix loop).

Given issue context + spec, an adapter must produce a pushed branch and an open PR linking the issue. The engine verifies the PR exists rather than trusting adapter output.

V1 adapters (see `adapters/`):
- `claude-code-action` (default) — uses `anthropics/claude-code-action`; fix loop via `@claude` PR comments
- `headless` — wraps any coding CLI (`claude -p`, codex, goose, aider, or a local-model harness); the engine owns git identity, branch naming `swarm/issue-N`, push, and `gh pr create`, so the adapter only edits the working tree; fix loop re-invokes the adapter with the failing-check context

Adapter selection is a caller input to `develop.yml` — no engine changes required to switch adapters.

See `schemas/runner-contract.md` for the full coding-adapter interface specification.

**Not yet implemented** — scaffold placeholder for issue #1.
