#!/usr/bin/env bash
# collab-say.sh <slug> <role> <item|-> <STATUS> [text...]
# A logged message is retained if projecting its result onto the board fails.
set -euo pipefail
# Session text is bytes; malformed UTF-8 must not break parsing or logging.
export LC_ALL=C
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

# A peer can observe the append immediately. Serialize append plus projection so
# its reply cannot overtake the board state of the message it answers.
lock="$kit/sessions/$slug/.say.lock"
locked=0
owner=""
cleanup() {
  local result=$?
  trap - EXIT
  if [ "$locked" -eq 1 ] && [ -n "$owner" ] && [ -f "$owner" ]; then
    if rm -f "$owner"; then
      rmdir "$lock" 2>/dev/null || { echo "message lock cleanup incomplete: $lock; inspect before recovery" >&2 || true; }
    fi
  fi
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
timeout=${COLLAB_LOCK_TIMEOUT_SECONDS:-10}
[[ $timeout =~ ^[0-9]+$ ]] && [ "${#timeout}" -le 2 ] || {
  echo "COLLAB_LOCK_TIMEOUT_SECONDS must be 0 through 60" >&2; exit 2;
}
timeout=$((10#$timeout))
[ "$timeout" -le 60 ] || { echo "COLLAB_LOCK_TIMEOUT_SECONDS must be 0 through 60" >&2; exit 2; }
started=$(date +%s)
until mkdir "$lock" 2>/dev/null; do
  if [ $(( $(date +%s) - started )) -ge "$timeout" ]; then
    echo "message lock timed out: $lock; inspect owner.* for its PID and confirm the holder stopped before recovery; no message was appended" >&2
    exit 1
  fi
  sleep 1
done
locked=1
owner=$(mktemp "$lock/owner.XXXXXX")
printf 'pid=%s\n' "$$" > "$owner"

text=""
if [ $# -gt 0 ]; then text=$(printf '%s ' "$@" | tr '\n\r' '  ' | sed 's/ *$//'); fi
if [ -n "$text" ]; then
  printf '[%s] #%s %s %s\n' "$role" "$item" "$status" "$text" >> "$log"
else
  printf '[%s] #%s %s\n' "$role" "$item" "$status" >> "$log"
fi

extract_hash() {
  printf '%s\n' "$1" | awk '
    { gsub(/[^[:alnum:]_]/, " "); for (i=1; i<=NF; i++) if ($i ~ /^[0-9a-fA-F]+$/ && length($i)>=7 && length($i)<=40) { print $i; found=1; exit } }
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
    [ -n "$hash" ] || hash=-
    project review "$item" "$role" "$hash" "$verdict"
    ;;
  DELEGATE\(*)
    [ "$role" = implementer ] || {
      echo "message logged, but only the implementer may offer a delegation" >&2; exit 1;
    }
    to=$(printf '%s\n' "$status" | sed -n 's/^DELEGATE(\([^)]*\))$/\1/p')
    project delegate "$item" "$to"
    ;;
  CLAIM)
    project claim "$item" "$role" "$text"
    ;;
  DEFERRED*|DEFER)
    reason=""
    case $status in *\(*\)) reason=${status#*(}; reason=${reason%)} ;; esac
    [ -n "$reason" ] || reason=$text
    [ -n "$reason" ] || reason=Deferred
    project defer "$item" "$reason" "$role"
    ;;
esac
