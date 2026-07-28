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
FIXTURE_RICH="$REPO_ROOT/tests/fixtures/event/rich.json"
FIXTURE_BLOCKED="$REPO_ROOT/tests/fixtures/event/rich-blocked.json"
FIXTURE_MERGED="$REPO_ROOT/tests/fixtures/event/rich-merged.json"

setup() {
  # Temp logs for curl and nak stubs
  export CURL_STUB_LOG
  CURL_STUB_LOG="$(mktemp)"
  export CURL_BODY_LOG
  CURL_BODY_LOG="$(mktemp)"
  export CURL_HEADER_LOG
  CURL_HEADER_LOG="$(mktemp)"
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
  rm -f "$CURL_STUB_LOG" "$CURL_BODY_LOG" "$CURL_HEADER_LOG" "$NAK_LOG" "$NAK_QUEUE"
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

@test "slack adapter: exits 1 when neither webhook nor bot-token configured" {
  unset SWARM_SLACK_WEBHOOK
  unset SWARM_SLACK_BOT_TOKEN
  unset SLACK_CHANNEL

  run bash "$ADAPTERS_DIR/slack.sh" "$FIXTURE_EVENT"
  [ "$status" -ne 0 ]
  # Must name both options so users know what to configure
  [[ "$output" == *"SWARM_SLACK_WEBHOOK"* ]]
  [[ "$output" == *"SWARM_SLACK_BOT_TOKEN"* ]]
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

@test "discord adapter: exits 1 when neither webhook nor bot-token configured" {
  unset SWARM_DISCORD_WEBHOOK
  unset SWARM_DISCORD_BOT_TOKEN
  unset DISCORD_CHANNEL

  run bash "$ADAPTERS_DIR/discord.sh" "$FIXTURE_EVENT"
  [ "$status" -ne 0 ]
  # Must name both options so users know what to configure
  [[ "$output" == *"SWARM_DISCORD_WEBHOOK"* ]]
  [[ "$output" == *"SWARM_DISCORD_BOT_TOKEN"* ]]
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
  # Override NAK_BIN to a nonexistent path so command -v fails regardless of
  # whether nak is installed on the host machine.
  export NAK_BIN="/nonexistent/nak"

  run bash "$ADAPTERS_DIR/buzz.sh" "$FIXTURE_EVENT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"'nak' CLI not found"* ]]
}

@test "buzz adapter: exits 1 when nak returns failure" {
  echo "fail" > "$NAK_QUEUE"

  run bash "$ADAPTERS_DIR/buzz.sh" "$FIXTURE_EVENT"
  [ "$status" -ne 0 ]
}

# =============================================================================
# adapters/slack.sh — bot-token mode golden payload
# =============================================================================

@test "slack adapter: bot-token mode posts to chat.postMessage URL" {
  unset SWARM_SLACK_WEBHOOK
  export SWARM_SLACK_BOT_TOKEN="xoxb-test-bot-token-value"
  export SLACK_CHANNEL="C0TEST1234"

  run bash "$ADAPTERS_DIR/slack.sh" "$FIXTURE_EVENT"
  [ "$status" -eq 0 ]

  # Must post to the Slack API endpoint, not a webhook URL
  grep -q "https://slack.com/api/chat.postMessage" "$CURL_STUB_LOG"
}

@test "slack adapter: bot-token mode sends Authorization header" {
  unset SWARM_SLACK_WEBHOOK
  export SWARM_SLACK_BOT_TOKEN="xoxb-test-bot-token-value"
  export SLACK_CHANNEL="C0TEST1234"

  run bash "$ADAPTERS_DIR/slack.sh" "$FIXTURE_EVENT"
  [ "$status" -eq 0 ]

  # Header name must be logged (secret hygiene: value is NOT asserted)
  grep -q "Authorization" "$CURL_HEADER_LOG"
  # Token value must NOT appear in the script's own stdout/stderr output
  [[ "$output" != *"xoxb-test-bot-token-value"* ]]
}

@test "slack adapter: bot-token mode payload includes channel and blocks" {
  unset SWARM_SLACK_WEBHOOK
  export SWARM_SLACK_BOT_TOKEN="xoxb-test-bot-token-value"
  export SLACK_CHANNEL="C0TEST1234"

  run bash "$ADAPTERS_DIR/slack.sh" "$FIXTURE_EVENT"
  [ "$status" -eq 0 ]

  body="$(cat "$CURL_BODY_LOG")"
  [ -n "$body" ]
  # Payload must include the channel ID
  echo "$body" | jq -e ".channel == \"C0TEST1234\"" > /dev/null
  # Payload must include blocks array
  echo "$body" | jq -e '.blocks | length > 0' > /dev/null
}

@test "slack adapter: bot-token mode payload contains event fields" {
  unset SWARM_SLACK_WEBHOOK
  export SWARM_SLACK_BOT_TOKEN="xoxb-test-bot-token-value"
  export SLACK_CHANNEL="C0TEST1234"

  run bash "$ADAPTERS_DIR/slack.sh" "$FIXTURE_EVENT"
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

@test "slack adapter: webhook wins when both webhook and bot-token are set" {
  export SWARM_SLACK_WEBHOOK="https://hooks.slack.com/services/fake/webhook"
  export SWARM_SLACK_BOT_TOKEN="xoxb-test-bot-token-value"
  export SLACK_CHANNEL="C0TEST1234"

  run bash "$ADAPTERS_DIR/slack.sh" "$FIXTURE_EVENT"
  [ "$status" -eq 0 ]

  # Must post to webhook URL, not the API endpoint
  grep -q "$SWARM_SLACK_WEBHOOK" "$CURL_STUB_LOG"
  ! grep -q "chat.postMessage" "$CURL_STUB_LOG"
}

@test "slack adapter: bot-token mode with ok:false response fails loudly" {
  unset SWARM_SLACK_WEBHOOK
  export SWARM_SLACK_BOT_TOKEN="xoxb-test-bot-token-value"
  export SLACK_CHANNEL="C0TEST1234"
  # Slack returns HTTP 200 even on error; adapter must detect ok:false
  export CURL_STUB_RESPONSE='{"ok":false,"error":"channel_not_found"}'

  run bash "$ADAPTERS_DIR/slack.sh" "$FIXTURE_EVENT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ok:false"* ]]
  [[ "$output" == *"channel_not_found"* ]]
}

@test "slack adapter: bot-token mode exits 1 when SLACK_CHANNEL not set" {
  unset SWARM_SLACK_WEBHOOK
  unset SLACK_CHANNEL
  export SWARM_SLACK_BOT_TOKEN="xoxb-test-bot-token-value"

  run bash "$ADAPTERS_DIR/slack.sh" "$FIXTURE_EVENT"
  [ "$status" -ne 0 ]
  # Should name both options since no complete mode is configured
  [[ "$output" == *"SWARM_SLACK_WEBHOOK"* ]] || [[ "$output" == *"SWARM_SLACK_BOT_TOKEN"* ]]
}

# =============================================================================
# adapters/discord.sh — bot-token mode golden payload
# =============================================================================

@test "discord adapter: bot-token mode posts to channels API URL" {
  unset SWARM_DISCORD_WEBHOOK
  export SWARM_DISCORD_BOT_TOKEN="Bot.test.discord.token"
  export DISCORD_CHANNEL="123456789012345678"

  run bash "$ADAPTERS_DIR/discord.sh" "$FIXTURE_EVENT"
  [ "$status" -eq 0 ]

  # Must post to the Discord channels API endpoint
  grep -q "https://discord.com/api/v10/channels/123456789012345678/messages" "$CURL_STUB_LOG"
}

@test "discord adapter: bot-token mode sends Authorization header" {
  unset SWARM_DISCORD_WEBHOOK
  export SWARM_DISCORD_BOT_TOKEN="Bot.test.discord.token"
  export DISCORD_CHANNEL="123456789012345678"

  run bash "$ADAPTERS_DIR/discord.sh" "$FIXTURE_EVENT"
  [ "$status" -eq 0 ]

  # Header name must be logged (secret hygiene: value is NOT asserted)
  grep -q "Authorization" "$CURL_HEADER_LOG"
  # Token value must NOT appear in the script's own stdout/stderr output
  [[ "$output" != *"Bot.test.discord.token"* ]]
}

@test "discord adapter: bot-token mode payload has embeds array" {
  unset SWARM_DISCORD_WEBHOOK
  export SWARM_DISCORD_BOT_TOKEN="Bot.test.discord.token"
  export DISCORD_CHANNEL="123456789012345678"

  run bash "$ADAPTERS_DIR/discord.sh" "$FIXTURE_EVENT"
  [ "$status" -eq 0 ]

  body="$(cat "$CURL_BODY_LOG")"
  [ -n "$body" ]
  echo "$body" | jq -e '.embeds | length > 0' > /dev/null
}

@test "discord adapter: bot-token mode payload contains event fields" {
  unset SWARM_DISCORD_WEBHOOK
  export SWARM_DISCORD_BOT_TOKEN="Bot.test.discord.token"
  export DISCORD_CHANNEL="123456789012345678"

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

@test "discord adapter: webhook wins when both webhook and bot-token are set" {
  export SWARM_DISCORD_WEBHOOK="https://discord.com/api/webhooks/fake/webhook"
  export SWARM_DISCORD_BOT_TOKEN="Bot.test.discord.token"
  export DISCORD_CHANNEL="123456789012345678"

  run bash "$ADAPTERS_DIR/discord.sh" "$FIXTURE_EVENT"
  [ "$status" -eq 0 ]

  # Must post to webhook URL, not the API endpoint
  grep -q "$SWARM_DISCORD_WEBHOOK" "$CURL_STUB_LOG"
  ! grep -q "api/v10/channels" "$CURL_STUB_LOG"
}

@test "discord adapter: bot-token mode fails on non-2xx curl exit" {
  unset SWARM_DISCORD_WEBHOOK
  export SWARM_DISCORD_BOT_TOKEN="Bot.test.discord.token"
  export DISCORD_CHANNEL="123456789012345678"
  # Stub returns non-zero to simulate HTTP 4xx/5xx (--fail exits non-zero)
  export CURL_STUB_STATUS=22

  run bash "$ADAPTERS_DIR/discord.sh" "$FIXTURE_EVENT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"non-2xx"* ]] || [[ "$output" == *"ERROR"* ]]
}

@test "discord adapter: bot-token mode exits 1 when DISCORD_CHANNEL not set" {
  unset SWARM_DISCORD_WEBHOOK
  unset DISCORD_CHANNEL
  export SWARM_DISCORD_BOT_TOKEN="Bot.test.discord.token"

  run bash "$ADAPTERS_DIR/discord.sh" "$FIXTURE_EVENT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SWARM_DISCORD_WEBHOOK"* ]] || [[ "$output" == *"SWARM_DISCORD_BOT_TOKEN"* ]]
}

