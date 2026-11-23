#!/usr/bin/env bash
# The project's role sessions (teams.sessions): start what is missing, report, stop, take a window.
# Usage: bash .claude/lib/roles.sh [up [<Role>]] | status | stop [<Role>|all] | here <Role>
#          | resume <Role> | runs [--json] | place <address>
#   up      start every standing, enabled role that is not running (idempotent, one at a time),
#           then list the interrupted team runs and the resume lines of gone ad-hoc sessions
#   status  per role: backend, alive|gone|stopped, state, inbox, session id, last seen; the same lists
#   stop    end a role (/exit, then a kill after 15 s); its record stays, marked stopped_at
#   here    this plain terminal becomes <Role> (not from inside Claude Code)
#   resume  start a gone Claude role on its previous conversation (claude --resume <session id>)
#   runs    the interrupted team runs (read-only; resume one with /start-team <team>)
#   place   put a running window into its Herdr tab: a role into its place.tab, a team session into
#           its team's tab (tmux: prints how to look at it); never fails on the window
# Roles: teams.sessions in .claude/project-profile.json (roles-lib.sh). Exit: 0 ok · 1 a role failed
# or another /roles is running · 2 usage or validation · 6 no session host.
#   e.g. bash .claude/lib/roles.sh        then: bash .claude/lib/roles.sh status
set -uo pipefail

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
LIB="$(cd "$(dirname "$0")" && pwd)"
command -v jq >/dev/null 2>&1 || { echo "roles: jq is required" >&2; exit 1; }
. "$LIB/session-host-lib.sh"
. "$LIB/roles-lib.sh"
. "$LIB/session-host-layout.sh"

cmd="${1:-up}"; [ $# -eq 0 ] || shift
case "$cmd" in
  up|status|stop|here|resume|runs|place) ;;
  -h|--help|help) usage ;;
  *) echo "roles: unknown verb '$cmd'" >&2; usage ;;
esac
MAIN="$(sh_main_root "")" || exit 2
export ROLES_ROOT="$MAIN"
REG="$(sh_reg_dir "$MAIN")"

# The launch line's bootstrap (spec §3): a SessionStart hook only adds context and starts no turn.
boot() {
  echo "You are $1. Follow the role contract the session context names and reconcile now — inbox \`new/\`, open records, pending decisions."
}
new_sid() {
  local s
  s="$(uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]')" || s=""
  [ -n "$s" ] || s="$(python3 -I -c 'import uuid; print(uuid.uuid4())')"
  echo "$s"
}
# The claude --name of a role: <Role><teams.channel.mail_suffix>, as the operator kit's health check
# looks for it.
claude_name() {
  local x
  x="$( { . "$LIB/team-channel.sh" && team_channel_names "$MAIN" && printf '%s' "${TEAM_CHANNEL_SUFFIX:-}"; } 2>/dev/null )" || x=""
  echo "$1$x"
}
# The channel's CODEX_HOME for a Claude role (its codex calls); else the caller's. The agent-mail
# channel is optional: without one this falls back silently. The redirect sits inside the
# substitution, since one after a bare assignment leaves the substitution's stderr on the terminal.
codex_home() {
  local h
  h="$( { . "$LIB/team-channel.sh" && team_channel_load "$MAIN" && printf '%s' "${TEAM_CHANNEL_CODEX_HOME:-}"; } 2>/dev/null )" || h=""
  echo "${h:-${CODEX_HOME:-}}"
}
standing() { roles_list --standing | grep -qxF "$1"; }

# materialize <role…> — each Claude role with a settings template gets its own profile
# (.agents/team/watch/profiles/<Role>.settings.json, env role = the role), then one profile check;
# a failure or a local allow leak launches nothing.
materialize() {
  local r out rc=0 done=""
  for r in "$@"; do
    [ -n "$(roles_cfg "$r" settings)" ] || continue
    out="$(bash "$LIB/supervisor-sessions.sh" materialize "$r" 2>&1)" \
      || { printf '%s\n' "$out" | tail -n 1 >&2; echo "refused: $r profile not materialised — nothing launched" >&2; return 1; }
    done="$done $r"
  done
  [ -n "$done" ] || return 0
  # shellcheck disable=SC2086
  out="$(python3 -I "$LIB/session_profile_check.py" "$MAIN" $done 2>&1)" || rc=$?
  case "$rc" in
    0) return 0 ;;
    3) printf '%s\n' "$out" | grep ' LEAK: ' >&2
       echo "refused: local allow leak in settings.local.json — nothing launched" >&2 ;;
    *) printf '%s\n' "$out" | grep -v ' note: ' >&2
       echo "refused: role profile check failed (exit $rc) — nothing launched" >&2 ;;
  esac
  return 1
}

