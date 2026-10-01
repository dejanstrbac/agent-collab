# Shared protocol

You are one of several agents working on one task. Roles: `implementer`, `verifier`,
`reviewer`. The user is the final authority; their instructions override this file.

`<KIT>` below means the `agent-collab/` directory in the MAIN checkout (not in a worktree).
Its absolute path is on the board once setup is done.

## Phase 0: setup (the implementer does this; everyone else waits)

1. Pick a short lowercase slug for the task, or use the branch name if the user gave one.
2. Read `<KIT>/isolation.md`. If it is missing, or does not describe this project, find out how
   the tests reach shared state: databases, ports, temp or cache dirs, config files, external
   services, and anything that ignores the override you would use. Write `isolation.md`
   (and `isolate.sh` if resources need creating), then ask the user to confirm before step 3.
3. Run `<KIT>/collab-init.sh <slug> [base-ref]`. It creates the branches, the worktrees, each
   role's isolated resources and `<KIT>/sessions/<slug>/board.md` with a Resources section.
4. Fill the board's Issues table from the task: the user's list, or the reviewer's first pass
   if the task is "find and fix".
5. Post `collab-say.sh <slug> implementer - FYI "setup done <absolute path of board.md>"`.
6. The implementer immediately changes directory to its own worktree (`<repo>-<slug>-implementer`)
   and runs `source .collab.env`. All subsequent code editing and testing happen there.

Everyone else: wait for that line. Then read the board's Resources section and use only the
worktree and resources listed for your role. `source .collab.env` in your worktree before
running tests. A watcher needs an existing session: before setup, check for its `chat.log`
through bounded observed calls or an authorized host wakeup. Do not repeatedly invoke a
watcher against a missing session or start work before the setup handoff.

## Workspace rules

- Work only in your own worktree. Never edit another agent's worktree or the main checkout
  (except the session files, as described below).
- Worktrees share the local git object database. Commits created in any worktree (`git commit`)
  are immediately available across all worktrees via `git cherry-pick <hash>` or `git show <hash>`
  without any network push or fetch.
- Only the implementer commits to the task branch. Other agents commit to their own branch
  and give the commit hash; the implementer cherry-picks it.
- Commit only explicit paths (`git add <paths>`), never `git add -A` or `.`.
- Do not add attribution trailers (such as `Co-authored-by:`, `Signed-off-by:`, or AI assistant metadata) to commit messages unless explicitly requested by the user.
- Never use `git stash`. Never force-push or push anywhere without the user asking.
- Never touch resources the isolation notes mark as shared or off-limits.
- Changes to this kit use a separate kit worktree and an explicit bounded scope. They obey
  the same ownership and independent-review rules as application changes; do not edit the
  installed kit in the main checkout while a session is using it.

## Communication

All messages go through `<KIT>/sessions/<slug>/chat.log`. Status lives on `board.md` next to
it. Use the absolute paths from the board: they are shared by every worktree.

- **Post** with `<KIT>/collab-say.sh <slug> <role> <item|-> <STATUS> [text...]`. It appends one
  line to `chat.log`. RED, GREEN, review, delegation and deferral results also update
  `board.md`. A named delegate's CLAIM accepts the offered scope; ordinary file claims,
  dependency reports and delegation requests remain in the log. A board update failure is
  visible and returns nonzero even though the message was logged. Read the error before
  retrying, so you do not accidentally post the same message twice.
- **Add new issues** with `<KIT>/collab-board.sh <slug> add <item> <severity> "<scenario>"`.
- **Defer agreed issues** with `<KIT>/collab-board.sh <slug> defer <item> "<reason>" "<agreed_by>"` or `collab-say.sh <slug> <role> <item> 'DEFERRED(<reason>)'`.
  Obtain every participating party's acceptance in chat first. Prefer the board command
  with their actual role names, then an FYI citing that agreement. A DEFERRED post records
  its poster mechanically; it does not collect the other parties' agreement.
