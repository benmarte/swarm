#!/usr/bin/env bats
# notify.bats — tests for notify action + all four adapters.
# Golden-payload assertions, missing-secret exits, invalid event rejection,
# and missing nak binary detection.
# Requires: ajv-cli@5.0.0 (npm install -g ajv-cli@5.0.0), jq, curl stub, nak stub.

REPO_ROOT="$(git -C "$(dirname "$BATS_TEST_FILENAME")" rev-parse --show-toplevel)"
NOTIFY_SH="$REPO_ROOT/actions/notify/notify.sh"
ADAPTERS_DIR="$REPO_ROOT/actions/notify/adapters"
STUBS_DIR="$REPO_ROOT/tests/stubs"
FIXTURE_EVENT="$REPO_ROOT/tests/fixtures/event/valid.json"
INVALID_EVENT="$REPO_ROOT/tests/fixtures/event/invalid-missing-field.json"

setup() {
  # Temp logs for curl and nak stubs
  export CURL_STUB_LOG
  CURL_STUB_LOG="$(mktemp)"
  export CURL_BODY_LOG
  CURL_BODY_LOG="$(mktemp)"
  export NAK_LOG
  NAK_LOG="$(mktemp)"
  export NAK_QUEUE
  NAK_QUEUE="$(mktemp)"

  # Prepend stubs dir so fake curl/nak are found first; real ajv lives later
  export PATH="$STUBS_DIR:$PATH"

  # Dummy secrets for adapters
  export SWARM_SLACK_WEBHOOK="https://hooks.slack.com/services/fake/webhook"
  export SWARM_DISCORD_WEBHOOK="https://discord.com/api/webhooks/fake/webhook"
  export SWARM_TEAMS_WEBHOOK="https://teams.webhook.office.com/fake/webhook"
  export SWARM_BUZZ_RELAY_URL="wss://relay.buzz.example"
  export SWARM_BUZZ_PRIVATE_KEY="0000000000000000000000000000000000000000000000000000000000000001"
  export BUZZ_CHANNEL="aabbccdd-1111-2222-3333-aabbccddeeff"
}

teardown() {
  rm -f "$CURL_STUB_LOG" "$CURL_BODY_LOG" "$NAK_LOG" "$NAK_QUEUE"
}

# =============================================================================
# notify.sh — validation gate (invalid event rejected BEFORE fan-out)
# =============================================================================

@test "notify.sh rejects invalid event before any fan-out" {
  export EVENT_FILE="$INVALID_EVENT"
  export ENABLED_SINKS="slack"

  run bash "$NOTIFY_SH"
  [ "$status" -ne 0 ]
  [[ "$output" == *"schema validation"* ]] || [[ "$output" == *"failed schema"* ]] || [[ "$output" == *"ERROR"* ]]

  # curl must NOT have been called
  [ ! -s "$CURL_STUB_LOG" ] || ! grep -q "^curl" "$CURL_STUB_LOG"
}

@test "notify.sh exits 0 with no sinks configured" {
  export EVENT_FILE="$FIXTURE_EVENT"
  export ENABLED_SINKS=""

  run bash "$NOTIFY_SH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to do"* ]] || [[ "$output" == *"no sinks"* ]]
}

@test "notify.sh exits 0 with valid event and enabled slack sink" {
  export EVENT_FILE="$FIXTURE_EVENT"
  export ENABLED_SINKS="slack"

  run bash "$NOTIFY_SH"
  [ "$status" -eq 0 ]
  grep -q "^curl" "$CURL_STUB_LOG"
}

@test "notify.sh exits 1 for unknown sink" {
  export EVENT_FILE="$FIXTURE_EVENT"
  export ENABLED_SINKS="bogus_sink"

  run bash "$NOTIFY_SH"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown sink"* ]] || [[ "$output" == *"bogus_sink"* ]]
}

# =============================================================================
# adapters/slack.sh — golden payload
# =============================================================================

@test "slack adapter: posts to SWARM_SLACK_WEBHOOK" {
  run bash "$ADAPTERS_DIR/slack.sh" "$FIXTURE_EVENT"
  [ "$status" -eq 0 ]
  grep -q "$SWARM_SLACK_WEBHOOK" "$CURL_STUB_LOG"
}

