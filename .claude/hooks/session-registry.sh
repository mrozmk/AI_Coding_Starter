#!/bin/bash
# SessionStart hook (startup | resume | clear | compact) — keeps the session registry
# (<main>/.agents/team/registry/, see session-host-lib.sh) on the live session:
#
#   a session the driver started (HARNESS_ADDRESS + HARNESS_REGISTRY in its launch environment):
#     its record <address>.json gets session_id (/clear and resume issue a new one) and last_seen;
#     with Claude's messaging socket in the environment, <address>.reg.json (socket, token, pid,
#     session_id — the doorbell's registration) is written and named in the record's `reg`.
#     In a team clone the address must be the clone's own active stage (session.json team + role).
#   any other Claude session in the main checkout, inside Herdr or tmux, with no role: an ad-hoc
#     record adhoc-<handle> (handle, name, tab, cwd, session_id, claude pid) so it can be resumed
#     after a crash (`claude --resume <session_id>`); a plain terminal gets no record.
#   prune: ad-hoc records not seen for 14 days whose terminal is gone.
#
# The per-run TeamLead keeps its own hook until the TeamLead branch lands. Records hold no secret;
# the registration holds the socket token. Everything is written 0600 (umask 077), tmp + mv. The
# session id comes from the hook payload — the transcript is never read. Prints at most one line.
# Always exits 0.

IN="$(cat 2>/dev/null)"
command -v jq >/dev/null 2>&1 || exit 0
umask 077
ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
sid="$(printf '%s' "$IN" | jq -r '.session_id // empty' 2>/dev/null)"
[[ "$sid" =~ ^[A-Za-z0-9-]{8,64}$ ]] || exit 0
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# put <file> <jq filter> [jq args…] — read ({} when absent), filter, write 0600 atomically. A
# here-string, not a pipe, as in sh_record_put: no writer that SIGPIPE can kill.
put() {
  local f="$1" filter="$2" cur; shift 2
  cur="$(cat "$f" 2>/dev/null)" || cur=""
  [ -n "$cur" ] || cur='{}'
  jq "$@" "(if type == \"object\" then . else {} end) | $filter" <<<"$cur" > "$f.tmp.$$" 2>/dev/null \
    && mv "$f.tmp.$$" "$f" || rm -f "$f.tmp.$$"
}
claude_pid() {  # the nearest claude ancestor of this hook process
  local p=$$ i=0
  while [ -n "$p" ] && [ "$p" != 0 ] && [ "$p" != 1 ] && [ "$i" -lt 30 ]; do
    case "$(basename "$(ps -o comm= -p "$p" 2>/dev/null)")" in claude*) echo "$p"; return 0 ;; esac
    p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"; i=$((i + 1))
  done
}
timebox() {  # timebox <secs> <cmd…> → exit 124 on timeout (pr_timebox, team-lib.sh)
  perl -e '$t = shift; $p = fork // exit 1;
    if (!$p) { setpgrp(0, 0); exec @ARGV or exit 127 }
    $SIG{ALRM} = sub { kill "KILL", -$p; waitpid $p, 0; exit 124 };
    alarm $t; waitpid $p, 0; exit($? & 127 ? 128 + ($? & 127) : $? >> 8)' "$@"
}
tmux_name() {  # the tmux session of this pane, from $TMUX (socket,pid,index) and $TMUX_PANE
  [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ] || return 1
  tmux -S "${TMUX%%,*}" display-message -p -t "$TMUX_PANE" '#S' 2>/dev/null
}
handle_alive() {  # handle_alive <backend> <handle>
  case "$1" in
    herdr) timebox 2 "${HC_BIN:-hc}" get "$2" --json >/dev/null 2>&1 ;;
    tmux) tmux has-session -t "=$2" 2>/dev/null ;;
    *) return 1 ;;
  esac
}

