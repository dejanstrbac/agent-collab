#!/usr/bin/env bash
# collab-watch.sh <slug> <role> [--once | --wait [seconds]] [--consumer <name>]
# One reader per cursor. Independent consumers receive independent copies.
set -euo pipefail
export LC_ALL=C

usage() { echo "usage: $0 <slug> <role> [--once | --wait [seconds]] [--consumer <name>]" >&2; exit 2; }
[ $# -ge 2 ] || usage
slug=$1; role=$2; shift 2
[[ $slug =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "invalid session slug" >&2; exit 2; }
[[ $role =~ ^[a-z][a-z0-9_-]*$ ]] || { echo "invalid role" >&2; exit 2; }
mode=continuous
mode_set=0
wait_timeout=30
consumer=""

while [ $# -gt 0 ]; do
  case $1 in
    --once)
      [ "$mode_set" -eq 0 ] || usage
      mode=once; mode_set=1; shift
      ;;
    --wait)
      [ "$mode_set" -eq 0 ] || usage
      mode=wait; mode_set=1; shift
      if [ $# -gt 0 ] && [[ $1 =~ ^[0-9]+$ ]]; then wait_timeout=$1; shift; fi
      ;;
    --consumer)
      [ $# -ge 2 ] && [ -z "$consumer" ] || usage
      consumer=$2; shift 2
      [[ $consumer =~ ^[a-z0-9][a-z0-9_-]*$ ]] || { echo "invalid consumer name" >&2; exit 2; }
      ;;
    *) usage ;;
  esac
done
[[ $wait_timeout =~ ^[0-9]+$ ]] && [ "${#wait_timeout}" -le 6 ] || usage
wait_timeout=$((10#$wait_timeout))
[ "$wait_timeout" -le 86400 ] || { echo "wait timeout must be 0 through 86400 seconds" >&2; exit 2; }

kit=$(cd "$(dirname "$0")" && pwd)
session="$kit/sessions/$slug"
log="$session/chat.log"
cursor="$session/.cursor-$role"
[ -z "$consumer" ] || cursor="$cursor.consumer-$consumer"
[ -f "$log" ] || { echo "no session $slug (run collab-init.sh first)" >&2; exit 1; }

lock="$cursor.lock"
locked=0
owner=""
tmp=""
cleanup() {
  local result=$?
  trap - EXIT
  [ -z "$tmp" ] || rm -f "$tmp" || true
  if [ "$locked" -eq 1 ] && [ -n "$owner" ] && [ -f "$owner" ]; then
    if rm -f "$owner"; then
      rmdir "$lock" 2>/dev/null || { echo "watch lock cleanup incomplete: $lock; inspect before recovery" >&2 || true; }
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
    echo "watch cursor lock timed out: $lock; inspect owner.* for its PID and confirm the holder stopped before recovery; --consumer replays history" >&2
    exit 1
  fi
  sleep 1
done
locked=1
owner=$(mktemp "$lock/owner.XXXXXX")
printf 'pid=%s\n' "$$" > "$owner"

seen=0
if [ -e "$cursor" ] && [ ! -f "$cursor" ]; then
  echo "cursor is not a regular file: $cursor" >&2; exit 1
fi
if [ -f "$cursor" ]; then
  seen=$(cat "$cursor")
  [[ $seen =~ ^[0-9]+$ ]] && [ "${#seen}" -le 12 ] || {
    echo "invalid cursor: $cursor; inspect it before resetting" >&2; exit 1;
  }
  seen=$((10#$seen))
fi

read_new() {
  local now lines found=0 reset=0
  if ! now=$(wc -l < "$log"); then
    echo "cannot count log: $log; cursor left unchanged" >&2; return 2
  fi
  now=${now//[[:space:]]/}
  [[ $now =~ ^[0-9]+$ ]] && [ "${#now}" -le 12 ] || {
    echo "invalid log line count; cursor left unchanged" >&2; return 2;
  }
  # A shortened replacement log has new history, not an already-read prefix.
  if [ "$now" -lt "$seen" ]; then seen=0; reset=1; fi
  if [ "$now" -gt "$seen" ]; then
    if ! lines=$(awk -v first="$((seen + 1))" -v last="$now" -v own="$role" '
      NR >= first && NR <= last && index($0, "[" own "] ") != 1 { print }
    ' "$log"); then
      echo "cannot read log: $log; cursor left unchanged" >&2; return 2
    fi
    if [ -n "$lines" ]; then
      if ! printf '%s\n' "$lines"; then
        echo "cannot deliver log output; cursor left unchanged" >&2; return 2
      fi
      found=1
    fi
  fi
  if [ "$now" -ne "$seen" ] || [ "$reset" -eq 1 ] || [ ! -f "$cursor" ]; then
    if ! tmp=$(mktemp "$session/.cursor.XXXXXX"); then
      echo "cannot create cursor temporary file; cursor left unchanged" >&2; return 2
    fi
    if ! printf '%s\n' "$now" > "$tmp" || ! mv "$tmp" "$cursor"; then
      echo "cannot persist cursor: $cursor; previous cursor retained" >&2; return 2
    fi
    tmp=""
  fi
  seen=$now
  [ "$found" -eq 1 ]
}

case $mode in
  once)
    if read_new; then :; else result=$?; [ "$result" -eq 1 ] || exit "$result"; fi
    ;;
  wait)
    start_time=$(date +%s)
    while true; do
      if read_new; then break; else result=$?; [ "$result" -eq 1 ] || exit "$result"; fi
      [ $(( $(date +%s) - start_time )) -lt "$wait_timeout" ] || break
      sleep 1
    done
    ;;
  continuous)
    while true; do
      if read_new; then :; else result=$?; [ "$result" -eq 1 ] || exit "$result"; fi
      sleep 2
    done
    ;;
esac
