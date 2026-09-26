#!/usr/bin/env bash
# worktree-setup.example.sh <worktree_path> <role> <repo_root>
#
# Optional project-specific hook invoked by collab-init.sh immediately after creating a worktree.
# Use this to symlink heavy uncommitted build dependencies (e.g. node_modules, vendor, build caches)
# so agents don't have to re-download or re-install dependencies in each worktree.

set -euo pipefail

wt=$1
role=$2
root=$3

# Example 1: Symlink node_modules from parent repo if present
if [ -d "$root/node_modules" ] && [ ! -e "$wt/node_modules" ]; then
  ln -s "$root/node_modules" "$wt/node_modules"
  echo "[$role] symlinked node_modules into worktree"
fi

# Example 2: Symlink subproject frontend dependencies (e.g. frontend/node_modules)
if [ -d "$root/frontend/node_modules" ] && [ ! -e "$wt/frontend/node_modules" ]; then
  mkdir -p "$wt/frontend"
  ln -s "$root/frontend/node_modules" "$wt/frontend/node_modules"
  echo "[$role] symlinked frontend/node_modules into worktree"
fi

# Example 3: Copy untracked local config/env if needed
# if [ -f "$root/.env.local" ] && [ ! -f "$wt/.env.local" ]; then
#   cp "$root/.env.local" "$wt/.env.local"
# fi
