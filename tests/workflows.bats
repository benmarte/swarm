#!/usr/bin/env bats
# workflows.bats — structural and static tests for reusable workflows.
#
# What is tested here:
#   1. actionlint passes (static YAML + expression correctness)
#   2. on.workflow_call declared
#   3. concurrency key declared at workflow level
#   4. Both inputs runner-label and dry-run declared
#   5. Every job has an explicit permissions: block
#   6. Every job has timeout-minutes
#   7. No run: block content contains ${{ (env-intermediary discipline)
#
# These tests run entirely from the filesystem — no Actions execution needed.
# actionlint must be installed (verify.sh enforces this; CI installs it).

REPO_ROOT="$(git -C "$(dirname "$BATS_TEST_FILENAME")" rev-parse --show-toplevel)"
INTAKE="$REPO_ROOT/workflows/intake.yml"
SPEC="$REPO_ROOT/workflows/spec.yml"
DEVELOP="$REPO_ROOT/workflows/develop.yml"
PR_GATES="$REPO_ROOT/workflows/pr-gates.yml"
FIX="$REPO_ROOT/workflows/fix.yml"
DOCS="$REPO_ROOT/workflows/docs.yml"
SWEEPER="$REPO_ROOT/workflows/sweeper.yml"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# check_no_interpolation_in_run FILE
# Returns 0 if no run: block in FILE contains ${{}}, non-zero otherwise.
check_no_interpolation_in_run() {
  local file="$1"
  WORKFLOW_FILE="$file" python3 - <<'PYEOF'
import os, re, sys

with open(os.environ["WORKFLOW_FILE"]) as fh:
    lines = fh.readlines()

in_run = False
run_indent = 0

for i, raw in enumerate(lines, 1):
    # Strip trailing newline for indent calculation
    line = raw.rstrip("\n")
    if not line.strip():
        # blank lines: keep in_run state (block scalars allow blank lines)
        if in_run and "${" + "{" in line:
            print(f"Line {i}: ${'{' + '{'} in run block: {line!r}")
            sys.exit(1)
        continue

    cur_indent = len(line) - len(line.lstrip(" "))
    stripped = line.strip()

    if re.match(r"^run:\s*(\||\|-|>|>-|>\+|\|+)?\s*$", stripped):
        in_run = True
        run_indent = cur_indent
        continue

    if in_run:
        if cur_indent > run_indent:
            # Inside the run: block body
            if "${" + "{" in line:
                print(f"Line {i}: ${'{' + '{'} found in run: block body: {line!r}")
                sys.exit(1)
        else:
            in_run = False

sys.exit(0)
PYEOF
}

# ---------------------------------------------------------------------------
# actionlint
# ---------------------------------------------------------------------------

@test "intake.yml: actionlint passes" {
  run actionlint "$INTAKE"
  [ "$status" -eq 0 ]
}

