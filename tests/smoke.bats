#!/usr/bin/env bats
# smoke.bats — scaffold smoke tests.
# Asserts the repo skeleton from SPEC §3 is in place and verify.sh is runnable.

REPO_ROOT="$(git -C "$(dirname "$BATS_TEST_FILENAME")" rev-parse --show-toplevel)"

@test "scripts/verify.sh exists and is executable" {
  [ -f "$REPO_ROOT/scripts/verify.sh" ]
  [ -x "$REPO_ROOT/scripts/verify.sh" ]
}

@test "workflows/ directory exists" {
  [ -d "$REPO_ROOT/workflows" ]
}

@test "actions/agent-run/adapters/ directory exists" {
  [ -d "$REPO_ROOT/actions/agent-run/adapters" ]
}

@test "actions/develop-run/adapters/ directory exists" {
  [ -d "$REPO_ROOT/actions/develop-run/adapters" ]
}

@test "actions/validate-outcome/ directory exists" {
  [ -d "$REPO_ROOT/actions/validate-outcome" ]
}

@test "actions/transition/ directory exists" {
  [ -d "$REPO_ROOT/actions/transition" ]
}

@test "actions/bump-attempts/ directory exists" {
  [ -d "$REPO_ROOT/actions/bump-attempts" ]
}

@test "actions/notify/adapters/ directory exists" {
  [ -d "$REPO_ROOT/actions/notify/adapters" ]
}

@test "prompts/ directory exists" {
  [ -d "$REPO_ROOT/prompts" ]
}

@test "schemas/ directory exists" {
  [ -d "$REPO_ROOT/schemas" ]
}

@test "docs/ directory exists" {
  [ -d "$REPO_ROOT/docs" ]
}

@test "tests/ directory exists" {
  [ -d "$REPO_ROOT/tests" ]
}

@test ".github/workflows/ci.yml exists" {
  [ -f "$REPO_ROOT/.github/workflows/ci.yml" ]
}
