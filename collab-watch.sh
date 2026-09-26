#!/usr/bin/env bash
# collab-watch.sh <slug> <role> [--once | --wait [seconds]]
#
# Prints each line appended to sessions/<slug>/chat.log by OTHER roles.
# Tracks position in sessions/<slug>/.cursor-<role> so new agents start from the beginning
# without missing prior messages, and restarts never skip unread lines.
#
# Options:
#   --once: print unread lines and exit immediately (ideal for polling agents).
#   --wait [seconds]: wait up to N seconds (default: 30) for a new message from another role,
#                     print it and exit immediately when one arrives. Ideal for LLM tool calls.
#   (default): stream continuously every 2 seconds.
set -euo pipefail

usage() { echo "usage: $0 <slug> <role> [--once | --wait [seconds]]" >&2; exit 2; }
[ $# -ge 2 ] || usage

slug=$1; role=$2; shift 2
mode="continuous"
wait_timeout=30

while [ $# -gt 0 ]; do
  case "$1" in
    --once)
      mode="once"
      shift
      ;;
    --wait)
      mode="wait"
      shift
      if [ $# -gt 0 ] && [[ "$1" =~ ^[0-9]+$ ]]; then
        wait_timeout=$1
        shift
      fi
      ;;
    *)
      usage
      ;;
  esac
done

kit=$(cd "$(dirname "$0")" && pwd)
session="$kit/sessions/$slug"
log="$session/chat.log"
cursor="$session/.cursor-$role"
[ -f "$log" ] || { echo "no session $slug (run collab-init.sh first)" >&2; exit 1; }

seen=0
if [ -f "$cursor" ]; then
  seen=$(cat "$cursor" 2>/dev/null || echo 0)
fi

read_new() {
  local now
  now=$(wc -l < "$log" | tr -d ' ')
  local found=0
  if [ "$now" -gt "$seen" ]; then
    local lines
    lines=$(sed -n "$((seen + 1)),${now}p" "$log" | grep -v "^\[$role\] " || true)
    if [ -n "$lines" ]; then
      printf '%s\n' "$lines"
      found=1
    fi
    seen=$now
    echo "$seen" > "$cursor"
  elif [ "$now" -lt "$seen" ]; then
    # Log was truncated/reset; reset position
    seen=$now
    echo "$seen" > "$cursor"
  fi
  [ "$found" -eq 1 ] && return 0 || return 1
}

case "$mode" in
  once)
    read_new || true
    exit 0
    ;;
  wait)
    start_time=$(date +%s)
    while true; do
      if read_new; then
        exit 0
      fi
      now_time=$(date +%s)
      if [ $((now_time - start_time)) -ge "$wait_timeout" ]; then
        exit 0
      fi
      sleep 1
    done
    ;;
  continuous)
    read_new || true
    while true; do
      sleep 2
      read_new || true
    done
    ;;
esac
