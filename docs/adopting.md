# Adopting swarm

This guide walks through adopting swarm in a fresh consumer repo in under 30 minutes. You reference swarm — you do not clone or fork it. Everything below happens in your consumer repo.

---

## Prerequisites

Before starting, confirm you have:

- **`gh`** authenticated to GitHub (`gh auth status` should show your account and the consumer repo's organization).
- **`node`** (any current LTS) — `ajv-cli@5.0.0` is installed globally by swarm's composite actions automatically; you need `node` on the self-hosted runner, not necessarily locally.
- **`nak`** installed on the self-hosted runner — only required if you enable the buzz/Nostr notify sink. `nak` must be on `$PATH` for the runner user. (`brew install nak` on macOS; see [github.com/fiatjaf/nak](https://github.com/fiatjaf/nak) for other platforms.)
- A **self-hosted runner labeled `swarm-agent`** registered to your repo or organization. Agent jobs run there for locality and auth reasons (same posture as Daedalus). Non-agent jobs (label swaps, validation, notify) run on `ubuntu-latest`. The runner user needs:
  - `claude` CLI on `$PATH` (if using the claude adapter) — `npm install -g @anthropic-ai/claude-code`.
  - `gh` CLI on `$PATH` and authenticated.
  - `jq` on `$PATH`.
  - `nak` on `$PATH` (if using buzz notify).
  - `ajv-cli@5.0.0` is installed in-job by the composite actions; it does not need to be pre-installed.

---

## Step 1 — Copy the credential template

In your consumer repo (not in the swarm repo):

```bash
curl -sSL https://raw.githubusercontent.com/benmarte/swarm/main/.env.example -o .env.example
cp .env.example .env
```

Or if you already have the swarm source locally:

```bash
cp /path/to/swarm/.env.example .env
```

Open `.env` and fill in each value. The template lists every credential name swarm can consume. You only need to fill the ones for features you enable:

| Variable | Required for |
|---|---|
| `SWARM_GITHUB_TOKEN` | Cross-repo ops (reserved for future use; `SWARM_TOKEN` is the reviewer PAT — see below) |
| `ANTHROPIC_API_KEY` | claude adapter (default for all decision roles + develop) |
| `SWARM_LLM_API_KEY` | openai-compat adapter against a cloud endpoint that requires a bearer token |
| `SWARM_SLACK_WEBHOOK` | Slack notifications |
| `SWARM_DISCORD_WEBHOOK` | Discord notifications |
| `SWARM_TEAMS_WEBHOOK` | Teams notifications |
| `SWARM_BUZZ_RELAY_URL` | Buzz/Nostr notifications (e.g. `wss://relay.example.com`) |
| `SWARM_BUZZ_PRIVATE_KEY` | Buzz/Nostr notifications (bot's Nostr private key, hex) |

The `SWARM_TOKEN` reviewer PAT is provisioned separately — see Step 3.

`.env` must never be committed. It is already in swarm's `.gitignore`; add it to your consumer repo's `.gitignore` as well:

```
.env
.env.local
.env.*
!.env.example
```

---

## Step 2 — Run bootstrap

`bootstrap.sh` is a one-time provisioning script that must be run from within the swarm repo directory (it uses `git rev-parse --show-toplevel` to find `.env.example`). The easiest approach is to clone swarm once for bootstrap purposes:

```bash
git clone https://github.com/benmarte/swarm.git /tmp/swarm-bootstrap
cd /tmp/swarm-bootstrap

bash scripts/bootstrap.sh \
  --env-file /path/to/your/consumer-repo/.env \
  --repo owner/your-consumer-repo \
  --reviewer yourgithubhandle
```

**Expected output shape:**

```
bootstrap: targeting repository: owner/your-consumer-repo
bootstrap: step 1/5 — creating swarm labels
  created: swarm:go
  created: swarm:spec
  ...
bootstrap: step 2/5 — creating swarm-approval environment
  created/updated: swarm-approval (reviewer: yourgithubhandle)
bootstrap: step 3/5 — seeding secrets from env file
  seeded: ANTHROPIC_API_KEY
  seeded: SWARM_SLACK_WEBHOOK
  total seeded: N key(s)
bootstrap: step 4/5 — key report
  missing keys (in .env.example, absent or blank in env file):
    - SWARM_BUZZ_RELAY_URL
    ...
bootstrap: step 5/5 — starter swarm.config.yml
  wrote: swarm.config.yml
bootstrap: caller workflow snippet
──────────────────────────────────────────────────────────────────────────
# .github/workflows/swarm.yml — caller workflow for benmarte/swarm
...
──────────────────────────────────────────────────────────────────────────
bootstrap: done.
```

Missing keys reported in step 4 are informational — they are credentials for features you have not enabled yet. Extra keys (in your `.env` but not in `.env.example`) are flagged so you know they will not be consumed.

The generated `swarm.config.yml` is written to the directory where you ran bootstrap (the swarm clone root). Copy it to your consumer repo:

```bash
cp swarm.config.yml /path/to/your/consumer-repo/swarm.config.yml
```

---

## Step 3 — Provision the SWARM_TOKEN reviewer PAT

`pr-gates.yml` posts real GitHub PR reviews using a separate actor so the review is not self-approved. `GITHUB_TOKEN` cannot approve a PR it opened.

1. Create a fine-grained PAT for a second GitHub account (or a bot account) with **pull-requests: write** scope scoped to the consumer repo.
2. Add it as a secret in the consumer repo named `SWARM_TOKEN`:

```bash
gh secret set SWARM_TOKEN --repo owner/your-consumer-repo
# Paste the PAT value at the prompt (input is hidden)
```

---

## Step 4 — Edit swarm.config.yml

Open the generated `swarm.config.yml` in your consumer repo and customize:

```yaml
# swarm.config.yml — behavior config committed in your consumer repo.
# Validate with: ajv validate -s schemas/config.schema.json -d swarm.config.yml

notify:
  # Uncomment the sinks you have credentials for:
  # slack: true
  # discord: true
  # teams: true
  # buzz_channel: "your-nostr-channel-uuid-here"   # channel UUID (not a secret)

develop:
  adapter: claude-code-action   # or: headless

# SWARM_LLM_BASE_URL is a schema-valid top-level key in swarm.config.yml (not a secret).
# Set it only when using the openai-compat adapter for decision roles:
# SWARM_LLM_BASE_URL: "http://localhost:11434/v1"   # Ollama; or LM Studio: http://localhost:1234/v1

qa:
  required_checks:
    - CI   # your existing CI job name(s) that must pass before merge

runner:
  label: swarm-agent

sweeper:
  schedule: "0 2 * * *"   # nightly at 02:00 UTC; used in your caller workflow cron
```

The `buzz_channel` value is the NIP-29 channel UUID — it is behavior config, not a secret, so it lives in `swarm.config.yml` rather than in GitHub Secrets.

---

## Step 5 — Add the caller workflow

Create `.github/workflows/swarm.yml` in your consumer repo. This is the thin wrapper that pins swarm at `@v1` and wires triggers to reusable workflows:

```yaml
name: swarm
on:
  issues:
    types: [labeled]
  pull_request:
    branches: [main]                    # adjust to your default branch if different
    types: [opened, synchronize, closed]
  workflow_run:
    workflows: ["*"]
    types: [completed]
  schedule:
    - cron: "0 2 * * *"               # sweeper — match sweeper.schedule in swarm.config.yml
  workflow_dispatch: {}

jobs:
  # ── intake / spec / develop ────────────────────────────────────────────────
  # Issue number comes directly from the label event — no extraction needed.

  intake:
    if: |
      github.event_name == 'issues' &&
      github.event.action == 'labeled' &&
      github.event.label.name == 'swarm:go'
    uses: benmarte/swarm/workflows/intake.yml@v1
    with:
      issue: ${{ github.event.issue.number }}
    secrets: inherit

  spec:
    if: |
      github.event_name == 'issues' &&
      github.event.action == 'labeled' &&
      github.event.label.name == 'swarm:spec'
    uses: benmarte/swarm/workflows/spec.yml@v1
    with:
      issue: ${{ github.event.issue.number }}
    secrets: inherit

  develop:
    if: |
      github.event_name == 'issues' &&
      github.event.action == 'labeled' &&
      github.event.label.name == 'swarm:develop'
    uses: benmarte/swarm/workflows/develop.yml@v1
    with:
      issue: ${{ github.event.issue.number }}
      adapter: claude-code-action   # or: headless
      maintainer: yourgithubhandle
    secrets: inherit

  # ── pr-gates ───────────────────────────────────────────────────────────────
  # Branch naming convention: swarm/issue-N (set by develop.yml).
  # extract-for-gates derives N; pr-gates receives it as a typed number via fromJSON.

  extract-for-gates:
    if: |
      github.event_name == 'pull_request' &&
      (github.event.action == 'opened' || github.event.action == 'synchronize') &&
      startsWith(github.head_ref, 'swarm/issue-')
    runs-on: ubuntu-latest
    outputs:
      issue: ${{ steps.extract.outputs.issue }}
    steps:
      - id: extract
        env:
          HEAD_REF: ${{ github.head_ref }}
        run: |
          # do not edit: derives issue number from swarm/issue-N branch name
          issue="${HEAD_REF#swarm/issue-}"
          printf '%s' "$issue" | grep -qE '^[0-9]+$' \
            || { printf 'ERROR: cannot parse issue from branch: %s\n' "$HEAD_REF" >&2; exit 1; }
          printf 'issue=%s\n' "$issue" >> "$GITHUB_OUTPUT"

  pr-gates:
    needs: extract-for-gates
    uses: benmarte/swarm/workflows/pr-gates.yml@v1
    with:
      pr: ${{ github.event.number }}
      issue: ${{ fromJSON(needs.extract-for-gates.outputs.issue) }}   # fromJSON: string → number input
    secrets: inherit   # passes SWARM_TOKEN through to pr-gates

  # ── fix ────────────────────────────────────────────────────────────────────
  # Triggered when any workflow completes with failure on a swarm/issue-N branch.
  # PR number is available in workflow_run.pull_requests[0].number for same-repo PRs.

  extract-for-fix:
    if: |
      github.event_name == 'workflow_run' &&
      github.event.workflow_run.conclusion == 'failure' &&
      startsWith(github.event.workflow_run.head_branch, 'swarm/issue-')
    runs-on: ubuntu-latest
    outputs:
      issue: ${{ steps.extract.outputs.issue }}
      pr: ${{ steps.extract.outputs.pr }}
    steps:
      - id: extract
        env:
          HEAD_BRANCH: ${{ github.event.workflow_run.head_branch }}
          PR_NUMBER: ${{ github.event.workflow_run.pull_requests[0].number }}
        run: |
          # do not edit: derives issue number from swarm/issue-N branch name
          issue="${HEAD_BRANCH#swarm/issue-}"
          printf '%s' "$issue" | grep -qE '^[0-9]+$' \
            || { printf 'ERROR: cannot parse issue from branch: %s\n' "$HEAD_BRANCH" >&2; exit 1; }
          printf 'issue=%s\n' "$issue" >> "$GITHUB_OUTPUT"
          printf 'pr=%s\n' "${PR_NUMBER}" >> "$GITHUB_OUTPUT"

  fix:
    needs: extract-for-fix
    uses: benmarte/swarm/workflows/fix.yml@v1
    with:
      pr: ${{ fromJSON(needs.extract-for-fix.outputs.pr) }}          # fromJSON: string → number input
      issue: ${{ fromJSON(needs.extract-for-fix.outputs.issue) }}    # fromJSON: string → number input
      maintainer: yourgithubhandle
      adapter: claude-code-action   # match develop.adapter in swarm.config.yml
    secrets: inherit

  # ── docs ───────────────────────────────────────────────────────────────────
  # Triggered when a swarm/issue-N PR is merged. Same branch-name extraction.

  extract-for-docs:
    if: |
      github.event_name == 'pull_request' &&
      github.event.action == 'closed' &&
      github.event.pull_request.merged == true &&
      startsWith(github.head_ref, 'swarm/issue-')
    runs-on: ubuntu-latest
    outputs:
      issue: ${{ steps.extract.outputs.issue }}
    steps:
      - id: extract
        env:
          HEAD_REF: ${{ github.head_ref }}
        run: |
          # do not edit: derives issue number from swarm/issue-N branch name
          issue="${HEAD_REF#swarm/issue-}"
          printf '%s' "$issue" | grep -qE '^[0-9]+$' \
            || { printf 'ERROR: cannot parse issue from branch: %s\n' "$HEAD_REF" >&2; exit 1; }
          printf 'issue=%s\n' "$issue" >> "$GITHUB_OUTPUT"

  docs:
    needs: extract-for-docs
    uses: benmarte/swarm/workflows/docs.yml@v1
    with:
      pr: ${{ github.event.number }}
      issue: ${{ fromJSON(needs.extract-for-docs.outputs.issue) }}   # fromJSON: string → number input
    secrets: inherit

  # ── sweeper ────────────────────────────────────────────────────────────────
  # sweeper.yml is on: workflow_call only — no internal schedule trigger.
  # The cron lives here in the caller.

  sweeper:
    if: github.event_name == 'schedule' || github.event_name == 'workflow_dispatch'
    uses: benmarte/swarm/workflows/sweeper.yml@v1
    with:
      stall-threshold-hours: 48
      # dry-run: false
    secrets: inherit
```

> Note: The `extract-for-*` helper jobs are thin `ubuntu-latest` jobs that derive the issue number from the `swarm/issue-N` branch-naming convention and expose it as a string output. `fromJSON()` converts that string to the `number` type the reusable workflow inputs require. If a branch does not follow the convention the extract job fails loudly rather than silently passing a wrong value.

Commit and push the caller workflow and `swarm.config.yml`:

```bash
git add .github/workflows/swarm.yml swarm.config.yml
git commit -m "chore: adopt swarm pipeline"
git push
```

---

## Step 6 — Branch protection + required checks

In your repo settings (or via `gh api`), configure branch protection on your default branch:

- Require status checks to pass before merging. Add at minimum:
  - Your existing CI check (the value in `swarm.config.yml qa.required_checks`).
- Require a pull request review before merging.
- Require the `swarm-approval` environment to be passed (this is the human merge gate — bootstrap created it in Step 2).

```bash
# Quick branch protection via gh api (adjust as needed for your repo)
gh api repos/owner/your-consumer-repo/branches/main/protection \
  --method PUT \
  --field required_status_checks[strict]=true \
  --field required_status_checks[contexts][]="CI" \
  --field required_pull_request_reviews[required_approving_review_count]=1 \
  --field enforce_admins=false \
  --field restrictions=null
```

---

## Step 7 — First issue walkthrough

1. Open a GitHub issue in your consumer repo describing something you want implemented.
2. Apply the label `swarm:go` to the issue (only a maintainer should apply this label — it is the prompt-injection gate).
3. Watch the Actions tab:
   - **intake** job runs the validator agent. If confirmed, the issue transitions to `swarm:spec`.
   - **spec** job runs the PM agent. The spec is posted as an issue comment and committed to `docs/specs/issue-N.md` on the feature branch.
   - **develop** job opens the PR on branch `swarm/issue-N`.
   - **pr-gates** runs reviewer and security in parallel. The reviewer posts a real GitHub review; security posts an advisory or blocks merge.
   - If all checks pass and the reviewer approves, the `swarm-approval` environment gate pauses for your human review.
   - Approve the deployment in the GitHub UI to allow merge.
   - After merge, **docs** runs the docs agent and transitions the issue to `swarm:done`.

---

## Key rotation

To rotate any credential:

1. Edit `.env` with the new value.
2. Re-run bootstrap:

```bash
bash scripts/bootstrap.sh --env-file .env --repo owner/your-consumer-repo
```

Bootstrap is idempotent. It re-seeds all secrets (only non-empty values), skips already-correct labels and environment settings, and does not overwrite an existing `swarm.config.yml` unless you pass `--force`.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `bootstrap: 'gh' is required but not installed` | gh CLI missing | `brew install gh && gh auth login` |
| `bootstrap: could not detect current repo` | Not in a git repo or gh can't detect it | Pass `--repo owner/name` explicitly |
| `ERROR: SWARM_TOKEN secret is absent` | SWARM_TOKEN not set in the consumer repo | `gh secret set SWARM_TOKEN --repo owner/name` |
| Agent job fails: `outcome.json` invalid | Agent emitted non-schema-conforming JSON | Check the agent step's logs; the fix loop will retry automatically (up to 3 attempts) |
| Agent job queues indefinitely | Self-hosted runner offline | Bring up the runner; the sweeper will escalate the issue if it stays stuck past the stall threshold |
| Duplicate label events trigger two runs | Concurrency group not firing | Each workflow uses `concurrency: swarm-<issue> / cancel-in-progress: false` — the second run will queue (not cancel) and exit cleanly after checking state |
| Issue stuck in `swarm:needs-human` | Fix loop exceeded 3 attempts or validator returned needs-info | Resolve the underlying problem, remove `swarm:needs-human`, re-apply the appropriate stage label |
| `swarm:paused` issue not escalated | Expected — the sweeper never touches `swarm:paused` issues | Remove `swarm:paused` manually when you are ready to resume; the sweeper will then escalate on the next run if the issue is still stuck |
| buzz notifications not delivered | `nak` not on runner PATH, or bad relay URL / key | `which nak` on runner; check `SWARM_BUZZ_RELAY_URL` and `SWARM_BUZZ_PRIVATE_KEY` in GitHub Secrets |
