#!/usr/bin/env bash
# Open a preview attached to a team's tmux session (the planner, or a role that waits): a tab in
# Herdr when the main checkout is open there as a space, otherwise a new Terminal.app window.
#
# Usage: bash .claude/lib/team-attach.sh <team> [planner|coder|qa|wrapup|cli|runner] [wait-seconds]
#   e.g. bash .claude/lib/team-attach.sh alfa planner 60
#   bash .claude/lib/team-attach.sh --close <tty>   (internal: the closer)
#
# Waits up to wait-seconds (default 0) for the session to appear. Detach in the window with Ctrl-b d.
# The window runs `exec tmux attach`, and a detached closer shuts it once no process is left on its
# tty — after the role ends or after Ctrl-b d.
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
# Herdr first: when a running Herdr window shows the main checkout as a space, the preview is a pane
# in that space's `Teams` tab — one tab for every team, one terminal per running role, each named
# `<project>-<team>-<role>` so the tab says which pane is whose.
# Detected through the window, not through HC_* variables: the runner's tmux session carries none.
# The terminal is started by `hc run` with the space (and, when the Teams tab exists, the tab)
# label, never by `tab.new`, which wraps the program in a login shell that stays after `attach`
# ends; an hc terminal ends with its program, so the pane closes itself and no closer is needed.
# argv is passed as arguments, no quoting layer. Any failure falls through to Terminal.app.
if command -v herdr-app >/dev/null 2>&1 && command -v hc >/dev/null 2>&1 \
  && command -v jq >/dev/null 2>&1; then
  tab_name="${TEAM_ATTACH_TAB:-Teams}"
  # The main checkout is where this script lives, never the caller's cwd: the runner launches roles
  # from the team's clone, whose folder is no Herdr space (that would send every role to Terminal).
  root="$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd -P || true)"
  space="$(herdr-app ls 2>/dev/null \
    | jq -r --arg f "$root" '[.spaces[]? | select(.folder == $f)][0].id // empty' 2>/dev/null || true)"
  if [ -n "$space" ]; then
    tab="$(herdr-app ls 2>/dev/null | jq -r --arg s "$space" --arg n "$tab_name" \
      '[.spaces[]? | select(.id == $s) | .tabs[]? | select(.name == $n)][0].id // empty' 2>/dev/null || true)"
    labels=(--label "herdr.space=$space")
    [ -z "$tab" ] || labels+=(--label "herdr.tab=$tab")
    # Named `<project>-<team>-<role>` (project = the main checkout's folder, lowercased) so the pane
    # says which project and team it belongs to even among several projects' teams; an hc name is
    # 1–32 of a-z 0-9 - _ and unique among live terminals, so a leftover pane with that name means a
    # second, unnamed try.
    tname="$(printf '%s' "$(basename "$root")" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '-')-$name"
    addr="$(hc run --bg --outlive-parent --cwd "$root" --name "${tname:0:32}" "${labels[@]}" \
      -- tmux -S "$sock" attach -t "=$name" 2>/dev/null | jq -r '.address // empty' 2>/dev/null || true)"
    [ -n "$addr" ] || addr="$(hc run --bg --outlive-parent --cwd "$root" "${labels[@]}" \
      -- tmux -S "$sock" attach -t "=$name" 2>/dev/null | jq -r '.address // empty' 2>/dev/null || true)"
    if [ -n "$addr" ]; then
      if [ -z "$tab" ]; then
        # The new tab is created by the window after the terminal appears: resolve it by the
        # terminal's address, then name it so the next role, of any team, finds it.
        for _ in 1 2 3 4 5; do
          tab="$(herdr-app ls 2>/dev/null | jq -r --arg t "$addr" \
            '[.spaces[]?.tabs[]? | select(any(.terminals[]?; .terminal == $t))][0].id // empty' 2>/dev/null || true)"
          [ -z "$tab" ] || break
          sleep 1
        done
        [ -z "$tab" ] || herdr-app do tab.rename --id "$tab" --name "$tab_name" >/dev/null 2>&1 || true
      fi
      echo "opened: Herdr tab $tab_name, pane ${tname:0:32} (detach: Ctrl-b d)"
      exit 0
    fi
    echo "warn: Herdr pane for $name failed; opening a Terminal window instead" >&2
  fi
fi
# The socket path (from TMUX_TMPDIR) and the name go into an AppleScript string that holds a
# single-quoted shell word: a quote or backslash in either would break out of both. Refused, not
# escaped — two quoting layers are easy to get wrong, and the caller degrades to a warning.
case "$sock$name" in *[\'\"\\]*)
  echo "error: the tmux socket path or session name of $name contains a quote or backslash" >&2
  exit 1 ;;
esac
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
