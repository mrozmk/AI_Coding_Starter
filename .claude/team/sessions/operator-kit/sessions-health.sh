#!/bin/bash
# Health check of the supervision sessions, run by a scheduler (launchd or cron) from the installed
# kit, outside the checkout: it reads only kit.conf and kit_dir (a launchd job cannot read
# ~/Desktop). One notification per outage of a role session or a team-watch loop, with the
# alarm sound; recovery clears it silently. It never restarts anything: a silent restart would
# hide a crash loop.
#
# Usage: sessions-health.sh              one check (what the scheduler runs)
#        sessions-health.sh --scheduled  exit 0 when a launchd job (LABEL) or a crontab line runs
#                                        this script, printing which; exit 1 `scheduled: none`
# The Supervisor also counts as up when a `claude --name <SUPERVISOR_NAME>` process runs (the
# `here` mode, no tmux). The name carries the project's mail suffix, so another project's
# Supervisor does not match — with an empty suffix and two projects on one machine it would.
set -u
# Appended, not prepended: a scheduler's PATH lacks the package dirs, and a caller's own tools win.
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
K="$(cd "$(dirname "$0")" && pwd)"
conf() {  # conf <KEY> → its value from kit.conf (parsed, never sourced)
  local k v
  [ -f "$K/kit.conf" ] || return 0
  while IFS='=' read -r k v; do [ "$k" = "$1" ] && { printf '%s' "$v"; return 0; }; done < "$K/kit.conf"
}
LABEL="$(conf LABEL)"

if [ "${1:-}" = --scheduled ]; then
  if [ "$(uname -s)" = Darwin ] && [ -n "$LABEL" ] && launchctl list "$LABEL" >/dev/null 2>&1; then
    echo "scheduled: launchd $LABEL"; exit 0
  fi
  if crontab -l 2>/dev/null | grep -qF "$K/sessions-health.sh"; then echo "scheduled: cron"; exit 0; fi
  echo "scheduled: none"; exit 1
fi

S="$K/sessions-health.state"
SUP="$(conf SUPERVISOR_NAME)"
down=""
for s in $(conf SESSIONS); do
  tmux has-session -t "=$s" 2>/dev/null && continue
  case "$s" in
    *-supervisor) [ -n "$SUP" ] && pgrep -f -- "^claude --name $SUP( |\$)" >/dev/null 2>&1 && continue ;;
  esac
  down="$down $s"
done
now="${down# }"
prev="$(cat "$S" 2>/dev/null || true)"
if [ -n "$now" ] && [ "$now" != "$prev" ]; then
  bash "$K/notify.sh" --alarm "$(conf PROJECT_CODE) sessions" "$now down" >/dev/null 2>&1 || true
fi
printf '%s\n' "$now" > "$S"
exit 0
