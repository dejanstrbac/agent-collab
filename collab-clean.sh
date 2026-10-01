#!/usr/bin/env bash
# collab-clean.sh <slug> [--keep-session]
#
# Removes a session's worktrees and drops its isolated resources (through ./isolate.sh).
# Branches are kept: merge or delete them yourself. sessions/<slug>/ is kept with
# --keep-session, otherwise it is removed too.
set -euo pipefail

[ $# -ge 1 ] || { echo "usage: $0 <slug> [--keep-session]" >&2; exit 2; }
slug=$1; keep=${2:-}

kit=$(cd "$(dirname "$0")" && pwd)
# The kit is usually its own clone (README), so resolve the host repo from its parent.
root=$(git -C "$kit/.." rev-parse --show-toplevel)
repo=$(basename "$root")

for wt in "$(dirname "$root")/$repo-$slug-"*; do
  [ -d "$wt" ] || continue
  role=${wt##*/$repo-$slug-}
  if [ -x "$kit/isolate.sh" ]; then
    name=$(echo "${repo}_${slug}_${role}" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9_\n' '_')
    "$kit/isolate.sh" drop "$name" || echo "warning: could not drop resources for $role" >&2
  fi
  if [ -n "$(git -C "$wt" status --porcelain --untracked-files=no)" ]; then
    echo "skipping $wt: it has uncommitted changes" >&2
    continue
  fi
  git -C "$root" worktree remove --force "$wt"
  echo "removed worktree $wt"
done
git -C "$root" worktree prune 2>/dev/null || true

if [ "$keep" != "--keep-session" ]; then
  rm -rf "$kit/sessions/$slug"
fi
