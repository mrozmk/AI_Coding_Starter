#!/usr/bin/env bash
# The session-host driver, sourced form: every interaction with the terminal multiplexer goes
# through these functions (CLI: session-host.sh). Backends: tmux, and herdr (herdr-core through
# `hc`, chosen explicitly: `auto` stays tmux until SH_AUTO_HERDR is switched on, sh_auto_herdr).
# Bash 3.2; sourced, never executed — the lib sets no shell options, callers run under their own.
#
# Addresses (the harness's names) → session names, all carrying the project prefix (sh_prefix), so
# two checkouts on one machine never collide. Callers hold addresses; names exist only in here.
#   <Role> (leading capital)  → <prefix>-<role lowercase>
#   <team>-<role>             → <prefix>-<team>-<role>
#   helper:<name>             → <prefix>-<name> (a name already starting <prefix>- is taken as is)
#   adhoc-<handle>            → registry only, never started
# Exit codes: 0 ok · 2 usage · 3 gone · 6 no host · 9 blocked · 10 skipped (lock held, input not
# safe) · 1 other.
# Registry: <main>/.agents/team/registry/<address>.json, one per address, tmp + mv. A verb on an
# address without a record uses tmux (sessions started before the driver). A Herdr session is
# addressed by its record's `handle` (`t7`, fixed for the terminal's life) after start: names are
# unique only among live terminals, so a finished one may share the name.
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

# sh_prefix <main> → the session-name prefix: teams.session_prefix (refused unless it matches
# ^[a-z0-9][a-z0-9_-]{0,11}$; empty = not set), else teams.channel.tmux_prefix, else the
# repo-directory slug — both through team_channel_names, lowercased, and cut to 12 with one warning
# per process (refusing a derived prefix would break a fresh install). Cached per main checkout.
SH_PREFIX_ROOT="" SH_PREFIX="" SH_PREFIX_WARNED=""
sh_prefix() {
  local v full
  if [ -n "$SH_PREFIX" ] && [ "$SH_PREFIX_ROOT" = "$1" ]; then printf '%s\n' "$SH_PREFIX"; return 0; fi
  v="$(jq -r '.teams.session_prefix // empty | strings' "$1/.claude/project-profile.json" 2>/dev/null || true)"
  if [ -n "$v" ]; then
    [[ "$v" =~ ^[a-z0-9][a-z0-9_-]{0,11}$ ]] \
      || { sh_err "teams.session_prefix=$v must match ^[a-z0-9][a-z0-9_-]{0,11}$ (lowercase, ≤ 12)"; return 2; }
  else
    full="$(sh_legacy_prefix "$1")" || return 2
    v="$(printf '%s' "$full" | tr '[:upper:]' '[:lower:]')"
    if [ "${#v}" -gt 12 ]; then
      v="${v:0:12}"
      while case "$v" in *-|*_) true ;; *) false ;; esac; do v="${v%?}"; done
      [ -n "$SH_PREFIX_WARNED" ] \
        || { echo "warn: session prefix $full cut to $v — set teams.session_prefix" >&2; SH_PREFIX_WARNED=1; }
    fi
  fi
  SH_PREFIX_ROOT="$1" SH_PREFIX="$v"
  printf '%s\n' "$v"
}

# sh_legacy_prefix <main> → the uncut tmux_prefix / slug of team_channel_names (the role prefix
# before step 2); a malformed channel block falls back to the slug alone.
sh_legacy_prefix() {
  . "$SH_LIB/team-channel.sh"
  if TEAM_CHANNEL_NAMES_LOADED="" team_channel_names "$1" 2>/dev/null; then
    printf '%s\n' "$TEAM_CHANNEL_TMUX_PREFIX"; return 0
  fi
  basename "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/-/g; s/^[^a-z0-9]*//' | grep . \
    || { sh_err "no session prefix: set teams.session_prefix"; return 2; }
}

# sh_name <main> <address> → the name a fresh start uses: prefixed, lowercase, [a-z0-9_-]{1,32}.
sh_name() {
  local k p n; k="$(sh_kind "$2")" || return 2
  p="$(sh_prefix "$1")" || return 2
  case "$k" in
    helper) n="${2#helper:}"; case "$n" in "$p"-*) ;; *) n="$p-$n" ;; esac ;;
    *) n="$p-$2" ;;
  esac
  n="$(printf '%s' "$n" | tr '[:upper:]' '[:lower:]')"
  if [ "${#n}" -gt 32 ]; then
    sh_err "session name $n is over 32 characters — shorten teams.session_prefix or the team name"
    return 2
  fi
  [[ "$n" =~ ^[a-z0-9_-]+$ ]] || { sh_err "session name $n must match [a-z0-9_-]"; return 2; }
  printf '%s\n' "$n"
}

# one release: remove in step 9a — the name a session had before step 2, so a run started before the
# upgrade is not orphaned: team <team>-<role>; role <uncut tmux_prefix|slug>-<role lc>; helper none.
sh_legacy_name() {
  case "$(sh_kind "$2")" in
    team) printf '%s\n' "$2" ;;
    role) printf '%s-%s\n' "$(sh_legacy_prefix "$1")" "$(echo "$2" | tr '[:upper:]' '[:lower:]')" ;;
    *) return 1 ;;
  esac
}

# sh_target <main> <address> → the live session's name: the record's name, else the prefixed name,
# else — no record, the new name absent, TEAM_HOST_LEGACY_NAMES not 0 — the old name when that one
# is alive (noted once per process). Every verb on an existing session resolves through here; only
# start uses sh_name alone.
SH_LEGACY_NOTED=""
sh_target() {
  local n old r
  if [ "$(sh_record_get "$1" "$2" backend)" = herdr ]; then sh_herdr_handle "$1" "$2"; return; fi
  r="$(sh_record_get "$1" "$2" name)"
  if [ -n "$r" ]; then printf '%s\n' "$r"; return 0; fi
  n="$(sh_name "$1" "$2")" || return 2
  if [ "${TEAM_HOST_LEGACY_NAMES:-1}" != 0 ] && old="$(sh_legacy_name "$1" "$2" 2>/dev/null)" \
    && [ -n "$old" ] && [ "$old" != "$n" ] && ! sh_tmux has-session -t "=$n" 2>/dev/null \
    && sh_tmux has-session -t "=$old" 2>/dev/null; then
    case " $SH_LEGACY_NOTED " in *" $2 "*) ;; *)
      echo "note: $2 reached under its old name $old" >&2; SH_LEGACY_NOTED="$SH_LEGACY_NOTED $2" ;; esac
    printf '%s\n' "$old"; return 0
  fi
  printf '%s\n' "$n"
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

