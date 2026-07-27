#!/usr/bin/env bash
# load-config.sh — reads + validates swarm.config.yml, exports step outputs.
#
# Called by actions/load-config/action.yml (composite action).
# Environment variables set by the composite step:
#   CONFIG_FILE        — path to swarm.config.yml (relative to GITHUB_WORKSPACE)
#   GITHUB_WORKSPACE   — absolute path to the workspace root
#   GITHUB_OUTPUT      — path to the step-output file
#
# Exports the following GITHUB_OUTPUT keys (random delimiter for multiline safety):
#   notify-slack, notify-discord, notify-teams, notify-buzz-channel,
#   runner-label, develop-adapter, sweeper-schedule
#
# On invalid config: prints ajv errors to stderr and exits 1.
set -euo pipefail

# ACTION_PATH must be set — it is injected by the composite action step env.
# Fail loudly rather than silently falling back to a wrong path.
if [ -z "${ACTION_PATH:-}" ]; then
  echo "load-config: ERROR: ACTION_PATH is not set." >&2
  echo "  This script must be invoked via the load-config composite action," >&2
  echo "  which sets ACTION_PATH to \${{ github.action_path }}." >&2
  exit 1
fi

# SCHEMA_PATH is an engine asset — resolve via ACTION_PATH so it works in
# consumer repos where schemas/ is not present in GITHUB_WORKSPACE.
SCHEMA_PATH="${ACTION_PATH}/../../schemas/config.schema.json"

# CONFIG_PATH is a consumer asset — stays workspace-relative.
CONFIG_FILE="${CONFIG_FILE:-swarm.config.yml}"
_workspace="${GITHUB_WORKSPACE:-$(git rev-parse --show-toplevel 2>/dev/null || printf '.')}"

# Resolve config path: if it's absolute use as-is; otherwise relative to workspace
if printf '%s' "$CONFIG_FILE" | grep -q '^/'; then
  CONFIG_PATH="$CONFIG_FILE"
else
  CONFIG_PATH="${_workspace}/$CONFIG_FILE"
fi

# ── Existence checks ───────────────────────────────────────────────────────────
if [ ! -f "$CONFIG_PATH" ]; then
  echo "load-config: ERROR: config file not found: $CONFIG_PATH" >&2
  echo "  Create swarm.config.yml at the repo root or pass a custom path." >&2
  echo "  Run 'bash scripts/bootstrap.sh --env-file .env' to generate a starter config." >&2
  exit 1
fi

if [ ! -f "$SCHEMA_PATH" ]; then
  echo "load-config: ERROR: schema file not found: $SCHEMA_PATH" >&2
  echo "  The schemas/config.schema.json file must be present (merged in #2)." >&2
  exit 1
fi

echo "load-config: validating '$CONFIG_PATH' against '$SCHEMA_PATH'"

# ── Schema validation ──────────────────────────────────────────────────────────
if ! validation_output="$(ajv validate -s "$SCHEMA_PATH" -d "$CONFIG_PATH" 2>&1)"; then
  echo "" >&2
  echo "load-config: FAILED — swarm.config.yml did not pass schema validation." >&2
  echo "" >&2
  echo "Config:  $CONFIG_PATH" >&2
  echo "Schema:  $SCHEMA_PATH" >&2
  echo "" >&2
  echo "Validation errors:" >&2
  echo "$validation_output" >&2
  echo "" >&2
  echo "Common mistakes:" >&2
  echo "  - Secret keys (SWARM_GITHUB_TOKEN, ANTHROPIC_API_KEY, etc.) must NOT" >&2
  echo "    appear in swarm.config.yml — they belong in .env / GitHub Secrets." >&2
  echo "  - See schemas/config.schema.json for allowed fields and types." >&2
  exit 1
fi

echo "load-config: validation passed"

