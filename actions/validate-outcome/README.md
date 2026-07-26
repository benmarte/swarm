# actions/validate-outcome/

Composite action — validates `outcome.json` against `schemas/outcome.schema.json` using `ajv-cli` (pinned version).

If validation fails, the job fails immediately — this triggers the Actions-level fix loop. There is no prefix parsing or prose interpretation: the engine only accepts schema-valid structured output from agents.

Behavior:
- Reads `outcome.json` from `$GITHUB_WORKSPACE`
- Runs `ajv validate -s schemas/outcome.schema.json -d outcome.json`
- Exits 0 on valid; exits non-zero on invalid (schema error printed to stderr)

**Not yet implemented** — scaffold placeholder for issue #1.