# A codex role's model "default" omits -m: Codex then runs the default model of its environment.
# For the shell line of launch_cmd only; here applies the same rule to its argv.
codex_model_flag() { [ "$1" = default ] || printf -- '-m %s ' "$1"; }
# codex_model_word <model> <effort> → "model: <pinned name | CLI default> · effort <effort>", as /roles
# prints it for a started codex role.
codex_model_word() { local m="$1"; [ "$m" != default ] || m="CLI default"; echo "model: $m · effort $2"; }

# launch_cmd <role> <session id> [resume] → the one shell line the session runs. A Claude role keeps
# its pane after an exit (`; read`, so an error stays readable; start replaces that pane next time).
# resume: `--resume <id>` and no bootstrap line (the conversation holds its role; the hook re-adds
# the contract on source resume).
launch_cmd() {
  local r="$1" m e s c
  m="$(roles_cfg "$r" model)" && e="$(roles_cfg "$r" effort)" || return 2
  if [ "$(roles_cfg "$r" cli)" = codex ]; then
    c="$(roles_cfg "$r" contract)"
    echo "codex --no-daemon $(codex_model_flag "$m")-c model_reasoning_effort=$e $(sh_quote "$(boot "$r") Contract: $c")"
    return 0
  fi
  s="$(roles_cfg "$r" settings)"
  if [ "${3:-}" = resume ]; then
    echo "claude --name $(sh_quote "$(claude_name "$r")") --resume $2 --model $m --effort $e${s:+ --settings .agents/team/watch/profiles/$r.settings.json}${TEAM_SESSIONS_CLAUDE_FLAGS:+ $TEAM_SESSIONS_CLAUDE_FLAGS}; read"
    return 0
  fi
  echo "claude --name $(sh_quote "$(claude_name "$r")") --session-id $2 --model $m --effort $e${s:+ --settings .agents/team/watch/profiles/$r.settings.json} ${TEAM_SESSIONS_CLAUDE_FLAGS:+$TEAM_SESSIONS_CLAUDE_FLAGS }-- $(sh_quote "$(boot "$r")"); read"
}

# A startup dialog is reported, never answered. A Claude role is past it once its hooks write the
# state file; a Codex role once its prompt shows; a Herdr role once it reports a status.
# TEAM_ROLES_TRUST_SECS (8) bounds the look. Prints one <role>:<word> per role still held:
# trust (the folder trust dialog), dialog (another recognised startup dialog: MCP servers), nostatus
# (Herdr: no status after the look and no recognised screen — no dialog is claimed).
needs_trust() {  # needs_trust "<role>:<name>:<cli> …"
  local pend="$1" left i=0 max="${TEAM_ROLES_TRUST_SECS:-8}" t r n c st esc="" h scr
  while [ -n "$pend" ] && [ "$i" -lt "$max" ]; do
    left=""
    for t in $pend; do
      r="${t%%:*}"; n="${t#*:}"; c="${n#*:}"; n="${n%%:*}"; h=""
      # Herdr: a role that reports a status is past every startup dialog (none reports one).
      if [ "$(sh_record_get "$MAIN" "$r" backend)" = herdr ]; then
        h="$(sh_target "$MAIN" "$r" 2>/dev/null)" || continue   # replaced: not ours to read or key
        [ -z "$(sh_herdr_state "$h")" ] || continue
        scr="$(sh_herdr_read "$h" 40 2>/dev/null || true)"
      else
        if [ "$c" = claude ] && [ -n "$(sh_state "$MAIN" "$r")" ]; then continue; fi
        scr="$(sh_tmux_read "$n" 40 2>/dev/null || true)"
      fi
      st="$(sh_screen_state "$scr" "$c")"
      case "$st" in
        trust) echo "$r:trust"; continue ;;
        mcp) echo "$r:dialog"; continue ;;
        ready) continue ;;
        update) case " $esc " in *" $r "*) ;; *)
                  if [ -n "$h" ]; then sh_herdr_keys "$h" esc || true; else sh_tmux send-keys -t "=$n:" Escape || true; fi
                  esc="$esc $r" ;; esac ;;
      esac
      left="$left $t"
    done
    pend="${left# }"
    [ -z "$pend" ] || { sleep 1; i=$((i + 1)); }
  done
  for t in $pend; do
    r="${t%%:*}"
    [ "$(sh_record_get "$MAIN" "$r" backend)" != herdr ] || echo "$r:nostatus"
  done
}
# placed <role> <layout_panes output> → rc 0 when the role's pane is listed in a tab (Herdr only).
placed() { printf '%s\n' "$2" | awk -F'\t' -v r="$1" '$1 == r && $2 != "none" && $2 != "?" { f = 1 } END { exit !f }'; }
# held_word <role> <needs_trust output> → the words after "started" / "resumed …", or nothing.
held_word() {
  case " $(echo $2) " in
    *" $1:trust "*) echo " (needs trust — pick Yes; Enter alone exits)" ;;   # Herdr's default is "No, exit"
    *" $1:dialog "*) echo " (startup dialog open)" ;;
    *" $1:nostatus "*) echo " (no status yet)" ;;
  esac
}