@test "spec.yml: actionlint passes" {
  run actionlint "$SPEC"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# workflow_call trigger
# ---------------------------------------------------------------------------

@test "intake.yml: declares on.workflow_call" {
  run grep -q "workflow_call:" "$INTAKE"
  [ "$status" -eq 0 ]
}

@test "spec.yml: declares on.workflow_call" {
  run grep -q "workflow_call:" "$SPEC"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# concurrency
# ---------------------------------------------------------------------------

@test "intake.yml: declares concurrency key" {
  run grep -q "^concurrency:" "$INTAKE"
  [ "$status" -eq 0 ]
}

@test "spec.yml: declares concurrency key" {
  run grep -q "^concurrency:" "$SPEC"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# caller inputs: runner-label and dry-run
# ---------------------------------------------------------------------------

@test "intake.yml: declares runner-label input" {
  run grep -q "runner-label:" "$INTAKE"
  [ "$status" -eq 0 ]
}

@test "spec.yml: declares runner-label input" {
  run grep -q "runner-label:" "$SPEC"
  [ "$status" -eq 0 ]
}

@test "intake.yml: declares dry-run input" {
  run grep -q "dry-run:" "$INTAKE"
  [ "$status" -eq 0 ]
}

@test "spec.yml: declares dry-run input" {
  run grep -q "dry-run:" "$SPEC"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# per-job permissions blocks
# ---------------------------------------------------------------------------

@test "intake.yml: every job has a permissions block" {
  # Count jobs and permissions blocks; they must match.
  # Jobs are lines matching "^  <name>:" inside the "jobs:" section.
  # We use Python for reliable multi-line YAML structure parsing.
  WORKFLOW_FILE="$INTAKE" python3 - <<'PYEOF'
import os, re, sys

with open(os.environ["WORKFLOW_FILE"]) as fh:
    content = fh.read()

# Simple structural check: count top-level job keys and permissions: occurrences.
# Each job block should contain exactly one "permissions:" key.
in_jobs = False
job_count = 0
perms_count = 0
job_indent = 0

for line in content.split("\n"):
    if line.strip() == "jobs:":
        in_jobs = True
        job_indent = 0
        continue
    if not in_jobs:
        continue
    if not line.strip():
        continue
    cur = len(line) - len(line.lstrip())
    if cur == 2 and line.rstrip().endswith(":") and not line.strip().startswith("#"):
        job_count += 1
    if line.strip().startswith("permissions:"):
        perms_count += 1

if job_count == 0:
    print("No jobs found in workflow")
    sys.exit(1)
if perms_count < job_count:
    print(f"Jobs: {job_count}, permissions blocks: {perms_count} — every job must declare permissions")
    sys.exit(1)
sys.exit(0)
PYEOF
  [ "$?" -eq 0 ]
}

@test "spec.yml: every job has a permissions block" {
  WORKFLOW_FILE="$SPEC" python3 - <<'PYEOF'
import os, re, sys

with open(os.environ["WORKFLOW_FILE"]) as fh:
    content = fh.read()

in_jobs = False
job_count = 0
perms_count = 0

for line in content.split("\n"):
    if line.strip() == "jobs:":
        in_jobs = True
        continue
    if not in_jobs:
        continue
    if not line.strip():
        continue
    cur = len(line) - len(line.lstrip())
    if cur == 2 and line.rstrip().endswith(":") and not line.strip().startswith("#"):
        job_count += 1
    if line.strip().startswith("permissions:"):
        perms_count += 1

if job_count == 0:
    print("No jobs found in workflow")
    sys.exit(1)
if perms_count < job_count:
    print(f"Jobs: {job_count}, permissions blocks: {perms_count} — every job must declare permissions")
    sys.exit(1)
sys.exit(0)
PYEOF
  [ "$?" -eq 0 ]
}

# ---------------------------------------------------------------------------
# per-job timeout-minutes
# ---------------------------------------------------------------------------

@test "intake.yml: every job has timeout-minutes" {
  WORKFLOW_FILE="$INTAKE" python3 - <<'PYEOF'
import os, sys

with open(os.environ["WORKFLOW_FILE"]) as fh:
    content = fh.read()

in_jobs = False
job_count = 0
timeout_count = 0

for line in content.split("\n"):
    if line.strip() == "jobs:":
        in_jobs = True
        continue
    if not in_jobs:
        continue
    if not line.strip():
        continue
    cur = len(line) - len(line.lstrip())
    if cur == 2 and line.rstrip().endswith(":") and not line.strip().startswith("#"):
        job_count += 1
    if "timeout-minutes:" in line:
        timeout_count += 1

if job_count == 0:
    print("No jobs found")
    sys.exit(1)
if timeout_count < job_count:
    print(f"Jobs: {job_count}, timeout-minutes declarations: {timeout_count}")
    sys.exit(1)
sys.exit(0)
PYEOF
  [ "$?" -eq 0 ]
}

@test "spec.yml: every job has timeout-minutes" {
  WORKFLOW_FILE="$SPEC" python3 - <<'PYEOF'
import os, sys

with open(os.environ["WORKFLOW_FILE"]) as fh:
    content = fh.read()

in_jobs = False
job_count = 0
timeout_count = 0

for line in content.split("\n"):
    if line.strip() == "jobs:":
        in_jobs = True
        continue
    if not in_jobs:
        continue
    if not line.strip():
        continue
    cur = len(line) - len(line.lstrip())
    if cur == 2 and line.rstrip().endswith(":") and not line.strip().startswith("#"):
        job_count += 1
    if "timeout-minutes:" in line:
        timeout_count += 1

if job_count == 0:
    print("No jobs found")
    sys.exit(1)
if timeout_count < job_count:
    print(f"Jobs: {job_count}, timeout-minutes declarations: {timeout_count}")
    sys.exit(1)
sys.exit(0)
PYEOF
  [ "$?" -eq 0 ]
}

# ---------------------------------------------------------------------------
# No ${{ }} expression interpolation inside run: blocks
# ---------------------------------------------------------------------------

@test "intake.yml: no '\${{' in run: block content" {
  run check_no_interpolation_in_run "$INTAKE"
  [ "$status" -eq 0 ]
}

@test "spec.yml: no '\${{' in run: block content" {
  run check_no_interpolation_in_run "$SPEC"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# No static EOF delimiters in GITHUB_OUTPUT heredoc writes
#
# Static delimiters (e.g. SWARM_CTX_EOF) can be contained in untrusted
# content (issue bodies, LLM output), escaping the heredoc and injecting
# forged step-output key=value pairs. All GITHUB_OUTPUT multiline writes
# MUST use a randomly-generated delimiter (openssl rand -hex 16 pattern).
# ---------------------------------------------------------------------------

# check_no_static_output_delimiters FILE
# Fails if any GITHUB_OUTPUT heredoc write uses a literal static delimiter
# (i.e. a fixed string like SWARM_CTX_EOF) instead of a shell variable.
check_no_static_output_delimiters() {
  local file="$1"
  WORKFLOW_FILE="$file" python3 - <<'PYEOF'
import os, re, sys

with open(os.environ["WORKFLOW_FILE"]) as fh:
    content = fh.read()

# Match lines of the form:   printf 'key<<LITERAL_DELIMITER\n'
# where LITERAL_DELIMITER is an uppercase or mixed static string (not a variable).
# Safe pattern: delimiter comes from a variable e.g. printf 'key<<%s\n' "$delim"
#
# We look for: printf '...<< followed by a non-% non-$ character
# (indicating a static literal rather than a printf format specifier or variable).
static_delim_pattern = re.compile(
    r'printf\s+[\'"].*?<<([A-Za-z_][A-Za-z0-9_]+)[\'"]'
)

for i, line in enumerate(content.split("\n"), 1):
    stripped = line.strip()
    if "GITHUB_OUTPUT" in line:
        continue  # the redirection line itself is not a delimiter line
    m = static_delim_pattern.search(stripped)
    if m:
        delim = m.group(1)
        # Check if this printf targets GITHUB_OUTPUT in the surrounding block
        # (conservative: flag any static delimiter in a run: block involving GITHUB_OUTPUT)
        print(f"Line {i}: static GITHUB_OUTPUT delimiter '{delim}' — use openssl rand -hex 16 instead: {line!r}")
        sys.exit(1)

sys.exit(0)
PYEOF
}

@test "intake.yml: no static GITHUB_OUTPUT heredoc delimiters" {
  run check_no_static_output_delimiters "$INTAKE"
  [ "$status" -eq 0 ]
}

@test "spec.yml: no static GITHUB_OUTPUT heredoc delimiters" {
  run check_no_static_output_delimiters "$SPEC"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# develop.yml structural tests (same suite as intake + spec)
# ---------------------------------------------------------------------------

@test "develop.yml: actionlint passes" {
  run actionlint "$DEVELOP"
  [ "$status" -eq 0 ]
}

@test "develop.yml: declares on.workflow_call" {
  run grep -q "workflow_call:" "$DEVELOP"
  [ "$status" -eq 0 ]
}

@test "develop.yml: declares concurrency key" {
  run grep -q "^concurrency:" "$DEVELOP"
  [ "$status" -eq 0 ]
}

@test "develop.yml: declares runner-label input" {
  run grep -q "runner-label:" "$DEVELOP"
  [ "$status" -eq 0 ]
}

@test "develop.yml: declares dry-run input" {
  run grep -q "dry-run:" "$DEVELOP"
  [ "$status" -eq 0 ]
}

@test "develop.yml: declares adapter input" {
  run grep -q "adapter:" "$DEVELOP"
  [ "$status" -eq 0 ]
}

@test "develop.yml: every job has a permissions block" {
  WORKFLOW_FILE="$DEVELOP" python3 - <<'PYEOF'
import os, sys

with open(os.environ["WORKFLOW_FILE"]) as fh:
    content = fh.read()

in_jobs = False
job_count = 0
perms_count = 0

for line in content.split("\n"):
    if line.strip() == "jobs:":
        in_jobs = True
        continue
    if not in_jobs:
        continue
    if not line.strip():
        continue
    cur = len(line) - len(line.lstrip())
    if cur == 2 and line.rstrip().endswith(":") and not line.strip().startswith("#"):
        job_count += 1
    if line.strip().startswith("permissions:"):
        perms_count += 1

if job_count == 0:
    print("No jobs found in workflow")
    sys.exit(1)
if perms_count < job_count:
    print(f"Jobs: {job_count}, permissions blocks: {perms_count} — every job must declare permissions")
    sys.exit(1)
sys.exit(0)
PYEOF
  [ "$?" -eq 0 ]
}

@test "develop.yml: every job has timeout-minutes" {
  WORKFLOW_FILE="$DEVELOP" python3 - <<'PYEOF'
import os, sys

with open(os.environ["WORKFLOW_FILE"]) as fh:
    content = fh.read()

in_jobs = False
job_count = 0
timeout_count = 0

for line in content.split("\n"):
    if line.strip() == "jobs:":
        in_jobs = True
        continue
    if not in_jobs:
        continue
    if not line.strip():
        continue
    cur = len(line) - len(line.lstrip())
    if cur == 2 and line.rstrip().endswith(":") and not line.strip().startswith("#"):
        job_count += 1
    if "timeout-minutes:" in line:
        timeout_count += 1

if job_count == 0:
    print("No jobs found")
    sys.exit(1)
if timeout_count < job_count:
    print(f"Jobs: {job_count}, timeout-minutes declarations: {timeout_count}")
    sys.exit(1)
sys.exit(0)
PYEOF
  [ "$?" -eq 0 ]
}

@test "develop.yml: no '\${{' in run: block content" {
  run check_no_interpolation_in_run "$DEVELOP"
  [ "$status" -eq 0 ]
}

@test "develop.yml: no static GITHUB_OUTPUT heredoc delimiters" {
  run check_no_static_output_delimiters "$DEVELOP"
  [ "$status" -eq 0 ]
}

@test "develop.yml: claude-code-action SHA-pinned (no @v tag reference)" {
  # Actions must be pinned to full SHAs (supply-chain rule per SPEC §4)
  # Verify that the claude-code-action uses a SHA, not a mutable tag.
  run python3 - "$DEVELOP" <<'PYEOF'
import sys, re

with open(sys.argv[1]) as fh:
    content = fh.read()

# Find all uses: anthropics/claude-code-action@<ref> lines
uses_pattern = re.compile(r'uses:\s*anthropics/claude-code-action@(\S+)')
matches = uses_pattern.findall(content)

if not matches:
    # Not referenced — skip (no violation)
    sys.exit(0)

sha_pattern = re.compile(r'^[0-9a-f]{40}$')
for ref in matches:
    # Strip comment part if any (e.g. "abc123 # v1.0.183")
    ref_clean = ref.split('#')[0].strip()
    if not sha_pattern.match(ref_clean):
        print(f"ERROR: claude-code-action ref is not a full SHA: '{ref}'. Use a 40-char commit SHA (see adapters/claude-code-action/README.md)")
        sys.exit(1)

sys.exit(0)
PYEOF
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# pr-gates.yml structural tests
# ---------------------------------------------------------------------------

@test "pr-gates.yml: actionlint passes" {
  run actionlint "$PR_GATES"
  [ "$status" -eq 0 ]
}

@test "pr-gates.yml: declares on.workflow_call" {
  run grep -q "workflow_call:" "$PR_GATES"
  [ "$status" -eq 0 ]
}

@test "pr-gates.yml: declares concurrency key" {
  run grep -q "^concurrency:" "$PR_GATES"
  [ "$status" -eq 0 ]
}

@test "pr-gates.yml: declares runner-label input" {
  run grep -q "runner-label:" "$PR_GATES"
  [ "$status" -eq 0 ]
}

@test "pr-gates.yml: declares dry-run input" {
  run grep -q "dry-run:" "$PR_GATES"
  [ "$status" -eq 0 ]
}

@test "pr-gates.yml: declares adapter input" {
  run grep -q "adapter:" "$PR_GATES"
  [ "$status" -eq 0 ]
}

@test "pr-gates.yml: every job has a permissions block" {
  WORKFLOW_FILE="$PR_GATES" python3 - <<'PYEOF'
import os, sys

with open(os.environ["WORKFLOW_FILE"]) as fh:
    content = fh.read()

in_jobs = False
job_count = 0
perms_count = 0

for line in content.split("\n"):
    if line.strip() == "jobs:":
        in_jobs = True
        continue
    if not in_jobs:
        continue
    if not line.strip():
        continue
    cur = len(line) - len(line.lstrip())
    if cur == 2 and line.rstrip().endswith(":") and not line.strip().startswith("#"):
        job_count += 1
    if line.strip().startswith("permissions:"):
        perms_count += 1

if job_count == 0:
    print("No jobs found in workflow")
    sys.exit(1)
if perms_count < job_count:
    print(f"Jobs: {job_count}, permissions blocks: {perms_count} — every job must declare permissions")
    sys.exit(1)
sys.exit(0)
PYEOF
  [ "$?" -eq 0 ]
}

@test "pr-gates.yml: every job has timeout-minutes" {
  WORKFLOW_FILE="$PR_GATES" python3 - <<'PYEOF'
import os, sys

with open(os.environ["WORKFLOW_FILE"]) as fh:
    content = fh.read()

in_jobs = False
job_count = 0
timeout_count = 0

for line in content.split("\n"):
    if line.strip() == "jobs:":
        in_jobs = True
        continue
    if not in_jobs:
        continue
    if not line.strip():
        continue
    cur = len(line) - len(line.lstrip())
    if cur == 2 and line.rstrip().endswith(":") and not line.strip().startswith("#"):
        job_count += 1
    if "timeout-minutes:" in line:
        timeout_count += 1

if job_count == 0:
    print("No jobs found")
    sys.exit(1)
if timeout_count < job_count:
    print(f"Jobs: {job_count}, timeout-minutes declarations: {timeout_count}")
    sys.exit(1)
sys.exit(0)
PYEOF
  [ "$?" -eq 0 ]
}

@test "pr-gates.yml: no '\${{' in run: block content" {
  run check_no_interpolation_in_run "$PR_GATES"
  [ "$status" -eq 0 ]
}

@test "pr-gates.yml: no static GITHUB_OUTPUT heredoc delimiters" {
  run check_no_static_output_delimiters "$PR_GATES"
  [ "$status" -eq 0 ]
}

@test "pr-gates.yml: references SWARM_TOKEN for reviewer step" {
  run grep -q "SWARM_TOKEN" "$PR_GATES"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# fix.yml structural tests
# ---------------------------------------------------------------------------

@test "fix.yml: actionlint passes" {
  run actionlint "$FIX"
  [ "$status" -eq 0 ]
}

@test "fix.yml: declares on.workflow_call" {
  run grep -q "workflow_call:" "$FIX"
  [ "$status" -eq 0 ]
}

@test "fix.yml: declares concurrency key" {
  run grep -q "^concurrency:" "$FIX"
  [ "$status" -eq 0 ]
}

@test "fix.yml: declares runner-label input" {
  run grep -q "runner-label:" "$FIX"
  [ "$status" -eq 0 ]
}

@test "fix.yml: declares dry-run input" {
  run grep -q "dry-run:" "$FIX"
  [ "$status" -eq 0 ]
}

@test "fix.yml: declares adapter input" {
  run grep -q "adapter:" "$FIX"
  [ "$status" -eq 0 ]
}

@test "fix.yml: every job has a permissions block" {
  WORKFLOW_FILE="$FIX" python3 - <<'PYEOF'
import os, sys

with open(os.environ["WORKFLOW_FILE"]) as fh:
    content = fh.read()

in_jobs = False
job_count = 0
perms_count = 0

for line in content.split("\n"):
    if line.strip() == "jobs:":
        in_jobs = True
        continue
    if not in_jobs:
        continue
    if not line.strip():
        continue
    cur = len(line) - len(line.lstrip())
    if cur == 2 and line.rstrip().endswith(":") and not line.strip().startswith("#"):
        job_count += 1
    if line.strip().startswith("permissions:"):
        perms_count += 1

if job_count == 0:
    print("No jobs found in workflow")
    sys.exit(1)
if perms_count < job_count:
    print(f"Jobs: {job_count}, permissions blocks: {perms_count} — every job must declare permissions")
    sys.exit(1)
sys.exit(0)
PYEOF
  [ "$?" -eq 0 ]
}

@test "fix.yml: every job has timeout-minutes" {
  WORKFLOW_FILE="$FIX" python3 - <<'PYEOF'
import os, sys

with open(os.environ["WORKFLOW_FILE"]) as fh:
    content = fh.read()

in_jobs = False
job_count = 0
timeout_count = 0

for line in content.split("\n"):
    if line.strip() == "jobs:":
        in_jobs = True
        continue
    if not in_jobs:
        continue
    if not line.strip():
        continue
    cur = len(line) - len(line.lstrip())
    if cur == 2 and line.rstrip().endswith(":") and not line.strip().startswith("#"):
        job_count += 1
    if "timeout-minutes:" in line:
        timeout_count += 1

if job_count == 0:
    print("No jobs found")
    sys.exit(1)
if timeout_count < job_count:
    print(f"Jobs: {job_count}, timeout-minutes declarations: {timeout_count}")
    sys.exit(1)
sys.exit(0)
PYEOF
  [ "$?" -eq 0 ]
}

@test "fix.yml: no '\${{' in run: block content" {
  run check_no_interpolation_in_run "$FIX"
  [ "$status" -eq 0 ]
}

@test "fix.yml: no static GITHUB_OUTPUT heredoc delimiters" {
  run check_no_static_output_delimiters "$FIX"
  [ "$status" -eq 0 ]
}

@test "fix.yml: contains both adapter-path conditionals" {
  run grep -q "claude-code-action" "$FIX"
  [ "$status" -eq 0 ]
  run grep -q "headless" "$FIX"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# docs.yml structural tests
# ---------------------------------------------------------------------------

@test "docs.yml: actionlint passes" {
  run actionlint "$DOCS"
  [ "$status" -eq 0 ]
}

@test "docs.yml: declares on.workflow_call" {
  run grep -q "workflow_call:" "$DOCS"
  [ "$status" -eq 0 ]
}

@test "docs.yml: declares concurrency key" {
  run grep -q "^concurrency:" "$DOCS"
  [ "$status" -eq 0 ]
}

@test "docs.yml: declares runner-label input" {
  run grep -q "runner-label:" "$DOCS"
  [ "$status" -eq 0 ]
}

@test "docs.yml: declares dry-run input" {
  run grep -q "dry-run:" "$DOCS"
  [ "$status" -eq 0 ]
}

@test "docs.yml: declares adapter input" {
  run grep -q "adapter:" "$DOCS"
  [ "$status" -eq 0 ]
}

@test "docs.yml: every job has a permissions block" {
  WORKFLOW_FILE="$DOCS" python3 - <<'PYEOF'
import os, sys

with open(os.environ["WORKFLOW_FILE"]) as fh:
    content = fh.read()

in_jobs = False
job_count = 0
perms_count = 0

for line in content.split("\n"):
    if line.strip() == "jobs:":
        in_jobs = True
        continue
    if not in_jobs:
        continue
    if not line.strip():
        continue
    cur = len(line) - len(line.lstrip())
    if cur == 2 and line.rstrip().endswith(":") and not line.strip().startswith("#"):
        job_count += 1
    if line.strip().startswith("permissions:"):
        perms_count += 1

if job_count == 0:
    print("No jobs found in workflow")
    sys.exit(1)
if perms_count < job_count:
    print(f"Jobs: {job_count}, permissions blocks: {perms_count} — every job must declare permissions")
    sys.exit(1)
sys.exit(0)
PYEOF
  [ "$?" -eq 0 ]
}

@test "docs.yml: every job has timeout-minutes" {
  WORKFLOW_FILE="$DOCS" python3 - <<'PYEOF'
import os, sys

with open(os.environ["WORKFLOW_FILE"]) as fh:
    content = fh.read()

in_jobs = False
job_count = 0
timeout_count = 0

for line in content.split("\n"):
    if line.strip() == "jobs:":
        in_jobs = True
        continue
    if not in_jobs:
        continue
    if not line.strip():
        continue
    cur = len(line) - len(line.lstrip())
    if cur == 2 and line.rstrip().endswith(":") and not line.strip().startswith("#"):
        job_count += 1
    if "timeout-minutes:" in line:
        timeout_count += 1

if job_count == 0:
    print("No jobs found")
    sys.exit(1)
if timeout_count < job_count:
    print(f"Jobs: {job_count}, timeout-minutes declarations: {timeout_count}")
    sys.exit(1)
sys.exit(0)
PYEOF
  [ "$?" -eq 0 ]
}

@test "docs.yml: no '\${{' in run: block content" {
  run check_no_interpolation_in_run "$DOCS"
  [ "$status" -eq 0 ]
}

@test "docs.yml: no static GITHUB_OUTPUT heredoc delimiters" {
  run check_no_static_output_delimiters "$DOCS"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# sweeper.yml structural tests
# ---------------------------------------------------------------------------

@test "sweeper.yml: actionlint passes" {
  run actionlint "$SWEEPER"
  [ "$status" -eq 0 ]
}

@test "sweeper.yml: declares on.workflow_call" {
  # Per SPEC §2.2 all swarm reusable workflows use workflow_call; callers own the cron
  run grep -q "workflow_call:" "$SWEEPER"
  [ "$status" -eq 0 ]
}

@test "sweeper.yml: declares on.workflow_dispatch trigger" {
  run grep -q "workflow_dispatch:" "$SWEEPER"
  [ "$status" -eq 0 ]
}

@test "sweeper.yml: does NOT have a bare on.schedule trigger" {
  # The schedule: trigger lives in the caller, not in the reusable workflow.
  # A top-level "  schedule:" line under "on:" would run in the swarm repo itself.
  WORKFLOW_FILE="$SWEEPER" python3 - <<'PYEOF'
import os, sys

with open(os.environ["WORKFLOW_FILE"]) as fh:
    lines = fh.readlines()

# Detect a "  schedule:" line that is a direct child of the top-level "on:" block.
in_on = False
for i, line in enumerate(lines, 1):
    stripped = line.rstrip('\n')
    if stripped == 'on:':
        in_on = True
        continue
    if in_on:
        # Any non-indented line closes the on: block
        if stripped and not stripped.startswith(' ') and not stripped.startswith('#'):
            in_on = False
            continue
        # Two-space indented "  schedule:" is a direct on: child
        if stripped.lstrip() == 'schedule:' and (len(stripped) - len(stripped.lstrip())) == 2:
            print(f"Line {i}: sweeper.yml has a bare on.schedule trigger — cron must live in the caller: {stripped!r}")
            sys.exit(1)

sys.exit(0)
PYEOF
  [ "$?" -eq 0 ]
}

@test "sweeper.yml: declares dry-run input" {
  run grep -q "dry-run:" "$SWEEPER"
  [ "$status" -eq 0 ]
}

@test "sweeper.yml: every job has a permissions block" {
  WORKFLOW_FILE="$SWEEPER" python3 - <<'PYEOF'
import os, sys

with open(os.environ["WORKFLOW_FILE"]) as fh:
    content = fh.read()

in_jobs = False
job_count = 0
perms_count = 0

for line in content.split("\n"):
    if line.strip() == "jobs:":
        in_jobs = True
        continue
    if not in_jobs:
        continue
    if not line.strip():
        continue
    cur = len(line) - len(line.lstrip())
    if cur == 2 and line.rstrip().endswith(":") and not line.strip().startswith("#"):
        job_count += 1
    if line.strip().startswith("permissions:"):
        perms_count += 1

if job_count == 0:
    print("No jobs found in workflow")
    sys.exit(1)
if perms_count < job_count:
    print(f"Jobs: {job_count}, permissions blocks: {perms_count} — every job must declare permissions")
    sys.exit(1)
sys.exit(0)
PYEOF
  [ "$?" -eq 0 ]
}

@test "sweeper.yml: every job has timeout-minutes" {
  WORKFLOW_FILE="$SWEEPER" python3 - <<'PYEOF'
import os, sys

with open(os.environ["WORKFLOW_FILE"]) as fh:
    content = fh.read()

in_jobs = False
job_count = 0
timeout_count = 0

for line in content.split("\n"):
    if line.strip() == "jobs:":
        in_jobs = True
        continue
    if not in_jobs:
        continue
    if not line.strip():
        continue
    cur = len(line) - len(line.lstrip())
    if cur == 2 and line.rstrip().endswith(":") and not line.strip().startswith("#"):
        job_count += 1
    if "timeout-minutes:" in line:
        timeout_count += 1

if job_count == 0:
    print("No jobs found")
    sys.exit(1)
if timeout_count < job_count:
    print(f"Jobs: {job_count}, timeout-minutes declarations: {timeout_count}")
    sys.exit(1)
sys.exit(0)
PYEOF
  [ "$?" -eq 0 ]
}

@test "sweeper.yml: no '\${{' in run: block content" {
  run check_no_interpolation_in_run "$SWEEPER"
  [ "$status" -eq 0 ]
}

@test "sweeper.yml: no static GITHUB_OUTPUT heredoc delimiters" {
  run check_no_static_output_delimiters "$SWEEPER"
  [ "$status" -eq 0 ]
}

@test "sweeper.yml: does not reference swarm:paused in any label-write context" {
  WORKFLOW_FILE="$SWEEPER" python3 - <<'PYEOF'
import os, re, sys

with open(os.environ["WORKFLOW_FILE"]) as fh:
    lines = fh.readlines()

mutation_pattern = re.compile(r'(add-label|remove-label|--add-label|--remove-label)')
paused_pattern = re.compile(r'swarm:paused')

for i, line in enumerate(lines, 1):
    stripped = line.strip()
    if stripped.startswith('#'):
        continue
    if paused_pattern.search(line) and mutation_pattern.search(line):
        print(f"Line {i}: sweeper.yml references swarm:paused in a label mutation context: {line!r}")
        sys.exit(1)

sys.exit(0)
PYEOF
  [ "$?" -eq 0 ]
}

@test "sweeper.yml: label-add allowlist is exactly swarm:needs-human" {
  WORKFLOW_FILE="$SWEEPER" python3 - <<'PYEOF'
import os, re, sys

with open(os.environ["WORKFLOW_FILE"]) as fh:
    content = fh.read()

add_label_pattern = re.compile(r'--add-label\s+["\']?([^\s"\'\\]+)["\']?')

for i, line in enumerate(content.split('\n'), 1):
    stripped = line.strip()
    if stripped.startswith('#'):
        continue
    for match in add_label_pattern.finditer(line):
        label = match.group(1).strip('"\'')
        if label != 'swarm:needs-human':
            print(f"Line {i}: sweeper adds label '{label}' — only 'swarm:needs-human' is permitted: {line!r}")
            sys.exit(1)

sys.exit(0)
PYEOF
  [ "$?" -eq 0 ]
}
