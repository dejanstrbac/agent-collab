#!/usr/bin/env bash
# Isolated integration checks. Only copied scripts and synthetic sessions are used.
set -euo pipefail

kit=$(cd "$(dirname "$0")/.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/agent-collab-smoke.XXXXXX")
child=""
delegator=""
claimant=""
cleanup() {
  if [ -n "$child" ]; then kill "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; fi
  if [ -n "$delegator" ]; then kill "$delegator" 2>/dev/null || true; wait "$delegator" 2>/dev/null || true; fi
  if [ -n "$claimant" ]; then kill "$claimant" 2>/dev/null || true; wait "$claimant" 2>/dev/null || true; fi
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

"$scratch/collab-say.sh" fixture implementer 2 FYI 'no row needed for an informational post'
"$scratch/collab-say.sh" fixture implementer 1 'DELEGATE(reviewer)' 'scope: code; base: abc1234; RED: 123abcd; done: tests; reviewers: implementer, verifier'
contains "$board" 'delegated to reviewer (awaiting CLAIM)'
cp "$board" "$scratch/pending"
"$scratch/collab-say.sh" fixture verifier 1 CLAIM 'branch: verifier-branch; worktree: /tmp/verifier'
cmp -s "$board" "$scratch/pending" || fail 'wrong role accepted delegation'
"$scratch/collab-say.sh" fixture reviewer 1 CLAIM 'reviewing abc1234'
cmp -s "$board" "$scratch/pending" || fail 'review CLAIM accepted implementation'
"$scratch/collab-say.sh" fixture reviewer 1 CLAIM 'branch: reviewer-branch; worktree: /tmp/reviewer'
contains "$board" 'delegated to reviewer, claimed: branch: reviewer-branch'
cp "$board" "$scratch/claimed"
"$scratch/collab-say.sh" fixture implementer - 'DELEGATE(verifier)' 'session only'
"$scratch/collab-say.sh" fixture verifier - CLAIM 'branch: other; worktree: /tmp/other'
cmp -s "$board" "$scratch/claimed" || fail 'session message changed issue notes'
pass 'pending delegation needs the named role and implementation location; #-, review and other-role claims do not transfer it'

"$scratch/collab-say.sh" fixture implementer 1 'REVIEW-OK(abc1234)' 'independent first review' &
first=$!
"$scratch/collab-say.sh" fixture verifier 1 'REVIEW-OK(abc1234)' 'independent second review' &
second=$!
wait "$first"
wait "$second"
contains "$board" "implementer: $tick""abc1234""$tick OK"
contains "$board" "verifier: $tick""abc1234""$tick OK"
"$scratch/collab-say.sh" fixture verifier 1 'REVIEW-CHANGES(123abcd)' 'new hash needs changes'
contains "$board" "implementer: $tick""abc1234""$tick OK"
contains "$board" "verifier: $tick""123abcd""$tick CHANGES"
if grep -F "verifier: $tick""abc1234""$tick OK" "$board" >/dev/null; then fail 'old verifier verdict was not replaced'; fi
contains "$board" "reviewer: $tick""abc1234""$tick CHANGES"
pass 'concurrent independent reviews persist; per-role replacement preserves other roles and differing hashes'

"$scratch/collab-board.sh" fixture update 1 review "$tick""abc1234""$tick OK"
"$scratch/collab-say.sh" fixture verifier 1 'REVIEW-OK(123abcd)' 'new role on legacy row'
contains "$board" "legacy: $tick""abc1234""$tick OK"
contains "$board" "verifier: $tick""123abcd""$tick OK"
pass 'legacy unlabelled review remains visible when a second role posts'

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
mkdir "$session/.say.lock"
cp "$log" "$scratch/log-before-lock"
expect_exit 1 env COLLAB_LOCK_TIMEOUT_SECONDS=0 "$scratch/collab-say.sh" fixture reviewer - FYI locked
contains "$scratch/command.err" 'message lock timed out'
cmp -s "$log" "$scratch/log-before-lock" || fail 'message lock timeout appended a message'
[ -d "$session/.say.lock" ] || fail 'message writer removed another lock'
rmdir "$session/.say.lock"
pass 'writer lock timeout is visible and leaves another lock intact'

# Pause delegation projection after its log append, then answer that visible post.
mv "$scratch/collab-board.sh" "$scratch/board-real.sh"
cat > "$scratch/collab-board.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
kit=$(cd "$(dirname "$0")" && pwd)
if [ "$2" = delegate ]; then
  touch "$kit/projection-paused"
  attempts=0
  until [ -f "$kit/release-projection" ]; do
    attempts=$((attempts+1))
    [ "$attempts" -lt 8 ] || exit 1
    sleep 1
  done
fi
exec "$kit/board-real.sh" "$@"
EOF
chmod +x "$scratch/collab-board.sh"
"$scratch/collab-say.sh" fixture implementer 1 'DELEGATE(verifier)' 'delayed projection' &
delegator=$!
attempt=0
until [ -f "$scratch/projection-paused" ]; do
  attempt=$((attempt+1)); [ "$attempt" -lt 5 ] || fail 'projection was not paused'; sleep 1
done
contains "$log" 'DELEGATE(verifier) delayed projection'
mkdir "$scratch/claim-bin"
cat > "$scratch/claim-bin/mkdir" <<'EOF'
#!/usr/bin/env bash
case "$*" in *.say.lock) touch "$COLLAB_TEST_CLAIM_ATTEMPT" ;; esac
exec /bin/mkdir "$@"
EOF
chmod +x "$scratch/claim-bin/mkdir"
env PATH="$scratch/claim-bin:$PATH" COLLAB_TEST_CLAIM_ATTEMPT="$scratch/claim-attempted" \
  "$scratch/collab-say.sh" fixture verifier 1 CLAIM 'branch: verifier-race; worktree: /tmp/verifier-race' &
