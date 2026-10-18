#!/usr/bin/env bash
# Open a new Terminal window attached to a team's tmux session (the planner, or a role that waits).
#
# Usage: bash .claude/lib/team-attach.sh <team> [planner|coder|qa|wrapup|cli|runner] [wait-seconds]
#   e.g. bash .claude/lib/team-attach.sh alfa planner 60
#   bash .claude/lib/team-attach.sh --close <tty>   (internal: the closer)
#
# Waits up to wait-seconds (default 0) for the session to appear. Detach in the window with Ctrl-b d.
# The window runs `exec tmux attach`, and a detached closer shuts it once no process is left on its
# tty — after the role ends or after Ctrl-b d (TT-790).
set -euo pipefail

if [ "${1:-}" = --close ]; then
  [ $# -eq 2 ] && [[ "$2" =~ ^/dev/ttys[0-9]+$ ]] || exit 2
  # The tty holds login/zsh until exec and the tmux client after it: empty means done.
  while [ -n "$(ps -t "${2#/dev/}" -o pid= 2>/dev/null || true)" ]; do
    sleep "${TEAM_ATTACH_POLL:-2}"
  done
  # By tty, not window id: an id read after `do script` can belong to another team's window.
  # Single-tab only: macOS tabbing can open the role as a tab, and `close w` would take its siblings.
  osascript -e 'on run argv' -e 'tell application "Terminal"' \
    -e 'repeat with w in windows' \
    -e 'if (count of tabs of w) is 1 and (tty of tab 1 of w) is (item 1 of argv) then close w' \
    -e 'end repeat' -e 'end tell' -e 'end run' "$2" >/dev/null 2>&1 || true
  exit 0
fi

if [ $# -lt 1 ] || [ $# -gt 3 ]; then
  sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
fi
name="$1-${2:-planner}"; wait="${3:-0}"
[[ "$name" =~ ^[a-z0-9-]+$ ]] || { echo "error: bad session name $name" >&2; exit 2; }

waited=0
until tmux has-session -t "=$name" 2>/dev/null; do
  [ "$waited" -lt "$wait" ] || { echo "error: tmux session $name not found" >&2; exit 1; }
  sleep 1; waited=$((waited + 1))
done
# The session's own server socket, resolved before the window opens. The Terminal window starts
# from the user's login shell, without this project's TMUX_TMPDIR, so a bare `tmux attach` would
# reach the DEFAULT server and could attach to a same-named session of another project entirely.
# Pane form `=NAME:` — tmux finds no target for the session-only `=NAME` (team-lib.sh → team_pane).
# Fail closed: the caller degrades a failure to `warn: no preview window` (team-run.sh → launch).
sock="$(tmux display-message -p -t "=$name:" '#{socket_path}' 2>/dev/null || true)"
if [ -z "$sock" ]; then
  echo "error: cannot resolve the tmux socket of $name" >&2
  exit 1
fi
# Quoted: the window's interactive zsh treats a bare =NAME as an EQUALS command lookup.
out="$(osascript -e 'tell application "Terminal"' \
  -e "set t to do script \"exec tmux -S '$sock' attach -t '=$name'\"" \
  -e 'activate' \
  -e 'return tty of t' \
  -e 'end tell')"
if [[ "$out" =~ ^/dev/ttys[0-9]+$ ]]; then
  nohup bash "$0" --close "$out" >/dev/null 2>&1 &
else
  echo "warn: window opened but will not close by itself (osascript said: ${out:-nothing})"
fi
echo "opened: Terminal window attached to $name (detach: Ctrl-b d)"