# sh_herdr_handle <main> <address> → the herdr record's handle; rc 2 no handle, 3 replaced. Herdr's
# docs do not promise an address is never given out again (after `hc rm`, a core restart, a reboot),
# and records outlive all three: when the record carries `created_ms` and the live terminal under
# the handle has another one, the record's terminal is gone and nothing may act on the new one. A
# terminal that is gone, or a probe that fails, still returns the handle (the verb says gone).
sh_herdr_handle() {
  local h c j
  h="$(sh_record_get "$1" "$2" handle)"
  [ -n "$h" ] || { sh_err "$2: herdr record without a handle"; return 2; }
  c="$(sh_record_get "$1" "$2" created_ms)"
  if [ -n "$c" ] && j="$(sh_herdr_get "$h" 2>/dev/null)" \
    && [ "$(jq -r '.created_ms // "" | tostring' <<<"$j" 2>/dev/null)" != "$c" ]; then
    sh_err "$2: terminal $h is not the recorded one (replaced)"; return 3
  fi
  printf '%s\n' "$h"
}

# The tmux binary. Under TEAM_SMOKE=1 only a binary inside TEAM_SMOKE_BIN_DIR runs: a fixture must
# never reach the machine's real server.
sh_bin_path() {  # sh_bin_path <binary> <label> → its path, with the TEAM_SMOKE fixture rule
  local p d
  p="$(command -v "$1" 2>/dev/null || true)"
  [ -n "$p" ] || { sh_err "$2 not found ($1)"; return 1; }
  if [ "${TEAM_SMOKE:-}" = 1 ]; then
    d="${TEAM_SMOKE_BIN_DIR:-}"
    if [ -z "$d" ] || [ "$(cd "$(dirname "$p")" && pwd -P)" != "$(cd "$d" 2>/dev/null && pwd -P)" ]; then
      sh_err "refusing $p under TEAM_SMOKE=1 (not in TEAM_SMOKE_BIN_DIR)"
      return 1
    fi
  fi
  echo "$p"
}
sh_tmux_path() { sh_bin_path "${TMUX_BIN:-tmux}" tmux; }
sh_tmux() {
  local p; p="$(sh_tmux_path)" || return 1
  "$p" "$@"
}
# herdr-core's CLI, under the same fixture rule. Never `server stop|restart`, never the force flag of
# send (it would answer a dialog), never keep (a lost program must stay lost, not become a shell).
sh_hc_path() { sh_bin_path "${HC_BIN:-hc}" hc; }
sh_hc() {
  local p; p="$(sh_hc_path)" || return 1
  "$p" "$@"
}
# sh_hc_rc <hc exit code> → the driver's: 0 · 3 gone (3 not_found, 11 finished) · 9 blocked · 1 other.
sh_hc_rc() { case "$1" in 0) return 0 ;; 3|11) return 3 ;; 9) return 9 ;; *) return 1 ;; esac; }

# sh_timebox <secs> <cmd…> → the command's exit, 124 on timeout (its process group is killed).
sh_timebox() {
  perl -e '$t = shift; $p = fork // exit 1;
    if (!$p) { setpgrp(0, 0); exec @ARGV or exit 127 }
    $SIG{ALRM} = sub { kill "KILL", -$p; waitpid $p, 0; exit 124 };
    alarm $t; waitpid $p, 0; exit($? & 127 ? 128 + ($? & 127) : $? >> 8)' "$@"
}

# sh_herdr_up → 0 when herdr-core answers `hc server status` within 3 s with its version.
sh_herdr_up() {
  local p j; p="$(sh_hc_path 2>/dev/null)" || return 1
  j="$(sh_timebox 3 "$p" server status --json 2>/dev/null)" || return 1
  jq -e '.version | strings' <<<"$j" >/dev/null 2>&1
}

# The one switch for `auto`: 0 = auto is tmux; 1 = auto probes herdr-core first (sh_herdr_up). Off
# until the Herdr backend has been checked on a live Herdr (owner, 2026-11-15). The smoke part host
# turns the probe on for itself with TEAM_SMOKE_AUTO_HERDR=1, under TEAM_SMOKE=1 only.
SH_AUTO_HERDR=0
sh_auto_herdr() {
  [ "$SH_AUTO_HERDR" = 1 ] || { [ "${TEAM_SMOKE:-}" = 1 ] && [ "${TEAM_SMOKE_AUTO_HERDR:-}" = 1 ]; }
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
  case "$h" in
    herdr) sh_herdr_up || { sh_err "no session host: herdr core not answering"; return 6; }
           echo herdr; return 0 ;;
    auto) if sh_auto_herdr && sh_herdr_up; then echo herdr; return 0; fi ;;
  esac
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
    if [ "$b" = herdr ] && sh_herdr_alive "$(sh_herdr_handle "$1" "$2" 2>/dev/null)" 2>/dev/null; then
      echo herdr; return 0
    fi
    sh_pick_host "$1"; return $?
  fi
  case "${b:-tmux}" in
    tmux) echo tmux ;;
    herdr) echo herdr ;;
    none) echo none ;;
    *) sh_err "$2: unknown backend '$b' in its registry record"; return 1 ;;
  esac
}

