#!/usr/bin/env bash
# collab-board.sh <slug> <action> [args...]
#
# Helpers to read and update sessions/<slug>/board.md safely without manual table editing.
#
# Actions:
#   add <item> <severity> <scenario...>
#       Appends a new issue row to the Issues table.
#
#   update <item> <test|fix|review|notes> <value...>
#       Updates a specific column in the issue row.
#
#   get <item>
#       Prints the row for the given item.
set -euo pipefail

usage() {
  cat <<'EOF' >&2
usage: collab-board.sh <slug> add <item> <severity> <scenario...>
       collab-board.sh <slug> update <item> <test|fix|review|notes> <value...>
       collab-board.sh <slug> get <item>
EOF
  exit 2
}

[ $# -ge 2 ] || usage
slug=$1; action=$2; shift 2

kit=$(cd "$(dirname "$0")" && pwd)
board="$kit/sessions/$slug/board.md"
[ -f "$board" ] || { echo "no board for session $slug (run collab-init.sh first)" >&2; exit 1; }

case $action in
  add)
    [ $# -ge 3 ] || { echo "usage: collab-board.sh <slug> add <item> <severity> <scenario...>" >&2; exit 2; }
    item=$1; severity=$2; shift 2
    scenario="$*"
    # Check if item already exists
    if awk -F'|' -v it="$item" '{ clean=$2; gsub(/^[ \t]+|[ \t]+$/, "", clean); if (clean == it) exit 0; } END { exit 1 }' "$board"; then
      echo "item $item already exists on board" >&2
      exit 1
    fi
    new_row="| $item | $severity | $scenario | | | | |"
    # Insert right before ## Deferred or at end of file
    awk -v row="$new_row" '
      /^## Deferred/ && !inserted { print row "\n"; inserted=1 }
      { print }
      END { if (!inserted) print row }
    ' "$board" > "$board.tmp" && mv "$board.tmp" "$board"
    ;;

  update)
    [ $# -ge 3 ] || { echo "usage: collab-board.sh <slug> update <item> <test|fix|review|notes> <value...>" >&2; exit 2; }
    item=$1; field=$2; shift 2
    val="$*"
    col=0
    case $field in
      test)   col=5 ;;
      fix)    col=6 ;;
      review) col=7 ;;
      notes)  col=8 ;;
      *) echo "unknown field: $field (must be test, fix, review, or notes)" >&2; exit 2 ;;
    esac
    awk -F'|' -v OFS='|' -v it="$item" -v c="$col" -v v=" $val " '
      {
        clean=$2; gsub(/^[ \t]+|[ \t]+$/, "", clean);
        if (clean == it) {
          $c = v;
        }
        print;
      }
    ' "$board" > "$board.tmp" && mv "$board.tmp" "$board"
    ;;

  get)
    [ $# -eq 1 ] || { echo "usage: collab-board.sh <slug> get <item>" >&2; exit 2; }
    item=$1
    awk -F'|' -v it="$item" '
      {
        clean=$2; gsub(/^[ \t]+|[ \t]+$/, "", clean);
        if (clean == it) print;
      }
    ' "$board"
    ;;

  *) usage ;;
esac
