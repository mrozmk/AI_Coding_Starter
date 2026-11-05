#!/usr/bin/env bash
# team-watch library: tick, heartbeats; delivery lives in team-watch-deliver.sh.
# Sourced by team-watch.sh, session-wake.sh, monitoring.sh and the team-watch-session hook, never
# executed; the caller runs tw_init <main root> first. Runbook: .agents/reference/team-watch.md.
# Bash 3.2 compatible: the open set lives in open.json and is diffed with jq.

. "$(dirname "${BASH_SOURCE[0]}")/team-lib.sh"
. "$(dirname "${BASH_SOURCE[0]}")/team-channel.sh"
. "$(dirname "${BASH_SOURCE[0]}")/team-watch-route.sh"
. "$(dirname "${BASH_SOURCE[0]}")/team-watch-inputs.sh"
. "$(dirname "${BASH_SOURCE[0]}")/team-watch-deliver.sh"

tw_num() {  # tw_num <value> <default> <regex> → value when it matches, else default
  if [[ "$1" =~ $3 ]]; then echo "$1"; else echo "$2"; fi
}

# tw_init <main root> → $root, $TW_DIR, the knobs and the committed channel names (tmux prefix,
# notifier); rc 3 with an error line when the profile's teams.channel block is invalid.
tw_init() {
  root="$1"
  TW_DIR="$root/.agents/team/watch"
  [ "${TEAM_CHANNEL_NAMES_ROOT:-}" = "$root" ] || TEAM_CHANNEL_NAMES_LOADED=""
  team_channel_names "$root" || { echo "error: team-watch needs a valid teams.channel block" >&2
    return 3; }
  TW_SECS="$(tw_num "${TEAM_WATCH_SECS:-}" 15 '^[1-9][0-9]*$')"
  TW_REMIND="$(tw_num "${TEAM_WATCH_REMIND_SECS:-}" 1800 '^[0-9]+$')"
  TW_UNDELIVERED="$(tw_num "${TEAM_WATCH_UNDELIVERED_SECS:-}" 120 '^[0-9]+$')"
  TW_SEND_SECS="$(tw_num "${TEAM_WATCH_SEND_SECS:-}" 5 '^[1-9][0-9]*$')"
  TW_LOCK_SECS="$(tw_num "${TEAM_WATCH_LOCK_SECS:-}" 5 '^[1-9][0-9]*$')"
  TW_PICKUP="$(tw_num "${TEAM_WATCH_PICKUP_SECS:-}" 180 '^[0-9]+$')"
  TW_ESC_UNSENT="$(tw_num "${TEAM_WATCH_ESC_UNSENT_SECS:-}" 180 '^[0-9]+$')"
  TW_PROGRESS="$(tw_num "${TEAM_WATCH_PROGRESS_SECS:-}" 1800 '^[0-9]+$')"
  TW_BATCH_MAX="$(tw_num "${TEAM_WATCH_BATCH_MAX:-}" 25 '^[1-9][0-9]*$')"
  TW_BATCH_BYTES="$(tw_num "${TEAM_WATCH_BATCH_BYTES:-}" 60000 '^[1-9][0-9]*$')"
  TW_BACKLOG_MAX="$(tw_num "${TEAM_WATCH_BACKLOG_MAX:-}" 100 '^[1-9][0-9]*$')"
  mkdir -p "$TW_DIR"
}

tw_log() { echo "team-watch: $(team_utc) $*"; }
tw_now() { date -u +%s; }
tw_mtime() { stat -f %m "$1" 2>/dev/null || echo 0; }
tw_iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }

# tmp + mv in the target dir: a reader never sees a half-written file.
tw_put() {  # tw_put <file> ← stdin
  cat > "$1.tmp.$$" && mv "$1.tmp.$$" "$1"
}

# tw_notify <title> <text> [alarm] — alarms always (as --alarm), signals only with TEAM_NOTIFY=1
# (default off). Through the operator kit's notifier (team_channel_notify); sounds are its concern.
tw_notify() {
  [ "${3:-}" = alarm ] || [ "${TEAM_NOTIFY:-0}" = 1 ] || return 0
  team_channel_notify ${3:+--alarm} "team-watch: $1" "$2"
}

