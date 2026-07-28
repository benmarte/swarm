#!/usr/bin/env bash
# adapters/buzz.sh — Buzz (Nostr/NIP-29) notification adapter.
# Reads a canonical swarm event JSON, renders a plain markdown message,
# and publishes a signed kind:9 event tagged ["h", <channel-uuid>] via
# the `nak` CLI.
#
# SPEC §2.3 / §2.6: Buzz is NOT a webhook. It is a Nostr/NIP-29 relay.
# `nak` answers the relay's NIP-42 AUTH challenge automatically with --auth.
# Threading (NIP-10 reply tags) is not used in v1 — root posts only.
#
# Message content (talos-parity):
#   Uses NOTIFY_TEXT if set (pre-rendered by notify.sh with verdict/evidence).
#   Falls back to building the message from raw event JSON fields, including
#   role, verdict, evidence bullets, and all standard fields.
#
# Required env:
#   SWARM_BUZZ_RELAY_URL    — wss:// relay URL for the buzz instance
#   SWARM_BUZZ_PRIVATE_KEY  — hex or nsec Nostr private key for the bot
#   BUZZ_CHANNEL            — NIP-29 channel UUID (from swarm.config.yml)
#
# Optional env:
#   NOTIFY_TEXT — pre-rendered notification text (set by notify.sh template
#                 rendering). When present, used as the message body.
#   NAK_BIN     — path to a pre-installed nak binary; auto-provisioned when absent.
#
# Argument:
#   $1 — path to the canonical event JSON file
set -euo pipefail

EVENT_FILE="${1:?event-file argument is required}"

if [ ! -f "$EVENT_FILE" ]; then
  echo "notify/buzz: ERROR: event file not found: $EVENT_FILE" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Loud failures for every missing dependency (name each)
# ---------------------------------------------------------------------------
if [ -z "${SWARM_BUZZ_RELAY_URL:-}" ]; then
  echo "notify/buzz: ERROR: SWARM_BUZZ_RELAY_URL not set" >&2
  exit 1
fi

if [ -z "${SWARM_BUZZ_PRIVATE_KEY:-}" ]; then
  echo "notify/buzz: ERROR: SWARM_BUZZ_PRIVATE_KEY not set" >&2
  exit 1
fi

if [ -z "${BUZZ_CHANNEL:-}" ]; then
  echo "notify/buzz: ERROR: BUZZ_CHANNEL not set (set notify.buzz_channel in swarm.config.yml)" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# nak auto-provisioner
#
# PINNED RELEASE — v0.20.2 (2025-07-28)
# To upgrade: update NAK_VERSION + all NAK_SHA256_* constants below,
# then regenerate checksums with:
#   for os_arch in linux-amd64 linux-arm64 darwin-amd64 darwin-arm64; do
#     curl -fsSL "https://github.com/fiatjaf/nak/releases/download/v<VER>/nak-v<VER>-${os_arch}" | sha256sum
#   done
# NAK_SHA256_* may be overridden via env vars for test isolation.
# ---------------------------------------------------------------------------
NAK_VERSION="v0.20.2"
NAK_SHA256_linux_amd64="${NAK_SHA256_linux_amd64:-424db88043d26d9c2f1cbd2d9bc06582c39526f91f8e5523590439d4257da087}"
NAK_SHA256_linux_arm64="${NAK_SHA256_linux_arm64:-ea5d5032e56aee8fea3bc90e53e194fee39f93a3979575e9f1f27f4cffa129f5}"
NAK_SHA256_darwin_amd64="${NAK_SHA256_darwin_amd64:-a5685466b6b9f414ec53420ce2fd18f61405a337187bc956ea4b49dd0cd1667a}"
NAK_SHA256_darwin_arm64="${NAK_SHA256_darwin_arm64:-68af2ae0ed28ac806e5d326a8b4f87f4f3998678c227226c584f297bee7ef7eb}"

