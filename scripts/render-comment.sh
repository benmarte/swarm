#!/usr/bin/env bash
# render-comment.sh — renders a comment template with environment variables.
#
# Uses python3 string.Template so ${VAR} substitution is injection-safe
# (no shell eval — backticks, $(), ${} in values are inert).
#
# Usage:
#   HEADER="..." VERDICT="..." SUMMARY="..." DETAILS="..." PR="..." \
#     bash scripts/render-comment.sh <template-path> <output-path>
#
# Template variables (all optional; unmatched placeholders left as-is):
#   HEADER    — comment header block (role + stage identifier)
#   VERDICT   — agent verdict string (single-line)
#   SUMMARY   — evidence.summary (single-line)
#   DETAILS   — formatted evidence bullets (may be multiline)
#   PR        — PR URL or "PR #N" reference (single-line)
#   NEXT_STEP — what-changed / next-step guidance (single-line)
#
# The output-path MUST be a mktemp-created path — never a path inside the repo tree.
# Callers must create the temp file and clean it up via trap 'rm -f "$body"' EXIT.
set -euo pipefail

TEMPLATE_PATH="${1:?render-comment: template path required (arg 1)}"
OUTPUT_PATH="${2:?render-comment: output path required (arg 2)}"

if [ ! -f "$TEMPLATE_PATH" ]; then
  printf 'render-comment: template not found: %s\n' "$TEMPLATE_PATH" >&2
  exit 1
fi

# Safety: output path must not be inside the repo working tree.
# Using git rev-parse; skip the check when not in a git repo (e.g., isolated test).
if git rev-parse --show-toplevel >/dev/null 2>&1; then
  _repo_root="$(git rev-parse --show-toplevel)"
  case "$OUTPUT_PATH" in
    "$_repo_root"/*)
      printf 'render-comment: output path must not be inside the repo tree: %s\n' "$OUTPUT_PATH" >&2
      exit 1
      ;;
  esac
fi

# python3 string.Template substitution:
#   safe_substitute leaves unmatched ${KEY} placeholders as-is (no KeyError).
#   Single-line fields strip embedded newlines; DETAILS preserves them.
python3 - "$TEMPLATE_PATH" "$OUTPUT_PATH" <<'PYEOF'
import sys, os, string

template_path = sys.argv[1]
output_path   = sys.argv[2]

def single(key, default=""):
    """Single-line field: strip all newlines and carriage returns."""
    return os.environ.get(key, default).replace('\r', '').replace('\n', ' ').strip()

def multi(key, default=""):
    """Multi-line field: strip carriage returns and collapse double-newlines.
    Double-newlines (blank lines) in substituted values are an injection vector —
    they create standalone markdown paragraphs that can forge pipeline headers.
    Callers must pre-sanitize individual values (e.g., via jq gsub) before
    assembling DETAILS; this collapses any residual blank lines as a second layer.
    """
    return os.environ.get(key, default).replace('\r', '').replace('\n\n', '\n')

mapping = {
    "HEADER":    multi("HEADER"),
    "VERDICT":   single("VERDICT"),
    "SUMMARY":   single("SUMMARY"),
    "DETAILS":   multi("DETAILS"),
    "PR":        single("PR"),
    "NEXT_STEP": single("NEXT_STEP"),
}

with open(template_path) as fh:
    tmpl = string.Template(fh.read())

rendered = tmpl.safe_substitute(mapping)

with open(output_path, "w") as fh:
    fh.write(rendered)
PYEOF
