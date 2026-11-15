#!/usr/bin/env bash
# The session-host driver, sourced form: every interaction with the terminal multiplexer goes
# through these functions (CLI: session-host.sh). Backends: tmux (this release); herdr is resolved
# but refused with exit 6 "not yet supported". Bash 3.2; sourced, never executed — the lib sets no
# shell options, callers run under their own.
#
# Addresses (the harness's names) → tmux session names, today's names exactly:
#   <Role> (leading capital)  → <tmux_prefix>-<role lowercase>   (tw_tmux_name)
#   <team>-<role>             → the same string                 (team_tmux_name)
#   helper:<name>             → <name>                          (team-watch daemon, retro-<run>)
#   adhoc-<handle>            → registry only, never started
# Exit codes: 0 ok · 2 usage · 3 gone · 6 no host · 9 blocked · 10 skipped (lock held, input not
# safe) · 1 other.
# Registry: <main>/.agents/team/registry/<address>.json, one per address, tmp + mv. A verb on an
# address without a record uses tmux (sessions started before the driver).
# Contract: .agents/reference/session-host.md (written with the Herdr backend).

SH_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SH_LIB/team-send-lock.sh"

sh_err() { echo "session-host: $*" >&2; }
sh_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# sh_main_root [dir] → the main checkout: dir → HARNESS_MAIN → parent of HARNESS_REGISTRY → the git
# toplevel, which is refused inside a team clone (its own registry would be the wrong one).
sh_main_root() {
  local d="${1:-}"
  [ -n "$d" ] || d="${HARNESS_MAIN:-}"
  if [ -z "$d" ] && [ -n "${HARNESS_REGISTRY:-}" ]; then d="${HARNESS_REGISTRY%/.agents/team/registry}"; fi
  if [ -z "$d" ]; then
    d="$(git rev-parse --show-toplevel 2>/dev/null)" \
      || { sh_err "not inside a git checkout — pass --main <main checkout>"; return 2; }
    [ ! -f "$d/.agents/team/team.json" ] \
      || { sh_err "team clone — pass --main or set HARNESS_MAIN"; return 2; }
  fi
  [ -d "$d/.agents" ] || { sh_err "$d is not a checkout with .agents/"; return 2; }
  (cd "$d" && pwd)
}

# sh_kind <address> → role | team | helper | adhoc; rc 2 for a malformed address.
sh_kind() {
  [[ "$1" =~ ^[A-Za-z0-9:_-]+$ ]] || { sh_err "address '$1' must match [A-Za-z0-9:_-]+"; return 2; }
  case "$1" in
    helper:*) [[ "${1#helper:}" =~ ^[A-Za-z0-9_-]+$ ]] \
                || { sh_err "helper name '${1#helper:}' must match [A-Za-z0-9_-]+"; return 2; }
              echo helper ;;
    adhoc-*) echo adhoc ;;
    # An explicit list: under many locales [A-Z] collates lowercase letters in (b..z).
    [ABCDEFGHIJKLMNOPQRSTUVWXYZ]*)
      [[ "$1" =~ ^[A-Za-z0-9]+$ ]] || { sh_err "role '$1' must match [A-Za-z0-9]+"; return 2; }
      echo role ;;
    *:*) sh_err "address '$1': only helper: may carry a colon"; return 2 ;;
    *-*) echo team ;;
    *) sh_err "address '$1' is neither a role, <team>-<role>, helper:<name> nor adhoc-<handle>"
       return 2 ;;
  esac
}

# sh_name <main> <address> → the session name (step 2 replaces this builder with the prefixed one).
sh_name() {
  local k; k="$(sh_kind "$2")" || return 2
  case "$k" in
    helper) printf '%s\n' "${2#helper:}" ;;
    role)
      . "$SH_LIB/team-channel.sh"
      team_channel_names "$1" || return 2
      printf '%s-%s\n' "$TEAM_CHANNEL_TMUX_PREFIX" "$(echo "$2" | tr '[:upper:]' '[:lower:]')" ;;
    *) printf '%s\n' "$2" ;;
  esac
}

sh_reg_dir() { printf '%s/.agents/team/registry\n' "$1"; }
sh_record_file() { printf '%s/%s.json\n' "$(sh_reg_dir "$1")" "$2"; }

# sh_record_get <main> <address> <field> → the value, empty when absent.
sh_record_get() {
  jq -r --arg f "$3" '.[$f] // empty | tostring' "$(sh_record_file "$1" "$2")" 2>/dev/null || true
}

