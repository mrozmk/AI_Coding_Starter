#!/bin/bash
# PreToolUse(WebFetch, Bash) guard, team mode only: auto mode would let the classifier approve
# egress, so an unlisted WebFetch host or an egress tool in command position asks
# (lib/guard_team_egress.py, by effect: lib/guard_team_egress_classify.py, #322). Never allows;
# denies a hard deny class (body/upload from a file, /dev/tcp, a token in a URL, a download piped
# into a shell, a write into settings or a role profile, a stage's hook write outside its clone and
# starter worktree). Fail-closed: no python3 / a crash asks.
# Contract: .agents/reference/security-egress.md, .agents/reference/team-mode.md
# The Supervisor's local allow rules (main checkout only): lib/guard_team_egress_supervisor.py.
# Supervisor touch log: every Supervisor ask appends to .agents/touches/<yyyy-mm>.jsonl.

# The fail-closed ask's touch-log line (the Python writer records every other verdict). Known limit:
# the shell has no no-follow / non-blocking open, so this checks, then appends — a path swapped in
# between is not caught. Never changes the verdict.
touch_fallback() { # <rc>
  local p="${CLAUDE_PROJECT_DIR:-}" d f who machine
  [ "${TEAM_SESSION_ROLE:-}" = Supervisor ] && [ -z "${TEAM_RUN_TEAM:-}" ] && [ -n "$p" ] || return 0
  { [ -e "$p/.agents/team/session.json" ] || [ -e "$p/.agents/team/team.json" ]; } && return 0
  command -v date >/dev/null 2>&1 && command -v mkdir >/dev/null 2>&1 || return 0
  for d in "$p/.agents" "$p/.agents/touches"; do
    [ -e "$d" ] || [ -L "$d" ] || mkdir -m 700 "$d" 2>/dev/null
    [ -d "$d" ] && [ ! -L "$d" ] || return 0
  done
  f="$p/.agents/touches/$(date -u +%Y-%m 2>/dev/null).jsonl"
  { [ -L "$f" ] || [ -p "$f" ]; } && return 0
  if [ -e "$f" ]; then
    [ -f "$f" ] && command -v find >/dev/null 2>&1 \
      && [ -n "$(find "$f" -prune -links 1 2>/dev/null)" ] || return 0
  fi
  who="${USER:-}"; who="${who//[^A-Za-z0-9._-]/}"
  machine="$(hostname -s 2>/dev/null)"; machine="${machine//[^A-Za-z0-9._-]/}"
  ( umask 077
    printf '{"at":"%s","machine":"%s","who":"%s","where":"solo ?","kind":"permission","what":"guard failed to run (rc %s)","reason":"guard","answer":"","wait_s":null}\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" "${machine:0:100}" "${who:0:100}" "$1" >> "$f"
  ) 2>/dev/null
  return 0
}

# Armed in a team run (session.json / TEAM_RUN_TEAM) and in every role session (TEAM_SESSION_ROLE:
# Supervisor, TeamLead, Advisor are launched with only that).
[ -f "${CLAUDE_PROJECT_DIR:-.}/.agents/team/session.json" ] || [ -n "${TEAM_RUN_TEAM:-}" ] \
  || [ -n "${TEAM_SESSION_ROLE:-}" ] || exit 0
payload="$(cat)"
out="$(printf '%s' "$payload" | python3 -I -B "$(dirname "$0")/lib/guard_team_egress.py" 2>/dev/null)"
rc=$?
if [ "$rc" -ne 0 ]; then
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"team egress: guard failed to run (rc '"$rc"') — Operator must approve (fail-closed)."}}'
  touch_fallback "$rc"
  exit 0
fi
[ -n "$out" ] && printf '%s\n' "$out"
exit 0
