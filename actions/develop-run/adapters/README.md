# actions/develop-run/adapters/

Adapter scripts/directories for the `develop-run` composite action. Each adapter implements the coding-agent contract: given issue context + spec, produce a pushed branch and open PR.

Required adapter interface (see `schemas/runner-contract.md`):
- Reads: `ISSUE_NUMBER`, `ISSUE_BODY`, `SPEC_COMMENT`, `BRANCH_NAME` environment variables (set by `develop-run`)
- Must: edit the working tree to implement the spec
- Must NOT: push, create the PR, or apply labels — the engine owns all git/gh operations
- Exit 0 on success; non-zero triggers the fix loop (re-invocation with failing-check context)

Planned adapters (issues #2+):
- `claude-code-action/` — configuration for `anthropics/claude-code-action`
- `headless.sh` — generic coding CLI wrapper

**Not yet implemented** — scaffold placeholder for issue #1.
