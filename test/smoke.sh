#!/usr/bin/env bash
# Isolated integration checks. Only copied scripts and synthetic sessions are used.
set -euo pipefail

kit=$(cd "$(dirname "$0")/.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/agent-collab-smoke.XXXXXX")
child=""
cleanup() {
  if [ -n "$child" ]; then kill "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; fi
  rm -rf "$scratch"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
for script in collab-board.sh collab-say.sh collab-watch.sh; do
  [ -x "$kit/$script" ] || { echo "not executable: $script" >&2; exit 1; }
  cp "$kit/$script" "$scratch/$script"
done
mkdir -p "$scratch/sessions/fixture"
session="$scratch/sessions/fixture"
board="$session/board.md"
log="$session/chat.log"
cat > "$board" <<'EOF'
# Synthetic fixture

## Resources

| Role | Branch |
|---|---|
| reviewer | branch |

## Issues

| # | Severity | Issue | Test | Fix | Review | Notes |
|---|---|---|---|---|---|---|

## Deferred

| # | Reason | Agreed by |
|---|---|---|
EOF
: > "$log"
checks=0
pass() { checks=$((checks+1)); printf 'ok %s - %s\n' "$checks" "$1"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
contains() { grep -F -- "$2" "$1" >/dev/null || fail "$1 missing $2"; }
expect_exit() {
  local expected=$1 actual
  shift
  if "$@" > "$scratch/command.out" 2> "$scratch/command.err"; then actual=0; else actual=$?; fi
  [ "$actual" -eq "$expected" ] || fail "expected exit $expected, got $actual: $*"
}

"$scratch/collab-board.sh" fixture add 1 P2 'concrete failure'
"$scratch/collab-board.sh" fixture get 1 > "$scratch/row"
contains "$scratch/row" '| 1 | P2 | concrete failure |'
cp "$board" "$scratch/before"
expect_exit 1 "$scratch/collab-board.sh" fixture add 1 P1 duplicate
cmp -s "$board" "$scratch/before" || fail "duplicate changed board"
contains "$scratch/command.err" 'already exists'
pass 'new issue succeeds; duplicate ID fails without changing board'

expect_exit 1 "$scratch/collab-board.sh" fixture update 999 fix deadbee
contains "$scratch/command.err" 'not found'
expect_exit 1 "$scratch/collab-board.sh" fixture get 999
expect_exit 1 "$scratch/collab-board.sh" fixture defer 999 missing reviewer
cmp -s "$board" "$scratch/before" || fail "missing item changed board"
pass 'missing update, get and defer fail'

"$scratch/collab-say.sh" fixture verifier 1 'RED(123abcd)' 'proved on parent'
"$scratch/collab-say.sh" fixture implementer '#1' 'GREEN(abc1234)' fixed
"$scratch/collab-say.sh" fixture reviewer 1 'REVIEW-OK(abc1234)' reviewed
tick=$(printf '\140')
contains "$board" "$tick""123abcd""$tick"
contains "$board" "$tick""abc1234""$tick OK"
"$scratch/collab-say.sh" fixture reviewer 1 'REVIEW-CHANGES(abc1234)' change
contains "$board" "$tick""abc1234""$tick CHANGES"
"$scratch/collab-say.sh" fixture reviewer - BLOCKED 'owner=implementer dependency=repair next=commit'
"$scratch/collab-say.sh" fixture reviewer 1 'REQUEST-DELEGATE(reviewer)' 'bounded request'
contains "$log" '#- BLOCKED owner=implementer'
contains "$log" '#1 REQUEST-DELEGATE(reviewer)'
pass 'successful RED, GREEN, review and dependency messages retain compatibility'

expect_exit 1 "$scratch/collab-say.sh" fixture reviewer 999 'REVIEW-OK(abc1234)' 'missing board row'
contains "$log" '#999 REVIEW-OK(abc1234) missing board row'
contains "$scratch/command.err" 'message logged, but board update failed'
pass 'failed board projection retains chat message and exits visibly'

mkdir "$session/.board.lock"
expect_exit 1 env COLLAB_LOCK_TIMEOUT_SECONDS=0 "$scratch/collab-board.sh" fixture update 1 notes locked
[ -d "$session/.board.lock" ] || fail 'writer removed another lock'
contains "$scratch/command.err" 'lock timed out'
expect_exit 1 env COLLAB_LOCK_TIMEOUT_SECONDS=0 "$scratch/collab-say.sh" fixture reviewer 1 'REVIEW-OK(abc1234)' 'locked board'
contains "$log" 'locked board'
contains "$scratch/command.err" 'message logged, but board update failed'
rmdir "$session/.board.lock"
pass 'writer lock timeout is visible and leaves another lock intact'

pids=()
index=2
while [ "$index" -le 9 ]; do
  "$scratch/collab-board.sh" fixture add "$index" P2 "parallel $index" &
  pids+=("$!")
  index=$((index+1))
done
for pid in "${pids[@]}"; do wait "$pid"; done
index=2
while [ "$index" -le 9 ]; do
  "$scratch/collab-board.sh" fixture get "$index" > "$scratch/row"
  contains "$scratch/row" "parallel $index"
  index=$((index+1))
done
"$scratch/collab-board.sh" fixture update 1 test retained-test &
first=$!
"$scratch/collab-board.sh" fixture update 1 fix retained-fix &
second=$!
wait "$first"
wait "$second"
contains "$board" 'retained-test'
contains "$board" 'retained-fix'
[ ! -d "$session/.board.lock" ] || fail 'writer lock not cleaned'
pass 'concurrent adds and independent column updates all persist'

"$scratch/collab-board.sh" fixture update 1 notes 'literal \n | pipe'
contains "$board" 'literal \n &#124; pipe'
"$scratch/collab-say.sh" fixture reviewer 9 'DEFERRED(agreed reason)' detail
"$scratch/collab-board.sh" fixture get 9 > "$scratch/row"
contains "$scratch/row" '| 9 | agreed reason | reviewer |'
expect_exit 1 "$scratch/collab-board.sh" fixture add 9 P2 reused
expect_exit 1 "$scratch/collab-board.sh" fixture update 9 notes deferred
pass 'cell content preserves literal escapes; agreed deferral preserves unique IDs'

cat > "$log" <<'EOF'
[implementer] #1 GREEN(abc1234) peer message
[reviewer] #1 FYI own message
EOF
"$scratch/collab-watch.sh" fixture reviewer --once > "$scratch/default"
contains "$scratch/default" 'peer message'
if grep -F 'own message' "$scratch/default" >/dev/null; then fail 'own message was emitted'; fi
"$scratch/collab-watch.sh" fixture reviewer --once > "$scratch/default-again"
[ ! -s "$scratch/default-again" ] || fail 'default reader repeated message'
"$scratch/collab-watch.sh" fixture reviewer --consumer audit --once > "$scratch/audit"
cmp -s "$scratch/default" "$scratch/audit" || fail 'independent consumer missed history'
"$scratch/collab-watch.sh" fixture reviewer --once --consumer audit > "$scratch/audit-again"
[ ! -s "$scratch/audit-again" ] || fail 'named reader repeated message'
pass 'default and independent watch consumers each receive peer history once'

"$scratch/collab-watch.sh" fixture verifier --consumer live --once > "$scratch/live-before"
"$scratch/collab-watch.sh" fixture verifier --consumer live --wait 5 > "$scratch/live-after" &
child=$!
attempt=0
while [ ! -d "$session/.cursor-verifier.consumer-live.lock" ]; do
  attempt=$((attempt+1))
  [ "$attempt" -le 4 ] || fail 'watcher did not acquire its cursor'
  sleep 1
done
expect_exit 1 env COLLAB_LOCK_TIMEOUT_SECONDS=0 "$scratch/collab-watch.sh" fixture verifier --consumer live --once
contains "$scratch/command.err" 'watch cursor lock timed out'
[ -d "$session/.cursor-verifier.consumer-live.lock" ] || fail 'competing reader removed live lock'
"$scratch/collab-say.sh" fixture implementer - FYI 'wake live watcher'
wait "$child"
child=""
contains "$scratch/live-after" 'wake live watcher'
[ ! -d "$session/.cursor-verifier.consumer-live.lock" ] || fail 'watcher left cursor locked'
pass 'live reader receives appended reply; competing same-consumer reader fails visibly'

"$scratch/collab-watch.sh" fixture verifier --consumer live --wait 0 > "$scratch/timeout"
[ ! -s "$scratch/timeout" ] || fail 'timeout invented a peer message'
pass 'wait timeout exits successfully with no invented peer output'

printf '[implementer] #- FYI replacement history\n' > "$log"
"$scratch/collab-watch.sh" fixture reviewer --once > "$scratch/replacement"
contains "$scratch/replacement" 'replacement history'
[ "$(cat "$session/.cursor-reviewer")" -eq 1 ] || fail 'replacement cursor incorrect'
"$scratch/collab-watch.sh" fixture reviewer --once > "$scratch/replacement-again"
[ ! -s "$scratch/replacement-again" ] || fail 'replacement history repeated'
pass 'shortened replacement log is replayed without skipping messages'

expect_exit 2 "$scratch/collab-watch.sh" '../escape' reviewer --once
expect_exit 2 "$scratch/collab-watch.sh" fixture 'bad[role]' --once
expect_exit 2 "$scratch/collab-watch.sh" fixture reviewer --consumer '../escape' --once
expect_exit 2 "$scratch/collab-watch.sh" fixture reviewer --wait 999999
expect_exit 2 "$scratch/collab-watch.sh" fixture reviewer --once --wait 0
expect_exit 2 "$scratch/collab-say.sh" '../escape' reviewer - FYI invalid
expect_exit 2 "$scratch/collab-board.sh" fixture add '../escape' P2 invalid
printf 'not-a-number\n' > "$session/.cursor-reviewer"
expect_exit 1 "$scratch/collab-watch.sh" fixture reviewer --once
contains "$scratch/command.err" 'invalid cursor'
[ ! -d "$session/.cursor-reviewer.lock" ] || fail 'invalid cursor left lock'
pass 'unsafe input and malformed cursors fail visibly'

printf 'PASS %s isolated smoke cases\n' "$checks"