# A plain terminal (`roles.sh here` outside tmux and Herdr) is recorded as backend none with the
# shell's pid and its start time; `exec` keeps that pid for the CLI. It is alive while that pid runs
# with the same start time (a reused pid is not it). It has no screen to read or type into.
sh_lstart() { ps -o lstart= -p "$1" 2>/dev/null | sed 's/^ *//; s/ *$//'; }
sh_none_alive() {  # sh_none_alive <main> <address> → 0 alive · 3 gone
  local p s
  p="$(sh_record_get "$1" "$2" pid)"; s="$(sh_record_get "$1" "$2" pid_start)"
  [[ "$p" =~ ^[0-9]+$ ]] && kill -0 "$p" 2>/dev/null && [ -n "$s" ] && [ "$(sh_lstart "$p")" = "$s" ] \
    && return 0
  return 3
}
# sh_live <main> <address> <backend> → 0 alive · 3 gone · 1 the probe failed
sh_live() {
  case "$3" in
    none) sh_none_alive "$1" "$2"; return ;;
    herdr) local h; h="$(sh_herdr_handle "$1" "$2")" || return 3
           sh_herdr_alive "$h" "$(sh_record_get "$1" "$2" program)"; return ;;
  esac
  sh_tmux_alive "$(sh_target "$1" "$2")" "$(sh_record_get "$1" "$2" program)"
}
# sh_alive_addr <main> <address> → sh_live with the record's backend (the team-lib.sh wrappers).
sh_alive_addr() {
  local b; b="$(sh_backend "$1" "$2" 2>/dev/null)" || return 1
  sh_live "$1" "$2" "$b"
}
# sh_screen_backend <main> <address> — sh_backend for the verbs that read or type into a screen.
sh_screen_backend() {
  local b; b="$(sh_backend "$1" "$2")" || return $?
  [ "$b" != none ] || { sh_err "$2 runs in a plain terminal — no screen to read or type into"; return 1; }
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
  # A target that is not a tmux pane id (%N) is a Herdr handle: no escapes there (plain text only).
  case "$t" in
    %*) ;;
    *) out="$(sh_herdr_history "$t" "$n")" || return 3
       if [ -n "$sq" ]; then printf '%s\n' "$out" | sed '/^[[:space:]]*$/d'; else printf '%s\n' "$out"; fi
       return 0 ;;
  esac
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

# sh_gen_addr <main> <address> → the generation of the address's live session (team_pane_gen).
sh_gen_addr() {
  case "$(sh_record_get "$1" "$2" backend)" in
    herdr) local h; h="$(sh_herdr_handle "$1" "$2" 2>/dev/null)" || return 1; sh_herdr_gen "$h" ;;
    *) sh_gen "$(sh_target "$1" "$2")" ;;
  esac
}

# sh_read_addr <main> <address> [lines] [--history N] → the screen of the address's session (team_pane,
# team_pane_history); rc 3 gone.
sh_read_addr() {
  local b n
  b="$(sh_backend "$1" "$2" 2>/dev/null)" || return 3
  n="$(sh_target "$1" "$2")" || return 3
  case "$b:${3:-}" in
    none:*) return 3 ;;
    herdr:--history) sh_herdr_history "$n" "${4:-200}" ;;
    herdr:*) sh_herdr_read "$n" "${3:-15}" ;;
    *:--history) sh_tmux_history "$n" "${4:-200}" ;;
    *) sh_tmux_read "$n" "${3:-15}" ;;
  esac
}

# sh_pid <name> → the pane's process id.
sh_pid() {
  local p
  p="$(sh_tmux display-message -p -t "=$1:" '#{pane_pid}' 2>/dev/null)" || return 1
  [ -n "$p" ] || return 1
  echo "$p"
}

# sh_pane_pid <main> <address> → the foreground pane's process id of the live session
# (session-registry.sh's TeamLead ownership probe). Herdr: the terminal's root program pid, an
# ancestor of everything that runs in it.
sh_pane_pid() {
  local p
  case "$(sh_record_get "$1" "$2" backend)" in
    herdr) p="$(sh_herdr_handle "$1" "$2" 2>/dev/null)" || return 1
           p="$(sh_herdr_get "$p" 2>/dev/null | jq -r '.pid // empty | tostring')"
           [[ "$p" =~ ^[0-9]+$ ]] || return 1; echo "$p"; return 0 ;;
    none) sh_none_alive "$1" "$2" || return 1; sh_record_get "$1" "$2" pid; return 0 ;;
  esac
  sh_pid "$(sh_target "$1" "$2")"
}

# sh_inbox_session <main> <inbox address> → the session address an inbox write rings: a declared
# role → itself; a team (an anchor in the main checkout) → <team>-lead; adhoc-* → itself (send
# refuses it); anything else → exit 3. Teams may not take a role's name (team-new.sh).
sh_inbox_session() {
  case "$2" in adhoc-*) echo "$2"; return 0 ;; esac
  if (ROLES_ROOT="$1"; . "$SH_LIB/roles-lib.sh" && roles_is_declared "$2") 2>/dev/null; then
    echo "$2"; return 0
  fi
  [ ! -f "$1/.agents/team/anchors/$2.json" ] || { echo "$2-lead"; return 0; }
  return 3
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

# --- herdr backend ------------------------------------------------------------------------------
# herdr-core through `hc`, addressed by the record's handle. JSON field names as `hc schema`
# (Terminal): state live|finished, foreground {argv, name, pid}, status {state, kind, msg} or null,
# created_ms, pid, labels. Exit codes: 3 not_found, 9 blocked, 11 finished (sh_hc_rc).

# sh_herdr_get <handle> → the terminal's JSON; rc 0 · 3 gone · 1 the probe failed.
sh_herdr_get() {
  local j rc p
  [ -n "$1" ] || return 3
  p="$(sh_hc_path)" || return 1   # a refused or missing hc is said on stderr; hc's own errors are not
  j="$("$p" get "$1" --json 2>/dev/null)"; rc=$?
  sh_hc_rc "$rc" || return $?
  printf '%s\n' "$j"
}

# sh_herdr_alive <handle> [program] → 0 alive, 3 gone, 1 the probe failed. With a program, alive also
# means that program runs in the foreground: foreground.argv[0] or .name is it, or — a command run
# through `sh -c '…; read'` keeps sh as the group leader — the foreground process group holds it.
# A kept or `; read` shell is gone.
sh_herdr_alive() {
  local j rc fg nm pg
  j="$(sh_herdr_get "$1")"; rc=$?
  [ $rc -eq 0 ] || return $rc
  [ "$(jq -r '.state // ""' <<<"$j" 2>/dev/null)" = live ] || return 3
  [ -n "${2:-}" ] || return 0
  fg="$(jq -r '.foreground.argv[0] // "" | strings' <<<"$j" 2>/dev/null)"
  nm="$(jq -r '.foreground.name // "" | strings' <<<"$j" 2>/dev/null)"
  [ "${fg##*/}" != "$2" ] && [ "$nm" != "$2" ] || return 0
  pg="$(jq -r '.foreground.pid // "" | tostring' <<<"$j" 2>/dev/null)"
  [[ "$pg" =~ ^[0-9]+$ ]] && pgrep -g "$pg" -x "$2" >/dev/null 2>&1 && return 0
  return 3
}

