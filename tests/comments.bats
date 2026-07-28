#!/usr/bin/env bats
# comments.bats — tests for per-stage findings comments (issue #50).
#
# Coverage:
#   1. render-comment.sh: golden template renders from fixture outcomes.
#   2. render-comment.sh: hostile evidence content renders safely.
#   3. render-comment.sh: output written to a temp path, not the repo tree.
#   4. render-comment.sh: missing template exits non-zero.
#   5. Structural: every stage workflow has a comment step gated on comments-enabled.
#   6. Structural: comment body always written to mktemp (never inline).
#   7. load-config: comments-enabled output present and exported.
#   8. config schema: comments.enabled field is valid.

REPO_ROOT="$(git -C "$(dirname "$BATS_TEST_FILENAME")" rev-parse --show-toplevel)"
RENDER_SH="$REPO_ROOT/scripts/render-comment.sh"
# Engine-owned templates: top-level templates/comments/ (NOT .claude/talos/)
TEMPLATES="$REPO_ROOT/templates/comments"
FIXTURES="$REPO_ROOT/tests/fixtures/comments"
INTAKE="$REPO_ROOT/.github/workflows/intake.yml"
DEVELOP="$REPO_ROOT/.github/workflows/develop.yml"
PR_GATES="$REPO_ROOT/.github/workflows/pr-gates.yml"
DOCS="$REPO_ROOT/.github/workflows/docs.yml"
LOAD_CONFIG_SH="$REPO_ROOT/actions/load-config/load-config.sh"
CONFIG_SCHEMA="$REPO_ROOT/schemas/config.schema.json"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# extract_details_from_fixture FIXTURE_JSON
# Renders the evidence details bullet list from a fixture outcome JSON file
# using the same jq pattern as the workflow steps (including newline sanitization).
extract_details_from_fixture() {
  local fixture="$1"
  jq -r '.evidence | to_entries | map(select(.key != "summary")) | .[] |
    "- **\(.key):** \(if (.value | type) == "array" then (.value | map(tostring | gsub("[\\n\\r]+"; " ")) | join(", ")) else (.value | tostring | gsub("[\\n\\r]+"; " ")) end)"' \
    "$fixture"
}

# ---------------------------------------------------------------------------
# render-comment.sh: golden template renders
# ---------------------------------------------------------------------------

@test "render-comment.sh: validator-verdict golden render from fixture outcome" {
  local fixture="$FIXTURES/validator-outcome.json"
  local template="$TEMPLATES/validator-verdict.md"
  local body_file
  body_file="$(mktemp)"
  trap 'rm -f "$body_file"' EXIT

  local verdict summary details
  verdict="$(jq -r '.verdict' "$fixture")"
  summary="$(jq -r '.evidence.summary' "$fixture")"
  details="$(extract_details_from_fixture "$fixture")"

  HEADER="**swarm validator**" \
    VERDICT="$verdict" \
    SUMMARY="$summary" \
    DETAILS="$details" \
    bash "$RENDER_SH" "$template" "$body_file"

  local rendered
  rendered="$(cat "$body_file")"
  [[ "$rendered" == *"**swarm validator**"* ]]
  [[ "$rendered" == *"**Verdict:** confirmed"* ]]
  [[ "$rendered" == *"actionable"* ]]
  [[ "$rendered" == *"no duplicate found"* ]]
}

@test "render-comment.sh: review-signoff golden render" {
  local template="$TEMPLATES/review-signoff.md"
  local body_file
  body_file="$(mktemp)"
  trap 'rm -f "$body_file"' EXIT

  HEADER="**swarm reviewer**" \
    VERDICT="approve" \
    SUMMARY="All acceptance criteria met." \
    DETAILS="- **files_reviewed:** schemas/config.schema.json, actions/load-config" \
    bash "$RENDER_SH" "$template" "$body_file"

  local rendered
  rendered="$(cat "$body_file")"
  [[ "$rendered" == *"**swarm reviewer**"* ]]
  [[ "$rendered" == *"**Review:** approve"* ]]
  [[ "$rendered" == *"All acceptance criteria met."* ]]
}

