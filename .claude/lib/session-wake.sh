#!/usr/bin/env bash
# Wake loop of a role session: run as Bash run_in_background. On a wake it pushes one message
# into its own session over the messaging socket, then exits. Sends no keys.
# Usage: bash .claude/lib/session-wake.sh   (role = TEAM_SESSION_ROLE, sources from monitoring.json)
#   knobs: TEAM_WAKE_SECS (3, prompts), TEAM_WAKE_SLOW_SECS (30, mail and pending),
#          TEAM_WAKE_CLAUDE_PID (the session's claude pid, else found from the socket or ancestors)
# Runbook: .agents/reference/team-watch.md#wake-loops
set -euo pipefail

LIB="$(cd "$(dirname "$0")" && pwd)"
. "$LIB/team-watch-lib.sh"
tw_init "$(git rev-parse --show-toplevel)"
[ ! -f "$root/.agents/team/team.json" ] \
  || { echo "error: team clone — run session-wake.sh from the main checkout" >&2; exit 1; }
cd "$root"

role="${TEAM_SESSION_ROLE:-}"
tw_session_role_ok "$role" \
  || { echo "error: TEAM_SESSION_ROLE unset or unknown — run in a role session" >&2; exit 2; }
DECL="$(tw_monitoring_file)"
WAKE="$(jq -c --arg r "$role" '.roles[$r].wake // {} | objects' "$DECL" 2>/dev/null)" || WAKE='{}'
[ "$(jq length <<<"$WAKE")" != 0 ] || { echo "wake: none declared for $role"; exit 0; }
REMIND="$(tw_num "$(jq -r '.remind_secs // ""' "$DECL" 2>/dev/null)" 1800 '^[0-9]+$')"
SECS="$(tw_num "${TEAM_WAKE_SECS:-}" 3 '^[1-9][0-9]*$')"
SLOW="$(tw_num "${TEAM_WAKE_SLOW_SECS:-}" 30 '^[1-9][0-9]*$')"

wake_grace() { tw_num "$(jq -r --arg s "$1" '.[$s] // ""' <<<"$WAKE")" "" '^[0-9]+$'; }

cpid="${TEAM_WAKE_CLAUDE_PID:-}"
[ -n "$cpid" ] \
  || cpid="$(tw_sock_pid)" \
  || cpid=""
[[ "$cpid" =~ ^[0-9]+$ ]] \
  || { echo "error: no claude process found — run from a Claude session" >&2; exit 2; }

WD="$TW_DIR/wake"
PF="$WD/$role.json"
mkdir -p "$WD" && chmod 700 "$WD"

wake_mine() { [ "$(jq -r '.pid // ""' "$PF" 2>/dev/null)" = "$$" ]; }

# Under the state lock: two arms in one turn must not both believe they hold the role.
wake_arm() {
  local p c s
  tw_lock || { echo "error: team-watch state lock busy" >&2; exit 1; }
  if [ -f "$PF" ]; then
    IFS=$'\t' read -r p c s <<<"$(jq -r '[.pid, .claude_pid, .since] | map(tostring) | @tsv' \
      "$PF" 2>/dev/null)" || p=""
    if [[ "${p:-}" =~ ^[0-9]+$ ]] && [[ "${c:-}" =~ ^[0-9]+$ ]] && kill -0 "$p" 2>/dev/null \
      && kill -0 "$c" 2>/dev/null; then
      tw_unlock
      if [ "$c" = "$cpid" ]; then echo "ALREADY-ARMED pid $p since $s"
      else echo "HELD by pid $p (claude $c)"; fi
      exit 0
    fi
  fi
  jq -n --argjson pid "$$" --argjson c "$cpid" --arg since "$(team_utc)" \
    --argjson src "$(jq -c keys <<<"$WAKE")" --argjson secs "$SECS" \
    '{pid: $pid, claude_pid: $c, since: $since, secs: $secs, sources: $src}' \
    | ( umask 077; tw_put "$PF" )
  tw_now > "$WD/$role.beat"
  tw_unlock
}

MAILCMD=""
if [ -n "$(wake_grace mail)" ]; then
  MAILCMD="$(jq -r --arg r "$role" '.mail[$r] // .wake_mail[$r] // ""' \
    "$root/.agents/team/watch.local.json" 2>/dev/null)" || MAILCMD=""
fi

wake_arm
T="$(mktemp -d "$WD/$role.XXXXXX")"
trap 'rm -rf "$T"; ! wake_mine || rm -f "$PF" "$WD/$role.beat"' EXIT
if [ -n "$(wake_grace mail)" ] && [ -z "$MAILCMD" ]; then
  echo "wake: mail source not configured for $role (watch.local.json .wake_mail)"
fi

# wake_panes → one item per team role pane showing a prompt, keyed by the hash of its last 30
# lines: a second question of the same role is a new screen, hence a new wake.
wake_panes() {
  local d t r s scr
  for d in $(team_clone_dirs "$root"); do
    t="$(jq -r '.team // empty' "$d/team.json" 2>/dev/null)" || continue
    for r in planner coder qa wrapup cli; do
      s="$t-$r"
      team_tmux_alive "$s" || continue
      scr="$(team_pane "$s" 30 2>/dev/null)" || continue
      grep -Eq 'Enter to select|Do you want to|Ready to submit' <<<"$scr" || continue
      printf 'prompt:%s:%s\tteam-prompts\t%s: %s\n' "$s" \
        "$(printf '%s' "$scr" | shasum -a 1 | cut -c1-16)" "$s" \
        "$(grep -E 'Enter to select|Do you want to|Ready to submit' <<<"$scr" | head -n 1 \
          | sed -E 's/^[[:space:]]+//' | cut -c1-140 | tr '\t' ' ')"
    done
  done
}

