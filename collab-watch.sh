#!/usr/bin/env bash
# collab-watch.sh <slug> <role> [--once]
#
# Prints each line appended to sessions/<slug>/chat.log by OTHER roles.
# Tracks position in sessions/<slug>/.cursor-<role> so new agents start from the beginning
# without missing prior messages, and restarts never skip unread lines.
#
# Options:
#   --once: print unread lines and exit immediately (ideal for polling agents).
#   (default): stream continuously every 2 seconds.
set -euo pipefail

usage() { echo "usage: $0 <slug> <role> [--once]" >&2; exit 2; }
[ $# -ge 2 ] || usage

slug=$1 role=$2
once=false
if [ "${3:-}" = "--once" ] || [ "${1:-}" = "--once" ]; then
  once=true
fi
if [ "${1:-}" = "--once" ]; then
  slug=$2 role=$3
fi

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
  if [ "$now" -gt "$seen" ]; then
    sed -n "$((seen + 1)),${now}p" "$log" | grep -v "^\[$role\] " || true
    seen=$now
    echo "$seen" > "$cursor"
  elif [ "$now" -lt "$seen" ]; then
    # Log was truncated/reset; reset position
    seen=$now
    echo "$seen" > "$cursor"
  fi
}

if [ "$once" = true ]; then
  read_new
  exit 0
fi

read_new
while true; do
  sleep 2
  read_new
done
