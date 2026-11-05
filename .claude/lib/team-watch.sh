#!/usr/bin/env bash
# Durable team monitor: pushes team signals into the role sessions over Claude Code's messaging
# socket (one daemon + watchdog per checkout, tmux <tmux_prefix>-team-watch[-dog]).
# Usage: bash .claude/lib/team-watch.sh start [--no-register]|register [--takeover]
#          |status [--open]|stop|mode tiers on|off|mode answering on|off
#          |mode class <name> on|off
#        bash .claude/lib/team-watch.sh ack <n>|done <n>|ping <role>|pending <role> [<since UTC>]
#          |routing split|routing single <role>|stats [--since <UTC>]
#        bash .claude/lib/team-watch.sh run|dog|tick --once|signals
#        bash .claude/lib/team-watch.sh [--once] <team> [team...]   (the poller, team-watch-poll.sh)
#   e.g. bash .claude/lib/team-watch.sh ack 42     (first action on a [team-watch #42] message)
#   roles: Supervisor TeamLead. `team-watch.sh pending` and `team-watch.sh status` take no lock and
#   return at once (the Stop hooks call them).
# Runbook: .agents/reference/team-watch.md.
set -euo pipefail

usage() { sed -n '4,14p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
[ $# -ge 1 ] || usage
# Anything that is not a subcommand is a team list for the no-daemon poller (/monitor without a
# daemon, and the rollback target).
case "$1" in
  start|register|status|stop|mode|ack|done|ping|pending|routing|stats|run|dog|tick|signals) ;;
  -h|--help) usage ;;
  *) exec bash "$(dirname "$0")/team-watch-poll.sh" "$@" ;;
esac
. "$(dirname "$0")/team-watch-lib.sh"
tw_init "$(git rev-parse --show-toplevel)" || exit 3
cmd="$1"; shift

if [ "$cmd" != status ] && [ -f "$root/.agents/team/team.json" ]; then
  echo "error: team clone — run team-watch from the main checkout" >&2; exit 1
fi

DAEMON="$(tw_tmux_name daemon)"
DOG="$(tw_tmux_name dog)"

ago() {  # ago <beat file> → "<UTC> (<age>s)" or "none"
  local t
  t="$(cut -d' ' -f1 "$TW_DIR/$1" 2>/dev/null)" || t=""
  [[ "$t" =~ ^[0-9]+$ ]] || { echo none; return 0; }
  echo "$(tw_iso "$t") ($(tw_age "$1")s)"
}

# launch <session> <loop> <beat> <alarm flag> — keep a live loop with a fresh beat of this
# version, else restart it: an older loop keeps its once-sourced functions.
launch() {
  local e=() v
  if team_tmux_alive "$1" && tw_current "$3"; then return 0; fi
  ! team_tmux_alive "$1" || tmux kill-session -t "=$1"
  rm -f "$TW_DIR/$3" "$TW_DIR/$4"
  for v in TEAM_WATCH_SECS TEAM_WATCH_REMIND_SECS TEAM_WATCH_UNDELIVERED_SECS \
    TEAM_WATCH_SEND_SECS TEAM_WATCH_PICKUP_SECS TEAM_WATCH_ESC_UNSENT_SECS \
    TEAM_WATCH_PROGRESS_SECS CLAUDE_CONFIG_DIR TEAM_NOTIFY TEAM_NOTIFY_SOUND \
    TEAM_NOTIFY_SOUND_ALARM TEAM_WATCH_ROTATE_BYTES TEAM_WATCH_KEEP_SECS \
    TEAM_WATCH_BATCH_MAX TEAM_WATCH_BATCH_BYTES TEAM_WATCH_BACKLOG_MAX; do
    # Set-but-empty is forwarded: TEAM_NOTIFY_SOUND= means "no sound", not "default".
    [ -z "${!v+x}" ] || e+=(-e "$v=${!v}")
  done
  # `; read` keeps the pane after a crash, so its error can be shown. The loop runs outside any
  # Claude session: a launching session's identity and socket must not leak into it.
  tmux new-session -d -s "$1" -c "$root" ${e[@]+"${e[@]}"} \
    "env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN bash .claude/lib/team-watch.sh $2; read"
}

# Loops of another version stop before the new ones start.
upgrade() {
  local s b
  for s in "$DAEMON:beat" "$DOG:dog.beat"; do
    b="${s#*:}"; s="${s%%:*}"
    ! team_tmux_alive "$s" || tw_current "$b" || tmux kill-session -t "=$s"
  done
}