# =============================================================================
# load-config: enabled-sinks derivation with channel-only config
# =============================================================================

@test "load-config: slack_channel alone enables the slack sink" {
  # A config with only slack_channel set (no boolean) should enable slack
  _tmpdir="$(mktemp -d)"
  trap 'rm -rf "$_tmpdir"' EXIT
  cat > "$_tmpdir/swarm.config.yml" <<'YAML'
notify:
  slack_channel: C0TEST1234
YAML
  export CONFIG_FILE="$_tmpdir/swarm.config.yml"
  export GITHUB_OUTPUT="$_tmpdir/output"
  touch "$GITHUB_OUTPUT"
  ACTION_PATH="$REPO_ROOT/actions/load-config" \
    GITHUB_WORKSPACE="$_tmpdir" \
    CONFIG_FILE="$_tmpdir/swarm.config.yml" \
    run bash "$REPO_ROOT/actions/load-config/load-config.sh"
  [ "$status" -eq 0 ]
  grep -q "enabled-sinks<<" "$_tmpdir/output"
  # enabled-sinks output must include 'slack'
  _sinks="$(grep -A1 'enabled-sinks<<' "$_tmpdir/output" | tail -1)"
  [[ "$_sinks" == *"slack"* ]]
}

@test "load-config: discord_channel alone enables the discord sink" {
  _tmpdir="$(mktemp -d)"
  trap 'rm -rf "$_tmpdir"' EXIT
  cat > "$_tmpdir/swarm.config.yml" <<'YAML'
notify:
  discord_channel: "123456789012345678"
YAML
  export CONFIG_FILE="$_tmpdir/swarm.config.yml"
  export GITHUB_OUTPUT="$_tmpdir/output"
  touch "$GITHUB_OUTPUT"
  ACTION_PATH="$REPO_ROOT/actions/load-config" \
    GITHUB_WORKSPACE="$_tmpdir" \
    CONFIG_FILE="$_tmpdir/swarm.config.yml" \
    run bash "$REPO_ROOT/actions/load-config/load-config.sh"
  [ "$status" -eq 0 ]
  _sinks="$(grep -A1 'enabled-sinks<<' "$_tmpdir/output" | tail -1)"
  [[ "$_sinks" == *"discord"* ]]
}