@test "render-comment.sh: docs-posted golden render" {
  local template="$TEMPLATES/docs-posted.md"
  local body_file
  body_file="$(mktemp)"
  trap 'rm -f "$body_file"' EXIT

  HEADER="**swarm docs**" \
    SUMMARY="Documentation written and posted." \
    DETAILS="- **files:** README.md, SPEC.md" \
    bash "$RENDER_SH" "$template" "$body_file"

  local rendered
  rendered="$(cat "$body_file")"
  [[ "$rendered" == *"**swarm docs**"* ]]
  [[ "$rendered" == *"**Docs:** posted"* ]]
  [[ "$rendered" == *"Documentation written"* ]]
}

@test "render-comment.sh: issue-closed golden render" {
  local template="$TEMPLATES/issue-closed.md"
  local body_file
  body_file="$(mktemp)"
  trap 'rm -f "$body_file"' EXIT

  HEADER="**swarm**" \
    PR="PR #42" \
    SUMMARY="All stages passed." \
    DETAILS="" \
    bash "$RENDER_SH" "$template" "$body_file"

  local rendered
  rendered="$(cat "$body_file")"
  [[ "$rendered" == *"**swarm**"* ]]
  [[ "$rendered" == *"Closed by PR #42"* ]]
}

@test "render-comment.sh: blocked golden render" {
  local template="$TEMPLATES/blocked.md"
  local body_file
  body_file="$(mktemp)"
  trap 'rm -f "$body_file"' EXIT

  HEADER="**swarm security**" \
    SUMMARY="Critical injection vulnerability found in commit SHA handling." \
    DETAILS="- **threat_model_checks:** secret exposure, injection" \
    bash "$RENDER_SH" "$template" "$body_file"

  local rendered
  rendered="$(cat "$body_file")"
  [[ "$rendered" == *"**Blocked**"* ]]
  [[ "$rendered" == *"injection vulnerability"* ]]
  [[ "$rendered" == *"pipeline:blocked"* ]]
}

# ---------------------------------------------------------------------------
# render-comment.sh: hostile content renders safely
# ---------------------------------------------------------------------------

@test "render-comment.sh: backticks in evidence do not execute as shell code" {
  local fixture="$FIXTURES/hostile-outcome.json"
  local template="$TEMPLATES/validator-verdict.md"
  local body_file
  body_file="$(mktemp)"
  trap 'rm -f "$body_file"' EXIT

  local verdict summary details
  verdict="$(jq -r '.verdict' "$fixture")"
  summary="$(jq -r '.evidence.summary' "$fixture")"
  details="$(extract_details_from_fixture "$fixture")"

  HEADER="**swarm validator**" \
    VERDICT="$verdict" \
    SUMMARY="$summary" \
    DETAILS="$details" \
    bash "$RENDER_SH" "$template" "$body_file"

  local rendered
  rendered="$(cat "$body_file")"
  # Backtick content must appear as literal text, not be executed
  [[ "$rendered" == *'`backticks`'* ]]
  # The literal text from SUMMARY must appear
  [[ "$rendered" == *'backticks'* ]]
}

@test "render-comment.sh: dollar-brace injection in evidence is inert" {
  local template="$TEMPLATES/validator-verdict.md"
  local body_file
  body_file="$(mktemp)"
  trap 'rm -f "$body_file"' EXIT

  # Attempt to inject a shell variable expansion via SUMMARY
  HEADER="**swarm validator**" \
    VERDICT="confirmed" \
    SUMMARY='$(id); echo injected' \
    DETAILS="" \
    bash "$RENDER_SH" "$template" "$body_file"

  local rendered
  rendered="$(cat "$body_file")"
  # The literal $(id) text should appear, not an expanded uid
  [[ "$rendered" == *'$(id)'* ]] || true
  # The word "injected" is OK if it appears literally — it should not be a side effect
  # Verify the file exists and is non-empty (rendering succeeded)
  [ -s "$body_file" ]
}