# sh_record_put <main> <address> <jq filter> [jq args…] — read ({} when absent), filter, write.
# Registry files are 0600 and the directory 0700: records hold no secret, but registrations hold
# the messaging-socket token, and both live side by side. The record reaches jq as a here-string,
# not through a pipe: under the CLI's pipefail a writer killed by SIGPIPE (jq done before it
# finished) would fail the write while jq itself succeeded.
sh_record_put() {
  local f filter="$3" cur; f="$(sh_record_file "$1" "$2")"; shift 3
  cur="$(cat "$f" 2>/dev/null)" || cur=""
  [ -n "$cur" ] || cur='{}'
  ( umask 077
    mkdir -p "$(dirname "$f")" || exit 1
    jq "$@" "(if type == \"object\" then . else {} end) | $filter" <<<"$cur" > "$f.tmp.$$" \
      && mv "$f.tmp.$$" "$f" || { rm -f "$f.tmp.$$"; exit 1; } )
}

# The tmux binary. Under TEAM_SMOKE=1 only a binary inside TEAM_SMOKE_BIN_DIR runs: a fixture must
# never reach the machine's real server.
sh_tmux_path() {
  local b="${TMUX_BIN:-tmux}" p d
  p="$(command -v "$b" 2>/dev/null || true)"
  [ -n "$p" ] || { sh_err "tmux not found ($b)"; return 1; }
  if [ "${TEAM_SMOKE:-}" = 1 ]; then
    d="${TEAM_SMOKE_BIN_DIR:-}"
    if [ -z "$d" ] || [ "$(cd "$(dirname "$p")" && pwd -P)" != "$(cd "$d" 2>/dev/null && pwd -P)" ]; then
      sh_err "refusing $p under TEAM_SMOKE=1 (not in TEAM_SMOKE_BIN_DIR)"
      return 1
    fi
  fi
  echo "$p"
}
sh_tmux() {
  local p; p="$(sh_tmux_path)" || return 1
  "$p" "$@"
}

# sh_configured_host <main> → auto | herdr | tmux (TEAM_SESSION_HOST wins over the profile key).
sh_configured_host() {
  local v="${TEAM_SESSION_HOST:-}"
  [ -n "$v" ] || v="$(jq -r '.teams.session_host // "auto"' "$1/.claude/project-profile.json" 2>/dev/null || true)"
  [ -n "$v" ] || v=auto
  case "$v" in
    auto|herdr|tmux) echo "$v" ;;
    *) sh_err "teams.session_host=$v must be auto|herdr|tmux"; return 2 ;;
  esac
}

# sh_pick_host <main> → the backend a fresh start uses; rc 6 when there is none.
sh_pick_host() {
  local h; h="$(sh_configured_host "$1")" || return $?
  if [ "$h" = herdr ]; then sh_err "teams.session_host=herdr: not yet supported"; return 6; fi
  command -v "${TMUX_BIN:-tmux}" >/dev/null 2>&1 \
    || { sh_err "no session host: install tmux or Herdr"; return 6; }
  echo tmux
}

# sh_backend <main> <address> [--for-start] → the backend of this session.
# Existing session: its record's backend (no record → tmux, a session from before the driver).
# A fresh start after the previous instance is gone: the configured backend, not the old record's.
sh_backend() {
  local b; b="$(sh_record_get "$1" "$2" backend)"
  if [ "${3:-}" = --for-start ]; then
    if [ "$b" = tmux ] && sh_tmux_alive "$(sh_name "$1" "$2")" 2>/dev/null; then echo tmux; return 0; fi
    sh_pick_host "$1"; return $?
  fi
  case "${b:-tmux}" in
    tmux) echo tmux ;;
    herdr) sh_err "$2: recorded on herdr — not yet supported"; return 6 ;;
    *) sh_err "$2: unknown backend '$b' in its registry record"; return 1 ;;
  esac
}

# --- locks: one target lock per address --------------------------------------------------------
# Team address: team_send_lock <team dir> <role> (today's send lock). Role or helper:
# <registry>/<address>.lock with the same mkdir primitive. Like team_send_lock, a stale lock is
# never reclaimed automatically — two contenders could both end up inside; the holder is named.

sh_team_dir() {  # sh_team_dir <main> <address> [--team-dir value] → the team dir of a team address
  local td="${3:-}"
  [ -n "$td" ] || td="$(sh_record_get "$1" "$2" team_dir)"
  printf '%s\n' "$td"
}

# sh_lock <main> <address> <team dir> <owner> <wait secs> → rc 0 holding; rc 1 prints the holder.
sh_lock() {
  local d tries=0 max p o
  if [ "$(sh_kind "$2")" = team ]; then
    [ -n "$3" ] || { echo "no team dir for $2 (no record, no --team-dir)"; return 1; }
    team_send_lock "$3" "${2##*-}" "$5" "$4"; return $?
  fi
  d="$(sh_reg_dir "$1")/$2.lock"; max=$(( $5 * 5 ))
  mkdir -p "$(dirname "$d")" || return 1
  until mkdir "$d" 2>/dev/null; do
    if [ "$tries" -ge "$max" ]; then
      p="$(cat "$d/pid" 2>/dev/null || echo none)"; o="$(cat "$d/owner" 2>/dev/null || echo unknown)"
      if kill -0 "$p" 2>/dev/null; then echo "pid $p ($o)"
      else echo "pid $p ($o) — stale: rm -rf $d"; fi
      return 1
    fi
    sleep 0.2; tries=$((tries + 1))
  done
  echo $$ > "$d/pid"
  printf '%s\n' "$4" > "$d/owner"
}