@test "slack adapter: payload has blocks array" {
  run bash "$ADAPTERS_DIR/slack.sh" "$FIXTURE_EVENT"
  [ "$status" -eq 0 ]

  body="$(cat "$CURL_BODY_LOG")"
  [ -n "$body" ]
  # Should have blocks
  echo "$body" | jq -e '.blocks | length > 0' > /dev/null
}

@test "slack adapter: payload contains event name in header" {
  run bash "$ADAPTERS_DIR/slack.sh" "$FIXTURE_EVENT"
  [ "$status" -eq 0 ]

  body="$(cat "$CURL_BODY_LOG")"
  # header block text should contain the event field value
  event_val="$(jq -r '.event' "$FIXTURE_EVENT")"
  echo "$body" | jq -e ".blocks[0].text.text | contains(\"$event_val\")" > /dev/null
}

@test "slack adapter: payload contains repo, issue, stage_from, stage_to, actor" {
  run bash "$ADAPTERS_DIR/slack.sh" "$FIXTURE_EVENT"
  [ "$status" -eq 0 ]

  body="$(cat "$CURL_BODY_LOG")"
  payload_text="$(echo "$body" | jq -r 'tostring')"

  repo="$(jq -r '.repo' "$FIXTURE_EVENT")"
  issue="$(jq -r '.issue | tostring' "$FIXTURE_EVENT")"
  from="$(jq -r '.stage_from' "$FIXTURE_EVENT")"
  to="$(jq -r '.stage_to' "$FIXTURE_EVENT")"
  actor="$(jq -r '.actor' "$FIXTURE_EVENT")"

  [[ "$payload_text" == *"$repo"* ]]
  [[ "$payload_text" == *"$issue"* ]]
  [[ "$payload_text" == *"$from"* ]]
  [[ "$payload_text" == *"$to"* ]]
  [[ "$payload_text" == *"$actor"* ]]
}

@test "slack adapter: payload contains view button with correct URL" {
  run bash "$ADAPTERS_DIR/slack.sh" "$FIXTURE_EVENT"
  [ "$status" -eq 0 ]

  body="$(cat "$CURL_BODY_LOG")"
  url="$(jq -r '.url' "$FIXTURE_EVENT")"
  echo "$body" | jq -e ".blocks[] | select(.accessory.url == \"$url\")" > /dev/null
}

@test "slack adapter: exits 1 when SWARM_SLACK_WEBHOOK not set" {
  unset SWARM_SLACK_WEBHOOK

  run bash "$ADAPTERS_DIR/slack.sh" "$FIXTURE_EVENT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SWARM_SLACK_WEBHOOK not set"* ]]
}

# =============================================================================
# adapters/discord.sh — golden payload
# =============================================================================

@test "discord adapter: posts to SWARM_DISCORD_WEBHOOK" {
  run bash "$ADAPTERS_DIR/discord.sh" "$FIXTURE_EVENT"
  [ "$status" -eq 0 ]
  grep -q "$SWARM_DISCORD_WEBHOOK" "$CURL_STUB_LOG"
}

@test "discord adapter: payload has embeds array" {
  run bash "$ADAPTERS_DIR/discord.sh" "$FIXTURE_EVENT"
  [ "$status" -eq 0 ]

  body="$(cat "$CURL_BODY_LOG")"
  [ -n "$body" ]
  echo "$body" | jq -e '.embeds | length > 0' > /dev/null
}

@test "discord adapter: embed contains event name in title" {
  run bash "$ADAPTERS_DIR/discord.sh" "$FIXTURE_EVENT"
  [ "$status" -eq 0 ]

  body="$(cat "$CURL_BODY_LOG")"
  event_val="$(jq -r '.event' "$FIXTURE_EVENT")"
  echo "$body" | jq -e ".embeds[0].title | contains(\"$event_val\")" > /dev/null
}