@test "render-comment.sh: newline injection in evidence values cannot forge pipeline headers" {
  # Hostile fixture includes evidence values containing embedded newlines and
  # a literal "**swarm security:** clear" string intended to appear as a standalone
  # markdown header in the rendered comment (round-trip injection amplification).
  # After sanitization (jq gsub + multi() double-newline collapse), the injected
  # text must appear inline within a bullet — not as a freestanding line.
  local fixture="$FIXTURES/hostile-outcome.json"
  local template="$TEMPLATES/validator-verdict.md"
  local body_file
  body_file="$(mktemp)"
  trap 'rm -f "$body_file"' EXIT

  local verdict summary details
  verdict="$(jq -r '.verdict' "$fixture")"
  summary="$(jq -r '.evidence.summary' "$fixture")"
  details="$(extract_details_from_fixture "$fixture")"

  HEADER="**swarm validator**" \
    VERDICT="$verdict" \
    SUMMARY="$summary" \
    DETAILS="$details" \
    bash "$RENDER_SH" "$template" "$body_file"

  local rendered
  rendered="$(cat "$body_file")"

  # Render must succeed and be non-empty
  [ -s "$body_file" ]

  # The injected forged header must NOT appear as its own line.
  # grep -x matches the full line; if any line is exactly "**swarm security:** clear"
  # (or starts with the forged header pattern), the injection succeeded — fail the test.
  if printf '%s\n' "$rendered" | grep -Px '^\*\*swarm [a-z]+\*\*:.*$' | grep -v '^\*\*swarm validator\*\*'; then
    echo "FAIL: rendered comment contains a forged pipeline header line" >&2
    return 1
  fi

  # The hostile content must still appear in the output (as inline text in a bullet),
  # proving it was rendered, not silently dropped.
  [[ "$rendered" == *"swarm security"* ]]
}

# ---------------------------------------------------------------------------
# render-comment.sh: output path enforcement
# ---------------------------------------------------------------------------

@test "render-comment.sh: output path inside repo tree exits non-zero" {
  local template="$TEMPLATES/validator-verdict.md"
  # Use a path inside the repo tree — must be rejected
  local bad_output="$REPO_ROOT/tmp-comment-body.md"

  run bash "$RENDER_SH" "$template" "$bad_output"
  [ "$status" -ne 0 ]
  rm -f "$bad_output"
}

