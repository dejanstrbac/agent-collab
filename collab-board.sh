#!/usr/bin/env bash
# collab-board.sh <slug> <add|update|defer|get> [args...]
# Mutations serialize their whole read/modify/rename transaction.
set -euo pipefail

usage() {
  cat <<'EOF' >&2
usage: collab-board.sh <slug> add <item> <severity> <scenario...>
       collab-board.sh <slug> update <item> <test|fix|review|notes> <value...>
       collab-board.sh <slug> defer <item> <reason> <agreed_by>
       collab-board.sh <slug> get <item>
EOF
  exit 2
}

[ $# -ge 2 ] || usage
slug=$1; action=$2; shift 2
[[ $slug =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "invalid session slug" >&2; exit 2; }
case $action in
  add|update|defer) [ $# -ge 3 ] || usage ;;
  get) [ $# -eq 1 ] || usage ;;
  *) usage ;;
esac
item=$1; shift
[[ $item =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || { echo "invalid item ID" >&2; exit 2; }

kit=$(cd "$(dirname "$0")" && pwd)
session="$kit/sessions/$slug"
board="$session/board.md"
[ -f "$board" ] || { echo "no board for session $slug (run collab-init.sh first)" >&2; exit 1; }

# Keep cells single-line and prevent embedded pipes from changing table columns.
cell() { printf '%s' "$1" | tr '\n\r' '  ' | sed 's/|/\&#124;/g'; }

# Only table rows in Issues or Deferred are IDs; Resources and headings are not.
count_item() {
  awk -F'|' -v it="$item" -v target="$1" '
    /^## Issues([[:space:]]|$)/ { section="issues"; next }
    /^## Deferred([[:space:]]|$)/ { section="deferred"; next }
    /^## / { section=""; next }
    /^\|/ && (target == "all" || section == target) && (section == "issues" || section == "deferred") {
      clean=$2; gsub(/^[ \t]+|[ \t]+$/, "", clean)
      if (clean == it) count++
    }
    END { print count+0 }
  ' "$board"
}

require_item() {
  local count
  count=$(count_item "$1")
  [ "$count" -eq 1 ] || {
    if [ "$count" -eq 0 ]; then echo "item $item not found in $1 table" >&2
    else echo "item $item is ambiguous in $1 table" >&2; fi
    exit 1
  }
}

lock="$session/.board.lock"
locked=0
tmp=""
cleanup() {
  [ -z "$tmp" ] || rm -f "$tmp"
  if [ "$locked" -eq 1 ]; then rmdir "$lock"; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [ "$action" != get ]; then
  timeout=${COLLAB_LOCK_TIMEOUT_SECONDS:-10}
  [[ $timeout =~ ^[0-9]+$ ]] && [ "${#timeout}" -le 2 ] || {
    echo "COLLAB_LOCK_TIMEOUT_SECONDS must be 0 through 60" >&2; exit 2;
  }
  timeout=$((10#$timeout))
  [ "$timeout" -le 60 ] || { echo "COLLAB_LOCK_TIMEOUT_SECONDS must be 0 through 60" >&2; exit 2; }
  started=$(date +%s)
  until mkdir "$lock" 2>/dev/null; do
    if [ $(( $(date +%s) - started )) -ge "$timeout" ]; then
      echo "board lock timed out: $lock; another writer's lock was left intact" >&2
      exit 1
    fi
    sleep 1
  done
  locked=1
  tmp=$(mktemp "$session/.board.XXXXXX")
fi

case $action in
  add)
    [ "$(count_item all)" -eq 0 ] || { echo "item $item already exists on board" >&2; exit 1; }
    awk '/^## Issues([[:space:]]|$)/ { found=1 } END { exit !found }' "$board" || {
      echo "board has no Issues section" >&2; exit 1;
    }
    severity=$(cell "$1"); shift
    scenario=$(cell "$*")
    COLLAB_BOARD_VALUE="| $item | $severity | $scenario | | | | |" awk '
      /^## Issues([[:space:]]|$)/ { in_issues=1; print; next }
      /^## / && in_issues { print ENVIRON["COLLAB_BOARD_VALUE"] "\n"; inserted=1; in_issues=0 }
      { print }
      END { if (!inserted) print ENVIRON["COLLAB_BOARD_VALUE"] }
    ' "$board" > "$tmp"
    ;;
  update)
    require_item issues
    field=$1; shift
    case $field in
      test) col=5 ;; fix) col=6 ;; review) col=7 ;; notes) col=8 ;;
      *) echo "unknown field: $field (must be test, fix, review, or notes)" >&2; exit 2 ;;
    esac
    val=$(cell "$*")
    COLLAB_BOARD_VALUE=" $val " awk -F'|' -v OFS='|' -v it="$item" -v c="$col" '
      /^## Issues([[:space:]]|$)/ { in_issues=1 }
      /^## / && !/^## Issues([[:space:]]|$)/ { in_issues=0 }
      {
        clean=$2; gsub(/^[ \t]+|[ \t]+$/, "", clean)
        if (in_issues && /^\|/ && clean == it) $c=ENVIRON["COLLAB_BOARD_VALUE"]
        print
      }
    ' "$board" > "$tmp"
    ;;
  defer)
    require_item issues
    [ "$(count_item all)" -eq 1 ] || { echo "item $item is ambiguous on board" >&2; exit 1; }
    reason=$(cell "$1"); agreed_by=$(cell "$2")
    COLLAB_BOARD_VALUE="| $item | $reason | $agreed_by |" awk -F'|' -v it="$item" '
      /^## Issues([[:space:]]|$)/ { section="issues"; print; next }
      /^## Deferred([[:space:]]|$)/ { section="deferred"; print; next }
      /^## / { section="" }
      section == "issues" && /^\|/ {
        clean=$2; gsub(/^[ \t]+|[ \t]+$/, "", clean)
        if (clean == it) next
      }
      section == "deferred" && /^\|[[:space:]]*-/ && !added {
        print; print ENVIRON["COLLAB_BOARD_VALUE"]; added=1; next
      }
      { print }
      END {
        if (!added) {
          print "\n## Deferred\n\n| # | Reason | Agreed by |\n|---|---|---|"
          print ENVIRON["COLLAB_BOARD_VALUE"]
        }
      }
    ' "$board" > "$tmp"
    ;;
  get)
    require_item all
    awk -F'|' -v it="$item" '
      /^## Issues([[:space:]]|$)/ { section="issues"; next }
      /^## Deferred([[:space:]]|$)/ { section="deferred"; next }
      /^## / { section=""; next }
      /^\|/ && (section == "issues" || section == "deferred") {
        clean=$2; gsub(/^[ \t]+|[ \t]+$/, "", clean)
        if (clean == it) print
      }
    ' "$board"
    exit 0
    ;;
esac

mv "$tmp" "$board"
tmp=""
