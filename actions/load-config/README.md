# actions/load-config/

Composite action — reads `swarm.config.yml` from the workspace, validates it against `schemas/config.schema.json` (resolved engine-relative via `ACTION_PATH`, not workspace-relative) using `ajv-cli@5.0.0`, converts the YAML to a temporary JSON file, and exports each top-level config value as a step output.

**YAML→JSON conversion:** `swarm.config.yml` is real YAML; `jq` cannot parse YAML directly. After validation, `load-config` converts the file once to a temp JSON file (cleaned up on exit via `trap`). Primary converter: `python3 + PyYAML`. Fallback: `node + js-yaml`. If neither is available the action exits 1 with a clear error naming the missing prerequisite. All field extractions read from the temp JSON file.

If validation fails the job fails immediately with the ajv error printed to stderr. Invalid config is never silently ignored.

**Runner prerequisites:** `python3` with `PyYAML` must be on `$PATH` (pre-installed on GitHub-hosted `ubuntu-*` runners; macOS self-hosted: `brew install python3 && pip3 install pyyaml`). Fallback: `node` with `js-yaml` (`npm install -g js-yaml`).

Outputs:

| Output | Description |
|---|---|
| `notify-slack` | Whether Slack notifications are enabled (`true`/`false`) |
| `notify-discord` | Whether Discord notifications are enabled (`true`/`false`) |
| `notify-teams` | Whether Teams notifications are enabled (`true`/`false`) |
| `notify-buzz-channel` | Nostr/NIP-29 channel UUID for buzz notifications |
| `runner-label` | GitHub Actions runner label for agent jobs |
| `develop-adapter` | Develop-stage adapter (`claude-code-action` or `headless`) |
| `sweeper-schedule` | Cron schedule expression for the sweeper |

Usage:

```yaml
- uses: benmarte/swarm/actions/load-config@main
  id: config

- run: echo "slack=${{ steps.config.outputs.notify-slack }}"
```

Required permissions on the calling job: `contents: read`.

Wired as the first composite-action step in `.github/workflows/intake.yml` (after checkout, before issue context fetch). Implemented in issue #10.