# _nak_ensure — sets NAK_BIN to a working nak binary.
# If NAK_BIN is already set and executable, uses it.
# If nak is on PATH, uses it and records the path in NAK_BIN.
# Otherwise downloads the pinned release for the current OS/arch,
# verifies the SHA256 checksum, and sets NAK_BIN to the downloaded binary.
# Exits 1 (loud) on any download or checksum failure.
_nak_ensure() {
  # 1. Caller-supplied override wins
  if [ -n "${NAK_BIN:-}" ]; then
    if command -v "$NAK_BIN" >/dev/null 2>&1 || [ -x "$NAK_BIN" ]; then
      return 0
    fi
    echo "notify/buzz: ERROR: NAK_BIN='$NAK_BIN' is not executable" >&2
    exit 1
  fi

  # 2. nak already on PATH — record it for explicitness and return
  if command -v nak >/dev/null 2>&1; then
    NAK_BIN="$(command -v nak)"
    echo "notify/buzz: using nak from PATH: $NAK_BIN"
    return 0
  fi

  # 3. Auto-provision: detect OS / arch
  _os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  _machine="$(uname -m)"
  case "$_machine" in
    x86_64)  _arch="amd64" ;;
    aarch64|arm64) _arch="arm64" ;;
    *)
      echo "notify/buzz: ERROR: unsupported machine architecture '$_machine' — install nak manually" >&2
      exit 1
      ;;
  esac

  case "$_os" in
    linux|darwin) ;;
    *)
      echo "notify/buzz: ERROR: unsupported OS '$_os' — install nak manually" >&2
      exit 1
      ;;
  esac

  _key="${_os}_${_arch}"
  # Resolve the expected checksum by indirect reference (portable bash 3.2+)
  eval "_expected_sha=\"\${NAK_SHA256_${_key}:-}\""
  if [ -z "$_expected_sha" ]; then
    echo "notify/buzz: ERROR: no pinned SHA256 for ${_key} — install nak manually" >&2
    exit 1
  fi

  _asset_name="nak-${NAK_VERSION}-${_os}-${_arch}"
  _download_url="https://github.com/fiatjaf/nak/releases/download/${NAK_VERSION}/${_asset_name}"
  _tmp_dir="${RUNNER_TEMP:-$(mktemp -d)}"
  _tmp_bin="${_tmp_dir}/nak"

  echo "notify/buzz: nak not found — downloading ${NAK_VERSION} for ${_os}/${_arch}"
  if ! curl -fsSL "$_download_url" -o "$_tmp_bin"; then
    echo "notify/buzz: ERROR: failed to download nak from $_download_url" >&2
    exit 1
  fi

  # Verify SHA256 checksum (supports both sha256sum and shasum -a 256)
  if command -v sha256sum >/dev/null 2>&1; then
    _got_sha="$(sha256sum "$_tmp_bin" | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    _got_sha="$(shasum -a 256 "$_tmp_bin" | awk '{print $1}')"
  else
    echo "notify/buzz: ERROR: neither sha256sum nor shasum available — cannot verify nak checksum" >&2
    rm -f "$_tmp_bin"
    exit 1
  fi

  if [ "$_got_sha" != "$_expected_sha" ]; then
    echo "notify/buzz: ERROR: nak checksum mismatch for ${_asset_name}" >&2
    echo "  expected: $_expected_sha" >&2
    echo "  got:      $_got_sha" >&2
    echo "  Refusing to execute an unverified binary." >&2
    rm -f "$_tmp_bin"
    exit 1
  fi

  chmod +x "$_tmp_bin"
  NAK_BIN="$_tmp_bin"
  echo "notify/buzz: nak provisioned and verified at $NAK_BIN"
}

_nak_ensure

# ---------------------------------------------------------------------------
# Build plain markdown message: use NOTIFY_TEXT when available (preferred),
# else build from raw event fields including optional role/verdict/evidence.
# ---------------------------------------------------------------------------
_notify_text="${NOTIFY_TEXT:-}"
if [ -n "$_notify_text" ]; then
  TEXT="$_notify_text"
else
  TEXT=$(jq -r \
    '"**swarm: " + .event + "**\n" +
     "**Repo:** " + .repo + " · " +
     "**Issue:** #" + (.issue | tostring) +
     (if .pr != null then " · **PR:** #" + (.pr | tostring) else "" end) + "\n" +
     (if .role then "**Role:** " + .role + (if .verdict then " | **Verdict:** " + .verdict else "" end) + "\n" else "" end) +
     "**Stage:** `" + .stage_from + "` -> `" + .stage_to + "`\n" +
     "**Actor:** " + .actor + "\n" +
     (if (.evidence // [] | length) > 0 then (.evidence | map("• " + (. | gsub("[\\n\\r]+"; " "))) | join("\n")) + "\n" else "" end) +
     .summary + "\n" +
     .url' \
    "$EVENT_FILE")
fi

# ---------------------------------------------------------------------------
# Publish kind:9 event to the buzz relay (root post, no threading in v1)
# ---------------------------------------------------------------------------
echo "notify/buzz: publishing kind:9 event to relay $SWARM_BUZZ_RELAY_URL"
if ! "$NAK_BIN" event --auth \
    --sec "$SWARM_BUZZ_PRIVATE_KEY" \
    -k 9 \
    -c "$TEXT" \
    -t "h=$BUZZ_CHANNEL" \
    "$SWARM_BUZZ_RELAY_URL"; then
  echo "notify/buzz: ERROR: nak failed to publish event" >&2
  exit 1
fi

echo "notify/buzz: delivered"