# wake_items <source> → "<key>\t<source>\t<text>" per item; rc 1 = the read failed this round.
wake_items() {
  local out now
  case "$1" in
    team-prompts)
      wake_panes
      now="$(tw_now)"
      [ -s "$TW_DIR/open.json" ] || return 0
      jq -r --arg r "$role" --argjson now "$now" '(.keys // {}) | to_entries[]
        | select((.key | startswith("att:")) and .value.to == $r)
        | "prompt:\(.key)\tteam-prompts\t\(.key | .[0:160]) (\($now - (.value.opened // $now))s)"' \
        "$TW_DIR/open.json" 2>/dev/null ;;
    mail)
      out="$(tw_timebox 20 bash -c "$MAILCMD" < /dev/null 2>/dev/null)" || return 1
      printf '%s\n' "$out" | while IFS= read -r l; do
        [ -n "$l" ] || continue
        printf 'mail:%s\tmail\t%s\n' "$(printf '%s' "$l" | shasum -a 1 | cut -c1-16)" \
          "$(printf '%s' "${l:0:160}" | tr '\t' ' ')"
      done ;;
    pending)
      out="$(bash .claude/lib/team-watch.sh pending "$role" 2>/dev/null)" || return 1
      printf '%s\n' "$out" | while IFS= read -r l; do
        [ -n "$l" ] || continue
        printf 'pending:%s\tpending\tbatch #%s (team-watch.sh ack %s)\n' "$l" "$l" "$l"
      done ;;
  esac
}

# FILENAME, not NR == FNR, tells the awk inputs apart: the first file is often empty.
# wake_round <slow 0|1> — refreshes $T/state ("<key>\t<first seen>\t<source>\t<text>"). A source
# not read this round, or whose read failed, keeps its items: a failed probe is never "no mail".
wake_round() {
  local s now
  now="$(tw_now)"; : > "$T/cur"
  for s in team-prompts mail pending; do
    [ -n "$(wake_grace "$s")" ] || continue
    [ "$s" != mail ] || [ -n "$MAILCMD" ] || continue
    if { [ "$s" = team-prompts ] || [ "$1" = 1 ]; } && wake_items "$s" > "$T/items"; then
      cat "$T/items" >> "$T/cur"
    else
      awk -F'\t' -v s="$s" '$3 == s {print $1 "\t" $3 "\t" $4}' "$T/state" >> "$T/cur"
    fi
  done
  awk -F'\t' -v now="$now" 'FILENAME == ARGV[1] {f[$1] = $2; next}
    {print $1 "\t" (($1 in f) ? f[$1] : now) "\t" $2 "\t" $3}' "$T/state" "$T/cur" > "$T/next"
  mv "$T/next" "$T/state"
}

# wake_push <text> — a message into this session (its own socket and token, read inside jq from
# the environment): it starts a turn even while the session idles.
wake_push() {
  [ -n "${CLAUDE_CODE_MESSAGING_SOCKET:-}" ] && [ -S "$CLAUDE_CODE_MESSAGING_SOCKET" ] \
    && [ -n "${CLAUDE_CODE_MESSAGING_TOKEN:-}" ] || return 0
  ( umask 077
    jq -n '{socket: env.CLAUDE_CODE_MESSAGING_SOCKET, token: env.CLAUDE_CODE_MESSAGING_TOKEN}' \
      > "$T/self.json" )
  printf '%s' "$1" | python3 -I "$LIB/team-watch-send.py" "$T/self.json" \
    || echo "wake: push into the session failed — this exit still wakes it"
}

# wake_fire → the items past their source's grace that are new since arming (or past remind_secs).
wake_fire() {
  awk -F'\t' -v now="$(tw_now)" -v armed="$ARMED" -v remind="$REMIND" \
    -v gp="$(wake_grace team-prompts)" -v gm="$(wake_grace mail)" -v gq="$(wake_grace pending)" '
    FILENAME == ARGV[1] {b[$1] = 1; next}
    { g = ($3 == "team-prompts") ? gp : (($3 == "mail") ? gm : gq) }
    now - $2 >= g && (!($1 in b) || now - armed >= remind) {print $3 "\t" $4}' \
    "$T/base" "$T/state"
}

: > "$T/state"
wake_round 1
cut -f1 "$T/state" > "$T/base"
ARMED="$(tw_now)"; LAST_SLOW="$ARMED"
set +e
while :; do
  sleep "$SECS"
  kill -0 "$cpid" 2>/dev/null || exit 0
  wake_mine || exit 0
  tw_now > "$WD/$role.beat"
  # Paused (or the flag unreadable): sleep and read the flag, nothing else.
  if tw_paused "$role" >/dev/null; then : > "$T/state"; continue; fi
  slow=0
  [ $(( $(tw_now) - LAST_SLOW )) -lt "$SLOW" ] || { slow=1; LAST_SLOW="$(tw_now)"; }
  wake_round "$slow" || continue
  wake_fire > "$T/fire" 2>/dev/null || continue
  [ -s "$T/fire" ] || continue
  # wake_round can take up to the slow-source timeout: a stop landing meanwhile must not wake.
  if tw_paused "$role" >/dev/null; then : > "$T/state"; continue; fi
  src="$(head -n 1 "$T/fire" | cut -f1)"
  msg="WAKE $role $src:
$(awk -F'\t' -v s="$src" '$1 == s {print "  " $2}' "$T/fire" | head -n 5)
Handle it, then re-arm in the background: bash .claude/lib/session-wake.sh (the Stop hook enforces it)"
  rm -f "$PF" "$WD/$role.beat"
  wake_push "$msg"
  echo "$msg"
  exit 0
done
