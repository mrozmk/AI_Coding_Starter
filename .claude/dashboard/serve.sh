#!/usr/bin/env bash
# Serve the live harness dashboard on 127.0.0.1 (read-only; run by the developer, never by Claude).
#
# Usage: bash .claude/dashboard/serve.sh
#   then open the printed http://127.0.0.1:<port>/
#
# Env: TEAM_DASH_PORT (8787), TEAM_DASH_SECS (refresh, 3), TEAM_DASH_SESSION (pin a transcript id).
# The snapshot lives in a temp dir removed on exit; nothing is written inside the repo.
set -euo pipefail

if [ $# -ne 0 ]; then
  sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
fi
root="$(git rev-parse --show-toplevel)"
for tool in jq python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: $tool not on PATH" >&2; exit 1; }
done
. "$root/.claude/lib/team-lib.sh"
port="${TEAM_DASH_PORT:-8787}"
secs="${TEAM_DASH_SECS:-3}"

# Pinned once, so activity in another main-checkout window never swaps the supervisor mid-run.
SID="$(team_dash_session "$root")"
export TEAM_DASH_SESSION="$SID" TEAM_DASH_SECS="$secs"

LOOP=""; SRV=""
T="$(mktemp -d)"
# The snapshot reuses PR merge states between runs (team-pr-state.sh).
export TEAM_DASH_CACHE="$T"
trap 'for p in $LOOP $SRV; do kill "$p" 2>/dev/null || true; done; rm -rf "$T"' EXIT
trap 'exit 130' INT TERM HUP

while :; do
  bash "$root/.claude/lib/team-snapshot.sh" --out "$T/snapshot.json" 2>>"$T/loop.log" || true
  sleep "$secs"
done &
LOOP=$!

echo "dashboard: http://127.0.0.1:$port/ · session ${SID:-none} (override: TEAM_DASH_SESSION=<id>)"
# Bash defers a trapped TERM until a foreground child exits; `wait` is interruptible.
python3 "$root/.claude/dashboard/server.py" "$port" "$root/.claude/dashboard/index.html" \
  "$T/snapshot.json" &
SRV=$!
wait "$SRV"