sh_unlock() {  # sh_unlock <main> <address> <team dir>
  local d
  if [ "$(sh_kind "$2")" = team ]; then team_send_unlock "$3" "${2##*-}"; return 0; fi
  d="$(sh_reg_dir "$1")/$2.lock"
  [ "$(cat "$d/pid" 2>/dev/null)" = "$$" ] || return 0
  rm -rf "$d"
}

sh_holder() {  # sh_holder <main> <address> <team dir> → the owner text of the current holder
  if [ "$(sh_kind "$2")" = team ]; then team_send_holder "$3" "${2##*-}"; return 0; fi
  cat "$(sh_reg_dir "$1")/$2.lock/owner" 2>/dev/null || echo unknown
}

# sh_lock_check_held <main> <address> <team dir> <owner> → 0 when the holder file names exactly
# that owner (the caller of a multi-step transaction already holds the lock).
sh_lock_check_held() {
  [ "$(sh_holder "$1" "$2" "$3")" = "$4" ]
}

# sh_log <main> <address> <team dir> <line> — the per-target send log (team: send-<role>.log in the
# team dir, today's file; role/helper: send-<address>.log in the registry).
sh_log() {
  if [ "$(sh_kind "$2")" = team ] && [ -n "$3" ]; then echo "$4" >> "$3/send-${2##*-}.log"
  else mkdir -p "$(sh_reg_dir "$1")" && echo "$4" >> "$(sh_reg_dir "$1")/send-$2.log"; fi
}

# --- tmux backend ------------------------------------------------------------------------------
# Byte-identical to the call sites they replace: sessions `-t =NAME`, panes `-t =NAME:` (tmux 3.7
# finds no pane for `=NAME`).

# sh_tmux_alive <name> [program] → 0 alive, 3 gone, 1 the probe failed (stderr passed through).
# With a program (records written by roles.sh), alive also means that program is the foreground:
# a dead session leaves a `; read` shell behind.
sh_tmux_alive() {
  local out cmd
  if out="$(sh_tmux has-session -t "=$1" 2>&1)"; then
    [ -n "${2:-}" ] || return 0
    cmd="$(sh_tmux display-message -p -t "=$1:" '#{pane_current_command}' 2>/dev/null || true)"
    [ "$cmd" = "$2" ] && return 0
    return 3
  fi
  case "$out" in
    *"can't find session"*|*"no server running"*) return 3 ;;
    *"error connecting to"*"No such file"*) return 3 ;;
  esac
  [ -z "$out" ] || printf '%s\n' "$out" >&2
  return 1
}

# sh_tmux_read <name> [lines] → the last non-empty lines of the pane (team_pane); rc 3 when gone.
sh_tmux_read() {
  local out
  out="$(sh_tmux capture-pane -p -t "=$1:" 2>/dev/null)" || return 3
  printf '%s\n' "$out" | sed '/^[[:space:]]*$/d' | tail -n "${2:-15}"
}

# sh_tmux_history <name> [lines] → pane plus scrollback, wrapped lines joined (team_pane_history).
sh_tmux_history() {
  sh_tmux capture-pane -p -J -S -"${2:-200}" -t "=$1:" 2>/dev/null || return 3
}

# sh_read_target <target> [--history N] [--escapes] [--squeeze] — a capture by a resolved target
# (a pane id such as %1): team_pane_scroll (--squeeze drops blank lines), team-answer.sh capture
# (--escapes keeps the colours the parser reads). Lib only.
sh_read_target() {
  local t="$1" n=200 e="" sq="" out
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --history) n="${2:-200}"; shift 2 ;;
      --escapes) e=1; shift ;;
      --squeeze) sq=1; shift ;;
      *) sh_err "sh_read_target: unknown option $1"; return 2 ;;
    esac
  done
  if [ -n "$e" ]; then out="$(sh_tmux capture-pane -p -e -J -S -"$n" -t "$t" 2>/dev/null)" || return 3
  else out="$(sh_tmux capture-pane -p -J -S -"$n" -t "$t" 2>/dev/null)" || return 3; fi
  if [ -n "$sq" ]; then printf '%s\n' "$out" | sed '/^[[:space:]]*$/d'; else printf '%s\n' "$out"; fi
}

# sh_gen <name> → "<pane_id>@<session_created>"; a replaced session is a new value (team_pane_gen).
sh_gen() {
  local g
  g="$(sh_tmux display-message -p -t "=$1:" '#{pane_id}@#{session_created}' 2>/dev/null)" || return 1
  [ -n "$g" ] || return 1
  echo "$g"
}