@test "load-config: slack_channel exported as notify-slack-channel output" {
  _tmpdir="$(mktemp -d)"
  trap 'rm -rf "$_tmpdir"' EXIT
  cat > "$_tmpdir/swarm.config.yml" <<'YAML'
notify:
  slack_channel: C0TEST1234
YAML
  export GITHUB_OUTPUT="$_tmpdir/output"
  touch "$GITHUB_OUTPUT"
  ACTION_PATH="$REPO_ROOT/actions/load-config" \
    GITHUB_WORKSPACE="$_tmpdir" \
    CONFIG_FILE="$_tmpdir/swarm.config.yml" \
    run bash "$REPO_ROOT/actions/load-config/load-config.sh"
  [ "$status" -eq 0 ]
  grep -q "notify-slack-channel<<" "$_tmpdir/output"
  _val="$(grep -A1 'notify-slack-channel<<' "$_tmpdir/output" | tail -1)"
  [ "$_val" = "C0TEST1234" ]
}

@test "load-config: discord_channel exported as notify-discord-channel output" {
  _tmpdir="$(mktemp -d)"
  trap 'rm -rf "$_tmpdir"' EXIT
  cat > "$_tmpdir/swarm.config.yml" <<'YAML'
notify:
  discord_channel: "123456789012345678"
YAML
  export GITHUB_OUTPUT="$_tmpdir/output"
  touch "$GITHUB_OUTPUT"
  ACTION_PATH="$REPO_ROOT/actions/load-config" \
    GITHUB_WORKSPACE="$_tmpdir" \
    CONFIG_FILE="$_tmpdir/swarm.config.yml" \
    run bash "$REPO_ROOT/actions/load-config/load-config.sh"
  [ "$status" -eq 0 ]
  grep -q "notify-discord-channel<<" "$_tmpdir/output"
  _val="$(grep -A1 'notify-discord-channel<<' "$_tmpdir/output" | tail -1)"
  [ "$_val" = "123456789012345678" ]
}

