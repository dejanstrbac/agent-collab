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

extract_hash() {
  local str="$1"
  local h
  # Check for parentheses: (abc1234)
  h=$(echo "$str" | sed -n 's/.*(\([0-9a-fA-F]\{7,40\}\)).*/\1/p')
  if [ -n "$h" ]; then echo "$h"; return 0; fi
  # Check for standalone 7-40 hex string
  h=$(echo "$str" | grep -oE '\b[0-9a-fA-F]{7,40}\b' | head -n1 || true)
  if [ -n "$h" ]; then echo "$h"; return 0; fi
  return 1
}

# Auto-update board.md when status reports a test, fix, review, or deferral result
clean_item="${item#\#}"
if [ "$clean_item" != "-" ] && [ -x "$kit/collab-board.sh" ] && [ -f "$kit/sessions/$slug/board.md" ]; then
  case "$status" in
    RED* )
      hash=$(extract_hash "$status" || extract_hash "$text" || true)
      [ -n "$hash" ] && "$kit/collab-board.sh" "$slug" update "$clean_item" test "\`$hash\`" 2>/dev/null || true
      ;;
    GREEN* )
      hash=$(extract_hash "$status" || extract_hash "$text" || true)
      [ -n "$hash" ] && "$kit/collab-board.sh" "$slug" update "$clean_item" fix "\`$hash\`" 2>/dev/null || true
      ;;
    REVIEW-OK* )
      hash=$(extract_hash "$status" || extract_hash "$text" || true)
      if [ -n "$hash" ]; then
        "$kit/collab-board.sh" "$slug" update "$clean_item" review "\`$hash\` OK" 2>/dev/null || true
      else
        "$kit/collab-board.sh" "$slug" update "$clean_item" review "OK" 2>/dev/null || true
      fi
      ;;
    REVIEW-CHANGES* )
      hash=$(extract_hash "$status" || extract_hash "$text" || true)
      if [ -n "$hash" ]; then
        "$kit/collab-board.sh" "$slug" update "$clean_item" review "\`$hash\` CHANGES" 2>/dev/null || true
      else
        "$kit/collab-board.sh" "$slug" update "$clean_item" review "CHANGES" 2>/dev/null || true
      fi
      ;;
    DELEGATE* )
      # The board shows who owns a delegated item: offered here, claimed below.
      to=$(echo "$status" | sed -n 's/.*(\(.*\)).*/\1/p')
      [ -n "$to" ] && "$kit/collab-board.sh" "$slug" update "$clean_item" notes "delegated to $to (awaiting CLAIM)" 2>/dev/null || true
      ;;
    CLAIM )
      # Only the delegate's own CLAIM accepts a delegation; a CLAIM of files or of a review
      # leaves the notes alone.
      row=$("$kit/collab-board.sh" "$slug" get "$clean_item" 2>/dev/null || true)
      case "$row" in
        *"delegated to $role (awaiting CLAIM)"*)
          where=$(printf '%s' "$text" | tr '|' '/' | cut -c1-120)
          "$kit/collab-board.sh" "$slug" update "$clean_item" notes "delegated to $role, claimed${where:+: $where}" 2>/dev/null || true
          ;;
      esac
      ;;
    DEFERRED*|DEFER )
      reason=$(echo "$status" | sed -n 's/.*(\(.*\)).*/\1/p')
      [ -z "$reason" ] && reason="$text"
      [ -z "$reason" ] && reason="Deferred"
      "$kit/collab-board.sh" "$slug" defer "$clean_item" "$reason" "$role" 2>/dev/null || true
      ;;
  esac
fi