# sh_herdr_state <handle> → the program's own status word (idle working done blocked error), empty
# while it reports none (status null: still starting, or not an agent).
sh_herdr_state() {
  sh_herdr_get "$1" 2>/dev/null | jq -r '.status.state // "" | strings' 2>/dev/null
}

# sh_herdr_read <handle> [lines] → the last non-empty lines of the screen (sh_tmux_read); rc 3 gone.
sh_herdr_read() {
  local out rc
  out="$(sh_hc read "$1" 2>/dev/null)"; rc=$?
  sh_hc_rc "$rc" || return $?
  printf '%s\n' "$out" | sed '/^[[:space:]]*$/d' | tail -n "${2:-15}"
}

# sh_herdr_history <handle> [lines] → screen plus history. While the program is working, blocked or
# in error, herdr returns only the screen (no scroll input is sent).
sh_herdr_history() {
  local rc
  sh_hc read "$1" --lines "${2:-200}" 2>/dev/null; rc=$?
  sh_hc_rc "$rc"
}

# sh_hc_key <name> → the hc key name (the driver's names and tmux's, as sh_key_name).
sh_hc_key() {
  local k; k="$(sh_key_name "$1")" || return 2
  case "$k" in
    Enter) echo enter ;; Escape) echo esc ;; Up) echo up ;; Down) echo down ;; Tab) echo tab ;;
    C-c) echo ctrl+c ;; C-e) echo ctrl+e ;; C-u) echo ctrl+u ;;
  esac
}

# sh_herdr_keys <handle> <key…> — one `hc keys` with the mapped names.
sh_herdr_keys() {
  local h="$1" k m ks=() rc
  shift
  for k in "$@"; do m="$(sh_hc_key "$k")" || return 2; ks+=("$m"); done
  [ ${#ks[@]} -gt 0 ] || { sh_err "keys: no key given"; return 2; }
  sh_hc keys "$h" "${ks[@]}" >/dev/null; rc=$?
  sh_hc_rc "$rc"
}

# sh_herdr_type <handle> <text> — `hc send`: pasted and submitted in one step, so Enter is implied;
# prints `typed+submitted`. An open prompt is refused (9): typing would answer it. Never forced.
sh_herdr_type() {
  local rc
  [ "$(sh_herdr_state "$1")" != blocked ] \
    || { sh_err "type into an open prompt is not supported under herdr"; return 9; }
  sh_hc send "$1" "$2" >/dev/null; rc=$?
  sh_hc_rc "$rc" || return $?
  echo "typed+submitted"
}

# sh_herdr_gen <handle> → "<handle>@<created_ms>"; a terminal replaced under the same name is new.
sh_herdr_gen() {
  local g
  g="$(sh_herdr_get "$1" 2>/dev/null | jq -r '"\(.address)@\(.created_ms)"' 2>/dev/null)" || return 1
  case "$g" in ""|*null*) return 1 ;; esac
  echo "$g"
}

# sh_herdr_launch_line <cli> <K=V…> -- <argv…> → SH_LINE: the argv `hc run` gets after `--`. The
# caller's environment does not reach an hc terminal (it gets the login session's), so every variable
# is a word for /usr/bin/env; one element is a shell command (`/bin/sh -c`), several are argv.
# No Claude config dir passed → unset, never inherited (spec §1 Environment).
SH_LINE=()
sh_herdr_launch_line() {
  local kv=() ch=""
  shift
  while [ $# -gt 0 ] && [ "$1" != -- ]; do
    kv+=("$1"); case "$1" in CLAUDE_CONFIG_DIR=*) ch=1 ;; esac; shift
  done
  shift
  SH_LINE=(/usr/bin/env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_MESSAGING_SOCKET
    -u CLAUDE_CODE_MESSAGING_TOKEN)
  [ -n "$ch" ] || SH_LINE+=(-u CLAUDE_CONFIG_DIR)
  SH_LINE+=(${kv[@]+"${kv[@]}"})
  if [ $# -eq 1 ]; then SH_LINE+=(/bin/sh -c "$1"); else SH_LINE+=("$@"); fi
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
  local a="$1" b
  shift; sh_opts "$a" "$@" || return 2
  b="$(sh_backend "$SH_MAIN" "$a")" || return $?
  sh_target "$SH_MAIN" "$a" >/dev/null || return $?
  sh_live "$SH_MAIN" "$a" "$b"
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
  sh_screen_backend "$SH_MAIN" "$a" || return $?
  n="$(sh_target "$SH_MAIN" "$a")" || return $?
  if [ "$(sh_backend "$SH_MAIN" "$a")" = herdr ]; then
    if [ -n "$hist" ]; then sh_herdr_history "$n" "$hist"; else sh_herdr_read "$n" "$lines"; fi
    return
  fi
  if [ -n "$hist" ]; then sh_tmux_history "$n" "$hist"; else sh_tmux_read "$n" "$lines"; fi
}

# keys <address> [--target <pane id>] <key…>
sh_keys() {
  local a="$1" n t="" rc k b
  shift; sh_opts "$a" "$@" || return 2
  set -- ${SH_ARGS[@]+"${SH_ARGS[@]}"}
  if [ "${1:-}" = --target ]; then t="${2:-}"; shift 2 || { sh_err "--target needs a value"; return 2; }; fi
  [ $# -gt 0 ] || { sh_err "keys: no key given"; return 2; }
  for k in "$@"; do sh_key_name "$k" >/dev/null || return 2; done
  sh_screen_backend "$SH_MAIN" "$a" || return $?
  n="$(sh_target "$SH_MAIN" "$a")" || return $?
  b="$(sh_backend "$SH_MAIN" "$a")"
  [ -n "$t" ] || { t="=$n:"; [ "$b" != herdr ] || t="$n"; }
  sh_target_lock "$a" "${SH_OWNER:-keys pid=$$}" "${TEAM_SEND_LOCK_WAIT:-30}" \
    || { sh_err "$a: skipped — target lock held by $(sh_holder "$SH_MAIN" "$a" "$SH_TD")"; return 10; }
  if [ "$b" = herdr ]; then sh_herdr_keys "$t" "$@"; else sh_tmux_keys "$t" "$@"; fi; rc=$?
  sh_target_unlock "$a"
  case $rc in 0) ;; 3) return 3 ;; *) return 1 ;; esac
}

