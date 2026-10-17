#!/usr/bin/env bash
# Open the live harness dashboard in the default browser; start it in tmux when it is not running.
#
# Usage: bash .claude/dashboard/dashboard.sh [open|stop]
#   e.g. bash .claude/dashboard/dashboard.sh        (what /dashboard runs)
#
# Pins the newest transcript of this checkout — the session that ran /dashboard — and restarts the
# server when another session asks. The tmux session `dashboard` survives the Claude session.
set -euo pipefail

action="${1:-open}"
case "$action" in
  open|stop) ;;
  *) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
root="$(git rev-parse --show-toplevel)"
. "$root/.claude/lib/team-lib.sh"
[ ! -f "$root/.agents/team/team.json" ] \
  || { echo "error: run /dashboard from the main checkout, not a team clone" >&2; exit 1; }
for tool in tmux jq python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: $tool not on PATH" >&2; exit 1; }
done

name=dashboard
port="${TEAM_DASH_PORT:-8787}"
url="http://127.0.0.1:$port/"

if [ "$action" = stop ]; then
  team_tmux_alive "$name" || { echo "dashboard: not running"; exit 0; }
  tmux kill-session -t "=$name"
  echo "dashboard: stopped"
  exit 0
fi

up() {  # the server answers our Host-guarded snapshot path with 200
  python3 -c 'import sys, http.client as h
c = h.HTTPConnection("127.0.0.1", int(sys.argv[1]), timeout=1)
c.request("GET", "/snapshot.json", headers={"Host": "127.0.0.1:" + sys.argv[1]})
sys.exit(0 if c.getresponse().status == 200 else 1)' "$port" 2>/dev/null
}

sid="$(team_dash_session "$root")"
if team_tmux_alive "$name"; then
  pinned="$(tmux show-environment -t "=$name" TEAM_DASH_SESSION 2>/dev/null)" || pinned=""
  pinned="${pinned#TEAM_DASH_SESSION=}"
  if [ "$pinned" = "$sid" ] && up; then
    open "$url"
    echo "dashboard: $url · session ${sid:-none} · already running (stop: /dashboard stop)"
    exit 0
  fi
  echo "dashboard: restarting for session ${sid:-none} (was ${pinned:-none})"
  tmux kill-session -t "=$name"
fi

# `; read` keeps the pane after a failure, so its error can be shown below.
tmux new-session -d -s "$name" -c "$root" -e "TEAM_DASH_SESSION=$sid" -e "TEAM_DASH_PORT=$port" \
  "bash .claude/dashboard/serve.sh; read"
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  ! up || break
  sleep 0.5
done
if ! up; then
  echo "error: dashboard did not start on port $port:" >&2
  team_pane "$name" 10 | sed 's/^/  | /' >&2
  tmux kill-session -t "=$name" 2>/dev/null || true
  exit 1
fi
open "$url"
echo "dashboard: $url · session ${sid:-none} · tmux session '$name' (stop: /dashboard stop)"
