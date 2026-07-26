# actions/validate-outcome/

Composite action — validates `outcome.json` against `schemas/outcome.schema.json` using `ajv-cli` (pinned version).

If validation fails, the job fails immediately — this triggers the Actions-level fix loop. There is no prefix parsing or prose interpretation: the engine only accepts schema-valid structured output from agents.

Behavior:
- Accepts `outcome-file` input (default: `outcome.json`) and resolves the schema path relative to the action directory
- Runs `ajv validate -s schemas/outcome.schema.json -d <outcome-file>` via `validate.sh`
- Exits 0 on valid; exits non-zero on invalid with an actionable error printed to stderr

Implemented in issue #2. `ajv-cli` is pinned to `5.0.0` in both the action and CI.