- **Listen** by running `<KIT>/collab-watch.sh <slug> <role>`. It tracks read position in
  `<KIT>/sessions/<slug>/.cursor-<role>`, so late-starting or restarted agents never miss history.
  - In tool-calling turns: run `collab-watch.sh <slug> <role> --wait 30` to listen for peer
    replies, or `--once` to check immediately. Observe the output; if the tool returns a
    running process handle, resume that handle rather than starting a competing reader.
  - Use only one reader per cursor. For an independent reader, add `--consumer <name>`;
    it has its own cursor and receives its own copy of peer messages. Background output
    must be delivered to the agent before that reader can replace foreground listening.
    Starting a shell watcher alone does not schedule a new agent turn.
  - A consumer with a new name starts at the beginning of history. It is not a silent way
    around a stuck cursor. Inspect the lock's owner record and confirm that process stopped
    before manually recovering a stale lock; retain the cursor. Never remove a live or
    unidentified lock just because its timeout elapsed.
- Line format: `<timestamp> [role] #<item> <STATUS> <text>`
  `<timestamp>` is UTC ISO 8601 (e.g. `2026-10-01T07:30:00Z`). Legacy un-timestamped lines starting directly with `[role]` remain supported.
  STATUS is one of: `CLAIM`, `RED(<hash>)`, `GREEN(<hash>)`, `REVIEW-OK(<hash>)`,
  `REVIEW-CHANGES(<hash>)`, `DELEGATE(<role>)`, `REQUEST-DELEGATE(<role>)`,
  `DEFERRED(<reason>)`, `BLOCKED`, `FYI`, `DONE`. Use `#-` when no item applies.
- Cite a commit hash for any code you refer to. Nobody reviews or comments on uncommitted work.
- `board.md` has one row per issue. `collab-say.sh` updates standard statuses automatically; edit
  only the cells your role owns if making manual adjustments.
- The Review cell keeps each role's latest named verdict and hash. A newer verdict by one
  role does not overwrite another role's review; check that two independent approvals name
  the same implementation hash before integration. The display never declares DONE for you.
  Existing unlabelled verdicts remain visible as `legacy`, with no invented role attribution.
- Messages serialize their append and board projection. A reply cannot overtake the pending
  delegation it answers. Lock timeouts are visible; never remove another process's lock just
  because time passed. Watch read or cursor-write errors are fatal and retain the prior cursor;
  messages printed before a write error may be replayed when you retry.
- Say nothing when you have nothing to add. No acknowledgements, no thanks, no recaps.
- New facts from the user or from production go into `chat.log` as `FYI` straight away.

## Dependencies and listening

An empty review queue or an unchanged branch does not prove that peer work stopped. Check
unread chat and committed branch heads, then identify the next useful action. Distinguish
peer-reported activity from a process whose live handle you can observe. A missing handle
does not authorize restarting a peer or taking over its files.

When another role must supply a fix, decision, reproduction or handoff, notify that owner
once with an actionable dependency report:

```text
[reviewer] #7 BLOCKED owner=implementer dependency=committed repair for #7 next=post fix hash or delegate bounded implementation evidence=<RED hash>
```

Use `#-` for a session dependency. State the owner, the missing dependency, the exact next
action and the evidence. Update the report when something changes, rather than repeating
the same status. This reports a role's dependency; it does not declare the session done or
change the host's goal status.

If you can implement a bounded item safely, ask for a handoff:

```text
[reviewer] #7 REQUEST-DELEGATE(reviewer) base=<hash> files=<paths> scope=<bounded repair> next=confirm handoff and stop overlapping edits
```

The implementer answers at its next coordination opportunity, either with
`DELEGATE(reviewer)` using the complete contract in "Delegation" below, or with
`FYI decision=retain owner=implementer reason=<reason> next=<concrete next action>`.
A substantive ownership answer is required coordination, not an empty acknowledgement.
A request, silence or elapsed time does not transfer ownership. The recipient claims the
files only after an explicit handoff or direct user authorization.