# =============================================================================
# Channel ID validation — hostile values rejected before any curl call
# =============================================================================

@test "slack adapter: bot-token mode rejects channel with path-traversal characters" {
  unset SWARM_SLACK_WEBHOOK
  export SWARM_SLACK_BOT_TOKEN="xoxb-test-token"
  export SLACK_CHANNEL="C123/../../evil"

  run bash "$ADAPTERS_DIR/slack.sh" "$FIXTURE_EVENT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid"* ]] || [[ "$output" == *"ERROR"* ]]
  # curl must NOT have been called — validation must be pre-flight
  [ ! -s "$CURL_STUB_LOG" ] || ! grep -q "^curl" "$CURL_STUB_LOG"
}

@test "slack adapter: bot-token mode rejects channel with dot-dot sequence" {
  unset SWARM_SLACK_WEBHOOK
  export SWARM_SLACK_BOT_TOKEN="xoxb-test-token"
  export SLACK_CHANNEL="../admin"

  run bash "$ADAPTERS_DIR/slack.sh" "$FIXTURE_EVENT"
  [ "$status" -ne 0 ]
  # curl must NOT have been called
  [ ! -s "$CURL_STUB_LOG" ] || ! grep -q "^curl" "$CURL_STUB_LOG"
}

@test "slack adapter: bot-token mode accepts valid alphanumeric channel ID" {
  unset SWARM_SLACK_WEBHOOK
  export SWARM_SLACK_BOT_TOKEN="xoxb-test-token"
  export SLACK_CHANNEL="C0VALIDCHAN"

  run bash "$ADAPTERS_DIR/slack.sh" "$FIXTURE_EVENT"
  [ "$status" -eq 0 ]
  grep -q "^curl" "$CURL_STUB_LOG"
}

@test "discord adapter: bot-token mode rejects channel with path-traversal characters" {
  unset SWARM_DISCORD_WEBHOOK
  export SWARM_DISCORD_BOT_TOKEN="Bot.test.token"
  export DISCORD_CHANNEL="123456789012345/../../etc"

  run bash "$ADAPTERS_DIR/discord.sh" "$FIXTURE_EVENT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"snowflake"* ]] || [[ "$output" == *"invalid"* ]] || [[ "$output" == *"ERROR"* ]]
  # curl must NOT have been called
  [ ! -s "$CURL_STUB_LOG" ] || ! grep -q "^curl" "$CURL_STUB_LOG"
}

@test "discord adapter: bot-token mode rejects non-numeric channel ID" {
  unset SWARM_DISCORD_WEBHOOK
  export SWARM_DISCORD_BOT_TOKEN="Bot.test.token"
  export DISCORD_CHANNEL="notanumber"

  run bash "$ADAPTERS_DIR/discord.sh" "$FIXTURE_EVENT"
  [ "$status" -ne 0 ]
  # curl must NOT have been called
  [ ! -s "$CURL_STUB_LOG" ] || ! grep -q "^curl" "$CURL_STUB_LOG"
}