claimant=$!
attempt=0
until [ -f "$scratch/claim-attempted" ]; do
  attempt=$((attempt+1)); [ "$attempt" -lt 5 ] || fail 'CLAIM never attempted the held message lock'; sleep 1
done
touch "$scratch/release-projection"
wait "$delegator"; delegator=""
wait "$claimant"; claimant=""
contains "$board" 'delegated to verifier, claimed: branch: verifier-race'
mv "$scratch/board-real.sh" "$scratch/collab-board.sh"
pass 'reply to an appended delegation cannot overtake its delayed board projection'

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

: > "$log"
"$scratch/collab-watch.sh" fixture reviewer --once > "$scratch/empty-reset"
[ "$(cat "$session/.cursor-reviewer")" -eq 0 ] || fail 'empty reset did not persist zero'
printf '[implementer] #- FYI after empty reset\n' > "$log"
"$scratch/collab-watch.sh" fixture reviewer --once > "$scratch/empty-reset-after"
contains "$scratch/empty-reset-after" 'after empty reset'
pass 'empty log reset persists zero and later messages remain readable'

# Inject command failures rather than relying on filesystem permissions.
mkdir "$scratch/fail-bin"
printf '[implementer] #- FYI unread after failure\n' >> "$log"
cp "$session/.cursor-reviewer" "$scratch/cursor-before"
cat > "$scratch/fail-bin/awk" <<'EOF'
#!/usr/bin/env bash
echo 'injected log read failure' >&2
exit 1
EOF
chmod +x "$scratch/fail-bin/awk"
for mode in --once --wait continuous; do
  if [ "$mode" = continuous ]; then
    expect_exit 2 env PATH="$scratch/fail-bin:$PATH" "$scratch/collab-watch.sh" fixture reviewer
  elif [ "$mode" = --wait ]; then
    expect_exit 2 env PATH="$scratch/fail-bin:$PATH" "$scratch/collab-watch.sh" fixture reviewer --wait 0
  else
    expect_exit 2 env PATH="$scratch/fail-bin:$PATH" "$scratch/collab-watch.sh" fixture reviewer --once
  fi
  contains "$scratch/command.err" 'cannot read log'
  cmp -s "$session/.cursor-reviewer" "$scratch/cursor-before" || fail 'failed log read advanced cursor'
done
rm "$scratch/fail-bin/awk"
cat > "$scratch/fail-bin/mv" <<'EOF'
#!/usr/bin/env bash
echo 'injected cursor persist failure' >&2
exit 1
EOF
chmod +x "$scratch/fail-bin/mv"
for mode in --once --wait continuous; do
  if [ "$mode" = continuous ]; then
    expect_exit 2 env PATH="$scratch/fail-bin:$PATH" "$scratch/collab-watch.sh" fixture reviewer
  elif [ "$mode" = --wait ]; then
    expect_exit 2 env PATH="$scratch/fail-bin:$PATH" "$scratch/collab-watch.sh" fixture reviewer --wait 0
  else
    expect_exit 2 env PATH="$scratch/fail-bin:$PATH" "$scratch/collab-watch.sh" fixture reviewer --once
  fi
  contains "$scratch/command.err" 'cannot persist cursor'
  cmp -s "$session/.cursor-reviewer" "$scratch/cursor-before" || fail 'failed write advanced cursor'
done
rm "$scratch/fail-bin/mv"
cat > "$scratch/fail-bin/mktemp" <<'EOF'
#!/usr/bin/env bash
echo 'injected cursor temporary-file failure' >&2
exit 1
EOF
chmod +x "$scratch/fail-bin/mktemp"
expect_exit 2 env PATH="$scratch/fail-bin:$PATH" "$scratch/collab-watch.sh" fixture reviewer --once
contains "$scratch/command.err" 'cannot create cursor temporary file'
cmp -s "$session/.cursor-reviewer" "$scratch/cursor-before" || fail 'failed temp creation advanced cursor'
rm "$scratch/fail-bin/mktemp"
"$scratch/collab-watch.sh" fixture reviewer --once > "$scratch/retry-after-failure"
contains "$scratch/retry-after-failure" 'unread after failure'
pass 'read failures are fatal in all modes; cursor-write failure preserves unread messages for retry'

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
