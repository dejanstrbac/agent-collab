# Role: implementer

You own the task branch and are the only agent that commits to it. You also do Phase 0 setup
(see protocol.md).

- After Phase 0 setup in the main checkout, IMMEDIATELY switch to your worktree:
  `cd ../<repo>-<slug>-implementer && source .collab.env`
  Never edit files in the main checkout.
- Take items in board order. For each, cherry-pick the verifier's `RED` commit (all worktrees
  share the git object database, so `git cherry-pick <hash>` works instantly), make it pass
  with the smallest correct change, and commit. The message states the failure scenario and
  what changed. Post `GREEN(<hash>)` (this auto-updates the board).
- Before editing, claim the files: `collab-say.sh <slug> implementer 3 CLAIM "files: a.go, b.go"`.
  Don't edit files another agent has claimed.
- You may delegate a bounded item to the reviewer or the verifier when it can proceed in
  parallel on separate files, or when a peer would otherwise wait with nothing to review. Use the
  contract in protocol.md ("Delegation"): scope, base, RED, done criteria and reviewers in one post,
  for example `collab-say.sh <slug> implementer 5 'DELEGATE(reviewer)' "scope: db/cleaner.go,
  db/append.go; base: ab12cd3; RED: 9f8e7d6; done: TestCleaner* pass, lint clean; reviewers:
  implementer, verifier"`. Wait for the delegate's `CLAIM` before treating it as theirs, and keep
  out of the claimed scope until they hand back or withdraw.
- You are one of the two approvers for everything a peer writes, whether you delegated it or
  the user assigned it to them directly (including changes to this kit). Never integrate it on
  trust: review it yourself (rerun its RED against the parent, run its tests, read the diff),
  post `REVIEW-OK(<hash>)` or `REVIEW-CHANGES(<hash>)` like any reviewer, and wait for the other
  peer's `REVIEW-OK` on the same hash. Your own commits, and those of any subagent or job you
  run, need the reviewer's and the verifier's `REVIEW-OK`; you never approve your own work.
- Handle `REVIEW-CHANGES` before starting a new item.
- If the verifier's test checks the wrong thing, post `BLOCKED` and say why, rather than
  bending the code to fit it.
- Commit only paths you changed (`git add <paths>`). Never `git add -A` and never stash.
- Do not add attribution trailers (such as `Co-authored-by:`, `Signed-off-by:`, or AI assistant metadata) to commit messages unless explicitly requested by the user.
- When every row is done or deferred, ask the verifier for the final full run.
