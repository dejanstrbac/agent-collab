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
cp "$board" "$scratch/request-before"
"$scratch/collab-say.sh" fixture reviewer 1 'REQUEST-DELEGATE(reviewer)' 'bounded request'
cmp -s "$board" "$scratch/request-before" || fail 'delegation request changed board'
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
# The earlier delegate has explicitly handed back in this synthetic fixture.
"$scratch/collab-board.sh" fixture update 1 notes ''
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
attempt=0
owner_files=("$session/.cursor-verifier.consumer-live.lock"/owner.*)
until [ -f "${owner_files[0]}" ]; do
  attempt=$((attempt+1)); [ "$attempt" -le 4 ] || fail 'watcher did not record its owner PID'; sleep 1
  owner_files=("$session/.cursor-verifier.consumer-live.lock"/owner.*)
done
contains "${owner_files[0]}" "pid=$child"
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
case "$*" in
  */.cursor.XXXXXX) echo 'injected cursor temporary-file failure' >&2; exit 1 ;;
  *) exec /usr/bin/mktemp "$@" ;;
esac
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

# Hashes must be complete tokens, not the hexadecimal part of an English word
# or a sample input such as 0xdeadbeef. Exercise the text fallback explicitly.
"$scratch/collab-board.sh" fixture add 20 P2 'hash token boundaries'
"$scratch/collab-say.sh" fixture implementer 20 GREEN 'addressed review feedback in 9f8e7d6a'
"$scratch/collab-board.sh" fixture get 20 > "$scratch/hash-row"
contains "$scratch/hash-row" "$tick""9f8e7d6a""$tick"
if grep -F 'feedbac' "$scratch/hash-row" >/dev/null; then fail 'English word became a fix hash'; fi
"$scratch/collab-say.sh" fixture verifier 20 REVIEW-OK 'checked 0xdeadbeef handling at 9f8e7d6a'
"$scratch/collab-board.sh" fixture get 20 > "$scratch/hash-row"
contains "$scratch/hash-row" "verifier: $tick""9f8e7d6a""$tick OK"
"$scratch/collab-say.sh" fixture reviewer 20 REVIEW-OK 'thanks for the feedback, looks right'
"$scratch/collab-board.sh" fixture get 20 > "$scratch/hash-row"
contains "$scratch/hash-row" 'reviewer: OK'
"$scratch/collab-say.sh" fixture verifier 20 RED 'failure shown by (123abcd), not prefix123abcdsuffix'
"$scratch/collab-board.sh" fixture get 20 > "$scratch/hash-row"
contains "$scratch/hash-row" "$tick""123abcd""$tick"
pass 'text hash fallback respects word boundaries and ignores hexadecimal sample inputs'

"$scratch/collab-board.sh" fixture add 21 P2 'delegation occupancy'
"$scratch/collab-say.sh" fixture implementer 21 'DELEGATE(reviewer)' 'bounded offer'
cp "$board" "$scratch/offer-before"
"$scratch/collab-say.sh" fixture implementer 21 'DELEGATE(reviewer)' 'same pending offer'
cmp -s "$board" "$scratch/offer-before" || fail 'identical pending offer changed board'
"$scratch/collab-say.sh" fixture reviewer 21 CLAIM 'branch=reviewer worktree=/tmp/reviewer'
cp "$board" "$scratch/owner-before"
expect_exit 1 "$scratch/collab-say.sh" fixture verifier 21 'DELEGATE(verifier)' 'self assignment'
cmp -s "$board" "$scratch/owner-before" || fail 'non-implementer delegation changed owner'
contains "$scratch/command.err" 'only the implementer'
expect_exit 1 "$scratch/collab-say.sh" fixture implementer 21 'DELEGATE(verifier)' 'claimed scope'
cmp -s "$board" "$scratch/owner-before" || fail 'claimed owner overwritten by implementer'
expect_exit 1 "$scratch/collab-board.sh" fixture delegate 21 verifier
cmp -s "$board" "$scratch/owner-before" || fail 'low-level delegate overwrote claimed scope'
"$scratch/collab-board.sh" fixture add 22 P2 'free notes'
"$scratch/collab-board.sh" fixture update 22 notes 'repro needs TZ=UTC; see thread'
cp "$board" "$scratch/notes-before"
expect_exit 1 "$scratch/collab-say.sh" fixture implementer 22 'DELEGATE(verifier)' 'free notes'
cmp -s "$board" "$scratch/notes-before" || fail 'delegation erased free Notes'
contains "$scratch/command.err" 'Notes'
pass 'only implementer offers delegations; atomic occupancy guards preserve claimed and free Notes'

