#!/usr/bin/env bash
# Per-target send lock: one writer of keystrokes into a role's pane at a time.
# Sourced from the MAIN checkout by team-run.sh (end_session) and team-answer.sh — a clone on an
# older base lacks this file. Bash 3.2; the caller sets its own shell options.

# Usage: team_send_lock <team dir> <role> <wait secs> <owner text> → rc 0 holding the lock;
# rc 1 prints the holder. Never reclaims a stale lock: two contenders could both end up inside.
team_send_lock() {
  local d="$1/send-$2.lock" tries=0 max p o
  max=$(( $3 * 5 ))
  until mkdir "$d" 2>/dev/null; do
    if [ "$tries" -ge "$max" ]; then
      p="$(cat "$d/pid" 2>/dev/null || echo none)"; o="$(cat "$d/owner" 2>/dev/null || echo unknown)"
      if kill -0 "$p" 2>/dev/null; then echo "pid $p ($o)"
      else echo "pid $p ($o) — stale: team-question.sh $(jq -r '.team // "<team>"' \
        "$1/team.json" 2>/dev/null || echo '<team>') unlock-send $2"; fi
      return 1
    fi
    sleep 0.2; tries=$((tries + 1))
  done
  echo $$ > "$d/pid"
  printf '%s\n' "$4" > "$d/owner"
}

team_send_unlock() {
  local d="$1/send-$2.lock"
  [ "$(cat "$d/pid" 2>/dev/null)" = "$$" ] || return 0
  rm -rf "$d"
}

team_send_holder() {
  cat "$1/send-$2.lock/owner" 2>/dev/null || echo unknown
}
