#!/usr/bin/env bash
# isolate.example.sh <create|drop> <resource-name>
#
# Optional project-specific hook called by collab-init.sh and collab-clean.sh.
# Use this when tests need isolated background services (e.g., PostgreSQL DB, Redis instance, local port).
#
# When `create <name>` is called:
#   - Provision the isolated resource
#   - Print KEY=VALUE environment variable lines to stdout (these get written to the worktree's .collab.env)
#
# When `drop <name>` is called:
#   - Tear down the isolated resource

set -euo pipefail

action=${1:-}
name=${2:-}

case "$action" in
  create)
    # Example: Start a docker container or create a distinct database
    # docker run -d --name "$name" -p 0:5432 -e POSTGRES_PASSWORD=secret postgres:16-alpine >/dev/null
    # port=$(docker port "$name" 5432/tcp | head -n1 | cut -d: -f2)
    # echo "TEST_DB_PORT=$port"
    # echo "DATABASE_URL=postgres://postgres:secret@127.0.0.1:$port/testdb"
    ;;
  drop)
    # Example: Stop and remove the container
    # docker rm -f "$name" >/dev/null 2>&1 || true
    ;;
  *)
    echo "usage: $0 <create|drop> <resource-name>" >&2
    exit 2
    ;;
esac
