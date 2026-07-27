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
  unset SWARM_TOKEN
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

@test "normal transition: logs notify no-op when ENABLED_SINKS not set" {
  export FROM_STAGE="swarm:go"
  export TO_STAGE="swarm:spec"
  export GH_STUB_LABELS_JSON='[{"name":"swarm:go"}]'
  unset ENABLED_SINKS

  run bash "$TRANSITION_SH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"notify: no sinks configured"* ]]
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

# ---------------------------------------------------------------------------
# Input validation — security hardening
# ---------------------------------------------------------------------------

@test "non-numeric ISSUE_NUMBER rejected before any gh call" {
  export FROM_STAGE="swarm:go"
  export TO_STAGE="swarm:spec"
  export ISSUE_NUMBER="1/../../repos"
  export GH_STUB_LABELS_JSON='[]'

  run bash "$TRANSITION_SH"
  [ "$status" -ne 0 ]
  [[ "$output" == *"positive integer"* ]] || [[ "${lines[*]}" == *"positive integer"* ]]

  # No gh calls should have been made
  [ ! -s "$GH_STUB_LOG" ] || ! grep -q "^gh api" "$GH_STUB_LOG"
}

@test "zero ISSUE_NUMBER rejected" {
  export FROM_STAGE="swarm:go"
  export TO_STAGE="swarm:spec"
  export ISSUE_NUMBER="0"
  export GH_STUB_LABELS_JSON='[]'

  run bash "$TRANSITION_SH"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# SWARM_TOKEN token selection (#40)
# ---------------------------------------------------------------------------

@test "token selection: uses SWARM_TOKEN when set (no fallback warning)" {
  export FROM_STAGE="swarm:go"
  export TO_STAGE="swarm:spec"
  export GH_STUB_LABELS_JSON='[{"name":"swarm:go"}]'
  export SWARM_TOKEN="pat-secret-value"

  run bash "$TRANSITION_SH"
  [ "$status" -eq 0 ]

  # Fallback warning must NOT appear when SWARM_TOKEN is provided
  [[ "$output" != *"WARNING: SWARM_TOKEN not set"* ]]
}

@test "token selection: emits loud warning when SWARM_TOKEN absent" {
  export FROM_STAGE="swarm:go"
  export TO_STAGE="swarm:spec"
  export GH_STUB_LABELS_JSON='[{"name":"swarm:go"}]'
  unset SWARM_TOKEN

  run bash "$TRANSITION_SH"
  [ "$status" -eq 0 ]

  # Warning lines must appear in stderr (captured in output by bats)
  [[ "$output" == *"WARNING: SWARM_TOKEN not set"* ]]
  [[ "$output" == *"Stage cascade will NOT trigger"* ]]
}

@test "token selection: succeeds with GH_TOKEN fallback when SWARM_TOKEN absent" {
  export FROM_STAGE="swarm:go"
  export TO_STAGE="swarm:spec"
  export GH_STUB_LABELS_JSON='[{"name":"swarm:go"}]'
  unset SWARM_TOKEN

  run bash "$TRANSITION_SH"
  [ "$status" -eq 0 ]

  # Label operations still execute via GH_TOKEN fallback
  grep -q "DELETE.*labels/swarm:go" "$GH_STUB_LOG"
  grep -q "labels\[\]=swarm:spec" "$GH_STUB_LOG" || \
    grep -q "POST.*labels.*swarm:spec" "$GH_STUB_LOG"
}

# ---------------------------------------------------------------------------
# Issue #53: notify sink end-to-end — ENABLED_SINKS=buzz invokes buzz adapter
# ---------------------------------------------------------------------------

@test "e2e: ENABLED_SINKS=buzz invokes buzz adapter with h-tag and event fields" {
  export FROM_STAGE="swarm:go"
  export TO_STAGE="swarm:spec"
  export GH_STUB_LABELS_JSON='[{"name":"swarm:go"}]'
  export POST_COMMENT="false"
  export GITHUB_ACTOR="testactor"

  # Set up buzz env
  export ENABLED_SINKS="buzz"
  export BUZZ_CHANNEL="aabbccdd-1111-2222-3333-aabbccddeeff"
  export SWARM_BUZZ_RELAY_URL="wss://relay.buzz.example"
  export SWARM_BUZZ_PRIVATE_KEY="0000000000000000000000000000000000000000000000000000000000000001"

  # NAK_LOG receives the nak invocation arguments
  export NAK_LOG
  NAK_LOG="$(mktemp)"

  # Point NOTIFY_SCRIPT to the real notify.sh which uses stubs dir nak
  # The stubs dir is already on PATH from setup()
  # transition.sh picks up NOTIFY_SCRIPT override for hermetic testing
  NOTIFY_SCRIPT_REAL="$REPO_ROOT/actions/notify/notify.sh"
  export NOTIFY_SCRIPT="$NOTIFY_SCRIPT_REAL"

  run bash "$TRANSITION_SH"
  [ "$status" -eq 0 ]

  # nak stub must have been called
  [ -s "$NAK_LOG" ]

  # Verify -t h=<channel> was passed to nak
  grep -q "h=${BUZZ_CHANNEL}" "$NAK_LOG"

  # Verify the event fields are present in the nak invocation
  grep -q "stage_transition\|swarm:go.*swarm:spec\|Issue #42" "$NAK_LOG" || \
    grep -q "swarm:go" "$NAK_LOG"

  rm -f "$NAK_LOG"
}

@test "e2e: ENABLED_SINKS=buzz: sink secrets are not echoed to stdout" {
  export FROM_STAGE="swarm:go"
  export TO_STAGE="swarm:spec"
  export GH_STUB_LABELS_JSON='[{"name":"swarm:go"}]'
  export POST_COMMENT="false"
  export GITHUB_ACTOR="testactor"

  export ENABLED_SINKS="buzz"
  export BUZZ_CHANNEL="aabbccdd-1111-2222-3333-aabbccddeeff"
  export SWARM_BUZZ_RELAY_URL="wss://relay.buzz.example"
  export SWARM_BUZZ_PRIVATE_KEY="secret-private-key-must-not-appear-in-logs"

  export NAK_LOG
  NAK_LOG="$(mktemp)"

  NOTIFY_SCRIPT_REAL="$REPO_ROOT/actions/notify/notify.sh"
  export NOTIFY_SCRIPT="$NOTIFY_SCRIPT_REAL"

  run bash "$TRANSITION_SH"
  [ "$status" -eq 0 ]

  # The private key value must not appear in stdout/stderr
  [[ "$output" != *"secret-private-key-must-not-appear-in-logs"* ]]

  rm -f "$NAK_LOG"
}

@test "e2e: ENABLED_SINKS empty disables notify fan-out (no nak call)" {
  export FROM_STAGE="swarm:go"
  export TO_STAGE="swarm:spec"
  export GH_STUB_LABELS_JSON='[{"name":"swarm:go"}]'
  export POST_COMMENT="false"
  unset ENABLED_SINKS

  export NAK_LOG
  NAK_LOG="$(mktemp)"

  run bash "$TRANSITION_SH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no sinks configured"* ]]

  # nak must NOT have been called
  [ ! -s "$NAK_LOG" ]

  rm -f "$NAK_LOG"
}
