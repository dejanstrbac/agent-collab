#!/usr/bin/env bash
# collab-board.sh <slug> <add|update|review|delegate|claim|defer|get> [args...]
# Mutations serialize their whole read/modify/rename transaction.
set -euo pipefail
# Session cells are bytes, including text copied from non-UTF-8 peers.
export LC_ALL=C

usage() {
  cat <<'EOF' >&2
usage: collab-board.sh <slug> add <item> <severity> <scenario...>
       collab-board.sh <slug> update <item> <test|fix|review|notes> <value...>
       collab-board.sh <slug> review <item> <role> <hash|-> <OK|CHANGES>
       collab-board.sh <slug> delegate <item> <role>
       collab-board.sh <slug> claim <item> <role> <location...>
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
  review) [ $# -eq 4 ] || usage ;;
  delegate) [ $# -eq 2 ] || usage ;;
  claim) [ $# -ge 3 ] || usage ;;
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
  local count
  if ! count=$(awk -F'|' -v it="$item" -v target="$1" '
    /^## Issues([[:space:]]|$)/ { section="issues"; next }
    /^## Deferred([[:space:]]|$)/ { section="deferred"; next }
    /^## / { section=""; next }
    /^\|/ && (target == "all" || section == target) && (section == "issues" || section == "deferred") {
      clean=$2; gsub(/^[ \t]+|[ \t]+$/, "", clean)
      if (clean == it) count++
    }
    END { print count+0 }
  ' "$board"); then
    echo "cannot read board: $board" >&2; return 1
  fi
  [[ $count =~ ^[0-9]+$ ]] || { echo "invalid board item count: $board" >&2; return 1; }
  printf '%s\n' "$count"
}

require_item() {
  local count
  count=$(count_item "$1") || exit 1
  [ "$count" -eq 1 ] || {
    if [ "$count" -eq 0 ]; then echo "item $item not found in $1 table" >&2
    else echo "item $item is ambiguous in $1 table" >&2; fi
    exit 1
  }
}

lock="$session/.board.lock"
locked=0
owner=""
tmp=""
cleanup() {
  local result=$?
  trap - EXIT
  [ -z "$tmp" ] || rm -f "$tmp" || true
  if [ "$locked" -eq 1 ] && [ -n "$owner" ] && [ -f "$owner" ]; then
    if rm -f "$owner"; then
      rmdir "$lock" 2>/dev/null || { echo "board lock cleanup incomplete: $lock; inspect before recovery" >&2 || true; }
    fi
  fi
  exit "$result"
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
      echo "board lock timed out: $lock; inspect owner.* for its PID and confirm the holder stopped before recovery" >&2
      exit 1
    fi
    sleep 1
  done
  locked=1
  owner=$(mktemp "$lock/owner.XXXXXX")
  printf 'pid=%s\n' "$$" > "$owner"
  tmp=$(mktemp "$session/.board.XXXXXX")
fi

case $action in
  add)
    count=$(count_item all) || exit 1
    [ "$count" -eq 0 ] || { echo "item $item already exists on board" >&2; exit 1; }
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
  review|delegate|claim)
    role=$1; shift
    [[ $role =~ ^[a-z][a-z0-9_-]*$ ]] || { echo "invalid role" >&2; exit 2; }
    if [ "$action" = claim ]; then
      location=$(cell "$*")
      hint=$(printf '%s' "$location" | tr '[:upper:]' '[:lower:]')
      ordinary_pattern='^[[:space:]]*(files?[:=]|review(ing|[[:space:]:=]|$))'
      acceptance_pattern='(^|[^a-z0-9_])(branch|worktree)([^a-z0-9_]|$)'
      # Ordinary file/review claims are log-only, even before an issue is added.
      [[ $hint =~ $ordinary_pattern ]] && exit 0
      count=$(count_item issues) || exit 1
      if [ "$count" -eq 0 ] && ! [[ $hint =~ $acceptance_pattern ]]; then exit 0; fi
    fi
    require_item issues
    if [ "$action" = review ]; then
      hash=$1; verdict=$2
      [[ $hash == "-" || $hash =~ ^[0-9a-fA-F]{7,40}$ ]] || { echo "invalid review hash" >&2; exit 2; }
      case $verdict in OK|CHANGES) ;; *) echo "invalid review verdict" >&2; exit 2 ;; esac
      tick=$(printf '\140')
      if [ "$hash" = "-" ]; then val="$role: $verdict"; else val="$role: $tick$hash$tick $verdict"; fi
      COLLAB_BOARD_VALUE="$val" awk -F'|' -v OFS='|' -v it="$item" -v who="$role" '
        /^## Issues([[:space:]]|$)/ { in_issues=1 }
        /^## / && !/^## Issues([[:space:]]|$)/ { in_issues=0 }
        {
          clean=$2; gsub(/^[ \t]+|[ \t]+$/, "", clean)
          if (in_issues && /^\|/ && clean == it) {
            result=""; count=split($7, entries, "<br>")
            for (i=1; i<=count; i++) {
              entry=entries[i]; gsub(/^[ \t]+|[ \t]+$/, "", entry)
              if (entry == "") continue
              # Old cells do not identify which role wrote their last verdict.
              if (entry !~ /^[a-z][a-z0-9_-]*: /) entry="legacy: " entry
              if (index(entry, who ": ") == 1) continue
              result=result (result == "" ? "" : "<br>") entry
            }
            result=result (result == "" ? "" : "<br>") ENVIRON["COLLAB_BOARD_VALUE"]
            $7=" " result " "
          }
          print
        }
      ' "$board" > "$tmp"
    else
      if [ "$action" = delegate ]; then val="delegated to $role (awaiting CLAIM)"
      else
        # A review/file CLAIM by the same role does not accept an implementation.
        branch_pattern='(^|[[:space:];,])branch[:=][[:space:]]*[^[:space:];,]+'
        worktree_pattern='(^|[[:space:];,])worktree[:=][[:space:]]*[^[:space:];,]+'
        valid=0
        if [[ $location =~ $branch_pattern ]] && [[ $location =~ $worktree_pattern ]]; then valid=1; fi
        val="delegated to $role, claimed: $location"
      fi
      COLLAB_BOARD_VALUE="$val" awk -F'|' -v OFS='|' -v it="$item" -v who="$role" -v action="$action" -v valid="${valid:-0}" '
        /^## Issues([[:space:]]|$)/ { in_issues=1 }
        /^## / && !/^## Issues([[:space:]]|$)/ { in_issues=0 }
        {
          clean=$2; gsub(/^[ \t]+|[ \t]+$/, "", clean)
          if (in_issues && /^\|/ && clean == it) {
            note=$8; gsub(/^[ \t]+|[ \t]+$/, "", note)
            pending="delegated to " who " (awaiting CLAIM)"
            if (action == "delegate") {
              if (note != "" && note != pending) {
                print "cannot delegate item " it ": Notes are occupied; confirm handback and update Notes explicitly" > "/dev/stderr"
                exit 1
              }
              $8=" " ENVIRON["COLLAB_BOARD_VALUE"] " "
            } else if (note == pending) {
              if (!valid) {
                print "malformed delegation CLAIM: use branch=<branch> worktree=<path> (lowercase keys)" > "/dev/stderr"
                exit 1
              }
              $8=" " ENVIRON["COLLAB_BOARD_VALUE"] " "
            } else if ((index(note, "delegated to " who " (") == 1 || index(note, "delegated to " who ", claimed: ") == 1) && note != ENVIRON["COLLAB_BOARD_VALUE"]) {
              print "cannot accept item " it ": Notes are not the exact pending delegation; inspect before retrying" > "/dev/stderr"
              exit 1
            }
          }
          print
        }
      ' "$board" > "$tmp"
    fi
    ;;
  defer)
    require_item issues
    count=$(count_item all) || exit 1
    [ "$count" -eq 1 ] || { echo "item $item is ambiguous on board" >&2; exit 1; }
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