# ---- 1. a session the driver started ----------------------------------------------------------
if [ -n "${HARNESS_ADDRESS:-}" ]; then
  [[ "$HARNESS_ADDRESS" =~ ^[A-Za-z0-9:_-]+$ ]] || exit 0
  REG="${HARNESS_REGISTRY:-}"
  [ -n "$REG" ] || { [ -z "${HARNESS_MAIN:-}" ] || REG="$HARNESS_MAIN/.agents/team/registry"; }
  [ -n "$REG" ] && [ -f "$REG/$HARNESS_ADDRESS.json" ] || exit 0
  if [ -f "$ROOT/.agents/team/team.json" ]; then
    # A team clone: only the clone's own active stage may move its record. The per-run TeamLead
    # (role lead) is out of this hook until the TeamLead branch lands.
    [ "${TEAM_SESSION_ROLE:-}" != TeamLead ] || exit 0
    me="$(jq -r '"\(.team // "")-\(.role // "")"' "$ROOT/.agents/team/session.json" 2>/dev/null)"
    [ "$me" = "$HARNESS_ADDRESS" ] || exit 0
  fi
  f="$REG/$HARNESS_ADDRESS.json" r=""
  if [ -n "${CLAUDE_CODE_MESSAGING_SOCKET:-}" ]; then
    r="$HARNESS_ADDRESS.reg.json"
    jq -n --arg pid "$(claude_pid)" --arg sid "$sid" --arg at "$now" '
      {socket: env.CLAUDE_CODE_MESSAGING_SOCKET, token: env.CLAUDE_CODE_MESSAGING_TOKEN,
       pid: (if $pid == "" then null else ($pid | tonumber) end), session_id: $sid,
       registered_at: $at}' > "$REG/$r.tmp.$$" 2>/dev/null \
      && mv "$REG/$r.tmp.$$" "$REG/$r" || { rm -f "$REG/$r.tmp.$$"; r=""; }
  fi
  put "$f" '.session_id = $sid | .last_seen = $at | (if $r != "" then .reg = $r else . end)' \
    --arg sid "$sid" --arg at "$now" --arg r "$r"
  exit 0
fi

# ---- 2. an ad-hoc session in the main checkout --------------------------------------------------
[ ! -f "$ROOT/.agents/team/team.json" ] || exit 0
[ -z "${TEAM_SESSION_ROLE:-}" ] || exit 0   # a role from the old launcher, not ad-hoc
[ -d "$ROOT/.agents" ] || exit 0
REG="$ROOT/.agents/team/registry"
be="" h="" name="" tab=""
if [ -n "${HC_TERMINAL_ID:-}" ] && [[ "$HC_TERMINAL_ID" =~ ^[A-Za-z0-9_/-]+$ ]]; then
  be=herdr h="$HC_TERMINAL_ID"
  j="$(timebox 2 "${HC_BIN:-hc}" get "$h" --json 2>/dev/null || true)"
  name="$(printf '%s' "$j" | jq -r '.name // empty' 2>/dev/null)"
  tab="$(printf '%s' "$j" | jq -r '.tab.name // .tab // empty | strings' 2>/dev/null)"
elif h="$(tmux_name)" && [ -n "$h" ]; then
  be=tmux name="$h"
else
  echo "ad-hoc session not registered (plain terminal)"
  exit 0
fi
a="adhoc-$(printf '%s' "$h" | tr -c 'A-Za-z0-9_-' '-')"
mkdir -p "$REG" 2>/dev/null || exit 0
f="$REG/$a.json"
rm -f "$f"   # a new session in the same terminal replaces the old record
put "$f" '{address: $a, kind: "adhoc", backend: $be, handle: $h, name: $n, tab: $t, cwd: $cwd,
    session_id: $sid, claude_pid: (if $pid == "" then null else ($pid | tonumber) end),
    started_at: $at, last_seen: $at}' \
  --arg a "$a" --arg be "$be" --arg h "$h" --arg n "$name" --arg t "$tab" --arg cwd "$ROOT" \
  --arg sid "$sid" --arg pid "$(claude_pid)" --arg at "$now"

# ---- 3. prune ad-hoc records not seen for 14 days whose terminal is gone ---------------------------
find "$REG" -maxdepth 1 -name 'adhoc-*.json' -mtime +14 2>/dev/null | while IFS= read -r o; do
  [ "$o" != "$f" ] || continue
  ob="$(jq -r '.backend // empty' "$o" 2>/dev/null)"; oh="$(jq -r '.handle // empty' "$o" 2>/dev/null)"
  [ -n "$oh" ] && handle_alive "$ob" "$oh" && continue
  rm -f "$o"
done
exit 0