# type <address> [--target <pane id|handle>] <text> [--enter] — herdr: pasted and submitted at once
# (prints typed+submitted; --enter is implied), refused with 9 while a prompt is open.
sh_type() {
  local a="$1" n t="" text enter="" rc b
  shift; sh_opts "$a" "$@" || return 2
  set -- ${SH_ARGS[@]+"${SH_ARGS[@]}"}
  if [ "${1:-}" = --target ]; then t="${2:-}"; shift 2 || { sh_err "--target needs a value"; return 2; }; fi
  [ $# -ge 1 ] || { sh_err "type: no text given"; return 2; }
  text="$1"; [ "${2:-}" != --enter ] || enter=--enter
  sh_screen_backend "$SH_MAIN" "$a" || return $?
  n="$(sh_target "$SH_MAIN" "$a")" || return $?
  b="$(sh_backend "$SH_MAIN" "$a")"
  [ -n "$t" ] || { t="=$n:"; [ "$b" != herdr ] || t="$n"; }
  sh_target_lock "$a" "${SH_OWNER:-type pid=$$}" "${TEAM_SEND_LOCK_WAIT:-30}" \
    || { sh_err "$a: skipped — target lock held by $(sh_holder "$SH_MAIN" "$a" "$SH_TD")"; return 10; }
  if [ "$b" = herdr ]; then sh_herdr_type "$t" "$text"; else sh_tmux_type "$t" "$text" $enter; fi; rc=$?
  sh_target_unlock "$a"
  case $rc in 0) ;; 3|9) return $rc ;; *) return 1 ;; esac
}

