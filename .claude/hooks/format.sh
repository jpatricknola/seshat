#!/usr/bin/env bash
# PostToolUse hook: mix format any Elixir file Claude just edited or wrote.
# Keeps `mix precommit` from failing on formatting alone.
#
# Receives the tool-call JSON on stdin.
set -euo pipefail

payload=$(cat)
file=$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty')

case "$file" in
  *.ex | *.exs | *.heex) ;;
  *) exit 0 ;;
esac

[ -f "$file" ] || exit 0

mix format "$file" 2>/dev/null || true
