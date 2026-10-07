#!/usr/bin/env bash
# collab-alive.sh <slug> <role> <item|-> <working|waiting|idle> <text...>
#   Records this participant's heartbeat: what it is doing right now. Every
#   participant ticks at least every 2 minutes (protocol.md, "Heartbeats").
#   working: name the item and the step ("#320 running the objects lane").
#   waiting: name the item AND whom it waits on ("#326 waiting on verifier").
#   idle:    nothing assigned; say so, so work can be handed over.
# collab-alive.sh <slug> show [stale-seconds]
#   Prints every participant's last heartbeat, its age, and STALE once it is
#   older than stale-seconds (default 300: two missed ticks plus slack). It
#   also flags a WAIT ON STALE: a participant waiting on a role whose own
#   heartbeat is stale, or idle, which is work nobody is doing.
# Heartbeats are files, not chat lines: a two-minute tick from every
# participant would bury the channel, and the protocol says to stay silent
# when there is nothing to add.
set -euo pipefail
export LC_ALL=C
[ $# -ge 2 ] || { echo "usage: $0 <slug> <role> <item|-> <working|waiting|idle> <text...> | $0 <slug> show [stale-seconds]" >&2; exit 2; }
slug=$1; shift
[[ $slug =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "invalid session slug" >&2; exit 2; }
kit=$(cd "$(dirname "$0")" && pwd)
dir="$kit/sessions/$slug/alive"
[ -d "$kit/sessions/$slug" ] || { echo "no session $slug" >&2; exit 1; }
mkdir -p "$dir"

if [ "$1" = show ]; then
	stale=${2:-300}
	set -- "$dir"/*.beat
	[ -e "$1" ] || { echo "no heartbeats yet"; exit 0; }
	# Two passes over the same files: ages and states first, then each line,
	# flagging a waiting participant whose text names a stale or idle role.
	awk -F'\t' -v now="$(date -u +%s)" -v stale="$stale" '
		FNR == 1 { file++ }
		file <= n0 { age[$3] = now - $1; st[$3] = $5; next }
		{
			a = now - $1; flag = (a > stale) ? " STALE" : ""
			# A reviewer instance (reviewer-root) also answers to "reviewer".
			if ($5 == "waiting") for (r in age) {
				base = r; sub(/-.*/, "", base)
				hit = (" " $6 " ") ~ ("[^a-z0-9-]" r "[^a-z0-9-]") || (base == "reviewer" && r != base && (" " $6 " ") ~ "[^a-z0-9-]reviewer[^a-z0-9-]")
				if (r != $3 && hit && (age[r] > stale || st[r] == "idle")) flag = flag " WAIT-ON-STALE(" r ")"
			}
			printf "%-14s %5ss ago  %-8s %-7s %s%s\n", $3, a, $5, "#" $4, $6, flag
		}' n0=$# "$@" "$@" | sort
	exit 0
fi

[ $# -ge 4 ] || { echo "usage: $0 <slug> <role> <item|-> <working|waiting|idle> <text...>" >&2; exit 2; }
role=$1 item=${2#\#} state=$3; shift 3
text="$*"
[[ $role =~ ^[a-z][a-z0-9_-]*$ ]] || { echo "invalid role" >&2; exit 2; }
[[ $item == "-" || $item =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || { echo "invalid item ID" >&2; exit 2; }
case $state in working|waiting|idle) ;; *) echo "state must be working, waiting or idle" >&2; exit 2 ;; esac
[ -n "$text" ] || { echo "say what you are doing (or waiting on)" >&2; exit 2; }
case $text in *$'\n'*|*$'\r'*|*$'\t'*) echo "text must be one line, no tabs" >&2; exit 2 ;; esac
tmp=$(mktemp "$dir/.$role.XXXXXX")
printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%s)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$role" "$item" "$state" "$text" > "$tmp"
mv -f "$tmp" "$dir/$role.beat"