# pr_timebox (team-lib.sh) keeps a signal death non-zero: a killed mail probe must not read as
# "no mail". The name stays for the watch's callers.
tw_timebox() { pr_timebox "$@"; }  # tw_timebox <secs> <cmd...> → exit 124 on timeout

# tw_claim <dir> <wait secs> [max age secs] — mkdir claim with our pid. A claim whose pid is dead,
# or older than max age, is reclaimed: its holder died mid-section and would block us forever.
tw_claim() {
  local d="$1" tries=0 max=$(( $2 * 5 ))
  until mkdir "$d" 2>/dev/null; do
    # A reclaim busy elsewhere counts against the wait like a live holder does.
    if tw_stale "$d" "${3:-}" && tw_reclaim "$d" "${3:-}"; then continue; fi
    [ "$tries" -lt "$max" ] || return 1
    sleep 0.2; tries=$((tries + 1))
  done
  echo $$ > "$d/pid"
}

tw_stale() {  # tw_stale <claim dir> [max age] — dead pid, no pid after 2 s, or past max age
  local p age
  p="$(cat "$1/pid" 2>/dev/null || true)"
  age=$(( $(tw_now) - $(tw_mtime "$1") ))
  { [ -n "$p" ] && ! kill -0 "$p" 2>/dev/null; } || { [ -z "$p" ] && [ "$age" -gt 2 ]; } \
    || { [ -n "${2:-}" ] && [ "$age" -gt "$2" ]; }
}

# tw_reclaim <claim dir> [max age] — removal under <dir>.reclaim, staleness checked again inside.
# Two waiters that judged the same dead holder would otherwise each rm and mkdir, the second
# removing the first one's fresh claim (and a rename-first reclaim races the same way). A
# .reclaim older than 5 s lost its holder inside this function and is cleared. rc 1: busy.
tw_reclaim() {
  local r="$1.reclaim"
  if ! mkdir "$r" 2>/dev/null; then
    [ $(( $(tw_now) - $(tw_mtime "$r") )) -le 5 ] || rm -rf "$r"
    return 1
  fi
  ! tw_stale "$1" "${2:-}" || rm -rf "$1"
  rmdir "$r" 2>/dev/null || true
}

tw_release() {  # only our own claim: a reclaimed one belongs to someone else now
  [ "$(cat "$1/pid" 2>/dev/null || true)" != "$$" ] || rm -rf "$1"
}

tw_lock() { tw_claim "$TW_DIR/lock.d" "$TW_LOCK_SECS"; }
tw_unlock() { tw_release "$TW_DIR/lock.d"; }

# tw_sock_pid → the claude process owning $CLAUDE_CODE_MESSAGING_SOCKET (<dir>/<pid>.sock),
# else the first ancestor whose command ends in `claude`; nothing when neither is found.
tw_sock_pid() {
  local b p c
  b="$(basename "${CLAUDE_CODE_MESSAGING_SOCKET:-}" .sock)"
  if [[ "$b" =~ ^[0-9]+$ ]]; then echo "$b"; return 0; fi
  p="$PPID"
  while [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -gt 1 ]; do
    c="$(ps -o comm= -p "$p" 2>/dev/null)" || return 0
    case "$c" in *claude) echo "$p"; return 0 ;; esac
    p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')" || return 0
  done
}