"$scratch/collab-board.sh" fixture add 23 P2 'malformed acceptance'
"$scratch/collab-say.sh" fixture implementer 23 'DELEGATE(verifier)' 'bounded offer'
cp "$board" "$scratch/claim-before"
expect_exit 1 "$scratch/collab-say.sh" fixture verifier 23 CLAIM 'Branch:x, Worktree:/tmp/y'
contains "$scratch/command.err" 'branch'
cmp -s "$board" "$scratch/claim-before" || fail 'malformed acceptance changed owner'
expect_exit 1 "$scratch/collab-say.sh" fixture verifier 23 CLAIM 'on branch x in worktree /tmp/y'
cmp -s "$board" "$scratch/claim-before" || fail 'prose acceptance changed owner'
expect_exit 1 "$scratch/collab-say.sh" fixture verifier 23 CLAIM 'I accept this implementation'
cmp -s "$board" "$scratch/claim-before" || fail 'incomplete acceptance changed owner'
"$scratch/collab-say.sh" fixture verifier 23 CLAIM 'reviewing abc1234'
cmp -s "$board" "$scratch/claim-before" || fail 'ordinary review claim accepted scope'
"$scratch/collab-board.sh" fixture update 23 notes 'delegated to verifier (awaiting CLAIM); see file:12'
cp "$board" "$scratch/claim-before"
expect_exit 1 "$scratch/collab-say.sh" fixture verifier 23 CLAIM 'branch=x worktree=/tmp/y'
cmp -s "$board" "$scratch/claim-before" || fail 'acceptance erased altered Notes'
"$scratch/collab-board.sh" fixture update 23 notes 'delegated to verifier (awaiting CLAIM)'
"$scratch/collab-say.sh" fixture verifier 23 CLAIM 'branch=x worktree=/tmp/y'
contains "$board" 'delegated to verifier, claimed: branch=x worktree=/tmp/y'
pass 'malformed named-delegate acceptance fails visibly; review claims stay log-only'

cp "$board" "$scratch/file-claim-before"
"$scratch/collab-say.sh" fixture implementer 999 CLAIM 'files: a.go, b.go'
"$scratch/collab-say.sh" fixture implementer 999 CLAIM 'files: branch.ts, docs/worktree.md'
"$scratch/collab-say.sh" fixture implementer 9 CLAIM 'files: deferred.go'
cmp -s "$board" "$scratch/file-claim-before" || fail 'ordinary file claim changed board'
contains "$log" '#999 CLAIM files: a.go, b.go'
expect_exit 1 "$scratch/collab-say.sh" fixture reviewer 999 'GREEN(abc1234)' missing
pass 'ordinary unknown and deferred file claims are log-only; missing result projection still fails'

"$scratch/collab-board.sh" fixture add 24 P2 'nested deferral'
"$scratch/collab-say.sh" fixture reviewer 24 'DEFERRED(upstream bug (tracked in go-smtp #42), not ours)'
"$scratch/collab-board.sh" fixture get 24 > "$scratch/nested-reason"
contains "$scratch/nested-reason" '| 24 | upstream bug (tracked in go-smtp #42), not ours | reviewer |'
pass 'nested parentheses in deferral reasons are preserved'