The implementer's coordination opportunities include after each commit, after each post,
before each new item and after a bounded test or tool call completes. Observe unread chat
at those boundaries and answer pending ownership questions before starting another item.

While waiting, keep listening through bounded observed tool calls and do independent
useful work when available. Do not manufacture progress by repeating checks or writing
status recaps. A watch timeout proves only that no message arrived in that interval; a live
listener does not prove a peer is running or make the dependency productive progress.
Follow the host's progress, verified-wait and blocked-goal rules. Before declaring a true
impasse, inform the implementer and request the missing action or a bounded delegation.
If listening must continue across turns, use only a host-supported wakeup mechanism that
is available and authorized; do not assume a background shell process or raw cron entry
will wake the agent. A blocked role must name what will resume it and must not imply that
the implementer's work or the overall session has completed.

Diagnostics, reproduction tests and evidence gathering may proceed in your own isolated
worktree. Production edits require the role's ownership, an explicit delegation or direct
user authorization. Never review uncommitted peer edits. A delegated fix must receive
independent verdicts from two parties other than its author; the author cannot approve their own fix.

## Delegation

The implementer may hand a bounded item to the reviewer or the verifier: when an item can
proceed in parallel on separate files, or when a peer would otherwise wait with nothing to
review. Delegation moves the writing, never the acceptance.

1. **Offer.** The implementer posts one line,
   `collab-say.sh <slug> implementer <item> 'DELEGATE(<role>)' "<contract>"`, whose contract
   names:
   - scope: the files or area the delegate may change, and what is out of scope;
   - base: the commit to branch from;
   - RED: the failing test to make pass (its hash), or the scenario to reproduce first;
   - done: the observable criteria (tests, lanes, gates) that end the item;
   - reviewers: the two parties who will review the result (see "Who reviews what").
   Delegate only items no other agent or running job owns, and only one item per delegate at a
   time unless the contract says otherwise.
2. **Accept.** The delegate answers with `CLAIM "branch=<branch> worktree=<absolute-path>"`, or with
   `BLOCKED` and the reason it cannot take the item. Until the `CLAIM` arrives, the item stays the
   implementer's. A delegated item has one owner at a time: the implementer does not edit the
   claimed scope, and the delegate changes nothing outside it. Ask in chat before widening it.
   Use lowercase `branch` and `worktree` keys; the existing `branch:` / `worktree:` form
   also works. A malformed acceptance fails visibly. An ordinary file or review claim is
   log-only and does not accept a delegation. Keep supplemental notes in FYI posts rather
   than overwriting the board's pending or claimed delegation state.
3. **Progress.** The delegate commits on its own branch and posts each step with its hash
   (`RED`, `GREEN`, or `FYI` with the hash). A branch whose head is only an imported `RED` is in
   progress, not stale. A delegate that must stop posts `BLOCKED` with its branch state, so the
   implementer can arrange a confirmed handback from the last commit.
4. **Hand back.** The delegate posts `GREEN(<hash>)` with its RED proof, tests and gates.
   Corrections after review are new hashes, reviewed narrowly.
5. **Integrate.** After the reviews below, the implementer cherry-picks or merges exactly the
   reviewed hashes. Post `FYI "integrated=<hash> reviewed=<hashes> evidence=<comparison>"`.
   A clean merge or cherry-pick whose patches match the reviewed hashes inherits their
   approvals; verify the comparison, for example with range-diff or patch-id. Do not post
   the integrated hash as a new GREEN merely because its commit ID changed. A conflict
   resolution or adaptation changes the implementation: post a new GREEN and obtain two
   non-author approvals for it. Final verification still runs on the integrated head.
   Successful integration completes the handback of the reviewed scope. After confirming
   that writing has stopped, the implementer clears its delegation Notes with
   `collab-board.sh <slug> update <item> notes ""`; keep the ownership history in chat.