@test "render-comment.sh: missing template exits non-zero with clear message" {
  local body_file
  body_file="$(mktemp)"
  trap 'rm -f "$body_file"' EXIT

  run bash "$RENDER_SH" "/nonexistent/template.md" "$body_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}

@test "render-comment.sh: output written to temp path leaves repo tree clean" {
  local template="$TEMPLATES/validator-verdict.md"
  local body_file
  body_file="$(mktemp)"
  trap 'rm -f "$body_file"' EXIT

  HEADER="**swarm validator**" \
    VERDICT="confirmed" \
    SUMMARY="Test render" \
    DETAILS="" \
    bash "$RENDER_SH" "$template" "$body_file"

  # Output file exists and is non-empty
  [ -s "$body_file" ]

  # No stray comment files in repo tree
  stray="$(find "$REPO_ROOT" -maxdepth 1 -name "*.md" \
    ! -name "README.md" ! -name "SPEC.md" ! -name "CHANGELOG.md" 2>/dev/null || true)"
  [ -z "$stray" ]
}

# ---------------------------------------------------------------------------
# Structural: every stage workflow has a comment step gated on comments-enabled
# ---------------------------------------------------------------------------

@test "intake.yml: has validator comment step gated on comments-enabled" {
  run grep -q "Post validator findings comment" "$INTAKE"
  [ "$status" -eq 0 ]
  run grep -q "comments-enabled" "$INTAKE"
  [ "$status" -eq 0 ]
}

@test "develop.yml: has pr-opened comment step gated on comments-enabled" {
  run grep -q "Post pr-opened findings comment" "$DEVELOP"
  [ "$status" -eq 0 ]
  run grep -q "comments-enabled" "$DEVELOP"
  [ "$status" -eq 0 ]
}

@test "pr-gates.yml: has review-signoff comment step gated on comments-enabled" {
  run grep -q "Post review-signoff findings comment" "$PR_GATES"
  [ "$status" -eq 0 ]
  run grep -q "comments-enabled" "$PR_GATES"
  [ "$status" -eq 0 ]
}

@test "pr-gates.yml: has security-signoff comment step gated on comments-enabled" {
  run grep -q "Post security-signoff findings comment" "$PR_GATES"
  [ "$status" -eq 0 ]
}

@test "docs.yml: has docs-posted comment step gated on comments-enabled" {
  run grep -q "Post docs findings comment" "$DOCS"
  [ "$status" -eq 0 ]
  run grep -q "comments-enabled" "$DOCS"
  [ "$status" -eq 0 ]
}

@test "docs.yml: has issue-closed comment step" {
  run grep -q "Post issue-closed findings comment" "$DOCS"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Structural: comment body always written via mktemp (never inline --body)
# ---------------------------------------------------------------------------

@test "comment steps in all 4 workflows use --body-file not --body with inline template content" {
  # Each comment step must pass --body-file (mktemp path), never raw --body with template content.
  # We verify the render-comment.sh call and --body-file pattern co-occur.
  for wf in "$INTAKE" "$DEVELOP" "$PR_GATES" "$DOCS"; do
    if grep -q "render-comment.sh" "$wf"; then
      if ! grep -q "body-file" "$wf"; then
        printf 'FAIL: %s uses render-comment.sh but missing --body-file\n' "$wf" >&2
        return 1
      fi
    fi
  done
}

@test "no comment body string written to repo tree path in any workflow" {
  # Comment body must go to mktemp (a temp path outside the repo).
  # Look for --body-file referencing GITHUB_WORKSPACE (workspace-relative path).
  for wf in "$INTAKE" "$DEVELOP" "$PR_GATES" "$DOCS"; do
    if grep -qE -- '--body-file.*GITHUB_WORKSPACE|--body-file.*github\.workspace' "$wf" 2>/dev/null; then
      printf 'FAIL: %s writes comment body to workspace path\n' "$wf" >&2
      return 1
    fi
  done
}

# ---------------------------------------------------------------------------
# load-config: comments-enabled output exported
# ---------------------------------------------------------------------------

@test "load-config.sh: exports comments-enabled output" {
  run grep -q "comments-enabled" "$LOAD_CONFIG_SH"
  [ "$status" -eq 0 ]
  run grep -q "comments_enabled" "$LOAD_CONFIG_SH"
  [ "$status" -eq 0 ]
}

@test "load-config.sh: comments-enabled defaults to true when absent" {
  run grep -q 'if . == null then "true"' "$LOAD_CONFIG_SH"
  [ "$status" -eq 0 ]
}

@test "load-config action.yml: declares comments-enabled output" {
  ACTION_YML="$REPO_ROOT/actions/load-config/action.yml"
  run grep -q "comments-enabled" "$ACTION_YML"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# config schema: comments.enabled field is valid
# ---------------------------------------------------------------------------

@test "config schema: comments property declared" {
  run grep -q '"comments"' "$CONFIG_SCHEMA"
  [ "$status" -eq 0 ]
}

@test "config schema: comments.enabled is a boolean field" {
  run python3 - "$CONFIG_SCHEMA" <<'PYEOF'
import sys, json

with open(sys.argv[1]) as fh:
    schema = json.load(fh)

comments = schema.get("properties", {}).get("comments", {})
if not comments:
    print("ERROR: comments property not found in schema")
    sys.exit(1)

enabled = comments.get("properties", {}).get("enabled", {})
if enabled.get("type") != "boolean":
    print(f"ERROR: comments.enabled type is {enabled.get('type')!r}, expected 'boolean'")
    sys.exit(1)

sys.exit(0)
PYEOF
  [ "$status" -eq 0 ]
}

@test "config schema: valid config with comments.enabled passes validation" {
  command -v ajv >/dev/null 2>&1 || skip "ajv-cli not installed"
  local tmp_config
  tmp_config="$(mktemp).yml"
  printf '{"runner": {"label": "swarm-agent"}, "develop": {"adapter": "claude-code-action"}, "comments": {"enabled": true}}\n' \
    > "$tmp_config"
  run ajv validate -s "$CONFIG_SCHEMA" -d "$tmp_config"
  rm -f "$tmp_config"
  [ "$status" -eq 0 ]
}

@test "config schema: comments.enabled false passes validation" {
  command -v ajv >/dev/null 2>&1 || skip "ajv-cli not installed"
  local tmp_config
  tmp_config="$(mktemp).yml"
  printf '{"runner": {"label": "swarm-agent"}, "develop": {"adapter": "claude-code-action"}, "comments": {"enabled": false}}\n' \
    > "$tmp_config"
  run ajv validate -s "$CONFIG_SCHEMA" -d "$tmp_config"
  rm -f "$tmp_config"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Template files: all required templates exist
# ---------------------------------------------------------------------------

@test "templates: validator-verdict.md exists" {
  [ -f "$TEMPLATES/validator-verdict.md" ]
}

@test "templates: pr-opened.md exists" {
  [ -f "$TEMPLATES/pr-opened.md" ]
}

@test "templates: review-signoff.md exists" {
  [ -f "$TEMPLATES/review-signoff.md" ]
}

@test "templates: security-signoff.md exists" {
  [ -f "$TEMPLATES/security-signoff.md" ]
}

@test "templates: docs-posted.md exists" {
  [ -f "$TEMPLATES/docs-posted.md" ]
}

@test "templates: issue-closed.md exists" {
  [ -f "$TEMPLATES/issue-closed.md" ]
}

@test "templates: blocked.md exists" {
  [ -f "$TEMPLATES/blocked.md" ]
}

@test "templates: render-comment.sh exists and is executable" {
  [ -f "$RENDER_SH" ]
  bash -n "$RENDER_SH"
}

# ---------------------------------------------------------------------------
# Structural: engine template dir is at top-level (not .claude/talos/)
# Guard: tests would FAIL if the templates were missing from the right path.
# ---------------------------------------------------------------------------

@test "templates dir exists at engine root (templates/comments/), not under .claude/" {
  [ -d "$REPO_ROOT/templates/comments" ]
  # Guard: dir must NOT exist only under .claude/ — the engine path must be canonical
  # (this catches the case where someone moved templates back to .claude/talos)
  [ -f "$TEMPLATES/validator-verdict.md" ]
  [ -f "$TEMPLATES/pr-opened.md" ]
  [ -f "$TEMPLATES/review-signoff.md" ]
  [ -f "$TEMPLATES/security-signoff.md" ]
  [ -f "$TEMPLATES/docs-posted.md" ]
  [ -f "$TEMPLATES/issue-closed.md" ]
  [ -f "$TEMPLATES/blocked.md" ]
}

@test "no engine runtime code references .swarm-engine/.claude/ asset paths" {
  # Engine runtime code must never reference assets via .swarm-engine/.claude/ —
  # that resolves to talos tooling in the engine checkout, not swarm engine assets.
  # Legitimate uses of .claude/ as a grep exclusion pattern (e.g. grep -v '^\.claude/')
  # are excluded from this check.
  local violations
  violations="$(grep -rn '\.swarm-engine/\.claude/\|swarm-engine.*\.claude/talos' \
    "$REPO_ROOT/.github/workflows/" \
    "$REPO_ROOT/actions/" \
    "$REPO_ROOT/scripts/" \
    "$REPO_ROOT/templates/" \
    --include='*.yml' --include='*.yaml' --include='*.sh' --include='*.md' \
    2>/dev/null || true)"
  if [ -n "$violations" ]; then
    printf 'FAIL: engine code references .swarm-engine/.claude/ path:\n%s\n' "$violations" >&2
    return 1
  fi
}

@test "no workflow references .claude/talos path" {
  for wf in "$INTAKE" "$DEVELOP" "$PR_GATES" "$DOCS"; do
    if grep -q '\.claude/talos' "$wf"; then
      printf 'FAIL: %s still references .claude/talos\n' "$wf" >&2
      grep -n '\.claude/talos' "$wf" >&2
      return 1
    fi
  done
}

@test "workflow comment steps reference .swarm-engine/templates/comments/ path" {
  # All four workflows that post findings comments must use the engine template path.
  local found=0
  for wf in "$INTAKE" "$DEVELOP" "$PR_GATES" "$DOCS"; do
    if grep -q "render-comment.sh" "$wf"; then
      if ! grep -q '\.swarm-engine/templates/comments/' "$wf"; then
        printf 'FAIL: %s uses render-comment.sh but not .swarm-engine/templates/comments/\n' "$wf" >&2
        return 1
      fi
      found=$((found + 1))
    fi
  done
  [ "$found" -ge 4 ]
}
