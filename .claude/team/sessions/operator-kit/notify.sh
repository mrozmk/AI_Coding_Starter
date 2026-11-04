#!/usr/bin/env bash
# The one platform notifier of the supervision roles. Used in sessions (from this template, in the
# checkout) and by the out-of-repo health check (from the installed copy in <kit_dir>).
#
# Usage: notify.sh [--backend osascript|notify-send|none] [--alarm] <title> <message>
#        notify.sh --check [--backend <b>]      one line: the backend's state (always exit 0)
# Backend: --backend, else $TEAM_NOTIFIER, else NOTIFIER= in a kit.conf next to this script,
# else none. --alarm uses TEAM_NOTIFY_SOUND_ALARM (default Sosumi), otherwise TEAM_NOTIFY_SOUND
# (default silent); set-but-empty is silence. Title and message lose `"` and `\`, newlines become
# spaces, both are cut to 200 characters.
# Always exits 0 and never types into a session: a missing binary is silent here and visible
# only through --check. `none` is a declared loss, not a neutral choice: alarms about the
# Supervisor itself, and a dead tmux server, then reach nobody.
# Bash 3.2 compatible (macOS /bin/bash).

backend="" alarm="" check=""
while [ $# -gt 0 ]; do
  case "$1" in
    --backend) backend="${2:-}"; shift 2 || shift ;;
    --alarm) alarm=1; shift ;;
    --check) check=1; shift ;;
    *) break ;;
  esac
done

conf_notifier() {  # NOTIFIER= from a kit.conf next to this script; parsed, never sourced
  local f k v
  f="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/kit.conf"
  [ -f "$f" ] || return 0
  while IFS='=' read -r k v; do
    [ "$k" = NOTIFIER ] && { printf '%s' "$v"; return 0; }
  done < "$f"
}
[ -n "$backend" ] || backend="${TEAM_NOTIFIER:-}"
[ -n "$backend" ] || backend="$(conf_notifier)"
[ -n "$backend" ] || backend=none

bin_of() { case "$1" in osascript) echo osascript ;; notify-send) echo notify-send ;; *) echo "" ;; esac; }

if [ -n "$check" ]; then
  case "$backend" in
    none) echo "notifier: none — declared loss: alarms about the Supervisor itself and a dead tmux server reach nobody" ;;
    osascript|notify-send)
      if command -v "$(bin_of "$backend")" >/dev/null 2>&1; then echo "notifier: $backend ok"
      else echo "notifier: $backend missing $(bin_of "$backend")"; fi ;;
    *) echo "notifier: $backend unknown — declared loss: nothing is notified" ;;
  esac
  exit 0
fi

clean() { printf '%s' "$1" | tr '\n' ' ' | tr -d '"\\' | cut -c1-200; }
title="$(clean "${1:-}")" msg="$(clean "${2:-}")"
[ -n "$title$msg" ] || exit 0

if [ -n "$alarm" ]; then snd="${TEAM_NOTIFY_SOUND_ALARM-Sosumi}"; else snd="${TEAM_NOTIFY_SOUND:-}"; fi
snd="$(printf '%s' "$snd" | tr -cd 'A-Za-z0-9 ')"

case "$backend" in
  osascript)
    command -v osascript >/dev/null 2>&1 || exit 0
    s=""; [ -z "$snd" ] || s=" sound name \"$snd\""
    osascript -e "display notification \"$msg\" with title \"$title\"$s" >/dev/null 2>&1 || true ;;
  notify-send)
    command -v notify-send >/dev/null 2>&1 || exit 0
    u=normal; [ -z "$alarm" ] || u=critical
    notify-send -u "$u" -- "$title" "$msg" >/dev/null 2>&1 || true ;;
esac
exit 0