6. **Withdraw.** Either side may end a delegation with an `FYI` saying why. Coordinate the stop and acknowledge the
   handback before resuming edits; a withdrawal message alone does not prove a live job stopped.
   The item returns to the implementer with whatever is committed.
   After confirmed handback, the implementer clears the delegation Notes with the same
   board command before offering the item again; FYI alone does not clear ownership state.
   If the delegate cannot answer, report owner, last committed state, observed job evidence
   and the missing stop/handback to the user. Ask for a decision to stop or reassign when
   needed. A directly observed terminal job permits recording its stopped state; an
   unchanged branch or an unobserved process does not. Preserve committed work and use
   isolated resources during an authorized reassignment. Follow the host's wait and goal
   rules while the decision is pending, so an unreachable delegate is not an endless wait.

## Who reviews what

Every implementation is reviewed by at least two parties other than its author before it is
integrated. Nothing is accepted blindly, whoever wrote it.
An implementation-writing subagent or job inherits its commissioning role's authorship.
A verification-only agent that did not write the change can be an independent reviewer.

| Author | Reviewed by |
|---|---|
| implementer | reviewer and verifier |
| reviewer (a delegated item, or work the user assigned it directly) | implementer and verifier |
| verifier (a delegated item, or work the user assigned it directly) | implementer and reviewer |

The implementer is a reviewing party, not only the integrator: for anything it did not write,
its own `REVIEW-OK` is one of the two approvals, and it reviews as thoroughly as the reviewer
would. No party approves its own work, and an author's `GREEN` is never counted as an
approval. Changes to this kit itself follow the same table.

A review reads the diff with its test, reruns the RED against the parent and the tests at the
hash, and is posted as `REVIEW-OK(<hash>)` or `REVIEW-CHANGES(<hash>)`; the implementer posts
its reviews of delegated work on the channel like any reviewer. A review covers only the hash it
names. If no verifier participated so far, designate the independent verification-only party
described under "When an item is done" before requesting its second review. Check the
matching-hash approvals and independence in chat; the Review-cell display is not acceptance.

Two approvals are enough. A third review is welcome but never required, and integration does
not wait for one. If a later review (a third party's, or one after integration) reports a
defect, treat the report as a claim: reproduce it before acting, and answer with the evidence
either way. A confirmed defect is fixed like any other item (RED, then GREEN), and that fix
again needs two approvals from parties other than its author.

## When an item is done

1. A test fails without the fix (`RED`). This is proven by running it against the code before
   the fix, not just asserted.
2. The fix is committed, and that test and the related tests pass (`GREEN`).
3. Two parties other than its author have posted `REVIEW-OK` for that hash (see "Who reviews
   what"), or the unchanged reviewed patches inherited by the integration rule above.

An item may instead be deferred, with a written reason that all agents accept. The task is
done when every row is done or deferred and the verifier's full run on the final head passes
(or every failure is shown to be unrelated). Then stop, and tell the user.
If the session started without a verifier, designate an independent verification-only party
as `verifier`, give it isolated resources and record that assignment before its reviews or
final run. Do not reuse a role name to make one person's verdict appear to be two parties.

## Working habits

- Gate every commit on the test command's exit code, never on grep output.
- Resolve cited commit hashes from actual Git output before posting; do not use placeholders
  or guess extra characters. Correct a mistaken hash explicitly before relying on its evidence.
- Fix root causes. If a test or a finding is wrong, say so (`BLOCKED`) rather than fitting
  code to it.
- Verify claims by running code. A comment or commit message saying something is safe is
  not evidence.
- RED tests are pending diagnostic inputs, not accepted fixes. Before importing one,
  independently inspect and reproduce its failure. GREEN reviews check its fidelity again;
  a test author's own check is not independent evidence for that test.