window_line() {  # the window this ran in, when it is no role's terminal
  local me="" f
  if [ -n "${HC_TERMINAL_ID:-}" ]; then me="$HC_TERMINAL_ID"
  elif [ -n "${TMUX:-}" ]; then me="$(sh_tmux display-message -p '#S' 2>/dev/null || true)"
  fi
  [ -n "$me" ] || return 0
  for f in "$REG"/*.json; do
    [ -f "$f" ] || continue
    jq -e --arg h "$me" '.kind == "role" and (.handle == $h or .name == $h)' "$f" >/dev/null 2>&1 && return 0
  done
  echo "This window is not a role — close it."
}

# ---- restore: interrupted team runs ----------------------------------------------------------------
# roles_runs → one JSON object per line: {team, run, stage, state, clone, resume} for every run that is
# not finished and whose runner is dead, or {team, clone, missing: true}. Teams come from the main
# checkout's anchors (trusted, with the clone's physical path); the clone's files are only read, and
# its run id is checked before it names a path. The runner lock's owner decides liveness, never its
# session (the runner frees its lock on every exit and its `; read` pane outlives it). Finished: the
# run's closed.json, or the mode's last role done and accepted (snap_team / team_role).
roles_runs() (
  . "$LIB/team-lib.sh" && . "$LIB/team-modes.sh" || exit 1
  for a in "$MAIN"/.agents/team/anchors/*.json; do
    [ -f "$a" ] || continue
    t="$(jq -r '.team // empty | strings' "$a" 2>/dev/null)"; c="$(jq -r '.clone // empty | strings' "$a" 2>/dev/null)"
    [[ "$t" =~ ^[a-z0-9][a-z0-9-]*$ ]] && [ -n "$c" ] || continue
    td="$c/.agents/team"
    if [ ! -f "$td/team.json" ]; then jq -cn --arg t "$t" --arg c "$c" '{team: $t, clone: $c, missing: true}'; continue; fi
    run="$(head -n 1 "$td/run" 2>/dev/null)"
    [[ "$run" =~ ^[A-Za-z0-9-]+$ ]] || continue
    [ ! -e "$td/runs/$run/closed.json" ] || continue
    if [ -d "$td/lock" ]; then
      p="$(cat "$td/lock/pid" 2>/dev/null || true)"
      [[ "$p" =~ ^[0-9]+$ ]] && kill -0 "$p" 2>/dev/null && continue
    fi
    mode="$(team_mode "$td/team.json" 2>/dev/null)" || mode=""
    roles="$(team_mode_roles "$mode" 2>/dev/null)" || roles=""
    [ -n "$roles" ] || continue
    last="$(echo $roles | awk '{print $NF}')"; first="$(echo $roles | awk '{print $1}')"
    d="$td/runs/$(team_run_ref "$td" "$run")"
    f="$(ls -1t "$d/$last"-*.json 2>/dev/null | head -n 1)"
    if [ -n "$f" ] && [ "$(jq -r '.verdict // empty' "$f" 2>/dev/null)" = done ] && [ -e "$f.accepted" ]; then continue; fi
    # The newest stage record (never a TeamLead verdict) gives the stage and its state.
    nr="$(for x in $roles; do ls -1 "$d/$x"-*.json 2>/dev/null; done | while IFS= read -r x; do
      printf '%s\t%s\n' "$(stat -f %m "$x" 2>/dev/null || stat -c %Y "$x")" "$x"; done | sort -rn | head -n 1 | cut -f2)"
    stage="$(jq -r '.role // empty | strings' "$td/session.json" 2>/dev/null)"
    case " $(echo $roles) " in *" $stage "*) ;; *) stage="" ;; esac
    state=open
    if [ -z "$stage" ] && [ -n "$nr" ]; then
      stage="$(basename "$nr")"; stage="${stage%%-*}"
      # A wrapup's proposals stop (#104) waits for its TeamLead, not for the Operator.
      case "$(jq -r 'if .proposals then "proposals" else .verdict // empty end' "$nr" 2>/dev/null)" in
        blocked) state=blocked ;; failed) state=failed ;; proposals) state=proposals ;; esac
    fi
    [ -n "$stage" ] || stage="$first"
    jq -cn --arg t "$t" --arg r "$run" --arg s "$stage" --arg st "$state" --arg c "$c" \
      '{team: $t, run: $r, stage: $s, state: $st, clone: $c, resume: "/start-team \($t)"}'
  done
)

# runs_report [--json] — oldest run first (the id ends in YYYYMMDD-HHMMSS; a team name may hold `-`).
runs_report() {
  local all
  all="$(roles_runs | jq -s 'map(select(.missing | not)) as $r | map(select(.missing)) as $m
    | {runs: ($r | sort_by(.run[-15:])), missing: $m}')" || all='{"runs": [], "missing": []}'
  if [ "${1:-}" = --json ]; then jq -c '.runs' <<<"$all"; return 0; fi
  jq -r '.missing[] | "\(.team): clone missing (\(.clone))"' <<<"$all"
  jq -r 'if (.runs | length) == 0 then "interrupted runs: none" else .runs[]
    | "interrupted run \(.team) (\(.run), stage \(.stage)\(if .state == "open" then "" else ", \(.state)" end)) — resume: \(.resume)" end' <<<"$all"
}

# ---- restore: ad-hoc sessions -------------------------------------------------------------------
# A recorded ad-hoc conversation is gone when its terminal is gone, when the terminal lives on with
# another foreground program (a kept Herdr terminal can come back as a shell under the same id), or
# when its claude pid is dead. A conversation that ended normally (ended_at, written by the
# SessionEnd hook) gets no line; the terminal is never touched.
hc_bin() {  # the Herdr CLI, or nothing; under TEAM_SMOKE=1 only a fixture binary
  local p; p="$(command -v "${HC_BIN:-hc}" 2>/dev/null)" || return 1
  if [ "${TEAM_SMOKE:-}" = 1 ] && [ "$(cd "$(dirname "$p")" && pwd -P)" != "$(cd "${TEAM_SMOKE_BIN_DIR:-/nonexistent}" 2>/dev/null && pwd -P)" ]; then
    return 1
  fi
  echo "$p"
}
timebox() {  # timebox <secs> <cmd…> → exit 124 on timeout (as session-registry.sh)
  perl -e '$t = shift; $p = fork // exit 1;
    if (!$p) { setpgrp(0, 0); exec @ARGV or exit 127 }
    $SIG{ALRM} = sub { kill "KILL", -$p; waitpid $p, 0; exit 124 };
    alarm $t; waitpid $p, 0; exit($? & 127 ? 128 + ($? & 127) : $? >> 8)' "$@"
}
adhoc_gone() {  # adhoc_gone <record> → 0 when its conversation is gone
  local f="$1" b h p fg j hc
  b="$(jq -r '.backend // empty' "$f")"; h="$(jq -r '.handle // empty' "$f")"
  p="$(jq -r '.claude_pid // empty' "$f")"
  [ -n "$h" ] || return 0
  case "$b" in
    tmux) sh_tmux has-session -t "=$h" 2>/dev/null || return 0
          fg="$(sh_tmux display-message -p -t "=$h:" '#{pane_current_command}' 2>/dev/null || true)" ;;
    herdr) hc="$(hc_bin)" || return 0
           j="$(timebox 2 "$hc" get "$h" --json 2>/dev/null)" || return 0
           fg="$(jq -r '.foreground.argv[0] // empty | strings' <<<"$j" 2>/dev/null)"; fg="${fg##*/}" ;;
    *) return 0 ;;
  esac
  case "$fg" in claude*) ;; *) return 0 ;; esac
  [ -z "$p" ] || kill -0 "$p" 2>/dev/null || return 0
  return 1
}
adhoc_lines() {  # one paste-ready resume line per gone ad-hoc conversation
  local f sid cwd
  for f in "$REG"/adhoc-*.json; do
    [ -f "$f" ] || continue
    [ -z "$(jq -r '.ended_at // empty' "$f" 2>/dev/null)" ] || continue
    sid="$(jq -r '.session_id // empty | strings' "$f" 2>/dev/null)"
    [[ "$sid" =~ ^[A-Za-z0-9-]{8,64}$ ]] || continue
    adhoc_gone "$f" || continue
    cwd="$(jq -r '.cwd // empty | strings' "$f")"
    echo "$(jq -r '[.tab, .name, .handle] | map(select(. != null and . != "")) | first // "?"' "$f") — cd $(sh_quote "$cwd") && claude --resume $sid"
  done
}

