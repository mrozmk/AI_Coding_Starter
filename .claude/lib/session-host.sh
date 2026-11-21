#!/usr/bin/env bash
# The session-host driver: one seam for every terminal-multiplexer interaction of the team layer.
# Usage: bash .claude/lib/session-host.sh <verb> <address> [options]
#        bash .claude/lib/session-host.sh --check-host [--main <dir>]
#   start <address> --kind role|team|helper --cwd <dir> --cli claude|codex|script [--env K=V]…
#         [--claude-home auto] [--program <exe>] [--session-id <id>] [--wait-ready] -- <argv…>
#   alive <address>                    0 alive · 3 gone · 1 the probe failed
#   status <address>                   one JSON line {state, kind, msg, source}
#   read <address> [--lines N | --history N]
#   keys <address> [--target <pane>] <enter|esc|up|down|tab|ctrl-c|ctrl-e|ctrl-u>…
#   type <address> [--target <pane>] <text> [--enter]   herdr: typed+submitted; 9 on an open prompt
#   send <address> <one line> [--reg <registration.json>]   the doorbell
#   kill <address> [--graceful <secs>]
#   hint <address>                     one line for a human: how to look at it
# Common options: --main <main checkout> (else HARNESS_MAIN, else the git toplevel — refused in a
#   team clone), --team-dir <dir> (a team address without a record), --lock-held <owner> (the
#   caller holds the target lock), --owner <text> (the lock owner text).
# Addresses: <Role> · <team>-<role> · helper:<name> · adhoc-<handle> (registry only).
# Backend: teams.session_host = auto | herdr | tmux (TEAM_SESSION_HOST overrides); auto = herdr when
#   its core answers, else tmux. Each session keeps the backend recorded at its start (herdr: its handle).
# Exit codes: 0 ok · 2 usage · 3 gone · 6 no host · 9 blocked · 10 skipped (lock held, input not
#   safe) · 1 other failure.
#   e.g. bash .claude/lib/session-host.sh alive alfa-coder
#        bash .claude/lib/session-host.sh send alfa-lead "inbox: accepted"
set -uo pipefail

usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "session-host: jq is required" >&2; exit 1; }
. "$(cd "$(dirname "$0")" && pwd)/session-host-lib.sh"

[ $# -ge 1 ] || usage
if [ "$1" = --check-host ]; then shift; sh_check_host "$@"; exit $?; fi
verb="$1"; shift
case "$verb" in
  start|alive|status|read|keys|type|send|kill|hint) ;;
  -h|--help|help) usage ;;
  *) echo "session-host: unknown verb '$verb'" >&2; usage ;;
esac
[ $# -ge 1 ] || usage
"sh_$verb" "$@"
exit $?