@test "discord adapter: bot-token mode rejects too-short numeric ID" {
  unset SWARM_DISCORD_WEBHOOK
  export SWARM_DISCORD_BOT_TOKEN="Bot.test.token"
  # Too short (< 17 digits) — not a valid Discord snowflake
  export DISCORD_CHANNEL="12345"

  run bash "$ADAPTERS_DIR/discord.sh" "$FIXTURE_EVENT"
  [ "$status" -ne 0 ]
  # curl must NOT have been called
  [ ! -s "$CURL_STUB_LOG" ] || ! grep -q "^curl" "$CURL_STUB_LOG"
}

@test "discord adapter: bot-token mode accepts valid 18-digit snowflake" {
  unset SWARM_DISCORD_WEBHOOK
  export SWARM_DISCORD_BOT_TOKEN="Bot.test.token"
  export DISCORD_CHANNEL="123456789012345678"

  run bash "$ADAPTERS_DIR/discord.sh" "$FIXTURE_EVENT"
  [ "$status" -eq 0 ]
  grep -q "^curl" "$CURL_STUB_LOG"
}

# =============================================================================
# curl network failure — adapters must not report success when curl dies
# =============================================================================

@test "slack adapter: bot-token mode exits non-zero when curl fails (network error)" {
  unset SWARM_SLACK_WEBHOOK
  export SWARM_SLACK_BOT_TOKEN="xoxb-test-token"
  export SLACK_CHANNEL="C0VALIDCHAN"
  # Stub exits non-zero to simulate network failure (DNS/timeout/connection refused)
  export CURL_STUB_STATUS=6

  run bash "$ADAPTERS_DIR/slack.sh" "$FIXTURE_EVENT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"curl failed"* ]] || [[ "$output" == *"ERROR"* ]]
}

@test "discord adapter: bot-token mode exits non-zero when curl fails (network error)" {
  unset SWARM_DISCORD_WEBHOOK
  export SWARM_DISCORD_BOT_TOKEN="Bot.test.token"
  export DISCORD_CHANNEL="123456789012345678"
  # Stub exits non-zero to simulate curl failure; discord uses --fail so exits non-zero
  export CURL_STUB_STATUS=6

  run bash "$ADAPTERS_DIR/discord.sh" "$FIXTURE_EVENT"
  [ "$status" -ne 0 ]
}

# =============================================================================
# Rich fixture — golden payloads with role/verdict/evidence (#63)
# Tests 3 event classes (validator/blocked/merged) across slack/discord/buzz.
# =============================================================================

# ---------------------------------------------------------------------------
# Event schema: rich fixtures validate against the extended schema
# ---------------------------------------------------------------------------

@test "event schema: rich fixture with role/verdict/evidence passes validation" {
  command -v ajv >/dev/null 2>&1 || skip "ajv-cli not installed"
  run ajv validate -s "$REPO_ROOT/schemas/event.schema.json" -d "$FIXTURE_RICH"
  [ "$status" -eq 0 ]
}

@test "event schema: rich-blocked fixture passes validation" {
  command -v ajv >/dev/null 2>&1 || skip "ajv-cli not installed"
  run ajv validate -s "$REPO_ROOT/schemas/event.schema.json" -d "$FIXTURE_BLOCKED"
  [ "$status" -eq 0 ]
}

@test "event schema: rich-merged fixture passes validation" {
  command -v ajv >/dev/null 2>&1 || skip "ajv-cli not installed"
  run ajv validate -s "$REPO_ROOT/schemas/event.schema.json" -d "$FIXTURE_MERGED"
  [ "$status" -eq 0 ]
}