up() {
  local only="${1:-}" list r rc=0 st todo="" res="" out err cli sid ch cmd name trust="" wait="" panes mw
  sh_pick_host "$MAIN" >/dev/null || exit $?
  roles_validate || exit 2
  roles_lock "$REG" "${TEAM_ROLES_LOCK_WAIT:-30}" || exit 1
  trap 'roles_unlock "$REG"' EXIT
  list="$(roles_list --standing)" || exit 2
  if [ -n "$only" ]; then
    printf '%s\n' "$list" | grep -qxF "$only" \
      || { echo "error: $only is not a standing, enabled role of teams.sessions" >&2; exit 2; }
    list="$only"
  fi
  # Each role's inbox exists from its first start, so an empty one reads as empty, not as missing
  # (team-inbox.sh would otherwise create it only with the first message).
  for r in $list; do mkdir -p "$MAIN/.agents/team/inbox/$r/tmp" "$MAIN/.agents/team/inbox/$r/new" \
    "$MAIN/.agents/team/inbox/$r/done"; done
  for r in $list; do
    sh_alive "$r" --main "$MAIN" 2>/dev/null; st=$?
    case "$st" in
      0) res="$res$r: already running"$'\n' ;;
      3) todo="$todo $r" ;;
      *) res="$res$r: failed: liveness probe (exit $st)"$'\n'; rc=1 ;;
    esac
  done
  # shellcheck disable=SC2086
  [ -z "$todo" ] || materialize $todo || exit 1
  err="$(mktemp "${TMPDIR:-/tmp}/roles-start.XXXXXX")"
  for r in $todo; do
    cli="$(roles_cfg "$r" cli)"; sid=""; ch=""
    if [ "$cli" = claude ]; then sid="$(new_sid)"; ch="$(codex_home)"; fi
    cmd="$(launch_cmd "$r" "$sid")" || { res="$res$r: failed: bad model or effort"$'\n'; rc=1; continue; }
    if name="$(sh_start "$r" --main "$MAIN" --kind role --cwd "$MAIN" --cli "$cli" \
         --env "TEAM_SESSION_ROLE=$r" ${ch:+--env "CODEX_HOME=$ch"} \
         ${sid:+--session-id "$sid" --program claude --claude-home auto} -- "$cmd" 2>"$err")"; then
      res="$res$r: started"$'\n'; wait="$wait $r:$name:$cli"
    else
      res="$res$r: failed: $(sed 's/^session-host: //' "$err" | tail -n 1)"$'\n'; rc=1
    fi
  done
  rm -f "$err"
  [ -z "$wait" ] || trust="$(needs_trust "${wait# }")"
  while IFS= read -r out; do
    [ -n "$out" ] || continue
    r="${out%%:*}"
    if [ "$out" = "$r: started" ]; then
      # A codex role's model comes after the held words, so "started (needs trust …" reads the same.
      mw=""; [ "$(roles_cfg "$r" cli)" != codex ] \
        || mw=" — $(codex_model_word "$(roles_cfg "$r" model)" "$(roles_cfg "$r" effort)")"
      echo "$out$(held_word "$r" "$trust")$mw"
    else echo "$out"; fi
  done <<<"$res"
  # Step 3: the running roles into their Herdr tabs (a failure only warns; tmux: nothing).
  layout_place_roles "$MAIN"
  panes="$(layout_panes "$MAIN")"
  for r in $list; do
    placed "$r" "$panes" && continue   # its pane is in a tab: no hint to read
    case "$res" in *"$r: started"*|*"$r: already running"*)
      out="$(sh_hint "$r" --main "$MAIN" 2>/dev/null)" && echo "  $r: $out" ;; esac
  done
  runs_report
  out="$(adhoc_lines)"
  [ -z "$out" ] || printf 'ad-hoc sessions (gone):\n%s\n' "$out" | sed '2,$s/^/  /'
  window_line
  return "$rc"
}