# send <address> <one line> [--reg <registration.json>] — the doorbell. 1. Claude's messaging
# socket from the session's own registration (draft- and dialog-safe); 2. else the text on an idle
# empty input under the send lock; 3. else skip and log. 0 delivered, 3 gone, 10 skipped.
# Same three steps and log line as team_session_doorbell (per-run TeamLead).
sh_send() {
  local a="$1" n text reg="" why="" rc=0 b st
  shift; sh_opts "$a" "$@" || return 2
  [ "$(sh_kind "$a")" != adhoc ] || { sh_err "$a is an ad-hoc session — never rung"; return 3; }
  set -- ${SH_ARGS[@]+"${SH_ARGS[@]}"}
  [ $# -ge 1 ] || { sh_err "send: no line given"; return 2; }
  text="${1//$'\n'/ }"; shift
  if [ "${1:-}" = --reg ]; then reg="${2:-}"; fi
  if [ "$(sh_record_get "$SH_MAIN" "$a" cli)" = script ]; then
    sh_err "$a is a script session — send is refused"; return 2
  fi
  b="$(sh_backend "$SH_MAIN" "$a")" || return $?
  # A dialog is open: no doorbell (the message stays in the inbox; the prompt hook shows it).
  if [ "$b" = herdr ]; then n="$(sh_target "$SH_MAIN" "$a")" || return $?; st="$(sh_herdr_state "$n")"
  else st="$(sh_state "$SH_MAIN" "$a" | jq -r '.state // ""' 2>/dev/null)"; fi
  if [ "$st" = blocked ]; then
    sh_log "$SH_MAIN" "$a" "$SH_TD" "doorbell-blocked $(sh_utc) — $text"; return 9
  fi
  # The registration lives in the registry for every address (session-registry.sh writes it).
  [ -n "$reg" ] || reg="$(sh_record_get "$SH_MAIN" "$a" reg)"
  [ -n "$reg" ] || reg="$a.reg.json"
  case "$reg" in /*) ;; *) reg="$(sh_reg_dir "$SH_MAIN")/$reg" ;; esac
  if [ -n "$reg" ] && [ -f "$reg" ] && printf '%s\n' "$text" \
    | python3 -I "$SH_LIB/team-watch-send.py" "$reg" >/dev/null 2>&1; then
    return 0
  fi
  if [ "$(sh_record_get "$SH_MAIN" "$a" backend)" = none ]; then
    sh_log "$SH_MAIN" "$a" "$SH_TD" "doorbell-skipped $(sh_utc) plain terminal, no registration — $text"
    return 10
  fi
  n="$(sh_target "$SH_MAIN" "$a")" || return $?
  if [ "$b" = herdr ]; then sh_herdr_send "$a" "$n" "$text"; return; fi
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

# sh_herdr_send <address> <handle> <line> — the doorbell's fallback under herdr (no registration):
# `hc send` under the target lock, never forced. Herdr cannot see a person's draft: send holds for it
# (draft_wait) and then submits it merged with the line — accepted by the owner (2026-11-15) and
# logged once per session as doorbell-draft-unsafe. 0 delivered, 3 gone, 9 blocked, 10 lock held.
sh_herdr_send() {
  local a="$1" h="$2" text="$3" why="" rc=0 id m
  if ! sh_herdr_alive "$h" 2>/dev/null; then
    why="session $h not alive"; rc=3
  elif sh_target_lock "$a" "${SH_OWNER:-doorbell pid=$$}" "${TEAM_SEND_LOCK_WAIT:-30}"; then
    id="$(sh_record_get "$SH_MAIN" "$a" session_id)"; id="${id:-$h}"
    m="$(sh_reg_dir "$SH_MAIN")/$a.draft-logged"
    if [ "$(cat "$m" 2>/dev/null)" != "$id" ]; then
      sh_log "$SH_MAIN" "$a" "$SH_TD" "doorbell-draft-unsafe $(sh_utc) $a"
      ( umask 077; printf '%s\n' "$id" > "$m" ) 2>/dev/null || true
    fi
    sh_hc send "$h" "$text" >/dev/null 2>&1; rc=$?
    sh_hc_rc "$rc"; rc=$?
    case $rc in 0) ;; 3) why="session $h gone" ;; 9) why="blocked" ;; *) why="hc send failed" ;; esac
    sh_target_unlock "$a"
  else
    why="send lock held by $(sh_holder "$SH_MAIN" "$a" "$SH_TD")"; rc=10
  fi
  [ -z "$why" ] || sh_log "$SH_MAIN" "$a" "$SH_TD" "doorbell-skipped $(sh_utc) $why — $text"
  return $rc
}

# sh_herdr_kill <address> <handle> <graceful secs or empty> — as sh_kill's tmux path: graceful only
# on an idle or done status and under the target lock (/exit, then wait), then always `hc kill` and
# `hc rm`. A person's unfinished draft would be submitted with /exit appended (hc send holds for it,
# then merges): the plan's rule, kept (step 6 report). 0 ended or never ran, 1 still alive.
sh_herdr_kill() {
  local a="$1" h="$2" wait="$3" waited=0 st o
  if ! sh_herdr_alive "$h" 2>/dev/null; then
    sh_hc rm "$h" >/dev/null 2>&1 || true   # a finished terminal of ours: remove it
    return 0
  fi
  if [ -n "$wait" ]; then
    if sh_target_lock "$a" "${SH_OWNER:-session-host pid=$$}" "${TEAM_SEND_LOCK_WAIT:-30}"; then
      st="$(sh_herdr_state "$h")"
      if [ "$st" = idle ] || [ "$st" = done ]; then
        sh_hc send "$h" "/exit" >/dev/null 2>&1 || true
        while sh_herdr_alive "$h" 2>/dev/null && [ "$waited" -lt "$wait" ]; do
          sleep 1; waited=$((waited + 1))
        done
      fi
      sh_target_unlock "$a"
    else
      o="$(sh_holder "$SH_MAIN" "$a" "$SH_TD")"
      sh_log "$SH_MAIN" "$a" "$SH_TD" "stop-during-send $(sh_utc) $o"
      echo "warn: stop while sender lock held by $o — session killed without /exit" >&2
    fi
  fi
  ! sh_herdr_alive "$h" 2>/dev/null || sh_hc kill "$h" >/dev/null 2>&1 || true
  sh_hc rm "$h" >/dev/null 2>&1 || true
  ! sh_herdr_alive "$h" 2>/dev/null
}

# kill <address> [--graceful <secs>] → 0 ended (or never ran), 1 still alive. Graceful: /exit +
# Enter only on an idle input and under the send lock, else a kill (team_end_session).
sh_kill() {
  local a="$1" n wait="" waited=0 h rc
  shift; sh_opts "$a" "$@" || return 2
  set -- ${SH_ARGS[@]+"${SH_ARGS[@]}"}
  if [ "${1:-}" = --graceful ]; then wait="${2:-}"; [[ "$wait" =~ ^[0-9]+$ ]] \
    || { sh_err "--graceful needs whole seconds"; return 2; }; fi
  h="$(sh_backend "$SH_MAIN" "$a")" || return $?
  if [ "$h" = none ]; then   # a plain terminal: SIGTERM to the recorded CLI, then wait for it
    sh_none_alive "$SH_MAIN" "$a" || return 0
    kill -TERM "$(sh_record_get "$SH_MAIN" "$a" pid)" 2>/dev/null || true
    while sh_none_alive "$SH_MAIN" "$a" && [ "$waited" -lt "${wait:-5}" ]; do sleep 1; waited=$((waited + 1)); done
    ! sh_none_alive "$SH_MAIN" "$a"; return
  fi
  n="$(sh_target "$SH_MAIN" "$a")" || { rc=$?; [ $rc != 3 ] || return 0; return $rc; }   # replaced: not ours
  if [ "$h" = herdr ]; then sh_herdr_kill "$a" "$n" "$wait"; return; fi
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
  local a="$1" n b
  shift; sh_opts "$a" "$@" || return 2
  b="$(sh_backend "$SH_MAIN" "$a")" || return $?
  if [ "$b" = none ]; then echo "a plain terminal (tty $(sh_record_get "$SH_MAIN" "$a" tty))"; return 0; fi
  n="$(sh_target "$SH_MAIN" "$a")" || return $?
  if [ "$b" = herdr ]; then
    echo "herdr: $(sh_record_get "$SH_MAIN" "$a" name | grep . || echo "$n") (click in the agent list) · hc attach $n"
    return 0
  fi
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
  local a="$1" b rc cli st j t msg n
  shift; sh_opts "$a" "$@" || return 2
  b="$(sh_backend "$SH_MAIN" "$a")" || return $?
  n="$(sh_target "$SH_MAIN" "$a")"; rc=$?   # 3: a replaced herdr terminal reads as gone
  case $rc in 0) sh_live "$SH_MAIN" "$a" "$b"; rc=$? ;; 3) ;; *) return 2 ;; esac
  case $rc in 0) ;; 3) jq -cn --arg s "$b" '{state: "gone", kind: null, msg: null, source: $s}'; return 0 ;;
    *) return 1 ;; esac
  cli="$(sh_record_get "$SH_MAIN" "$a" cli)"
  # Herdr: the program's own status (OSC 7501), Codex included; null = still starting. Never the screen.
  if [ "$b" = herdr ] && [ "$cli" != script ]; then
    j="$(sh_herdr_get "$n" 2>/dev/null)" \
      && j="$(jq -c 'if .status == null
      then {state: "starting", kind: null, msg: null, source: "herdr"}
      else {state: (.status.state // "unknown"), kind: (.status.kind // null),
            msg: (.status.msg // null), source: "herdr"} end' <<<"$j" 2>/dev/null)" && [ -n "$j" ] \
      || j="$(jq -cn '{state: "unknown", kind: null, msg: null, source: "herdr"}')"
    printf '%s\n' "$j"; return 0
  fi
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
# Matched texts: Claude's trust dialog line "Do you trust the files in this folder?" or its option
# "Yes, I trust this folder"; Codex's trust prompt carries "trust" and "folder" on one line, or the
# option "Trust and continue"; Codex's update prompt "Update available", or "Update now" with "Skip"
# (the spike's Codex screens under Herdr).
sh_screen_state() {
  if printf '%s\n' "$1" | grep -qE 'Do you trust the files in this folder\?|Yes, I trust this folder'; then
    echo trust; return 0
  fi
  if [ "$2" = codex ]; then
    if printf '%s\n' "$1" | grep -qi 'update available' \
      || { printf '%s\n' "$1" | grep -q 'Update now' && printf '%s\n' "$1" | grep -qi 'skip'; }; then
      echo update; return 0
    fi
    if printf '%s\n' "$1" | grep -i 'trust' | grep -qi 'folder'; then echo trust; return 0; fi
    if printf '%s\n' "$1" | grep -q 'Trust and continue'; then echo trust; return 0; fi
    if printf '%s\n' "$1" | grep -qE '^[[:space:]]*›[[:space:]]*$'; then echo ready; return 0; fi
    return 0
  fi
  if printf '%s\n' "$1" | python3 -I "$SH_LIB/team_prompt.py" parse \
    | jq -e '.complete and .kind == "none" and .input_empty == true' >/dev/null 2>&1; then
    echo ready
  fi
}

# sh_herdr_start_probe <address> <name> <cwd> → 0 free to start; 1 already running, or the name is
# another checkout's. Our record's terminal alive → running. A terminal under the name: ours (labels
# harness=<prefix> and address=<address>) is ended and removed unless it is alive (a lost record);
# a live one without our labels belongs to someone else. A finished foreign one does not block (names
# are unique among live terminals only).
sh_herdr_start_probe() {
  local a="$1" n="$2" prog j h p rc
  prog="$(sh_record_get "$SH_MAIN" "$a" program)"
  if [ "$(sh_record_get "$SH_MAIN" "$a" backend)" = herdr ] \
    && h="$(sh_herdr_handle "$SH_MAIN" "$a" 2>/dev/null)" && sh_herdr_alive "$h" "$prog" 2>/dev/null; then
    sh_err "$a is already running ($(sh_hint "$a" --main "$SH_MAIN"))"; return 1
  fi
  j="$(sh_herdr_get "$n" 2>/dev/null)" || return 0
  h="$(jq -r '.address // empty' <<<"$j")"; p="$(sh_prefix "$SH_MAIN")"
  if [ "$(jq -r '.labels.harness // ""' <<<"$j")" = "$p" ] && [ "$(jq -r '.labels.address // ""' <<<"$j")" = "$a" ]; then
    [ -n "$h" ] || return 0
    sh_herdr_alive "$h" "$prog" 2>/dev/null; rc=$?
    case $rc in   # kill and remove only what is known gone; a failed probe is not "dead"
      0) sh_err "$a is already running (herdr: $n · hc attach $h)"; return 1 ;;
      3) sh_hc kill "$h" >/dev/null 2>&1 || true; sh_hc rm "$h" >/dev/null 2>&1 || true; return 0 ;;
      *) sh_err "$a: cannot probe $n — not started"; return 1 ;;
    esac
  fi
  if [ "$(jq -r '.state // ""' <<<"$j")" = live ]; then
    sh_err "$n belongs to another checkout ($(jq -r '.cwd // "unknown path"' <<<"$j")); this one is $3 — set a different teams.session_prefix"
    return 1
  fi
  return 0
}

# sh_herdr_run <address> <kind> <name> <cwd> <cli> [-e K=V]… -- <argv…> → "<handle> <created_ms>" of the
# new terminal (created_ms from the run reply, else from `hc get`; empty when neither gives it).
# `hc run --bg --no-parent`: no parent to end it with, never kept, labelled for the probe above.
sh_herdr_run() {
  local a="$1" k="$2" n="$3" cwd="$4" cli="$5" kv=() lab out h c
  shift 5
  while [ $# -gt 0 ] && [ "$1" != -- ]; do [ "$1" = -e ] || kv+=("$1"); shift; done
  shift
  sh_herdr_launch_line "$cli" ${kv[@]+"${kv[@]}"} -- "$@"
  lab=(--label "harness=$(sh_prefix "$SH_MAIN")" --label "kind=$k" --label "address=$a")
  [ "$k" != team ] || lab+=(--label "team=${a%-*}")
  out="$(sh_hc run --bg --no-parent --json --name "$n" --cwd "$cwd" "${lab[@]}" -- "${SH_LINE[@]}" 2>&1)"
  h="$(jq -r '.address // empty' <<<"$out" 2>/dev/null)"
  [ -n "$h" ] || { sh_err "$a: hc run failed: ${out:0:300}"; return 1; }
  c="$(jq -r '.created_ms // empty | tostring' <<<"$out" 2>/dev/null)"
  [ -n "$c" ] || c="$(sh_herdr_get "$h" 2>/dev/null | jq -r '.created_ms // empty | tostring' 2>/dev/null)"
  echo "$h $c"
}

# start <address> --kind role|team|helper --cwd <dir> --cli claude|codex|script [--env K=V]…
#   [--claude-home auto] [--program <exe>] [--session-id <id>] [--wait-ready] [--no-probe] -- <argv…>
# The backend: the record's while its session lives, else the configured one (sh_pick_host);
# --host tmux pins tmux (lib only, team-watch.sh until step 9a). Herdr records the terminal's handle.
# --no-probe: the caller has already decided the session is gone (the runner's own liveness
# checks), so start issues no has-session before new-session — the call sequence stays the
# caller's, and a live duplicate fails in new-session itself, as a direct call did.
sh_start() {
  local a="$1" kind="" cwd="" cli="" ch="" prog="" sid="" ready="" probe=1 host="" n k rc be cmd w s h c="" envs=() argv=()
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
      --host) host="${2:-}"; shift 2 ;;
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
  # --host tmux (lib only): team-watch.sh keeps its helpers on tmux until it is retired (step 9a).
  case "$host" in
    "") if [ -n "$probe" ]; then be="$(sh_backend "$SH_MAIN" "$a" --for-start)" || return $?
        else be="$(sh_pick_host "$SH_MAIN")" || return $?; fi ;;
    tmux) command -v "${TMUX_BIN:-tmux}" >/dev/null 2>&1             || { sh_err "no session host: install tmux or Herdr"; return 6; }
          be=tmux ;;
    *) sh_err "start: --host takes only tmux"; return 2 ;;
  esac
  n="$(sh_name "$SH_MAIN" "$a")" || return 2
  if [ "$(sh_record_get "$SH_MAIN" "$a" backend)" = none ] && sh_none_alive "$SH_MAIN" "$a"; then
    sh_err "$a is already running ($(sh_hint "$a" --main "$SH_MAIN"))"; return 1
  fi
  if [ "$be" = herdr ]; then
    [ -z "$probe" ] || sh_herdr_start_probe "$a" "$n" "$cwd" || return $?
  elif [ -n "$probe" ] && sh_tmux_alive "$n" "$(sh_record_get "$SH_MAIN" "$a" program)" 2>/dev/null; then
    if [ ! -f "$(sh_record_file "$SH_MAIN" "$a")" ]; then
      # The name is alive and no record of ours names it: our own session with a lost record when it
      # runs in this start's cwd, else (or unreadable) another checkout with the same prefix.
      w="$(sh_tmux display-message -p -t "=$n:" '#{session_path}' 2>/dev/null || true)"
      if [ -z "$w" ] || [ "$(cd "$w" 2>/dev/null && pwd -P)" != "$(cd "$cwd" && pwd -P)" ]; then
        sh_err "$n belongs to another checkout (${w:-unknown path}); this one is $cwd — set a different teams.session_prefix"
        return 1
      fi
    fi
    sh_err "$a is already running ($(sh_hint "$a" --main "$SH_MAIN"))"; return 1
  fi
  # A recorded program that no longer runs leaves its shell behind (a `; read` pane): end it. Only
  # records that carry `program` (roles.sh) — the runner's own `; read` cleanup stays its caller's.
  if [ "$be" != herdr ] && [ -n "$probe" ] && [ -n "$(sh_record_get "$SH_MAIN" "$a" program)" ] \
    && sh_tmux has-session -t "=$n" 2>/dev/null; then
    sh_tmux kill-session -t "=$n" || true
  fi
  envs+=(-e "HARNESS_ADDRESS=$a" -e "HARNESS_MAIN=$SH_MAIN" -e "HARNESS_REGISTRY=$(sh_reg_dir "$SH_MAIN")"
    -e "HARNESS_BACKEND=$be")
  if [ "$ch" = auto ]; then
    . "$SH_LIB/team-profile.sh"
    if ! w="$(team_claude_home "$SH_MAIN")"; then echo "$w" >&2; return 1; fi
    [ -z "$w" ] || envs+=(-e "CLAUDE_CONFIG_DIR=$w")
  fi
  h="$n"
  if [ "$be" = herdr ]; then
    # The identity guard (sh_herdr_handle) keeps the terminal's creation time with its handle.
    h="$(sh_herdr_run "$a" "$k" "$n" "$cwd" "$cli" "${envs[@]}" -- "${argv[@]}")" || return 1
    c="${h#* }"; h="${h%% *}"
  else
    if [ ${#argv[@]} -eq 1 ]; then cmd="${argv[0]}"
    else cmd=""; for w in "${argv[@]}"; do cmd="${cmd:+$cmd }$(sh_quote "$w")"; done; fi
    # No Claude config dir passed: the tmux server may carry another project's value in its global
    # environment, so the session must not inherit it (spec §1 Environment).
    case " ${envs[*]} " in *" CLAUDE_CONFIG_DIR="*) ;; *)
      [ "$cli" != claude ] || cmd="env -u CLAUDE_CONFIG_DIR $cmd" ;; esac
    w="$(sh_tmux_path)" || return 1
    env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_MESSAGING_SOCKET \
      -u CLAUDE_CODE_MESSAGING_TOKEN "$w" \
      new-session -d -s "$n" -c "$cwd" "${envs[@]}" "$cmd" || { sh_err "$a: tmux new-session failed"; return 1; }
  fi
  s=""; [ "$k" != team ] || s="$(cd "$cwd" && pwd)/.agents/team"
  [ -z "$SH_TD" ] || s="$SH_TD"
  sh_record_put "$SH_MAIN" "$a" '{address: $a, kind: $k, backend: $b, handle: $h, name: $n,
      cwd: $cwd, cli: $cli, started_at: $at}
    + (if $prog != "" then {program: $prog} else {} end)
    + (if $sid != "" then {session_id: $sid} else {} end)
    + (if $td != "" then {team_dir: $td} else {} end)
    + (if $c != "" then {created_ms: $c} else {} end)' \
    --arg a "$a" --arg k "$k" --arg b "$be" --arg n "$n" --arg h "$h" --arg c "$c" --arg cwd "$cwd" --arg cli "$cli" \
    --arg at "$(sh_utc)" --arg prog "$prog" --arg sid "$sid" --arg td "$s" \
    || sh_err "$a: started, but the registry record could not be written"
  echo "$n"
  [ -n "$ready" ] && [ "$cli" != script ] || return 0
  sh_wait_ready "$a" "$h" "$cli" "$be"
  return 0
}

# sh_wait_ready <address> <name|handle> <cli> [backend] — up to TEAM_HOST_READY_SECS (20) for a first
# sign of life. A trust dialog is reported, never answered (trusting a folder is the Operator's
# decision); a Codex update prompt is skipped once with esc (non-destructive). Herdr: ready once the
# program reports a status (it reports none while a startup dialog is open); the screen decides
# meanwhile.
sh_wait_ready() {
  local i=0 max="${TEAM_HOST_READY_SECS:-20}" poll="${TEAM_HOST_READY_POLL:-1}" esc="" scr st hint
  hint="tmux attach -t $2"; [ "${4:-tmux}" != herdr ] || hint="hc attach $2"
  while [ "$i" -lt "$max" ]; do
    if [ "${4:-tmux}" = herdr ]; then
      [ -z "$(sh_herdr_state "$2")" ] || return 0
      scr="$(sh_herdr_read "$2" 40 2>/dev/null || true)"
    else
      scr="$(sh_tmux_read "$2" 40 2>/dev/null || true)"
    fi
    st="$(sh_screen_state "$scr" "$3")"
    case "$st" in
      ready) return 0 ;;
      trust) echo "warn: $1: waiting at the folder trust dialog — accept it once in $hint" >&2
             return 0 ;;
      update) if [ -z "$esc" ]; then
                if [ "${4:-tmux}" = herdr ]; then sh_herdr_keys "$2" esc || true
                else sh_tmux send-keys -t "=$2:" Escape || true; fi
                esc=1
              fi ;;
    esac
    sleep "$poll"; i=$((i + 1))
  done
  echo "warn: $1: no sign of life after ${max}s — look at it: $hint" >&2
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
