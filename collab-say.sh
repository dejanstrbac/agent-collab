#!/usr/bin/env bash
# collab-say.sh <slug> <role> <item> <STATUS> <text...>
#
# Appends one line to sessions/<slug>/chat.log:  [role] #item STATUS text
# Appending (never rewriting) is what lets every watcher see each line exactly once.
# Example: collab-say.sh fts-review verifier 3 'RED(ab12cd3)' "TestX fails: row poisoned"
set -euo pipefail
[ $# -ge 4 ] || { echo "usage: $0 <slug> <role> <item|-> <STATUS> [text...]" >&2; exit 2; }
slug=$1 role=$2 item=$3 status=$4; shift 4
kit=$(cd "$(dirname "$0")" && pwd)
log="$kit/sessions/$slug/chat.log"
[ -f "$log" ] || { echo "no session $slug (run collab-init.sh first)" >&2; exit 1; }

text=""
if [ $# -gt 0 ]; then
  text=$(printf '%s ' "$@" | tr '\n' ' ' | sed 's/ *$//')
fi

if [ -n "$text" ]; then
  printf '[%s] #%s %s %s\n' "$role" "${item#\#}" "$status" "$text" >> "$log"
else
  printf '[%s] #%s %s\n' "$role" "${item#\#}" "$status" >> "$log"
fi

# Auto-update board.md when status reports a test, fix, or review result
clean_item="${item#\#}"
if [ "$clean_item" != "-" ] && [ -x "$kit/collab-board.sh" ] && [ -f "$kit/sessions/$slug/board.md" ]; then
  case "$status" in
    RED\(*)
      hash=$(echo "$status" | sed -n 's/.*(\(.*\)).*/\1/p')
      [ -n "$hash" ] && "$kit/collab-board.sh" "$slug" update "$clean_item" test "\`$hash\`" 2>/dev/null || true
      ;;
    GREEN\(*)
      hash=$(echo "$status" | sed -n 's/.*(\(.*\)).*/\1/p')
      [ -n "$hash" ] && "$kit/collab-board.sh" "$slug" update "$clean_item" fix "\`$hash\`" 2>/dev/null || true
      ;;
    REVIEW-OK\(*)
      hash=$(echo "$status" | sed -n 's/.*(\(.*\)).*/\1/p')
      [ -n "$hash" ] && "$kit/collab-board.sh" "$slug" update "$clean_item" review "\`$hash\` OK" 2>/dev/null || true
      ;;
    REVIEW-CHANGES\(*)
      hash=$(echo "$status" | sed -n 's/.*(\(.*\)).*/\1/p')
      [ -n "$hash" ] && "$kit/collab-board.sh" "$slug" update "$clean_item" review "\`$hash\` CHANGES" 2>/dev/null || true
      ;;
    REVIEW-OK)
      "$kit/collab-board.sh" "$slug" update "$clean_item" review "OK" 2>/dev/null || true
      ;;
  esac
fi