status() {
  local r rc=0 j b alive state n sid seen panes="" pane
  roles_validate || rc=2
  # Under Herdr a PANE column: the tab each role's terminal is in (one window listing per call).
  for r in $(roles_list --standing); do
    [ "$(sh_record_get "$MAIN" "$r" backend)" != herdr ] || { panes="$(layout_panes "$MAIN")"; break; }
  done
  printf '%-12s %-7s %-7s %-9s %-5s %-36s %s' ROLE BACKEND ALIVE STATE INBOX SESSION LAST_SEEN
  if [ -n "$panes" ]; then printf ' PANE\n'; else printf '\n'; fi
  for r in $(roles_list --standing); do
    b="$(sh_record_get "$MAIN" "$r" backend)"
    if j="$(sh_status "$r" --main "$MAIN" 2>/dev/null)"; then
      state="$(jq -r '.state // "-"' <<<"$j")"
      if [ "$state" = gone ]; then
        alive=gone
        [ "$(sh_record_get "$MAIN" "$r" stopped_at)" \> "$(sh_record_get "$MAIN" "$r" started_at)" ] && alive=stopped
      else alive=alive; fi
    else alive=unknown state=-; rc=1
    fi
    n="$(ls "$MAIN/.agents/team/inbox/$r/new" 2>/dev/null | wc -l | tr -d ' ')"
    sid="$(sh_record_get "$MAIN" "$r" session_id)"; seen="$(sh_record_get "$MAIN" "$r" last_seen)"
    printf '%-12s %-7s %-7s %-9s %-5s %-36s %s' "$r" "${b:--}" "$alive" "$state" "$n" "${sid:--}" "${seen:--}"
    if [ -n "$panes" ]; then
      pane="$(printf '%s\n' "$panes" | awk -F'\t' -v r="$r" '$1 == r { print $2 }')"
      printf ' pane: %s\n' "${pane:--}"
    else printf '\n'; fi
  done
  echo "interrupted runs:"
  runs_report | sed 's/^interrupted runs: none$/none/; s/^/  /'
  echo "ad-hoc sessions (gone):"
  n="$(adhoc_lines)"; printf '%s\n' "${n:-none}" | sed 's/^/  /'
  return "$rc"
}