@test "event schema: existing transition fixture still validates (backward compat)" {
  command -v ajv >/dev/null 2>&1 || skip "ajv-cli not installed"
  run ajv validate -s "$REPO_ROOT/schemas/event.schema.json" -d "$FIXTURE_EVENT"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Slack golden payload — validator event (blue, NOTIFY_TEXT with evidence)
# ---------------------------------------------------------------------------

@test "slack adapter: rich validator event payload has context block with repo/event/issue" {
  export NOTIFY_TEXT="[validator] confirmed — Issue is valid and actionable
• no duplicate found
• acceptance criteria are clear
• scope is bounded"

  run bash "$ADAPTERS_DIR/slack.sh" "$FIXTURE_RICH"
  [ "$status" -eq 0 ]

  body="$(cat "$CURL_BODY_LOG")"
  # Context block must contain repo · event · #issue
  echo "$body" | jq -e '
    .blocks[] | select(.type == "context") |
    .elements[0].text | (contains("benmarte/swarm") and contains("validator") and contains("#7"))
  ' > /dev/null
}

@test "slack adapter: rich validator event payload has color attachment (default blue)" {
  export NOTIFY_TEXT="[validator] confirmed"

  run bash "$ADAPTERS_DIR/slack.sh" "$FIXTURE_RICH"
  [ "$status" -eq 0 ]

  body="$(cat "$CURL_BODY_LOG")"
  # attachments[0].color must be the default blue
  echo "$body" | jq -e '.attachments[0].color == "#3498db"' > /dev/null
}

@test "slack adapter: rich validator event section body contains verdict and evidence" {
  export NOTIFY_TEXT="[validator] confirmed — Issue is valid and actionable
• no duplicate found
• acceptance criteria are clear"

  run bash "$ADAPTERS_DIR/slack.sh" "$FIXTURE_RICH"
  [ "$status" -eq 0 ]

  body="$(cat "$CURL_BODY_LOG")"
  section_text="$(echo "$body" | jq -r '.blocks[0].text.text')"
  [[ "$section_text" == *"confirmed"* ]]
  [[ "$section_text" == *"no duplicate found"* ]]
}

# ---------------------------------------------------------------------------
# Slack golden payload — blocked event (red)
# ---------------------------------------------------------------------------

@test "slack adapter: blocked event has red color attachment" {
  run bash "$ADAPTERS_DIR/slack.sh" "$FIXTURE_BLOCKED"
  [ "$status" -eq 0 ]

  body="$(cat "$CURL_BODY_LOG")"
  echo "$body" | jq -e '.attachments[0].color == "#e74c3c"' > /dev/null
}

@test "slack adapter: blocked event context block contains repo and issue" {
  run bash "$ADAPTERS_DIR/slack.sh" "$FIXTURE_BLOCKED"
  [ "$status" -eq 0 ]

  body="$(cat "$CURL_BODY_LOG")"
  echo "$body" | jq -e '
    .blocks[] | select(.type == "context") |
    .elements[0].text | contains("benmarte/swarm")
  ' > /dev/null
}

# ---------------------------------------------------------------------------
# Slack golden payload — merged event (green)
# ---------------------------------------------------------------------------

@test "slack adapter: merged event has green color attachment" {
  run bash "$ADAPTERS_DIR/slack.sh" "$FIXTURE_MERGED"
  [ "$status" -eq 0 ]

  body="$(cat "$CURL_BODY_LOG")"
  echo "$body" | jq -e '.attachments[0].color == "#2ecc71"' > /dev/null
}

# ---------------------------------------------------------------------------
# Slack: security event (orange), reviewer event (purple) color mapping
# ---------------------------------------------------------------------------

@test "slack adapter: security event has orange color attachment" {
  # Create a minimal security event in a temp file
  _tmp="$(mktemp)"
  trap 'rm -f "$_tmp"' EXIT
  jq '.event = "security"' "$FIXTURE_RICH" > "$_tmp"

  run bash "$ADAPTERS_DIR/slack.sh" "$_tmp"
  [ "$status" -eq 0 ]

  body="$(cat "$CURL_BODY_LOG")"
  echo "$body" | jq -e '.attachments[0].color == "#e67e22"' > /dev/null
}

@test "slack adapter: reviewer event has purple color attachment" {
  _tmp="$(mktemp)"
  trap 'rm -f "$_tmp"' EXIT
  jq '.event = "reviewer"' "$FIXTURE_RICH" > "$_tmp"

  run bash "$ADAPTERS_DIR/slack.sh" "$_tmp"
  [ "$status" -eq 0 ]

  body="$(cat "$CURL_BODY_LOG")"
  echo "$body" | jq -e '.attachments[0].color == "#9b59b6"' > /dev/null
}

# ---------------------------------------------------------------------------
# Discord golden payload — validator event (blue embed color)
# ---------------------------------------------------------------------------

@test "discord adapter: rich validator event embed has blue color (3447003)" {
  run bash "$ADAPTERS_DIR/discord.sh" "$FIXTURE_RICH"
  [ "$status" -eq 0 ]

  body="$(cat "$CURL_BODY_LOG")"
  echo "$body" | jq -e '.embeds[0].color == 3447003' > /dev/null
}

@test "discord adapter: rich validator event embed footer has context line" {
  run bash "$ADAPTERS_DIR/discord.sh" "$FIXTURE_RICH"
  [ "$status" -eq 0 ]

  body="$(cat "$CURL_BODY_LOG")"
  footer="$(echo "$body" | jq -r '.embeds[0].footer.text')"
  [[ "$footer" == *"benmarte/swarm"* ]]
  [[ "$footer" == *"validator"* ]]
  [[ "$footer" == *"#7"* ]]
}

@test "discord adapter: rich validator event embed url is clickable" {
  run bash "$ADAPTERS_DIR/discord.sh" "$FIXTURE_RICH"
  [ "$status" -eq 0 ]

  body="$(cat "$CURL_BODY_LOG")"
  url="$(jq -r '.url' "$FIXTURE_RICH")"
  echo "$body" | jq -e ".embeds[0].url == \"$url\"" > /dev/null
}

# ---------------------------------------------------------------------------
# Discord golden payload — blocked (red) and merged (green) event colors
# ---------------------------------------------------------------------------

@test "discord adapter: blocked event embed has red color (15158332)" {
  run bash "$ADAPTERS_DIR/discord.sh" "$FIXTURE_BLOCKED"
  [ "$status" -eq 0 ]

  body="$(cat "$CURL_BODY_LOG")"
  echo "$body" | jq -e '.embeds[0].color == 15158332' > /dev/null
}

@test "discord adapter: merged event embed has green color (3066993)" {
  run bash "$ADAPTERS_DIR/discord.sh" "$FIXTURE_MERGED"
  [ "$status" -eq 0 ]

  body="$(cat "$CURL_BODY_LOG")"
  echo "$body" | jq -e '.embeds[0].color == 3066993' > /dev/null
}

# ---------------------------------------------------------------------------
# Buzz golden payload — rich validator event with verdict/evidence in text
# ---------------------------------------------------------------------------

@test "buzz adapter: rich validator event text contains role, verdict, evidence, url" {
  export NOTIFY_TEXT="[validator] confirmed — Issue is valid and actionable
• no duplicate found
• acceptance criteria are clear
• scope is bounded
https://github.com/benmarte/swarm/issues/7"

  run bash "$ADAPTERS_DIR/buzz.sh" "$FIXTURE_RICH"
  [ "$status" -eq 0 ]

  nak_args="$(cat "$NAK_LOG")"
  [[ "$nak_args" == *"confirmed"* ]]
  [[ "$nak_args" == *"no duplicate found"* ]]
  [[ "$nak_args" == *"https://github.com/benmarte/swarm/issues/7"* ]]
}

@test "buzz adapter: without NOTIFY_TEXT, rich fixture fallback includes role and verdict" {
  unset NOTIFY_TEXT

  run bash "$ADAPTERS_DIR/buzz.sh" "$FIXTURE_RICH"
  [ "$status" -eq 0 ]

  nak_args="$(cat "$NAK_LOG")"
  # Fallback format includes role/verdict/evidence from event JSON
  [[ "$nak_args" == *"validator"* ]]
  [[ "$nak_args" == *"confirmed"* ]]
  [[ "$nak_args" == *"no duplicate"* ]]
}

@test "buzz adapter: blocked event fallback text contains blocked verdict and evidence" {
  unset NOTIFY_TEXT

  run bash "$ADAPTERS_DIR/buzz.sh" "$FIXTURE_BLOCKED"
  [ "$status" -eq 0 ]

  nak_args="$(cat "$NAK_LOG")"
  [[ "$nak_args" == *"blocked"* ]]
  [[ "$nak_args" == *"SHA leaked"* ]]
}

# ---------------------------------------------------------------------------
# Teams golden payload — rich fixture includes verdict and evidence blocks
# ---------------------------------------------------------------------------

@test "teams adapter: rich validator event AdaptiveCard includes verdict TextBlock" {
  run bash "$ADAPTERS_DIR/teams.sh" "$FIXTURE_RICH"
  [ "$status" -eq 0 ]

  body="$(cat "$CURL_BODY_LOG")"
  payload_text="$(echo "$body" | jq -r 'tostring')"
  # Verdict line should appear somewhere in the card
  [[ "$payload_text" == *"confirmed"* ]]
}

@test "teams adapter: rich validator event AdaptiveCard includes evidence bullets" {
  run bash "$ADAPTERS_DIR/teams.sh" "$FIXTURE_RICH"
  [ "$status" -eq 0 ]

  body="$(cat "$CURL_BODY_LOG")"
  payload_text="$(echo "$body" | jq -r 'tostring')"
  [[ "$payload_text" == *"no duplicate found"* ]]
  [[ "$payload_text" == *"acceptance criteria"* ]]
}

@test "teams adapter: base event without evidence still renders FactSet" {
  run bash "$ADAPTERS_DIR/teams.sh" "$FIXTURE_EVENT"
  [ "$status" -eq 0 ]

  body="$(cat "$CURL_BODY_LOG")"
  echo "$body" | jq -e '
    .attachments[0].content.body[] | select(.type == "FactSet")
  ' > /dev/null
}

# ---------------------------------------------------------------------------
# Notification templates: render with and without optional evidence
# ---------------------------------------------------------------------------

@test "notification template: validator.md renders with verdict and evidence" {
  _tmpl="$REPO_ROOT/templates/notifications/validator.md"
  [ -f "$_tmpl" ]

  rendered="$(ROLE="validator" VERDICT="confirmed" \
    SUMMARY="Issue is valid and actionable." \
    EVIDENCE="• no duplicate found
• acceptance criteria are clear" \
    REPO="benmarte/swarm" ISSUE="7" URL="https://github.com/benmarte/swarm/issues/7" \
    python3 -c '
import os, string, sys
with open(sys.argv[1]) as f:
    t = string.Template(f.read())
print(t.safe_substitute(os.environ).strip())
' "$_tmpl")"

  [[ "$rendered" == *"validator"* ]]
  [[ "$rendered" == *"confirmed"* ]]
  [[ "$rendered" == *"no duplicate found"* ]]
  [[ "$rendered" == *"https://github.com/benmarte/swarm/issues/7"* ]]
}

@test "notification template: validator.md renders without evidence (empty EVIDENCE)" {
  _tmpl="$REPO_ROOT/templates/notifications/validator.md"
  [ -f "$_tmpl" ]

  rendered="$(ROLE="validator" VERDICT="confirmed" \
    SUMMARY="Issue is valid and actionable." \
    EVIDENCE="" \
    REPO="benmarte/swarm" ISSUE="7" URL="https://github.com/benmarte/swarm/issues/7" \
    python3 -c '
import os, string, sys
with open(sys.argv[1]) as f:
    t = string.Template(f.read())
print(t.safe_substitute(os.environ).strip())
' "$_tmpl")"

  [[ "$rendered" == *"validator"* ]]
  [[ "$rendered" == *"confirmed"* ]]
  [[ "$rendered" == *"Issue is valid"* ]]
}

@test "notification template: blocked.md renders with human-attention note" {
  _tmpl="$REPO_ROOT/templates/notifications/blocked.md"
  [ -f "$_tmpl" ]

  rendered="$(ROLE="security" VERDICT="blocked" \
    SUMMARY="Secret exposure risk." \
    EVIDENCE="• SHA leaked at line 42" \
    REPO="benmarte/swarm" ISSUE="7" URL="https://github.com/benmarte/swarm/issues/7" \
    python3 -c '
import os, string, sys
with open(sys.argv[1]) as f:
    t = string.Template(f.read())
print(t.safe_substitute(os.environ).strip())
' "$_tmpl")"

  [[ "$rendered" == *"blocked"* ]]
  [[ "$rendered" == *"Human attention"* ]]
  [[ "$rendered" == *"SHA leaked"* ]]
}

@test "notification template: all required notification templates exist" {
  for name in validator developer reviewer security qa docs blocked merged pr-opened issue-closed transition; do
    [ -f "$REPO_ROOT/templates/notifications/${name}.md" ] \
      || { echo "FAIL: missing $name.md" >&2; return 1; }
  done
}

# ---------------------------------------------------------------------------
# notify.sh integration: template rendering sets NOTIFY_TEXT before fan-out
# ---------------------------------------------------------------------------

@test "notify.sh: renders notification template and sets NOTIFY_TEXT for adapters" {
  export EVENT_FILE="$FIXTURE_RICH"
  export ENABLED_SINKS="slack"

  run bash "$NOTIFY_SH"
  [ "$status" -eq 0 ]

  # The rendered body (from validator.md template) should appear in the Slack payload
  body="$(cat "$CURL_BODY_LOG")"
  section_text="$(echo "$body" | jq -r '.blocks[0].text.text')"
  # Template includes role+verdict+summary from the rich fixture
  [[ "$section_text" == *"validator"* ]]
  [[ "$section_text" == *"confirmed"* ]]
}

@test "notify.sh: blocked event template renders with red color in Slack" {
  export EVENT_FILE="$FIXTURE_BLOCKED"
  export ENABLED_SINKS="slack"

  run bash "$NOTIFY_SH"
  [ "$status" -eq 0 ]

  body="$(cat "$CURL_BODY_LOG")"
  echo "$body" | jq -e '.attachments[0].color == "#e74c3c"' > /dev/null
}

@test "notify.sh: merged event template renders with green color in Slack" {
  export EVENT_FILE="$FIXTURE_MERGED"
  export ENABLED_SINKS="slack"

  run bash "$NOTIFY_SH"
  [ "$status" -eq 0 ]

  body="$(cat "$CURL_BODY_LOG")"
  echo "$body" | jq -e '.attachments[0].color == "#2ecc71"' > /dev/null
}
