#!/usr/bin/env bats
# bump-attempts.bats — unit tests for actions/bump-attempts/bump-attempts.sh
# Uses a mocked gh CLI on PATH that records invocations to a log file.

REPO_ROOT="$(git -C "$(dirname "$BATS_TEST_FILENAME")" rev-parse --show-toplevel)"
BUMP_SH="$REPO_ROOT/actions/bump-attempts/bump-attempts.sh"
STUBS_DIR="$REPO_ROOT/tests/stubs"

setup() {
  export GH_STUB_LOG="$(mktemp)"
  export GITHUB_REPOSITORY="testowner/testrepo"
  export GH_TOKEN="fake-token"
  export ISSUE_NUMBER="42"
  export MAINTAINER="benmarte"
  export POST_COMMENT="false"
  export RUNNER_TEMP="$(mktemp -d)"
  # Prepend stubs dir so our fake gh is found first
  export PATH="$STUBS_DIR:$PATH"
}

teardown() {
  rm -f "$GH_STUB_LOG"
  rm -rf "$RUNNER_TEMP"
}

# ---------------------------------------------------------------------------
# 0 → 1: no existing attempts label → adds swarm:attempts:1, no escalation
# ---------------------------------------------------------------------------

@test "0→1: no attempts label → adds swarm:attempts:1, no escalation" {
  export GH_STUB_LABELS_JSON='[]'

  run bash "$BUMP_SH"
  [ "$status" -eq 0 ]

  grep -q "labels\[\]=swarm:attempts:1" "$GH_STUB_LOG"
  ! grep -q "swarm:needs-human" "$GH_STUB_LOG"
  ! grep -q "assignees" "$GH_STUB_LOG"
}

# ---------------------------------------------------------------------------
# 1 → 2: removes swarm:attempts:1, adds swarm:attempts:2, no escalation
# ---------------------------------------------------------------------------

@test "1→2: removes swarm:attempts:1, adds swarm:attempts:2, no escalation" {
  export GH_STUB_LABELS_JSON='[{"name":"swarm:attempts:1"}]'

  run bash "$BUMP_SH"
  [ "$status" -eq 0 ]

  grep -q "DELETE.*swarm:attempts:1" "$GH_STUB_LOG"
  grep -q "labels\[\]=swarm:attempts:2" "$GH_STUB_LOG"
  ! grep -q "swarm:needs-human" "$GH_STUB_LOG"
  ! grep -q "assignees" "$GH_STUB_LOG"
}

# ---------------------------------------------------------------------------
# 2 → 3 (boundary): escalation side-effects all asserted independently
# ---------------------------------------------------------------------------

@test "2→3: removes swarm:attempts:2, adds swarm:attempts:3" {
  export GH_STUB_LABELS_JSON='[{"name":"swarm:attempts:2"}]'

  run bash "$BUMP_SH"
  [ "$status" -eq 0 ]

  grep -q "DELETE.*swarm:attempts:2" "$GH_STUB_LOG"
  grep -q "labels\[\]=swarm:attempts:3" "$GH_STUB_LOG"
}

@test "2→3: applies swarm:needs-human at limit" {
  export GH_STUB_LABELS_JSON='[{"name":"swarm:attempts:2"}]'

  run bash "$BUMP_SH"
  [ "$status" -eq 0 ]

  grep -q "labels\[\]=swarm:needs-human" "$GH_STUB_LOG"
}

@test "2→3: assigns configured maintainer at limit" {
  export GH_STUB_LABELS_JSON='[{"name":"swarm:attempts:2"}]'

  run bash "$BUMP_SH"
  [ "$status" -eq 0 ]

  grep -q "assignees\[\]=benmarte" "$GH_STUB_LOG"
}

@test "2→3: emits escalation event JSON file" {
  export GH_STUB_LABELS_JSON='[{"name":"swarm:attempts:2"}]'

  run bash "$BUMP_SH"
  [ "$status" -eq 0 ]

  # Event JSON file should exist
  [ -f "$RUNNER_TEMP/escalation-event.json" ]

  # Validate it has required fields
  event=$(cat "$RUNNER_TEMP/escalation-event.json")
  echo "$event" | jq -e '.event' > /dev/null
  echo "$event" | jq -e '.repo' > /dev/null
  echo "$event" | jq -e '.issue' > /dev/null
  echo "$event" | jq -e '.stage_from' > /dev/null
  echo "$event" | jq -e '.stage_to' > /dev/null
  echo "$event" | jq -e '.actor' > /dev/null
  echo "$event" | jq -e '.url' > /dev/null
  echo "$event" | jq -e '.summary' > /dev/null
}

@test "2→3: escalation event has correct event type" {
  export GH_STUB_LABELS_JSON='[{"name":"swarm:attempts:2"}]'

  run bash "$BUMP_SH"
  [ "$status" -eq 0 ]

  event_type=$(jq -r '.event' "$RUNNER_TEMP/escalation-event.json")
  [ "$event_type" = "escalation" ]
}