stop() {
  local t="${1:-all}" r list rc=0 st
  if [ "$t" = all ]; then list="$(roles_list --standing)"
  else
    roles_is_declared "$t" || { echo "error: $t is not a role of teams.sessions" >&2; exit 2; }
    list="$t"
  fi
  for r in $list; do
    sh_alive "$r" --main "$MAIN" 2>/dev/null; st=$?
    case "$st" in
      0) if sh_kill "$r" --main "$MAIN" --graceful 15 >/dev/null; then
           [ ! -f "$(sh_record_file "$MAIN" "$r")" ] \
             || sh_record_put "$MAIN" "$r" '.stopped_at = $at' --arg at "$(sh_utc)"
           echo "$r: stopped"
         else echo "$r: still running"; rc=1; fi ;;
      3) echo "$r: not running" ;;
      *) echo "$r: failed: liveness probe (exit $st)"; rc=1 ;;
    esac
  done
  return "$rc"
}

# here <Role> — this terminal's own handle goes into the record: Herdr's terminal id, the tmux
# session, or (a plain terminal) this shell's pid and start time, which `exec` keeps for the CLI.
here() {
  local r="${1:-}" be h="" name="" hcm="" cli m e s c t sid="" ch="" w="" flags="${TEAM_SESSIONS_CLAUDE_FLAGS:-}"
  [ -n "$r" ] || usage
  if [ "${CLAUDECODE:-}" = 1 ]; then
    echo "refused: a running Claude session cannot take a role — open a new terminal and run: bash .claude/lib/roles.sh here $r" >&2
    exit 1
  fi
  roles_validate || exit 2
  standing "$r" || { echo "error: $r is not a standing, enabled role of teams.sessions" >&2; exit 2; }
  sh_alive "$r" --main "$MAIN" 2>/dev/null
  case $? in
    0) echo "refused: $r is already running ($(sh_hint "$r" --main "$MAIN" 2>/dev/null))" >&2; exit 1 ;;
  esac
  if [ -n "${HC_TERMINAL_ID:-}" ] && [[ "$HC_TERMINAL_ID" =~ ^[A-Za-z0-9_/-]+$ ]]; then
    be=herdr h="$HC_TERMINAL_ID" name="$HC_TERMINAL_ID"
    # The identity guard of the driver (sh_herdr_handle): this terminal's creation time.
    hcm="$(sh_herdr_get "$h" 2>/dev/null | jq -r '.created_ms // empty | tostring' 2>/dev/null)"
  elif [ -n "${TMUX:-}" ] && name="$(sh_tmux display-message -p '#S' 2>/dev/null)" && [ -n "$name" ]; then
    be=tmux h="$name"
  else
    be=none name=""
  fi
  cli="$(roles_cfg "$r" cli)"
  m="$(roles_cfg "$r" model)" && e="$(roles_cfg "$r" effort)" || exit 2
  if [ "$cli" = claude ]; then
    materialize "$r" || exit 1
    . "$LIB/team-profile.sh"
    w="$(team_claude_home "$MAIN")" || { echo "refused: $w" >&2; exit 1; }
    sid="$(new_sid)"; ch="$(codex_home)"
  fi
  t="$(tty 2>/dev/null)" || t=none
  sh_record_put "$MAIN" "$r" '{address: $a, kind: "role", backend: $b, handle: $h, name: $n, cwd: $cwd,
      cli: $cli, started_at: $at, pid: ($pid | tonumber), pid_start: $ps, tty: $tty}
    + (if $cli == "claude" then {program: "claude", session_id: $sid} else {} end)
    + (if $hcm != "" then {created_ms: $hcm} else {} end)' \
    --arg a "$r" --arg b "$be" --arg h "$h" --arg n "$name" --arg hcm "$hcm" --arg cwd "$MAIN" --arg cli "$cli" \
    --arg at "$(sh_utc)" --arg pid "$$" --arg ps "$(sh_lstart $$)" --arg tty "$t" \
    --arg sid "$sid" || { echo "error: the registry record could not be written" >&2; exit 1; }
  cd "$MAIN" || exit 1
  # env options first, then the assignments: the role's identity, as the driver gives a started one.
  set -- -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN
  [ "$cli" != claude ] || [ -n "$w" ] || set -- "$@" -u CLAUDE_CONFIG_DIR
  set -- "$@" TEAM_SESSION_ROLE="$r" HARNESS_ADDRESS="$r" HARNESS_MAIN="$MAIN" HARNESS_REGISTRY="$REG" \
    HARNESS_BACKEND="$be"
  [ -z "$w" ] || set -- "$@" CLAUDE_CONFIG_DIR="$w"
  [ -z "$ch" ] || set -- "$@" CODEX_HOME="$ch"
  if [ "$cli" = codex ]; then
    c="$(roles_cfg "$r" contract)"
    echo "$r: $(codex_model_word "$m" "$e")"
    set -- "$@" codex --no-daemon
    [ "$m" = default ] || set -- "$@" -m "$m"
    exec env "$@" -c "model_reasoning_effort=$e" "$(boot "$r") Contract: $c"
  fi
  s="$(roles_cfg "$r" settings)"
  # shellcheck disable=SC2086
  exec env "$@" claude --name "$(claude_name "$r")" --session-id "$sid" --model "$m" --effort "$e" \
    ${s:+--settings ".agents/team/watch/profiles/$r.settings.json"} $flags -- "$(boot "$r")"
}

