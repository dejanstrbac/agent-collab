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
5. Post `[implementer] FYI setup done <absolute path of board.md>`.
6. The implementer immediately changes directory to its own worktree (`<repo>-<slug>-implementer`)
   and runs `source .collab.env`. All subsequent code editing and testing happen there.

Everyone else: wait for that line. Then read the board's Resources section and use only the
worktree and resources listed for your role. `source .collab.env` in your worktree before
running tests.

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

## Communication

All messages go through `<KIT>/sessions/<slug>/chat.log`. Status lives on `board.md` next to
it. Use the absolute paths from the board: they are shared by every worktree.

- **Post** with `<KIT>/collab-say.sh <slug> <role> <item|-> <STATUS> [text...]`. It appends one
  line to `chat.log` and automatically updates the corresponding status columns in `board.md`.
- **Add new issues** with `<KIT>/collab-board.sh <slug> add <item> <severity> "<scenario>"`.
- **Defer agreed issues** with `<KIT>/collab-board.sh <slug> defer <item> "<reason>" "<agreed_by>"` or `collab-say.sh <slug> <role> <item> 'DEFERRED(<reason>)'`.
- **Listen** by running `<KIT>/collab-watch.sh <slug> <role>`. It tracks read position in
  `<KIT>/sessions/<slug>/.cursor-<role>`, so late-starting or restarted agents never miss history.
  - In background watchers: run `collab-watch.sh <slug> <role>` continuously.
  - In tool-calling/polling turns: run `collab-watch.sh <slug> <role> --wait [seconds]` to block until peer replies, or `--once` to check immediately.
- Line format: `[role] #<item> <STATUS> <text>`
  STATUS is one of: `CLAIM`, `RED(<hash>)`, `GREEN(<hash>)`, `REVIEW-OK(<hash>)`,
  `REVIEW-CHANGES(<hash>)`, `DELEGATE(<role>)`, `DEFERRED(<reason>)`, `BLOCKED`, `FYI`, `DONE`. Use `#-` when no item applies.
- Cite a commit hash for any code you refer to. Nobody reviews or comments on uncommitted work.
- `board.md` has one row per issue. `collab-say.sh` updates standard statuses automatically; edit
  only the cells your role owns if making manual adjustments.
- Say nothing when you have nothing to add. No acknowledgements, no thanks, no recaps.
- New facts from the user or from production go into `chat.log` as `FYI` straight away.

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
2. **Accept.** The delegate answers with `CLAIM` naming its branch and worktree, or with
   `BLOCKED` and the reason it cannot take the item. Until the `CLAIM` arrives, the item stays the
   implementer's. A delegated item has one owner at a time: the implementer does not edit the
   claimed scope, and the delegate changes nothing outside it. Ask in chat before widening it.
3. **Progress.** The delegate commits on its own branch and posts each step with its hash
   (`RED`, `GREEN`, or `FYI` with the hash). A branch whose head is only an imported `RED` is in
   progress, not stale. A delegate that must stop posts `BLOCKED` with its branch state, so the
   implementer can take the item back from the last commit.
4. **Hand back.** The delegate posts `GREEN(<hash>)` with its RED proof, tests and gates.
   Corrections after review are new hashes, reviewed narrowly.
5. **Integrate.** After the reviews below, the implementer cherry-picks or merges exactly the
   reviewed hashes and posts the integrated hash.
6. **Withdraw.** Either side may end a delegation with an `FYI` saying why. The item returns to
   the implementer with whatever is committed.

## Who reviews what

Every implementation is reviewed by at least two parties other than its author before it is
integrated. Nothing is accepted blindly, whoever wrote it.

| Author | Reviewed by |
|---|---|
| implementer, or a subagent or job the implementer runs | reviewer and verifier |
| reviewer (a delegated item, or work the user assigned it directly) | implementer and verifier |
| verifier (a delegated item, or work the user assigned it directly) | implementer and reviewer |

The implementer is a reviewing party, not only the integrator: for anything it did not write,
its own `REVIEW-OK` is one of the two approvals, and it reviews as thoroughly as the reviewer
would. No party approves its own work, and an author's `GREEN` is never counted as an
approval. Changes to this kit itself follow the same table.

A review reads the diff with its test, reruns the RED against the parent and the tests at the
hash, and is posted as `REVIEW-OK(<hash>)` or `REVIEW-CHANGES(<hash>)`; the implementer posts
its reviews of delegated work on the channel like any reviewer. A review covers only the hash it
names. In a session without a verifier, the second review comes from an independent agent that
did not write the change (for example one the implementer starts only to review it).

## When an item is done

1. A test fails without the fix (`RED`). This is proven by running it against the code before
   the fix, not just asserted.
2. The fix is committed, and that test and the related tests pass (`GREEN`).
3. Two parties other than its author have posted `REVIEW-OK` for that hash (see "Who reviews
   what").

An item may instead be deferred, with a written reason that all agents accept. The task is
done when every row is done or deferred and the verifier's full run on the final head passes
(or every failure is shown to be unrelated). Then stop, and tell the user.

## Working habits

- Gate every commit on the test command's exit code, never on grep output.
- Fix root causes. If a test or a finding is wrong, say so (`BLOCKED`) rather than fitting
  code to it.
- Verify claims by running code. A comment or commit message saying something is safe is
  not evidence.