# BSD awk/tr under a UTF-8 locale must safely handle a byte supplied by a peer.
invalid_byte=$(printf 'caf\351 latin1')
env LC_ALL=C "$scratch/collab-board.sh" fixture add 25 P2 "$invalid_byte"
env LC_ALL=en_US.UTF-8 "$scratch/collab-board.sh" fixture get 25 > "$scratch/byte-row"
LC_ALL=C grep -F "$invalid_byte" "$scratch/byte-row" >/dev/null || fail 'invalid byte did not survive board parsing'
env LC_ALL=en_US.UTF-8 "$scratch/collab-say.sh" fixture implementer 25 FYI "$invalid_byte"
LC_ALL=C grep -F "$invalid_byte" "$log" >/dev/null || fail 'invalid byte did not survive log append'
cat > "$scratch/fail-bin/awk" <<'EOF'
#!/usr/bin/env bash
echo 'injected board read failure' >&2
exit 1
EOF
chmod +x "$scratch/fail-bin/awk"
cp "$board" "$scratch/read-before"
expect_exit 1 env PATH="$scratch/fail-bin:$PATH" "$scratch/collab-board.sh" fixture add 26 P2 inaccessible
contains "$scratch/command.err" 'cannot read board'
if grep -F 'already exists' "$scratch/command.err" >/dev/null; then fail 'board read error misreported as duplicate'; fi
cmp -s "$board" "$scratch/read-before" || fail 'failed read changed board'
expect_exit 1 env PATH="$scratch/fail-bin:$PATH" "$scratch/collab-board.sh" fixture get 25
contains "$scratch/command.err" 'cannot read board'
rm "$scratch/fail-bin/awk"
pass 'byte-safe parsing preserves peer text; board read errors are distinct from duplicates'

# Replace each held lock just before cleanup. No old process owns this new lock.
cat > "$scratch/fail-bin/mv" <<'EOF'
#!/usr/bin/env bash
/bin/mv "$@" || exit $?
rm -rf "$COLLAB_TEST_REPLACE_LOCK"
mkdir "$COLLAB_TEST_REPLACE_LOCK"
EOF
chmod +x "$scratch/fail-bin/mv"
env PATH="$scratch/fail-bin:$PATH" COLLAB_TEST_REPLACE_LOCK="$session/.board.lock" \
  "$scratch/collab-board.sh" fixture update 25 fix unchanged
[ -d "$session/.board.lock" ] || fail 'old board writer deleted replacement lock'
rmdir "$session/.board.lock"
printf '[implementer] #- FYI replacement cursor lock\n' > "$log"
printf '0\n' > "$session/.cursor-reviewer"
env PATH="$scratch/fail-bin:$PATH" COLLAB_TEST_REPLACE_LOCK="$session/.cursor-reviewer.lock" \
  "$scratch/collab-watch.sh" fixture reviewer --once > "$scratch/replace-watch"
[ -d "$session/.cursor-reviewer.lock" ] || fail 'old watcher deleted replacement lock'
rmdir "$session/.cursor-reviewer.lock"
rm "$scratch/fail-bin/mv"
mv "$scratch/collab-board.sh" "$scratch/board-real.sh"
cat > "$scratch/collab-board.sh" <<'EOF'
#!/usr/bin/env bash
kit=$(cd "$(dirname "$0")" && pwd)
"$kit/board-real.sh" "$@" || exit $?
rm -rf "$COLLAB_TEST_REPLACE_LOCK"
mkdir "$COLLAB_TEST_REPLACE_LOCK"
EOF
chmod +x "$scratch/collab-board.sh"
env COLLAB_TEST_REPLACE_LOCK="$session/.say.lock" \
  "$scratch/collab-say.sh" fixture verifier 25 'REVIEW-OK(abc1234)' replacement