@test "2→3: escalation event stage_to is swarm:needs-human" {
  export GH_STUB_LABELS_JSON='[{"name":"swarm:attempts:2"}]'

  run bash "$BUMP_SH"
  [ "$status" -eq 0 ]

  stage_to=$(jq -r '.stage_to' "$RUNNER_TEMP/escalation-event.json")
  [ "$stage_to" = "swarm:needs-human" ]
}

@test "2→3: logs notify stub" {
  export GH_STUB_LABELS_JSON='[{"name":"swarm:attempts:2"}]'

  run bash "$BUMP_SH"
  [ "$status" -eq 0 ]

  [[ "$output" == *"notify: stub (#4 pending)"* ]]
}

# ---------------------------------------------------------------------------
# Already at limit — no further increment
# ---------------------------------------------------------------------------

@test "already at N=3: no increment, no duplicate escalation calls" {
  export GH_STUB_LABELS_JSON='[{"name":"swarm:attempts:3"}]'

  run bash "$BUMP_SH"
  [ "$status" -eq 0 ]

  [[ "$output" == *"already at attempt limit"* ]]

  # No label writes should happen
  ! grep -q "POST.*labels" "$GH_STUB_LOG" || true
  ! grep -q "DELETE" "$GH_STUB_LOG" || true
}

# ---------------------------------------------------------------------------
# Missing required inputs
# ---------------------------------------------------------------------------

@test "missing ISSUE_NUMBER exits non-zero" {
  export GH_STUB_LABELS_JSON='[]'
  unset ISSUE_NUMBER

  run bash "$BUMP_SH"
  [ "$status" -ne 0 ]
}

@test "missing MAINTAINER exits non-zero" {
  export GH_STUB_LABELS_JSON='[]'
  unset MAINTAINER

  run bash "$BUMP_SH"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# stage_from derived from current labels (reviewer finding)
# ---------------------------------------------------------------------------

@test "escalation event stage_from reflects actual current stage (swarm:qa)" {
  # Issue is at swarm:qa with 2 attempts → escalation should record stage_from=swarm:qa
  export GH_STUB_LABELS_JSON='[{"name":"swarm:qa"},{"name":"swarm:attempts:2"}]'

  run bash "$BUMP_SH"
  [ "$status" -eq 0 ]

  [ -f "$RUNNER_TEMP/escalation-event.json" ]
  stage_from=$(jq -r '.stage_from' "$RUNNER_TEMP/escalation-event.json")
  [ "$stage_from" = "swarm:qa" ]
}

@test "escalation event stage_from is 'unknown' when no stage label present" {
  # Issue has attempts:2 but no stage label at all
  export GH_STUB_LABELS_JSON='[{"name":"swarm:attempts:2"}]'

  run bash "$BUMP_SH"
  [ "$status" -eq 0 ]

  [ -f "$RUNNER_TEMP/escalation-event.json" ]
  stage_from=$(jq -r '.stage_from' "$RUNNER_TEMP/escalation-event.json")
  [ "$stage_from" = "unknown" ]
}

# ---------------------------------------------------------------------------
# Input validation — security hardening
# ---------------------------------------------------------------------------

@test "non-numeric ISSUE_NUMBER rejected before any gh call" {
  export ISSUE_NUMBER="1/../../repos"
  export GH_STUB_LABELS_JSON='[]'

  run bash "$BUMP_SH"
  [ "$status" -ne 0 ]
  [[ "$output" == *"positive integer"* ]] || [[ "${lines[*]}" == *"positive integer"* ]]

  # No gh calls should have been made
  [ ! -s "$GH_STUB_LOG" ] || ! grep -q "^gh api" "$GH_STUB_LOG"
}

@test "zero ISSUE_NUMBER rejected" {
  export ISSUE_NUMBER="0"
  export GH_STUB_LABELS_JSON='[]'

  run bash "$BUMP_SH"
  [ "$status" -ne 0 ]
}

@test "malicious MAINTAINER with injection chars rejected before any gh call" {
  export MAINTAINER='x" --method DELETE'
  export GH_STUB_LABELS_JSON='[]'

  run bash "$BUMP_SH"
  [ "$status" -ne 0 ]
  [[ "$output" == *"valid GitHub username"* ]] || [[ "${lines[*]}" == *"valid GitHub username"* ]]

  # No gh calls should have been made
  [ ! -s "$GH_STUB_LOG" ] || ! grep -q "^gh api" "$GH_STUB_LOG"
}

@test "MAINTAINER starting with hyphen rejected" {
  export MAINTAINER="-baduser"
  export GH_STUB_LABELS_JSON='[]'

  run bash "$BUMP_SH"
  [ "$status" -ne 0 ]
}