@test "discord adapter: embed fields contain repo, issue, stage, actor" {
  run bash "$ADAPTERS_DIR/discord.sh" "$FIXTURE_EVENT"
  [ "$status" -eq 0 ]

  body="$(cat "$CURL_BODY_LOG")"
  payload_text="$(echo "$body" | jq -r 'tostring')"

  repo="$(jq -r '.repo' "$FIXTURE_EVENT")"
  issue="$(jq -r '.issue | tostring' "$FIXTURE_EVENT")"
  actor="$(jq -r '.actor' "$FIXTURE_EVENT")"

  [[ "$payload_text" == *"$repo"* ]]
  [[ "$payload_text" == *"$issue"* ]]
  [[ "$payload_text" == *"$actor"* ]]
}

@test "discord adapter: embed url matches event url" {
  run bash "$ADAPTERS_DIR/discord.sh" "$FIXTURE_EVENT"
  [ "$status" -eq 0 ]

  body="$(cat "$CURL_BODY_LOG")"
  url="$(jq -r '.url' "$FIXTURE_EVENT")"
  echo "$body" | jq -e ".embeds[0].url == \"$url\"" > /dev/null
}

@test "discord adapter: exits 1 when SWARM_DISCORD_WEBHOOK not set" {
  unset SWARM_DISCORD_WEBHOOK

  run bash "$ADAPTERS_DIR/discord.sh" "$FIXTURE_EVENT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SWARM_DISCORD_WEBHOOK not set"* ]]
}

# =============================================================================
# adapters/teams.sh — golden payload
# =============================================================================

@test "teams adapter: posts to SWARM_TEAMS_WEBHOOK" {
  run bash "$ADAPTERS_DIR/teams.sh" "$FIXTURE_EVENT"
  [ "$status" -eq 0 ]
  grep -q "$SWARM_TEAMS_WEBHOOK" "$CURL_STUB_LOG"
}

@test "teams adapter: payload is type=message with attachments" {
  run bash "$ADAPTERS_DIR/teams.sh" "$FIXTURE_EVENT"
  [ "$status" -eq 0 ]

  body="$(cat "$CURL_BODY_LOG")"
  [ -n "$body" ]
  echo "$body" | jq -e '.type == "message"' > /dev/null
  echo "$body" | jq -e '.attachments | length > 0' > /dev/null
}

@test "teams adapter: attachment is AdaptiveCard contentType" {
  run bash "$ADAPTERS_DIR/teams.sh" "$FIXTURE_EVENT"
  [ "$status" -eq 0 ]

  body="$(cat "$CURL_BODY_LOG")"
  echo "$body" | jq -e '.attachments[0].contentType == "application/vnd.microsoft.card.adaptive"' > /dev/null
}

@test "teams adapter: AdaptiveCard body contains event name" {
  run bash "$ADAPTERS_DIR/teams.sh" "$FIXTURE_EVENT"
  [ "$status" -eq 0 ]

  body="$(cat "$CURL_BODY_LOG")"
  event_val="$(jq -r '.event' "$FIXTURE_EVENT")"
  payload_text="$(echo "$body" | jq -r 'tostring')"
  [[ "$payload_text" == *"$event_val"* ]]
}

@test "teams adapter: FactSet contains repo, issue, stage, actor" {
  run bash "$ADAPTERS_DIR/teams.sh" "$FIXTURE_EVENT"
  [ "$status" -eq 0 ]

  body="$(cat "$CURL_BODY_LOG")"
  payload_text="$(echo "$body" | jq -r 'tostring')"

  repo="$(jq -r '.repo' "$FIXTURE_EVENT")"
  issue="$(jq -r '.issue | tostring' "$FIXTURE_EVENT")"
  actor="$(jq -r '.actor' "$FIXTURE_EVENT")"

  [[ "$payload_text" == *"$repo"* ]]
  [[ "$payload_text" == *"$issue"* ]]
  [[ "$payload_text" == *"$actor"* ]]
}

@test "teams adapter: AdaptiveCard has OpenUrl action with event url" {
  run bash "$ADAPTERS_DIR/teams.sh" "$FIXTURE_EVENT"
  [ "$status" -eq 0 ]

  body="$(cat "$CURL_BODY_LOG")"
  url="$(jq -r '.url' "$FIXTURE_EVENT")"
  echo "$body" | jq -e \
    '.attachments[0].content.actions[] | select(.type == "Action.OpenUrl" and .url == "'"$url"'")' \
    > /dev/null
}

