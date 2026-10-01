#!/usr/bin/env bash
# collab-say.sh <slug> <role> <item|-> <STATUS> [text...]
# A logged message is retained if projecting its result onto the board fails.
set -euo pipefail
[ $# -ge 4 ] || { echo "usage: $0 <slug> <role> <item|-> <STATUS> [text...]" >&2; exit 2; }
slug=$1 role=$2 item=${3#\#} status=$4; shift 4
[[ $slug =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "invalid session slug" >&2; exit 2; }
[[ $role =~ ^[a-z][a-z0-9_-]*$ ]] || { echo "invalid role" >&2; exit 2; }
[[ $item == "-" || $item =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || { echo "invalid item ID" >&2; exit 2; }
[ -n "$status" ] || { echo "status cannot be empty" >&2; exit 2; }
case $status in *$'\n'*|*$'\r'*) echo "status must be one line" >&2; exit 2 ;; esac
kit=$(cd "$(dirname "$0")" && pwd)
log="$kit/sessions/$slug/chat.log"
[ -f "$log" ] || { echo "no session $slug (run collab-init.sh first)" >&2; exit 1; }

text=""
if [ $# -gt 0 ]; then text=$(printf '%s ' "$@" | tr '\n\r' '  ' | sed 's/ *$//'); fi
if [ -n "$text" ]; then
  printf '[%s] #%s %s %s\n' "$role" "$item" "$status" "$text" >> "$log"
else
  printf '[%s] #%s %s\n' "$role" "$item" "$status" >> "$log"
fi

extract_hash() {
  printf '%s\n' "$1" | awk '
    { gsub(/[^0-9a-fA-F]/, " "); for (i=1; i<=NF; i++) if (length($i)>=7 && length($i)<=40) { print $i; found=1; exit } }
    END { if (!found) exit 1 }
  '
}

project() {
  if ! "$kit/collab-board.sh" "$slug" "$@"; then
    echo "message logged, but board update failed for item $item; inspect the error before reposting" >&2
    return 1
  fi
}

[ "$item" != "-" ] || exit 0
tick=$(printf '\140')
case $status in
  RED*|GREEN*)
    hash=$(extract_hash "$status" || extract_hash "$text" || true)
    if [ -n "$hash" ]; then
      if [[ $status == RED* ]]; then field=test; else field=fix; fi
      project update "$item" "$field" "$tick$hash$tick"
    fi
    ;;
  REVIEW-OK*|REVIEW-CHANGES*)
    hash=$(extract_hash "$status" || extract_hash "$text" || true)
    if [[ $status == REVIEW-OK* ]]; then verdict=OK; else verdict=CHANGES; fi
    if [ -n "$hash" ]; then verdict="$tick$hash$tick $verdict"; fi
    project update "$item" review "$verdict"
    ;;
  DEFERRED*|DEFER)
    reason=$(printf '%s\n' "$status" | sed -n 's/.*(\(.*\)).*/\1/p')
    [ -n "$reason" ] || reason=$text
    [ -n "$reason" ] || reason=Deferred
    project defer "$item" "$reason" "$role"
    ;;
esac
