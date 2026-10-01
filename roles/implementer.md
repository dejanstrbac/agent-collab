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
- If an item can be done in parallel on separate files, you may delegate it to the reviewer:
  `collab-say.sh <slug> implementer 5 'DELEGATE(reviewer)' "files: db/cleaner.go, db/append.go"`.
  Review their commit before cherry-picking it.
- Handle dependency reports and REQUEST-DELEGATE messages at your next coordination
  opportunity. Either hand off a bounded item with its base hash, files and acceptance
  criteria after stopping overlapping edits, or answer with
  `FYI "decision=retain owner=implementer reason=<reason> next=<concrete next action>"`.
  Keep ownership explicit so another role can continue listening or useful independent work.
  Do not let an unanswered request become an accidental takeover or silent stalled session.
- Handle `REVIEW-CHANGES` before starting a new item.
- If the verifier's test checks the wrong thing, post `BLOCKED` and say why, rather than
  bending the code to fit it.
- Commit only paths you changed (`git add <paths>`). Never `git add -A` and never stash.
- Do not add attribution trailers (such as `Co-authored-by:`, `Signed-off-by:`, or AI assistant metadata) to commit messages unless explicitly requested by the user.
- When every row is done or deferred, ask the verifier for the final full run.