# tw_write_registration <file> <pid> <id> <role> — caller holds tw_lock. The token is read from
# the environment inside jq, never passed in argv.
tw_write_registration() {
  ( umask 077
    jq -n --arg pid "$2" --arg id "$3" --arg role "$4" --arg at "$(team_utc)" '
      {socket: env.CLAUDE_CODE_MESSAGING_SOCKET, token: env.CLAUDE_CODE_MESSAGING_TOKEN,
       pid: (if $pid == "" then null else ($pid | tonumber) end), id: $id, role: $role,
       registered_at: $at, active: true}' | tw_put "$1" )
}

tw_routing_json() {  # → {mode, receiver, live: {<role>: bool}}
  local m live='{}' r
  m="$(tw_routing)"
  for r in $TW_ROLES; do
    if tw_live "$r"; then live="$(jq -c --arg r "$r" '.[$r] = true' <<<"$live")"; fi
  done
  jq -cn --arg m "$m" --argjson live "$live" '{mode: ($m | split(" ")[0]),
    receiver: ($m | split(" ")[1] // null), live: $live}'
}

# tw_inputs <work dir> → <work dir>/in.json = {now, esc_unsent_secs, snapshot, mail, mail_errors,
# esc_mail, esc_mail_error, snapshot_error, routing, roles} and <work dir>/gen, the routing
# generation the signals were routed with. A failed read is never data: an empty or invalid
# snapshot is snapshot_error, a failed esc_mail probe is esc_mail_error.
tw_inputs() {
  local w="$1" se="" rc=0 ep
  mkdir -p "$TW_DIR/cache"
  rm -f "$w/snap.json"
  tw_gen > "$w/gen"
  TEAM_DASH_CACHE="$TW_DIR/cache" bash "$root/.claude/lib/team-snapshot.sh" --out "$w/snap.json" \
    2> "$w/snap.err" || rc=$?
  if [ "$rc" != 0 ]; then
    se="team-snapshot.sh exit $rc: $(tail -n 1 "$w/snap.err" | cut -c1-160)"
  elif ! jq -e 'type == "object" and .schema == 1 and (.teams | type) == "array"' "$w/snap.json" \
    >/dev/null 2>&1; then
    se="team-snapshot.sh wrote no valid snapshot"
  fi
  [ -z "$se" ] || echo null > "$w/snap.json"
  # Concurrent like tw_mail's probes: two sequential timeouts outlast the dog's 2 × TW_SECS.
  tw_esc_mail "$w" & ep=$!
  tw_mail "$w"
  wait "$ep" || true
  tw_role_panes "$w" || echo '{}' > "$w/roles.json"
  jq -n --slurpfile s "$w/snap.json" --slurpfile m "$w/mail.json" \
    --slurpfile me "$w/mail_err.json" --slurpfile em "$w/esc_mail.json" --arg se "$se" \
    --argjson r "$(tw_routing_json)" \
    --slurpfile ro "$w/roles.json" \
    --argjson now "$(tw_now)" --argjson eu "$TW_ESC_UNSENT" '
    {now: $now, esc_unsent_secs: $eu,
     snapshot: (if $se == "" then $s[0] else null end), mail: $m[0], mail_errors: $me[0],
     esc_mail: ($em[0].lines // []), esc_mail_error: $em[0].error,
     snapshot_error: (if $se == "" then null else $se end), routing: $r,
     roles: ($ro[0] // {})}' \
    > "$w/in.json"
}

tw_signals() {  # tw_signals <work dir> → <work dir>/sig.json
  tw_inputs "$1" && jq -f "$root/.claude/lib/team-watch-signals.jq" "$1/in.json" > "$1/sig.json"
}

# tw_last_seq → the last event's seq, 0 without events. A last line with no integer seq (a write
# cut short) is rc 1 and a log line, never 0: new seqs restarting at 1 would sit below every cursor
# and never be delivered. Callers append nothing until it is repaired.
tw_last_seq() {
  local l s
  l="$(tail -n 1 "$TW_DIR/events.jsonl" 2>/dev/null)" || l=""
  [ -n "$l" ] || { echo 0; return 0; }
  s="$(jq -r '.seq' <<<"$l" 2>/dev/null)" || s=""
  case "$s" in
    ''|*[!0-9]*)
      tw_log "events.jsonl: last line has no seq (truncated?) — nothing is appended until it is repaired" >&2
      return 1 ;;
  esac
  echo "$s"
}

tw_cursor() {  # tw_cursor <role>
  local c
  c="$(cat "$TW_DIR/cursor.$1" 2>/dev/null || echo 0)"
  tw_num "$c" 0 '^[0-9]+$'
}

tw_tiers() {
  local t
  t="$(jq -r '.tiers // "on"' "$TW_DIR/state.json" 2>/dev/null)" || t=on
  echo "${t:-on}"
}

tw_answering() {
  local t
  t="$(jq -r '.answering // "on"' "$TW_DIR/state.json" 2>/dev/null)" || t=on
  echo "${t:-on}"
}

tw_append_to() {  # tw_append_to <role> <label> <text> [class] — caller holds tw_lock
  local last
  last="$(tw_last_seq)" || return 1
  jq -cn --argjson seq "$(( last + 1 ))" --arg at "$(team_utc)" --arg to "$1" \
    --arg l "$2" --arg t "$3" --arg c "${4:-}" \
    '{seq: $seq, at: $at, to: $to, label: $l, text: $t}
     + (if $c == "" then {} else {class: $c} end)' >> "$TW_DIR/events.jsonl"
}

tw_reg_ids() {  # → {<role>: <active registration id>}
  local f ids='{}' r i
  for f in "$TW_DIR"/receivers/*.json; do
    [ -f "$f" ] || continue
    r="$(basename "$f" .json)"
    i="$(jq -r 'select(.active == true) | .id // empty' "$f" 2>/dev/null)" || i=""
    [ -z "$i" ] || ids="$(jq -c --arg r "$r" --arg i "$i" '.[$r] = $i' <<<"$ids")"
  done
  echo "$ids"
}

tw_cursors() {  # → {<role>: <cursor>} for every receiver an event can be addressed to
  local c='{}' r
  for r in $TW_ROLES; do
    c="$(jq -c --arg r "$r" --argjson v "$(tw_cursor "$r")" '.[$r] = $v' <<<"$c")"
  done
  echo "$c"
}

# tw_update <sig file> — caller holds tw_lock. New keys → one event each; keys gone → dropped
# (open-interval rule: the same condition reopening is a new delivery); keys open longer than
# TW_REMIND → `(reminder)`. A receiver's new registration sees its open keys as new:
# `(current state)`. A result routed with an older routing generation is discarded. `notify`
# lists new role-attention heads: a role session's prompt also gets a platform notification.
# Events carry the signal key.
tw_update() {
  local res w base
  w="$(dirname "$1")"; res="$w/update.json"
  if [ -f "$w/gen" ] && [ "$(cat "$w/gen")" != "$(tw_gen)" ]; then
    tw_log "tick: routing changed while collecting — result discarded"; return 0
  fi
  [ -s "$TW_DIR/open.json" ] || echo '{}' > "$TW_DIR/open.json"
  touch "$TW_DIR/events.jsonl" "$TW_DIR/deliveries.jsonl"
  jq -n --slurpfile o "$TW_DIR/open.json" --slurpfile s "$1" --argjson ids "$(tw_reg_ids)" \
    --argjson now "$(tw_now)" --argjson rem "$TW_REMIND" \
    --argjson split "$([ "$(tw_routing)" = split ] && echo true || echo false)" '
    ($o[0] // {}) as $old | ($old.registrations // {}) as $regs
    | [ $s[0] | unique_by(.key)[] | . as $g
        | (($regs[$g.to] // "") == ($ids[$g.to] // "")) as $same
        | (if $same then ($old.keys // {})[$g.key] else null end)
        | (if . != null and .to != null and .to != $g.to then null else . end) as $p
        | if $p == null then {g: $g, label: (if $same then "" else "(current state)" end),
            st: {opened: $now, reminded: $now, to: $g.to}}
          elif $now - $p.reminded >= $rem and $g.kind != "silence" then
            {g: $g, label: "(reminder)", st: {opened: $p.opened, reminded: $now, to: $g.to}}
          else {g: $g, label: null, st: $p} end ] as $rows
    | {open: {registrations: $ids,
              keys: ($rows | map({key: .g.key, value: .st}) | from_entries)},
       events: [ $rows[] | select(.label != null)
                 | {to: .g.to, key: .g.key, label,
                    text: ([.g.head] + (.g.screen | map("  | " + .)) | join("\n"))} ],
       text: [ $rows[] | (if $split then "[\(.g.to)] " else "" end) as $pre
               | $pre + .g.head, (.g.screen[] | "  | " + .) ],
       notify: [ $rows[] | select(.g.kind == "role-attention"
                   and (.label == "" or .label == "(current state)")) | .g.head ]}' > "$res" \
    || return 1
  base="$(tw_last_seq)" || return 1
  jq -c --argjson base "$base" --arg at "$(team_utc)" '
    .events | to_entries[]
    | {seq: ($base + .key + 1), at: $at, to: .value.to, key: .value.key, label: .value.label,
       text: .value.text}' \
    "$res" >> "$TW_DIR/events.jsonl"
  jq '.open' "$res" | tw_put "$TW_DIR/open.json"
  jq -r '.text[]' "$res" | tw_put "$TW_DIR/open.txt"
}

tw_tick() {
  local w rc=0
  w="$(mktemp -d "$TW_DIR/work.XXXXXX")"
  if ! tw_signals "$w"; then
    tw_log "tick: inputs or filter failed"; rm -rf "$w"; return 1
  fi
  if tw_lock; then
    tw_update "$w/sig.json" || { rc=1; tw_log "tick: state update failed"; }
    tw_unlock
  else
    rc=1; tw_log "tick: state lock busy"
  fi
  jq -r '.notify[]' "$w/update.json" 2>/dev/null | while IFS= read -r h; do
    tw_notify "role prompt" "$h"
  done
  rm -rf "$w"
  tw_deliver || true
  return "$rc"
}

tw_undelivered() {  # tw_undelivered <role> — one notification (and alarm) per outage episode
  local s="$TW_DIR/undelivered.$1.since"
  [ -f "$s" ] || tw_now > "$s"
  if [ $(( $(tw_now) - $(cat "$s") )) -ge "$TW_UNDELIVERED" ] \
    && [ ! -f "$TW_DIR/undelivered.$1.notified" ]; then
    tw_notify "$1 not receiving" "re-register in its window: bash .claude/lib/team-watch.sh register" alarm
    touch "$TW_DIR/undelivered.$1.notified"
    # Queued, not sent: we hold send.d, so the target gets it on this or the next loop.
    if [ "$1" != "$(tw_alarm_target)" ] && tw_live "$(tw_alarm_target)" && tw_lock; then
      tw_append_to "$(tw_alarm_target)" "" "UNDELIVERED $1 ($(( $(tw_now) - $(cat "$s") ))s)" \
        alarm || tw_log "UNDELIVERED $1: alarm not queued"
      tw_unlock
    fi
  fi
}

tw_delivered() { rm -f "$TW_DIR/undelivered.$1.since" "$TW_DIR/undelivered.$1.notified"; }

tw_beat() { echo "$(tw_now) $2 v$TW_VERSION" | tw_put "$TW_DIR/$1"; }

tw_age() {  # tw_age <beat file> → seconds since its beat; huge when absent
  local t
  t="$(cut -d' ' -f1 "$TW_DIR/$1" 2>/dev/null)" || t=""
  [[ "$t" =~ ^[0-9]+$ ]] || { echo 999999999; return 0; }
  echo $(( $(tw_now) - t ))
}

tw_fresh() { [ "$(tw_age "$1")" -le $(( 2 * TW_SECS )) ]; }
tw_current() { tw_fresh "$1" && grep -q " v$TW_VERSION\$" "$TW_DIR/$1" 2>/dev/null; }
tw_loops_ok() { tw_fresh beat && tw_fresh dog.beat; }

tw_receiver_line() {  # tw_receiver_line <role> → its status line, never the token; rc 1 when none
  local f s
  f="$(tw_receiver_file "$1")"
  [ -f "$f" ] || return 1
  s="$(jq -r '.socket // ""' "$f")"
  jq -r --arg st "$(tw_sock_state "$s")" '
    "receiver \(.role // "?"): pid \(.pid // "?") · socket \($st)"
    + " · \(if .active then "active" else "inactive" end)"
    + " · since \(.registered_at // "?")"' "$f"
}

# tw_check_peer <peer beat> <alarm flag> <name> — notify first, then report, so a hung receiver
# or a hung daemon holding the lock cannot silence the alarm. An absent beat is not an outage.
tw_check_peer() {
  local f="$TW_DIR/$1" flag="$TW_DIR/$2" t
  [ -f "$f" ] || return 0
  if [ "$(tw_age "$1")" -gt $(( 2 * TW_SECS )) ]; then
    [ ! -f "$flag" ] || return 0
    t="$(tw_iso "$(cut -d' ' -f1 "$f")" 2>/dev/null)" || t="?"
    touch "$flag"
    tw_notify "$3 dead" "last beat $t — run bash .claude/lib/team-watch.sh start" alarm
    tw_alarm - "MONITOR $3 dead (last beat $t)"
  elif [ -f "$flag" ]; then
    rm -f "$flag"
    tw_alarm - "MONITOR $3 recovered"
  fi
}