# ── Convert YAML → JSON (one-shot, before any jq extraction) ──────────────────
# jq cannot parse YAML directly; convert once to a temp file and clean up on exit.
_config_json="$(mktemp)"
trap 'rm -f "$_config_json"' EXIT

if command -v python3 >/dev/null 2>&1 && python3 -c "import yaml" 2>/dev/null; then
  python3 -c 'import yaml,json,sys; json.dump(yaml.safe_load(open(sys.argv[1])), sys.stdout)' \
    "$CONFIG_PATH" > "$_config_json"
elif NODE_PATH="$(npm root -g 2>/dev/null)" node \
       -e "require('js-yaml')" 2>/dev/null; then
  NODE_PATH="$(npm root -g 2>/dev/null)" node \
    -e "const fs=require('fs'); const yaml=require('js-yaml'); \
        process.stdout.write(JSON.stringify(yaml.load(fs.readFileSync(process.argv[1],'utf8'))));" \
    "$CONFIG_PATH" > "$_config_json"
else
  echo "load-config: ERROR: no YAML-to-JSON converter found." >&2
  echo "  Required: python3 with PyYAML ('pip3 install pyyaml')." >&2
  echo "  Fallback: node with js-yaml ('npm install -g js-yaml')." >&2
  echo "  On GitHub-hosted ubuntu runners, python3 + PyYAML is pre-installed." >&2
  echo "  On self-hosted macOS runners: 'brew install python3 && pip3 install pyyaml'." >&2
  exit 1
fi

# ── Extract and export values ──────────────────────────────────────────────────
# Use random delimiters for all outputs (required for any potentially-multiline value).

export_output() {
  local key="$1"
  local value="$2"
  # Strip any embedded newlines/carriage returns from single-line values
  local clean_value
  clean_value="$(printf '%s' "$value" | tr -d '\n\r')"
  local delim
  delim="swarm_$(openssl rand -hex 8)"
  {
    printf '%s<<%s\n' "$key" "$delim"
    printf '%s\n' "$clean_value"
    printf '%s\n' "$delim"
  } >> "${GITHUB_OUTPUT:-/dev/stdout}"
}

# Parse config values via jq from the converted JSON temp file.
# Use `| if . == null then "" else tostring end` instead of `// ""`
# because jq's // operator returns the fallback for both null AND false,
# causing YAML boolean `false` values to be silently dropped.
notify_slack="$(jq -r '.notify.slack | if . == null then "" else tostring end' "$_config_json")"
notify_discord="$(jq -r '.notify.discord | if . == null then "" else tostring end' "$_config_json")"
notify_teams="$(jq -r '.notify.teams | if . == null then "" else tostring end' "$_config_json")"
notify_buzz_channel="$(jq -r '.notify.buzz_channel | if . == null then "" else tostring end' "$_config_json")"
runner_label="$(jq -r '.runner.label | if . == null then "" else tostring end' "$_config_json")"
develop_adapter="$(jq -r '.develop.adapter | if . == null then "" else tostring end' "$_config_json")"
sweeper_schedule="$(jq -r '.sweeper.schedule | if . == null then "" else tostring end' "$_config_json")"

export_output "notify-slack"       "$notify_slack"
export_output "notify-discord"     "$notify_discord"
export_output "notify-teams"       "$notify_teams"
export_output "notify-buzz-channel" "$notify_buzz_channel"
export_output "runner-label"       "$runner_label"
export_output "develop-adapter"    "$develop_adapter"
export_output "sweeper-schedule"   "$sweeper_schedule"

echo "load-config: exported outputs:"
echo "  notify-slack=$notify_slack"
echo "  notify-discord=$notify_discord"
echo "  notify-teams=$notify_teams"
echo "  notify-buzz-channel=$notify_buzz_channel"
echo "  runner-label=$runner_label"
echo "  develop-adapter=$develop_adapter"
echo "  sweeper-schedule=$sweeper_schedule"
echo "load-config: OK"