# sh_pid <name> → the pane's process id (teamlead-register.sh's ownership probe).
sh_pid() {
  local p
  p="$(sh_tmux display-message -p -t "=$1:" '#{pane_pid}' 2>/dev/null)" || return 1
  [ -n "$p" ] || return 1
  echo "$p"
}

# sh_key_name <name> → the tmux key. The driver's names, plus tmux's own (team-answer.sh passes
# those today); anything else is refused, never typed.
sh_key_name() {
  case "$1" in
    enter|Enter) echo Enter ;;
    esc|Escape) echo Escape ;;
    up|Up) echo Up ;;
    down|Down) echo Down ;;
    tab|Tab) echo Tab ;;
    ctrl-c|C-c) echo C-c ;;
    ctrl-e|C-e) echo C-e ;;
    ctrl-u|C-u) echo C-u ;;
    *) sh_err "unknown key '$1' (enter esc up down tab ctrl-c ctrl-e ctrl-u)"; return 2 ;;
  esac
}

# sh_tmux_keys <target> <key…> — one send-keys with the mapped names. <target> is `=NAME:` or a pane id.
sh_tmux_keys() {
  local t="$1" k m ks=()
  shift
  for k in "$@"; do m="$(sh_key_name "$k")" || return 2; ks+=("$m"); done
  [ ${#ks[@]} -gt 0 ] || { sh_err "keys: no key given"; return 2; }
  sh_tmux send-keys -t "$t" "${ks[@]}"
}

# sh_tmux_type <target> <text> [--enter] — literal text, then Enter when asked.
sh_tmux_type() {
  sh_tmux send-keys -t "$1" -l -- "$2" || return 1
  [ "${3:-}" != --enter ] || sh_tmux send-keys -t "$1" Enter
}

# sh_pane_idle <name> → 0 when the pane shows a recognised empty idle input (team_pane_idle). On an
# open prompt Enter would approve the focused option, so text goes only on this.
sh_pane_idle() {
  sh_tmux_read "$1" 40 | python3 -I "$SH_LIB/team_prompt.py" parse \
    | jq -e '.complete and .kind == "none" and .input_empty == true' >/dev/null 2>&1
}

# --- verbs ---------------------------------------------------------------------------------------
# Each verb: sh_<verb> <address> [options]. Common options: --main <dir>, --team-dir <dir>,
# --lock-held <owner>, --owner <text>.

SH_MAIN="" SH_TD="" SH_HELD="" SH_OWNER="" SH_ARGS=()
# sh_opts <address> <args…> — pulls the common options out; the rest stays in SH_ARGS.
sh_opts() {
  local a="$1"; shift
  SH_MAIN="" SH_TD="" SH_HELD="" SH_OWNER="" SH_ARGS=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --main) SH_MAIN="${2:-}"; shift 2 || { sh_err "--main needs a value"; return 2; } ;;
      --team-dir) SH_TD="${2:-}"; shift 2 || { sh_err "--team-dir needs a value"; return 2; } ;;
      --lock-held) SH_HELD="${2:-}"; shift 2 || { sh_err "--lock-held needs a value"; return 2; } ;;
      --owner) SH_OWNER="${2:-}"; shift 2 || { sh_err "--owner needs a value"; return 2; } ;;
      --) SH_ARGS+=("$@"); break ;;
      *) SH_ARGS+=("$1"); shift ;;
    esac
  done
  SH_MAIN="$(sh_main_root "$SH_MAIN")" || return 2
  sh_kind "$a" >/dev/null || return 2
  SH_TD="$(sh_team_dir "$SH_MAIN" "$a" "$SH_TD")"
}

# sh_target_lock <address> <owner> <wait> → rc 0 when the caller may type (lock taken or verified
# held), 10 otherwise. Sets SH_TOOK=1 when this call took the lock and must release it.
SH_TOOK=""
sh_target_lock() {
  local h
  SH_TOOK=""
  if [ -n "$SH_HELD" ]; then
    sh_lock_check_held "$SH_MAIN" "$1" "$SH_TD" "$SH_HELD" && return 0
    sh_err "$1: lock is held by '$(sh_holder "$SH_MAIN" "$1" "$SH_TD")', not '$SH_HELD'"; return 10
  fi
  if h="$(sh_lock "$SH_MAIN" "$1" "$SH_TD" "$2" "$3")"; then SH_TOOK=1; return 0; fi
  return 10
}
sh_target_unlock() { [ -z "$SH_TOOK" ] || sh_unlock "$SH_MAIN" "$1" "$SH_TD"; SH_TOOK=""; }

sh_alive() {
  local a="$1" n
  shift; sh_opts "$a" "$@" || return 2
  sh_backend "$SH_MAIN" "$a" >/dev/null || return $?
  n="$(sh_name "$SH_MAIN" "$a")" || return 2
  sh_tmux_alive "$n" "$(sh_record_get "$SH_MAIN" "$a" program)"
}

