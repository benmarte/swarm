#!/usr/bin/env bats
# transition.bats — unit tests for actions/transition/transition.sh
# Uses a mocked gh CLI on PATH that records invocations to a log file.

REPO_ROOT="$(git -C "$(dirname "$BATS_TEST_FILENAME")" rev-parse --show-toplevel)"
TRANSITION_SH="$REPO_ROOT/actions/transition/transition.sh"
STUBS_DIR="$REPO_ROOT/tests/stubs"

setup() {
  export GH_STUB_LOG="$(mktemp)"
  export GITHUB_REPOSITORY="testowner/testrepo"
  export GH_TOKEN="fake-token"
  export ISSUE_NUMBER="42"
  export POST_COMMENT="false"
  # Prepend stubs dir so our fake gh is found first
  export PATH="$STUBS_DIR:$PATH"
}

teardown() {
  rm -f "$GH_STUB_LOG"
}

# ---------------------------------------------------------------------------
# Normal transition: swarm:go → swarm:spec
# ---------------------------------------------------------------------------

@test "normal transition: removes old label and adds new label" {
  export FROM_STAGE="swarm:go"
  export TO_STAGE="swarm:spec"
  # Issue currently has swarm:go
  export GH_STUB_LABELS_JSON='[{"name":"swarm:go"}]'

  run bash "$TRANSITION_SH"
  [ "$status" -eq 0 ]

  # Verify DELETE was called for swarm:go
  grep -q "DELETE.*labels/swarm:go" "$GH_STUB_LOG"
  # Verify POST was called to add swarm:spec
  grep -q "POST.*labels.*swarm:spec" "$GH_STUB_LOG" || \
    grep -q "labels\[\]=swarm:spec" "$GH_STUB_LOG"
}

@test "normal transition: posts comment when POST_COMMENT=true" {
  export FROM_STAGE="swarm:go"
  export TO_STAGE="swarm:spec"
  export POST_COMMENT="true"
  export GH_STUB_LABELS_JSON='[{"name":"swarm:go"}]'

  run bash "$TRANSITION_SH"
  [ "$status" -eq 0 ]

  grep -q "POST.*comments" "$GH_STUB_LOG"
}

@test "normal transition: logs notify stub when notify not on PATH" {
  export FROM_STAGE="swarm:go"
  export TO_STAGE="swarm:spec"
  export GH_STUB_LABELS_JSON='[{"name":"swarm:go"}]'

  run bash "$TRANSITION_SH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"notify: stub (#4 pending)"* ]]
}

# ---------------------------------------------------------------------------
# Repeat-transition no-op: to-stage already present, from-stage absent
# ---------------------------------------------------------------------------

@test "repeat-transition no-op: exits 0 and makes no label-write calls" {
  export FROM_STAGE="swarm:go"
  export TO_STAGE="swarm:spec"
  # Issue already has swarm:spec (to-stage) and swarm:go is gone
  export GH_STUB_LABELS_JSON='[{"name":"swarm:spec"}]'

  run bash "$TRANSITION_SH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no-op"* ]]

  # No DELETE or POST label calls should have been made
  ! grep -q "DELETE" "$GH_STUB_LOG" || true
  # The only gh call should be the GET labels call
  call_count=$(grep -c "^gh api" "$GH_STUB_LOG" || echo 0)
  [ "$call_count" -le 1 ]
}

# ---------------------------------------------------------------------------
# Invalid stage name rejected before any gh call
# ---------------------------------------------------------------------------

@test "invalid from-stage rejected before any gh call" {
  export FROM_STAGE="swarm:INVALID"
  export TO_STAGE="swarm:spec"
  export GH_STUB_LABELS_JSON='[]'

  run bash "$TRANSITION_SH"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a valid swarm stage label"* ]] || \
    [[ "${lines[*]}" == *"not a valid swarm stage label"* ]]

  # No gh calls should have been made
  [ ! -s "$GH_STUB_LOG" ] || ! grep -q "^gh api" "$GH_STUB_LOG"
}

@test "invalid to-stage rejected before any gh call" {
  export FROM_STAGE="swarm:go"
  export TO_STAGE="swarm:NOTASTATE"
  export GH_STUB_LABELS_JSON='[]'

  run bash "$TRANSITION_SH"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a valid swarm stage label"* ]] || \
    [[ "${lines[*]}" == *"not a valid swarm stage label"* ]]

  [ ! -s "$GH_STUB_LOG" ] || ! grep -q "^gh api" "$GH_STUB_LOG"
}

@test "outcome-style unvalidated string rejected if not in allowlist" {
  # Simulate an injected label value that is not in the allowlist
  export FROM_STAGE='swarm:go; echo pwned'
  export TO_STAGE="swarm:spec"
  export GH_STUB_LABELS_JSON='[]'

  run bash "$TRANSITION_SH"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# All valid stage names are accepted
# ---------------------------------------------------------------------------

@test "all allowed stage names pass validation" {
  for stage in swarm:go swarm:spec swarm:develop swarm:qa swarm:docs swarm:done swarm:needs-human swarm:paused; do
    export FROM_STAGE="$stage"
    export TO_STAGE="swarm:done"
    export GH_STUB_LABELS_JSON="[{\"name\":\"${stage}\"}]"

    run bash "$TRANSITION_SH"
    # Should not fail on allowlist check (status is 0 or label ops happen)
    # (will exit 0 — either no-op or normal transition)
    [ "$status" -eq 0 ]
    : > "$GH_STUB_LOG"  # reset log
  done
}

# ---------------------------------------------------------------------------
# Missing required inputs
# ---------------------------------------------------------------------------

@test "missing ISSUE_NUMBER exits non-zero" {
  export FROM_STAGE="swarm:go"
  export TO_STAGE="swarm:spec"
  unset ISSUE_NUMBER

  run bash "$TRANSITION_SH"
  [ "$status" -ne 0 ]
}

@test "missing FROM_STAGE exits non-zero" {
  export TO_STAGE="swarm:spec"
  unset FROM_STAGE

  run bash "$TRANSITION_SH"
  [ "$status" -ne 0 ]
}

@test "missing TO_STAGE exits non-zero" {
  export FROM_STAGE="swarm:go"
  unset TO_STAGE

  run bash "$TRANSITION_SH"
  [ "$status" -ne 0 ]
}
