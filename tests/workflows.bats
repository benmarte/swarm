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