sh_read() {
  local a="$1" n lines=15 hist=""
  shift; sh_opts "$a" "$@" || return 2
  set -- ${SH_ARGS[@]+"${SH_ARGS[@]}"}
  while [ $# -gt 0 ]; do
    case "$1" in
      --lines) lines="${2:-15}"; shift 2 ;;
      --history) hist="${2:-200}"; shift 2 ;;
      *) sh_err "read: unknown option $1"; return 2 ;;
    esac
  done
  sh_backend "$SH_MAIN" "$a" >/dev/null || return $?
  n="$(sh_name "$SH_MAIN" "$a")" || return 2
  if [ -n "$hist" ]; then sh_tmux_history "$n" "$hist"; else sh_tmux_read "$n" "$lines"; fi
}

# keys <address> [--target <pane id>] <key…>
sh_keys() {
  local a="$1" n t="" rc k
  shift; sh_opts "$a" "$@" || return 2
  set -- ${SH_ARGS[@]+"${SH_ARGS[@]}"}
  if [ "${1:-}" = --target ]; then t="${2:-}"; shift 2 || { sh_err "--target needs a value"; return 2; }; fi
  [ $# -gt 0 ] || { sh_err "keys: no key given"; return 2; }
  for k in "$@"; do sh_key_name "$k" >/dev/null || return 2; done
  sh_backend "$SH_MAIN" "$a" >/dev/null || return $?
  n="$(sh_name "$SH_MAIN" "$a")" || return 2
  [ -n "$t" ] || t="=$n:"
  sh_target_lock "$a" "${SH_OWNER:-keys pid=$$}" "${TEAM_SEND_LOCK_WAIT:-30}" \
    || { sh_err "$a: skipped — target lock held by $(sh_holder "$SH_MAIN" "$a" "$SH_TD")"; return 10; }
  sh_tmux_keys "$t" "$@"; rc=$?
  sh_target_unlock "$a"
  [ $rc -eq 0 ] || return 1
}

# type <address> [--target <pane id>] <text> [--enter]
sh_type() {
  local a="$1" n t="" text enter="" rc
  shift; sh_opts "$a" "$@" || return 2
  set -- ${SH_ARGS[@]+"${SH_ARGS[@]}"}
  if [ "${1:-}" = --target ]; then t="${2:-}"; shift 2 || { sh_err "--target needs a value"; return 2; }; fi
  [ $# -ge 1 ] || { sh_err "type: no text given"; return 2; }
  text="$1"; [ "${2:-}" != --enter ] || enter=--enter
  sh_backend "$SH_MAIN" "$a" >/dev/null || return $?
  n="$(sh_name "$SH_MAIN" "$a")" || return 2
  [ -n "$t" ] || t="=$n:"
  sh_target_lock "$a" "${SH_OWNER:-type pid=$$}" "${TEAM_SEND_LOCK_WAIT:-30}" \
    || { sh_err "$a: skipped — target lock held by $(sh_holder "$SH_MAIN" "$a" "$SH_TD")"; return 10; }
  sh_tmux_type "$t" "$text" $enter; rc=$?
  sh_target_unlock "$a"
  [ $rc -eq 0 ] || return 1
}

# send <address> <one line> [--reg <registration.json>] — the doorbell. 1. Claude's messaging
# socket from the session's own registration (draft- and dialog-safe); 2. else the text on an idle
# empty input under the send lock; 3. else skip and log. 0 delivered, 3 gone, 10 skipped.
# Same three steps and log line as team_session_doorbell (per-run TeamLead).
sh_send() {
  local a="$1" n text reg="" why="" rc=0
  shift; sh_opts "$a" "$@" || return 2
  set -- ${SH_ARGS[@]+"${SH_ARGS[@]}"}
  [ $# -ge 1 ] || { sh_err "send: no line given"; return 2; }
  text="${1//$'\n'/ }"; shift
  if [ "${1:-}" = --reg ]; then reg="${2:-}"; fi
  if [ "$(sh_record_get "$SH_MAIN" "$a" cli)" = script ]; then
    sh_err "$a is a script session — send is refused"; return 2
  fi
  sh_backend "$SH_MAIN" "$a" >/dev/null || return $?
  # A dialog is open: no doorbell (the message stays in the inbox; the prompt hook shows it).
  if [ "$(sh_state "$SH_MAIN" "$a" | jq -r '.state // ""' 2>/dev/null)" = blocked ]; then
    sh_log "$SH_MAIN" "$a" "$SH_TD" "doorbell-blocked $(sh_utc) — $text"; return 9
  fi
  [ -n "$reg" ] || reg="$(sh_record_get "$SH_MAIN" "$a" reg)"
  [ -z "$reg" ] || case "$reg" in /*) ;; *) reg="$(sh_reg_dir "$SH_MAIN")/$reg" ;; esac
  if [ -z "$reg" ] && [ "$(sh_kind "$a")" = team ] && [ "${a##*-}" = lead ] && [ -n "$SH_TD" ]; then
    reg="$SH_TD/teamlead.reg.json"
  fi
  if [ -n "$reg" ] && [ -f "$reg" ] && printf '%s\n' "$text" \
    | python3 -I "$SH_LIB/team-watch-send.py" "$reg" >/dev/null 2>&1; then
    return 0
  fi
  n="$(sh_name "$SH_MAIN" "$a")" || return 2
  if ! sh_tmux_alive "$n" 2>/dev/null; then
    why="session $n not alive"; rc=3
  elif sh_target_lock "$a" "${SH_OWNER:-doorbell pid=$$}" "${TEAM_SEND_LOCK_WAIT:-30}"; then
    if ! sh_pane_idle "$n"; then why="input not idle"; rc=10
    elif ! sh_tmux_type "=$n:" "$text" --enter; then why="send-keys failed"; rc=1
    fi
    sh_target_unlock "$a"
  else
    why="send lock held by $(sh_holder "$SH_MAIN" "$a" "$SH_TD")"; rc=10
  fi
  [ -z "$why" ] || sh_log "$SH_MAIN" "$a" "$SH_TD" "doorbell-skipped $(sh_utc) $why — $text"
  return $rc
}

# kill <address> [--graceful <secs>] → 0 ended (or never ran), 1 still alive. Graceful: /exit +
# Enter only on an idle input and under the send lock, else a kill (team_end_session).
sh_kill() {
  local a="$1" n wait="" waited=0 h
  shift; sh_opts "$a" "$@" || return 2
  set -- ${SH_ARGS[@]+"${SH_ARGS[@]}"}
  if [ "${1:-}" = --graceful ]; then wait="${2:-}"; [[ "$wait" =~ ^[0-9]+$ ]] \
    || { sh_err "--graceful needs whole seconds"; return 2; }; fi
  sh_backend "$SH_MAIN" "$a" >/dev/null || return $?
  n="$(sh_name "$SH_MAIN" "$a")" || return 2
  sh_tmux_alive "$n" 2>/dev/null || return 0
  if [ -z "$wait" ]; then
    sh_tmux kill-session -t "=$n" || true
  elif sh_target_lock "$a" "${SH_OWNER:-session-host pid=$$}" "${TEAM_SEND_LOCK_WAIT:-30}"; then
    if sh_pane_idle "$n"; then
      sh_tmux send-keys -t "=$n:" "/exit" Enter || true
      while sh_tmux_alive "$n" 2>/dev/null && [ "$waited" -lt "$wait" ]; do
        sleep 1; waited=$((waited + 1))
      done
    fi
    ! sh_tmux_alive "$n" 2>/dev/null || sh_tmux kill-session -t "=$n" || true
    sh_target_unlock "$a"
  else
    h="$(sh_holder "$SH_MAIN" "$a" "$SH_TD")"
    sh_log "$SH_MAIN" "$a" "$SH_TD" "stop-during-send $(sh_utc) $h"
    echo "warn: stop while sender lock held by $h — session killed without /exit" >&2
    sh_tmux kill-session -t "=$n" || true
  fi
  ! sh_tmux_alive "$n" 2>/dev/null
}

sh_hint() {
  local a="$1" n
  shift; sh_opts "$a" "$@" || return 2
  sh_backend "$SH_MAIN" "$a" >/dev/null || return $?
  n="$(sh_name "$SH_MAIN" "$a")" || return 2
  echo "tmux attach -t $n"
}

# sh_state <main> <address> → the hook's state file as one JSON object, or nothing when there is
# none or it belongs to another session than the record's (a leftover of the replaced session).
# A record without session_id (started without --session-id) accepts any state file.
sh_state() {
  local f rsid
  f="$(sh_reg_dir "$1")/state/$2.json"
  [ -f "$f" ] || return 0
  rsid="$(sh_record_get "$1" "$2" session_id)"
  jq -c --arg r "$rsid" 'select(type == "object" and ($r == "" or .session_id == $r))' "$f" 2>/dev/null || true
}

# status <address> → one JSON line {state, kind, msg, source}. tmux: a Claude session's state comes
# from its own hooks (team-status.sh writes the state file); a permission prompt's tool and command
# come from the transcript's open tool call, never from the screen. Codex and script sessions have
# no hook: `unknown` while alive. No state file yet → `starting`.
sh_status() {
  local a="$1" n rc cli st j t msg
  shift; sh_opts "$a" "$@" || return 2
  sh_backend "$SH_MAIN" "$a" >/dev/null || return $?
  n="$(sh_name "$SH_MAIN" "$a")" || return 2
  sh_tmux_alive "$n" "$(sh_record_get "$SH_MAIN" "$a" program)"; rc=$?
  case $rc in 0) ;; 3) jq -cn '{state: "gone", kind: null, msg: null, source: "tmux"}'; return 0 ;;
    *) return 1 ;; esac
  cli="$(sh_record_get "$SH_MAIN" "$a" cli)"
  if [ -z "$cli" ] || [ "$cli" = codex ] || [ "$cli" = script ]; then
    jq -cn '{state: "unknown", kind: null, msg: null, source: "none"}'; return 0
  fi
  j="$(sh_state "$SH_MAIN" "$a")"
  if [ -z "$j" ]; then jq -cn '{state: "starting", kind: null, msg: null, source: "none"}'; return 0; fi
  st="$(jq -r '.state // "unknown"' <<<"$j")"; msg=""
  if [ "$st" = blocked ] && [ "$(jq -r '.kind // ""' <<<"$j")" = permission ]; then
    t="$(jq -r '.transcript_path // ""' <<<"$j")"
    [ -z "$t" ] || msg="$(python3 -I "$SH_LIB/team_prompt.py" pending-tool "$t" 2>/dev/null \
      | jq -r 'select(type == "object" and .tool != null) | "\(.tool): \(.detail // "")"' 2>/dev/null \
      | cut -c1-200)"
  fi
  jq -cn --argjson j "$j" --arg m "$msg" \
    '{state: ($j.state // "unknown"), kind: ($j.kind // null), msg: (if $m == "" then null else $m end), source: "hook"}'
}

# sh_quote <word> → the word in POSIX single quotes ('…'\''…'), never printf %q.
sh_quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# sh_screen_state <screen> <cli> → update | trust | ready | "" (still starting).
# Matched texts: Claude's trust dialog line "Do you trust the files in this folder?"; Codex's trust
# prompt carries "trust" and "folder" on one line; Codex's update prompt "Update available".
sh_screen_state() {
  if printf '%s\n' "$1" | grep -q 'Do you trust the files in this folder?'; then echo trust; return 0; fi
  if [ "$2" = codex ]; then
    if printf '%s\n' "$1" | grep -qi 'update available'; then echo update; return 0; fi
    if printf '%s\n' "$1" | grep -i 'trust' | grep -qi 'folder'; then echo trust; return 0; fi
    if printf '%s\n' "$1" | grep -qE '^[[:space:]]*›[[:space:]]*$'; then echo ready; return 0; fi
    return 0
  fi
  if printf '%s\n' "$1" | python3 -I "$SH_LIB/team_prompt.py" parse \
    | jq -e '.complete and .kind == "none" and .input_empty == true' >/dev/null 2>&1; then
    echo ready
  fi
}

# start <address> --kind role|team|helper --cwd <dir> --cli claude|codex|script [--env K=V]…
#   [--claude-home auto] [--program <exe>] [--session-id <id>] [--wait-ready] [--no-probe] -- <argv…>
# --no-probe: the caller has already decided the session is gone (the runner's own liveness
# checks), so start issues no has-session before new-session — the call sequence stays the
# caller's, and a live duplicate fails in new-session itself, as a direct call did.
sh_start() {
  local a="$1" kind="" cwd="" cli="" ch="" prog="" sid="" ready="" probe=1 n k rc be cmd w s envs=() argv=()
  shift; sh_opts "$a" "$@" || return 2
  set -- ${SH_ARGS[@]+"${SH_ARGS[@]}"}
  while [ $# -gt 0 ]; do
    case "$1" in
      --kind) kind="${2:-}"; shift 2 ;;
      --cwd) cwd="${2:-}"; shift 2 ;;
      --cli) cli="${2:-}"; shift 2 ;;
      --env) [[ "${2:-}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] \
               || { sh_err "--env needs K=V, got '${2:-}'"; return 2; }
             envs+=(-e "$2"); shift 2 ;;
      --claude-home) ch="${2:-}"; shift 2 ;;
      --program) prog="${2:-}"; shift 2 ;;
      --session-id) sid="${2:-}"; shift 2 ;;
      --wait-ready) ready=1; shift ;;
      --no-probe) probe=""; shift ;;
      --) shift; argv=("$@"); break ;;
      *) sh_err "start: unknown option $1"; return 2 ;;
    esac
  done
  k="$(sh_kind "$a")" || return 2
  [ "$k" != adhoc ] || { sh_err "$a: ad-hoc sessions are registry only, never started"; return 2; }
  case "$kind" in role|team|helper) ;; *) sh_err "start: --kind must be role|team|helper"; return 2 ;; esac
  [ "$kind" = "$k" ] || { sh_err "start: address $a is a $k address, not --kind $kind"; return 2; }
  case "$cli" in claude|codex|script) ;; *) sh_err "start: --cli must be claude|codex|script"; return 2 ;; esac
  [ -n "$cwd" ] && [ -d "$cwd" ] || { sh_err "start: --cwd must be an existing directory"; return 2; }
  [ ${#argv[@]} -gt 0 ] || { sh_err "start: nothing to run after --"; return 2; }
  case "$ch" in ""|auto) ;; *) sh_err "start: --claude-home takes only auto"; return 2 ;; esac
  if [ -n "$probe" ]; then be="$(sh_backend "$SH_MAIN" "$a" --for-start)" || return $?
  else be="$(sh_pick_host "$SH_MAIN")" || return $?; fi
  n="$(sh_name "$SH_MAIN" "$a")" || return 2
  if [ -n "$probe" ] && sh_tmux_alive "$n" "$(sh_record_get "$SH_MAIN" "$a" program)" 2>/dev/null; then
    sh_err "$a is already running ($(sh_hint "$a" --main "$SH_MAIN"))"; return 1
  fi
  # A recorded program that no longer runs leaves its shell behind (a `; read` pane): end it. Only
  # records that carry `program` (roles.sh) — the runner's own `; read` cleanup stays its caller's.
  if [ -n "$probe" ] && [ -n "$(sh_record_get "$SH_MAIN" "$a" program)" ] && sh_tmux has-session -t "=$n" 2>/dev/null; then
    sh_tmux kill-session -t "=$n" || true
  fi
  envs+=(-e "HARNESS_ADDRESS=$a" -e "HARNESS_MAIN=$SH_MAIN" -e "HARNESS_REGISTRY=$(sh_reg_dir "$SH_MAIN")"
    -e "HARNESS_BACKEND=$be")
  if [ "$ch" = auto ]; then
    . "$SH_LIB/team-profile.sh"
    if ! w="$(team_claude_home "$SH_MAIN")"; then echo "$w" >&2; return 1; fi
    [ -z "$w" ] || envs+=(-e "CLAUDE_CONFIG_DIR=$w")
  fi
  if [ ${#argv[@]} -eq 1 ]; then cmd="${argv[0]}"
  else cmd=""; for w in "${argv[@]}"; do cmd="${cmd:+$cmd }$(sh_quote "$w")"; done; fi
  w="$(sh_tmux_path)" || return 1
  env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_MESSAGING_SOCKET \
    -u CLAUDE_CODE_MESSAGING_TOKEN "$w" \
    new-session -d -s "$n" -c "$cwd" "${envs[@]}" "$cmd" || { sh_err "$a: tmux new-session failed"; return 1; }
  s=""; [ "$k" != team ] || s="$(cd "$cwd" && pwd)/.agents/team"
  [ -z "$SH_TD" ] || s="$SH_TD"
  sh_record_put "$SH_MAIN" "$a" '{address: $a, kind: $k, backend: $b, handle: $n, name: $n,
      cwd: $cwd, cli: $cli, started_at: $at}
    + (if $prog != "" then {program: $prog} else {} end)
    + (if $sid != "" then {session_id: $sid} else {} end)
    + (if $td != "" then {team_dir: $td} else {} end)' \
    --arg a "$a" --arg k "$k" --arg b "$be" --arg n "$n" --arg cwd "$cwd" --arg cli "$cli" \
    --arg at "$(sh_utc)" --arg prog "$prog" --arg sid "$sid" --arg td "$s" \
    || sh_err "$a: started, but the registry record could not be written"
  echo "$n"
  [ -n "$ready" ] && [ "$cli" != script ] || return 0
  sh_wait_ready "$a" "$n" "$cli"
  return 0
}

# sh_wait_ready <address> <name> <cli> — up to TEAM_HOST_READY_SECS (20) for a first sign of life.
# A trust dialog is reported, never answered (trusting a folder is the Operator's decision); a
# Codex update prompt is skipped once with esc (non-destructive).
sh_wait_ready() {
  local i=0 max="${TEAM_HOST_READY_SECS:-20}" poll="${TEAM_HOST_READY_POLL:-1}" esc="" scr st
  while [ "$i" -lt "$max" ]; do
    scr="$(sh_tmux_read "$2" 40 2>/dev/null || true)"
    st="$(sh_screen_state "$scr" "$3")"
    case "$st" in
      ready) return 0 ;;
      trust) echo "warn: $1: waiting at the folder trust dialog — accept it once in tmux attach -t $2" >&2
             return 0 ;;
      update) if [ -z "$esc" ]; then sh_tmux send-keys -t "=$2:" Escape || true; esc=1; fi ;;
    esac
    sleep "$poll"; i=$((i + 1))
  done
  echo "warn: $1: no sign of life after ${max}s — look at it: tmux attach -t $2" >&2
  return 0
}

# sh_check_host [--main <dir>] → prints the backend a fresh start would use, or the reason; rc 6.
sh_check_host() {
  local m="" h
  [ "${1:-}" != --main ] || m="${2:-}"
  m="$(sh_main_root "$m")" || return 2
  if h="$(sh_pick_host "$m" 2>&1)"; then echo "$h"; return 0; fi
  echo "${h#session-host: }"; return 6
}