[ -d "$session/.say.lock" ] || fail 'old message writer deleted replacement lock'
rmdir "$session/.say.lock"
mv "$scratch/board-real.sh" "$scratch/collab-board.sh"
cat > "$scratch/fail-bin/awk" <<'EOF'
#!/usr/bin/env bash
rm -rf "$COLLAB_TEST_REPLACE_LOCK"
mkdir "$COLLAB_TEST_REPLACE_LOCK"
touch "$COLLAB_TEST_REPLACE_LOCK/replacement-owner"
echo 'injected read failure after lock replacement' >&2
exit 1
EOF
chmod +x "$scratch/fail-bin/awk"
printf '0\n' > "$session/.cursor-reviewer"
expect_exit 2 env PATH="$scratch/fail-bin:$PATH" COLLAB_TEST_REPLACE_LOCK="$session/.cursor-reviewer.lock" \
  "$scratch/collab-watch.sh" fixture reviewer --once
[ -f "$session/.cursor-reviewer.lock/replacement-owner" ] || fail 'replacement owner lost'
rm "$session/.cursor-reviewer.lock/replacement-owner"
rmdir "$session/.cursor-reviewer.lock"
rm "$scratch/fail-bin/awk"
pass 'owner tokens preserve replacement locks and original command exit codes'

# Focused probes also reject mutants of two properties already correct at base.
probe_request() {
  local target=$1
  mkdir -p "$target/sessions/fixture"
  cp "$scratch/read-before" "$target/sessions/fixture/board.md"
  : > "$target/sessions/fixture/chat.log"
  cp "$target/sessions/fixture/board.md" "$target/before"
  "$target/collab-say.sh" fixture implementer 25 'REQUEST-DELEGATE(reviewer)' bounded >/dev/null 2>&1 || return 1
  cmp -s "$target/before" "$target/sessions/fixture/board.md"
}
probe_print_failure() {
  local target=$1 actual
  mkdir -p "$target/sessions/fixture"
  printf '[implementer] #- FYI output must reach caller\n' > "$target/sessions/fixture/chat.log"
  printf '0\n' > "$target/sessions/fixture/.cursor-reviewer"
  cat > "$target/printf-failure" <<'EOF'
printf() {
  case ${2-} in '[implementer] '* ) return 1 ;; esac
  builtin printf "$@"
}
EOF
  if env BASH_ENV="$target/printf-failure" "$target/collab-watch.sh" fixture reviewer --once > "$target/output" 2> "$target/error"; then actual=0; else actual=$?; fi
  [ "$actual" -eq 2 ] && [ "$(cat "$target/sessions/fixture/.cursor-reviewer")" -eq 0 ]
}
mkdir "$scratch/probe-base" "$scratch/probe-request-mutant" "$scratch/probe-print-mutant"
for target in probe-base probe-request-mutant probe-print-mutant; do
  for script in collab-board.sh collab-say.sh collab-watch.sh; do cp "$scratch/$script" "$scratch/$target/$script"; done
done
probe_request "$scratch/probe-base" || fail 'REQUEST-DELEGATE guard probe failed'
awk '
  /case \$status in/ {
    print
    print "  REQUEST-DELEGATE\\(*)"
    print "    project update \"$item\" notes mutated-request"
    print "    ;;"
    next
  }
  { print }
' "$scratch/collab-say.sh" > "$scratch/probe-request-mutant/collab-say.sh"
if probe_request "$scratch/probe-request-mutant"; then fail 'REQUEST-DELEGATE board mutation survived probe'; fi
probe_print_failure "$scratch/probe-base" || fail 'printf failure cursor guard probe failed'
awk '
  index($0, "if ! printf") && index($0, "\"$lines\"") {
    print "      if ! { printf '\''%s\\n'\'' \"$lines\" || true; }; then"
    next
  }
  { print }
' "$scratch/collab-watch.sh" > "$scratch/probe-print-mutant/collab-watch.sh"
if probe_print_failure "$scratch/probe-print-mutant"; then fail 'ignored printf failure mutation survived probe'; fi
pass 'REQUEST-DELEGATE board and printf-failure cursor guards reject explicit mutants'

printf 'PASS %s isolated smoke cases\n' "$checks"
