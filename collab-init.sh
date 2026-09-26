#!/usr/bin/env bash
# collab-init.sh <slug> [base-ref] [roles...]
#
# Creates a collaboration session for one task:
#   - branch <slug> from base-ref (default: the current HEAD), used by the implementer
#   - branch <slug>-<role> for every other role
#   - one worktree per role at ../<repo>-<slug>-<role>
#   - per-role isolated resources through ./isolate.sh (if present), written to
#     <worktree>/.collab.env as KEY=VALUE lines
#   - sessions/<slug>/board.md (with a Resources section) and an empty chat.log
# Re-running it is safe: anything that already exists is left alone.
set -euo pipefail

usage() { echo "usage: $0 <slug> [base-ref] [roles...]  (default roles: implementer verifier reviewer)" >&2; exit 2; }
[ $# -ge 1 ] || usage

slug=$1; shift
[[ $slug =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "slug must be lowercase letters, digits and dashes" >&2; exit 2; }
base=HEAD
if [ $# -ge 1 ] && git rev-parse --verify --quiet "$1^{commit}" >/dev/null; then base=$1; shift; fi
roles=("$@"); [ ${#roles[@]} -gt 0 ] || roles=(implementer verifier reviewer)

kit=$(cd "$(dirname "$0")" && pwd)
root=$(git -C "$kit" rev-parse --show-toplevel)
repo=$(basename "$root")
common=$(git -C "$root" rev-parse --git-common-dir)
case $common in /*) ;; *) common="$root/$common" ;; esac

# Keep the kit and per-worktree env files out of git, locally only.
if [ "$root" != "$kit" ]; then
  kit_name=$(basename "$kit")
  for pat in "$kit_name/" ".collab.env"; do
    grep -qxF "$pat" "$common/info/exclude" 2>/dev/null || echo "$pat" >> "$common/info/exclude"
  done
fi

session="$kit/sessions/$slug"
mkdir -p "$session"
touch "$session/chat.log"

if ! git -C "$root" show-ref --verify --quiet "refs/heads/$slug"; then
  git -C "$root" branch "$slug" "$base"
  echo "created branch $slug from $base"
fi

resources=""
for role in "${roles[@]}"; do
  if [ "$role" = implementer ]; then branch=$slug; else branch="$slug-$role"; fi
  if ! git -C "$root" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$root" branch "$branch" "$slug"
  fi
  wt="$(dirname "$root")/$repo-$slug-$role"
  if [ ! -e "$wt" ]; then
    git -C "$root" worktree add -q "$wt" "$branch"
    echo "created worktree $wt ($branch)"
  fi

  # Run optional project worktree setup hook (e.g. symlinking node_modules, build caches)
  if [ -x "$kit/worktree-setup.sh" ]; then
    "$kit/worktree-setup.sh" "$wt" "$role" "$root" || echo "warning: worktree-setup.sh failed for $role" >&2
  elif [ -x "$root/worktree-setup.sh" ]; then
    "$root/worktree-setup.sh" "$wt" "$role" "$root" || echo "warning: worktree-setup.sh failed for $role" >&2
  fi

  env=""
  if [ -x "$kit/isolate.sh" ]; then
    name=$(echo "${repo}_${slug}_${role}" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9_\n' '_')
    env=$("$kit/isolate.sh" create "$name")
    if [ -n "$env" ]; then
      printf '%s\n' "$env" | sed 's/^/export /' > "$wt/.collab.env"
    else
      touch "$wt/.collab.env"
    fi
  else
    touch "$wt/.collab.env"
  fi
  resources+="| $role | \`$branch\` | \`$wt\` | ${env//$'\n'/<br>} |"$'\n'
done

board="$session/board.md"
if [ ! -e "$board" ]; then
  cat > "$board" <<EOF
# $slug

Kit: \`$kit\`
Chat: \`$session/chat.log\`
Base: \`$(git -C "$root" rev-parse --short "$base")\` ($base)

## Resources

Each agent uses only its own row. Run \`source .collab.env\` in your worktree before tests.

| Role | Branch | Worktree | Isolated resources |
|---|---|---|---|
${resources}
## Issues

Owners: Issue = reviewer or user · Test = verifier · Fix = implementer · Review = reviewer.

| # | Severity | Issue (file:line, failure scenario) | Test (RED hash) | Fix (GREEN hash) | Review | Notes |
|---|---|---|---|---|---|---|

## Deferred

| # | Reason | Agreed by |
|---|---|---|
EOF
fi

echo "board: $board"