# resume_ring <role> → ", inbox N rung" (or why not) when the role's inbox holds messages, else
# nothing. A resumed conversation gets no bootstrap line, so no turn starts by itself: one doorbell
# makes it reconcile. Its result never changes resume's exit code. Herdr refuses a terminal with no
# status yet (still starting): the ring is then deferred to the inbox hook on the next prompt.
resume_ring() {
  local n rc
  n="$(find "$MAIN/.agents/team/inbox/$1/new" -type f ! -name '.*' 2>/dev/null | wc -l | tr -d ' ')"
  [ "${n:-0}" -gt 0 ] || return 0
  sh_send "$1" "inbox: $n waiting — reconcile .agents/team/inbox/$1/new" --main "$MAIN" >/dev/null 2>&1; rc=$?
  if [ "$rc" = 0 ]; then echo ", inbox $n rung"
  elif [ "$rc" = 9 ] && [ "$(sh_record_get "$MAIN" "$1" backend)" = herdr ] \
    && [ -z "$(sh_herdr_state "$(sh_target "$MAIN" "$1" 2>/dev/null)" 2>/dev/null)" ]; then
    echo ", inbox $n waiting — ring deferred (still starting)"
  else echo ", inbox $n waiting — ring $rc"; fi
}

# resume <Role> — a gone Claude role on its previous conversation, started like `up` otherwise.
resume() {
  local r="${1:-}" sid name cmd ch err rc=0
  [ -n "$r" ] || usage
  roles_validate || exit 2
  standing "$r" || { echo "error: $r is not a standing, enabled role of teams.sessions" >&2; exit 2; }
  [ "$(roles_cfg "$r" cli)" = claude ] || { echo "refused: Codex roles restore fresh — bash .claude/lib/roles.sh up $r" >&2; exit 2; }
  sh_alive "$r" --main "$MAIN" 2>/dev/null
  case $? in
    3) ;;
    0) echo "refused: $r is running" >&2; exit 1 ;;
    *) echo "refused: $r: liveness probe failed" >&2; exit 1 ;;
  esac
  sid="$(sh_record_get "$MAIN" "$r" session_id)"
  [[ "$sid" =~ ^[A-Za-z0-9-]{8,64}$ ]] || { echo "refused: no previous session for $r" >&2; exit 1; }
  roles_lock "$REG" "${TEAM_ROLES_LOCK_WAIT:-30}" || exit 1
  trap 'roles_unlock "$REG"' EXIT
  materialize "$r" || exit 1
  cmd="$(launch_cmd "$r" "$sid" resume)" || exit 2
  ch="$(codex_home)"; err="$(mktemp "${TMPDIR:-/tmp}/roles-start.XXXXXX")"
  # --session-id: the record keeps the conversation's id until the live session's hook confirms it.
  if name="$(sh_start "$r" --main "$MAIN" --kind role --cwd "$MAIN" --cli claude \
       --env "TEAM_SESSION_ROLE=$r" ${ch:+--env "CODEX_HOME=$ch"} --program claude --claude-home auto \
       --session-id "$sid" -- "$cmd" 2>"$err")"; then
    echo "$r: resumed $sid$(held_word "$r" "$(needs_trust "$r:$name:claude")")$(resume_ring "$r")"
    layout_place_roles "$MAIN"
    placed "$r" "$(layout_panes "$MAIN")" || echo "  $r: $(sh_hint "$r" --main "$MAIN" 2>/dev/null)"
  else
    echo "$r: failed: $(sed 's/^session-host: //' "$err" | tail -n 1)"; rc=1
  fi
  rm -f "$err"
  return "$rc"
}

case "$cmd" in
  up) up "$@" ;;
  resume) resume "$@" ;;
  runs) runs_report "$@" ;;
  status) status ;;
  stop) stop "$@" ;;
  here) here "$@" ;;
  place) [ $# -ge 1 ] || usage
    if roles_is_declared "$1" && [ -n "$(roles_cfg "$1" place.tab 2>/dev/null)" ]; then
      if [ "$(sh_record_get "$MAIN" "$1" backend)" = herdr ]; then layout_place_roles "$MAIN"
      else echo "$1: $(sh_hint "$1" --main "$MAIN" 2>/dev/null)"; fi
    else
      layout_place_team "$MAIN" "$1"
    fi ;;
esac
exit $?