start() {
  local t n=0
  for t in tmux jq python3; do
    command -v "$t" >/dev/null 2>&1 || { echo "error: $t not on PATH" >&2; exit 1; }
  done
  upgrade
  # Loops only: the launcher's form, also usable from a session without a role.
  if [ "${1:-}" = --no-register ]; then shift; else tw_register "$@"; fi
  # Claims whose owner died (a killed loop) must not block the new loops.
  for t in lock.d send.d; do
    [ ! -d "$TW_DIR/$t" ] || kill -0 "$(cat "$TW_DIR/$t/pid" 2>/dev/null || echo x)" 2>/dev/null \
      || rm -rf "${TW_DIR:?}/$t"
  done
  launch "$DAEMON" run beat alarm.daemon
  launch "$DOG" dog dog.beat alarm.dog
  until tw_fresh beat && tw_fresh dog.beat; do
    if [ "$n" -ge $(( 3 * TW_SECS * 2 )) ]; then
      echo "error: team-watch loops did not beat within $(( 3 * TW_SECS ))s:" >&2
      for t in "$DAEMON" "$DOG"; do team_pane "$t" 10 | sed "s/^/  $t | /" >&2; done
      exit 1
    fi
    sleep 0.5; n=$((n + 1))
  done
  status
}

receiver_lines() {
  local f n=0
  for f in "$TW_DIR"/receivers/*.json; do
    [ -f "$f" ] || continue
    n=$((n + 1)); tw_receiver_line "$(basename "$f" .json)"
  done
  [ "$n" -gt 0 ] || echo "receiver: none registered"
}

undelivered_lines() {
  local f r
  for f in "$TW_DIR"/receivers/*.json; do
    [ -f "$f" ] || continue
    r="$(basename "$f" .json)"
    if [ -f "$TW_DIR/undelivered.$r.since" ]; then
      echo "undelivered $r: $(jq -s --arg r "$r" --argjson c "$(tw_cursor "$r")" \
        'map(select(.to == $r and .seq > $c)) | length' "$TW_DIR/events.jsonl")" \
        "(oldest $(( $(tw_now) - $(cat "$TW_DIR/undelivered.$r.since") ))s)"
    else
      echo "undelivered $r: 0"
    fi
  done
}

open_line() {
  jq -r '(.keys // {}) | keys | map(split(":")[0]) as $k
    | def n($p): $k | map(select(. == $p)) | length;
    "open: \($k | length) (attention \(n("att")), record \(n("rec")), runner \(n("run")),"
    + " ready \(n("ready")), mail \(n("mail")), error \(n("err")))"' \
    "$TW_DIR/open.json" \
    2>/dev/null \
    || echo "open: 0"
}

mail_line() {  # a mail error key stays open while that probe's last run failed
  [ -f "$root/.agents/team/watch.local.json" ] || { echo "mail: not configured"; return 0; }
  jq -r '[(.keys // {}) | keys[] | select(startswith("err:mail"))] as $e
    | if $e == [] then "mail: ok"
      else "mail: failed (\($e | map(ltrimstr("err:mail") | ltrimstr(":")
        | if . == "" then "single" else . end) | join(", "))) — see open signals" end' \
    "$TW_DIR/open.json" 2>/dev/null || echo "mail: ok"
}

notifier_line() {  # the backend's state from the kit's notify.sh, else the declared loss
  local k="$root/.claude/team/sessions/operator-kit/notify.sh" l
  if [ -f "$k" ]; then
    l="$(bash "$k" --check --backend "$TEAM_CHANNEL_NOTIFIER" 2>/dev/null | head -n 1)" || l=""
    echo "${l:-notifier: $TEAM_CHANNEL_NOTIFIER — notify.sh --check printed nothing}"
  else
    team_channel_loss_line
  fi
}

status() {
  local rc=0
  if tw_fresh beat && tw_fresh dog.beat; then
    echo "team-watch: works"
  else
    echo "team-watch: not working"; rc=1
  fi
  echo "daemon: last beat $(ago beat)"
  echo "dog: last beat $(ago dog.beat)"
  echo "routing: $(tw_routing)"
  receiver_lines
  undelivered_lines
  mail_line
  notifier_line
  echo "tiers: $(tw_tiers)"
  echo "answering: $(tw_answering)"
  echo "classes: $(python3 -I "$(dirname "$0")/team_prompt_classes.py" switches "$root")"
  echo "paused: $(s="$(tw_state_json)" && jq -r '[(.paused // {}) | to_entries[]
    | select(.value != "")
    | "\(.key) since \(.value | if type == "object" then "\(.since) (\(.by))" else . end)"]
    | if . == [] then "none" else join(", ") end' <<<"$s" 2>/dev/null \
    || echo "unreadable (state.json)")"
  open_line
  [ "${1:-}" != --open ] || cat "$TW_DIR/open.txt" 2>/dev/null || true
  return "$rc"
}

stop() {
  local f
  ! team_tmux_alive "$DOG" || tmux kill-session -t "=$DOG"
  ! team_tmux_alive "$DAEMON" || tmux kill-session -t "=$DAEMON"
  if tw_lock; then
    for f in "$TW_DIR"/receivers/*.json; do
      [ -f "$f" ] || continue
      jq '.active = false' "$f" | ( umask 077; tw_put "$f" )
    done
    tw_unlock
  fi
  echo "team-watch: stopped"
}

loop() {  # loop run|dog
  local n=0
  while :; do
    n=$((n + 1))
    if [ "$1" = run ]; then
      tw_beat beat "$n"
      tw_tick || tw_log "cycle $n: tick failed"
      tw_check_receivers || tw_log "cycle $n: receiver check failed"
      tw_check_peer dog.beat alarm.dog dog || tw_log "cycle $n: dog check failed"
      tw_rotate || tw_log "cycle $n: rotate failed"
    else
      tw_beat dog.beat "$n"
      tw_check_peer beat alarm.daemon daemon || tw_log "cycle $n: daemon check failed"
    fi
    sleep "$TW_SECS"
  done
}

# Read-merge-write under the lock, so two concurrent switches never lose each other's restriction.
refuse_state() {  # a broken state.json may hold a pause — never rewrite it
  tw_unlock
  echo "error: state.json unreadable — fix it by hand" >&2
  exit 1
}

set_mode() {  # set_mode <tiers|answering> <on|off>
  local s
  tw_lock || { echo "error: team-watch state lock busy" >&2; exit 1; }
  s="$(tw_state_json)" || refuse_state
  jq --arg k "$1" --arg v "$2" '.[$k] = $v' <<<"$s" | tw_put "$TW_DIR/state.json"
  tw_unlock
  echo "team-watch: $1 $2"
}

set_class() {  # set_class <name> <on|off> — a tier-1 class switch, same lock as set_mode
  local s
  tw_lock || { echo "error: team-watch state lock busy" >&2; exit 1; }
  s="$(tw_state_json)" || refuse_state
  jq --arg n "$1" --arg v "$2" \
    '.classes = ((.classes | if type == "object" then . else {} end) + {($n): $v})' <<<"$s" \
    | tw_put "$TW_DIR/state.json"
  tw_unlock
  echo "team-watch: class $1 $2"
}

case "$cmd" in
  start) start "$@" ;;
  register) tw_register "$@" ;;
  status) status "${1:-}" ;;
  stop) stop ;;
  mode)
    if [ "${1:-}" = class ]; then
      case " $TEAM_CLASSES " in *" ${2:-x} "*) ;; *) usage ;; esac
      [[ "${3:-}" =~ ^(on|off)$ ]] || usage
      set_class "$2" "$3"
    else
      [[ "${1:-}" =~ ^(tiers|answering)$ ]] && [[ "${2:-}" =~ ^(on|off)$ ]] || usage
      set_mode "$1" "$2"
    fi ;;
  ack|done)
    [[ "${1:-}" =~ ^[0-9]+$ ]] || usage
    if [ "$cmd" = ack ]; then tw_ack picked "$1"; else tw_ack done "$1"; fi ;;
  ping|pending)
    tw_role_ok "${1:-}" || usage
    [ -z "${2:-}" ] || [[ "$2" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$ ]] || usage
    if [ "$cmd" = ping ]; then tw_ping "$1"; else tw_pending "$1" "${2:-}"; fi ;;
  routing) tw_handover "$@" ;;
  stats) tw_stats "$@" ;;
  run|dog) loop "$cmd" ;;
  tick)
    [ "${1:-}" = --once ] || usage
    tw_beat beat 0
    tw_tick ;;
  signals)
    w="$(mktemp -d "$TW_DIR/work.XXXXXX")"
    trap 'rm -rf "$w"' EXIT
    tw_signals "$w"
    jq . "$w/sig.json" ;;
  *) usage ;;
esac
