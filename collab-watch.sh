#!/usr/bin/env bash
# collab-watch.sh <slug> <role> [--once | --wait [seconds]] [--consumer <name>]
# One reader per cursor. Independent consumers receive independent copies.
set -euo pipefail

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
tmp=""
cleanup() {
  [ -z "$tmp" ] || rm -f "$tmp"
  if [ "$locked" -eq 1 ]; then rmdir "$lock"; fi
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
    echo "watch cursor lock timed out: $lock; observe the existing reader or use --consumer" >&2
    exit 1
  fi
  sleep 1
done
locked=1

seen=0
if [ -f "$cursor" ]; then
  seen=$(cat "$cursor")
  [[ $seen =~ ^[0-9]+$ ]] && [ "${#seen}" -le 12 ] || {
    echo "invalid cursor: $cursor; inspect it before resetting" >&2; exit 1;
  }
  seen=$((10#$seen))
fi

read_new() {
  local now lines found=0
  now=$(wc -l < "$log" | tr -d ' ')
  # A shortened replacement log has new history, not an already-read prefix.
  if [ "$now" -lt "$seen" ]; then seen=0; fi
  if [ "$now" -gt "$seen" ]; then
    lines=$(sed -n "$((seen + 1)),${now}p" "$log" | grep -v "^\[$role\] " || true)
    if [ -n "$lines" ]; then
      printf '%s\n' "$lines"
      found=1
    fi
  fi
  if [ "$now" -ne "$seen" ] || [ ! -f "$cursor" ]; then
    tmp=$(mktemp "$session/.cursor.XXXXXX")
    printf '%s\n' "$now" > "$tmp"
    mv "$tmp" "$cursor"
    tmp=""
  fi
  seen=$now
  [ "$found" -eq 1 ]
}

case $mode in
  once) read_new || true ;;
  wait)
    start_time=$(date +%s)
    while true; do
      if read_new; then break; fi
      [ $(( $(date +%s) - start_time )) -lt "$wait_timeout" ] || break
      sleep 1
    done
    ;;
  continuous)
    while true; do read_new || true; sleep 2; done
    ;;
esac