@test "teams adapter: exits 1 when SWARM_TEAMS_WEBHOOK not set" {
  unset SWARM_TEAMS_WEBHOOK

  run bash "$ADAPTERS_DIR/teams.sh" "$FIXTURE_EVENT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SWARM_TEAMS_WEBHOOK not set"* ]]
}

# =============================================================================
# adapters/buzz.sh — golden payload (nak argv assertions)
# =============================================================================

@test "buzz adapter: invokes nak with expected arguments" {
  run bash "$ADAPTERS_DIR/buzz.sh" "$FIXTURE_EVENT"
  [ "$status" -eq 0 ]

  nak_args="$(cat "$NAK_LOG")"
  # Must have: event --auth --sec <key> -k 9 -c <text> -t h=<channel> <relay-url>
  [[ "$nak_args" == *"--auth"* ]]
  [[ "$nak_args" == *"--sec $SWARM_BUZZ_PRIVATE_KEY"* ]]
  [[ "$nak_args" == *"-k 9"* ]]
  [[ "$nak_args" == *"-c "* ]]
  [[ "$nak_args" == *"h=$BUZZ_CHANNEL"* ]]
  [[ "$nak_args" == *"$SWARM_BUZZ_RELAY_URL"* ]]
}

@test "buzz adapter: message text contains repo, issue, stage_from, stage_to, actor, url" {
  run bash "$ADAPTERS_DIR/buzz.sh" "$FIXTURE_EVENT"
  [ "$status" -eq 0 ]

  nak_args="$(cat "$NAK_LOG")"

  repo="$(jq -r '.repo' "$FIXTURE_EVENT")"
  issue="$(jq -r '.issue | tostring' "$FIXTURE_EVENT")"
  from="$(jq -r '.stage_from' "$FIXTURE_EVENT")"
  to="$(jq -r '.stage_to' "$FIXTURE_EVENT")"
  actor="$(jq -r '.actor' "$FIXTURE_EVENT")"
  url="$(jq -r '.url' "$FIXTURE_EVENT")"

  [[ "$nak_args" == *"$repo"* ]]
  [[ "$nak_args" == *"$issue"* ]]
  [[ "$nak_args" == *"$from"* ]]
  [[ "$nak_args" == *"$to"* ]]
  [[ "$nak_args" == *"$actor"* ]]
  [[ "$nak_args" == *"$url"* ]]
}

@test "buzz adapter: exits 1 when SWARM_BUZZ_RELAY_URL not set" {
  unset SWARM_BUZZ_RELAY_URL

  run bash "$ADAPTERS_DIR/buzz.sh" "$FIXTURE_EVENT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SWARM_BUZZ_RELAY_URL not set"* ]]
}

@test "buzz adapter: exits 1 when SWARM_BUZZ_PRIVATE_KEY not set" {
  unset SWARM_BUZZ_PRIVATE_KEY

  run bash "$ADAPTERS_DIR/buzz.sh" "$FIXTURE_EVENT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SWARM_BUZZ_PRIVATE_KEY not set"* ]]
}

@test "buzz adapter: exits 1 when BUZZ_CHANNEL not set" {
  unset BUZZ_CHANNEL

  run bash "$ADAPTERS_DIR/buzz.sh" "$FIXTURE_EVENT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"BUZZ_CHANNEL not set"* ]]
}

@test "buzz adapter: exits 1 when nak binary not found" {
  # Remove stubs dir from PATH so nak is not found
  local stripped_path
  stripped_path="$(echo "$PATH" | tr ':' '\n' | grep -v "$STUBS_DIR" | tr '\n' ':' | sed 's/:$//')"
  export PATH="$stripped_path"

  run bash "$ADAPTERS_DIR/buzz.sh" "$FIXTURE_EVENT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"'nak' CLI not found"* ]]
}

@test "buzz adapter: exits 1 when nak returns failure" {
  echo "fail" > "$NAK_QUEUE"

  run bash "$ADAPTERS_DIR/buzz.sh" "$FIXTURE_EVENT"
  [ "$status" -ne 0 ]
}
