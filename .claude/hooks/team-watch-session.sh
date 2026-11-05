#!/bin/bash
# SessionStart hook — keeps team-watch pointed at this role's current messaging socket.
#
# Problem it solves: after /clear, resume or compact a receiver may get a new socket/token, and
# team-watch would push into a dead one. Re-registers only this session's own receiver
# (TEAM_SESSION_ROLE, else the single-routing receiver — the single window) and only for the same
# claude pid, never another window. No-op when hooks do not inherit the CLAUDE_CODE_MESSAGING_*
# env or team-watch has no state here. Prints nothing (stdout would enter the context) and always
# exits 0.

command -v jq >/dev/null 2>&1 || exit 0
ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
[ ! -f "$ROOT/.agents/team/team.json" ] || exit 0
[ -d "$ROOT/.agents/team/watch" ] || exit 0
[ -n "${CLAUDE_CODE_MESSAGING_SOCKET:-}" ] && [ -n "${CLAUDE_CODE_MESSAGING_TOKEN:-}" ] || exit 0
[ -S "$CLAUDE_CODE_MESSAGING_SOCKET" ] || exit 0

{
  . "$(dirname "$0")/../lib/team-watch-lib.sh"
  tw_init "$ROOT" || exit 0
  TW_LOCK_SECS=3   # inside the hook's 5 s timeout
  role="$(tw_self_role 2>/dev/null)" || exit 0
  F="$(tw_receiver_file "$role")"
  [ -f "$F" ] || exit 0
  reg="$(jq -c 'select(.active == true) | {pid, id, socket, token}' "$F" 2>/dev/null)"
  [ -n "$reg" ] || exit 0
  pid="$(tw_sock_pid)"
  [ -n "$pid" ] && [ "$pid" = "$(jq -r '.pid // empty' <<<"$reg")" ] || exit 0
  jq -e '.socket == env.CLAUDE_CODE_MESSAGING_SOCKET
    and .token == env.CLAUDE_CODE_MESSAGING_TOKEN' \
    <<<"$reg" >/dev/null && exit 0
  tw_lock || exit 0
  # A takeover between the first read and the lock wins.
  now="$(jq -c 'select(.active == true) | {pid, id}' "$F" 2>/dev/null)"
  if [ "$now" = "$(jq -c '{pid, id}' <<<"$reg")" ]; then
    tw_write_registration "$F" "$pid" "$(tw_now)-$$" "$role" && tw_supersede "$role"
  fi
  tw_unlock
} >/dev/null 2>&1
exit 0
