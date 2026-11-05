#!/usr/bin/env bash
# team-watch routing: role-bound receivers, routing table, acks, pickup alarms, handover, stats.
# Sourced by team-watch-lib.sh, never executed; functions only.
# Runbook and state files: .agents/reference/team-watch.md.
# TW_ROLES is the single source of the receiver role names; mirrors to change with it:
# team-watch-signals.jq destinations, tw_contract (team-watch-deliver.sh), the roles of
# .claude/team/sessions/monitoring.json and the role-profile checker of the session launcher.
# TW_SESSION_ROLES adds the session roles that are no receiver; TW_PANE_ROLES are the role
# sessions whose own prompts the daemon scans (the Supervisor answers them).
# TW_LEGACY is only the name of the default single receiver: no routing.json = `single Supervisor`,
# the single-window /monitor. It is a real role that acks; nothing iterates it next to TW_ROLES.

TW_ROLES="Supervisor TeamLead"
TW_PANE_ROLES="TeamLead Advisor"
TW_LEGACY=Supervisor
# A version bump makes `team-watch.sh start` restart running loops.
TW_VERSION=1
TW_SESSION_ROLES="$TW_ROLES Advisor"
TW_ROUTE_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

tw_role_ok() {
  local r
  for r in $TW_ROLES; do [ "${1:-}" != "$r" ] || return 0; done
  return 1
}

tw_session_role_ok() {
  local r
  for r in $TW_SESSION_ROLES; do [ "${1:-}" != "$r" ] || return 0; done
  return 1
}

tw_monitoring_file() { echo "${TEAM_MONITORING_JSON:-$root/.claude/team/sessions/monitoring.json}"; }

# tw_paused <role> → "<UTC since> (<author>)", rc 0 while paused. An unreadable flag is a pause:
# a read error must never let routine through or wake a paused role.
tw_paused() {
  local s v
  s="$(tw_state_json)" || { echo "unreadable state.json"; return 0; }
  v="$(jq -r --arg r "$1" '.paused[$r] // empty
    | if type == "object" then "\(.since // "?") (\(.by // "?"))" else . end
    | select(. != "")' <<<"$s" 2>/dev/null)" || { echo "unreadable state.json"; return 0; }
  [ -n "$v" ] || return 1
  echo "$v"
}

# tw_state_json → the compact state.json object (absent file → {}), rc 1 when the file exists but
# is empty, unreadable or no object: every writer refuses then, so a broken pause is never lost.
tw_state_json() {
  local f="$TW_DIR/state.json"
  [ -e "$f" ] || { echo '{}'; return 0; }
  jq -ce 'objects' "$f" 2>/dev/null
}

# tw_pause_pass <role> → compact .roles[<role>].pause.pass. A broken declaration falls back to
# the incident pass, never to {}: a bad Operator edit must not silence incidents.
TW_PASS_FALLBACK='{"alarms":true,"mail_threads":["incident-"]}'
tw_pause_pass() {
  jq -ce --arg r "$1" '.roles[$r].pause.pass // {} | objects' "$(tw_monitoring_file)" \
    2>/dev/null || echo "$TW_PASS_FALLBACK"
}
tw_alarms_pass() { jq -e '.alarms == true' <<<"$(tw_pause_pass "$1")" >/dev/null 2>&1; }

# tw_tmux_name <role|daemon|dog> — the one source of this checkout's tmux session names, from
# teams.channel.tmux_prefix (team_channel_names, run by tw_init): two checkouts on one machine
# never share a name.
tw_tmux_name() {
  local p="$TEAM_CHANNEL_TMUX_PREFIX"
  case "$1" in
    daemon) echo "$p-team-watch" ;;
    dog) echo "$p-team-watch-dog" ;;
    *) echo "$p-$(echo "$1" | tr '[:upper:]' '[:lower:]')" ;;
  esac
}

tw_receiver_file() { echo "$TW_DIR/receivers/$1.json"; }

tw_routing() {  # → "split" | "single <role>"; no routing.json = the single-window Supervisor
  local f="$TW_DIR/routing.json"
  [ -f "$f" ] || { echo "single $TW_LEGACY"; return 0; }
  jq -r --arg l "$TW_LEGACY" \
    'if .mode == "split" then "split" else "single \(.receiver // $l)" end' "$f" 2>/dev/null \
    || echo "single $TW_LEGACY"
}

tw_gen() { jq -r '.gen // 0' "$TW_DIR/routing.json" 2>/dev/null || echo 0; }

tw_alarm_target() {
  local m
  m="$(tw_routing)"
  if [ "$m" = split ]; then echo Supervisor; else echo "${m#single }"; fi
}

# tw_sock_state <socket path> → `ok 0600` | `missing` | `refused mode <mode>` | `refused owner
# <uid>` | `refused not-a-socket`; rc 0 only for ok. The verdict is team-watch-send.py --check, the
# same predicate the send enforces (exit 3): the messaging token is not enforced by the CLI, so the
# socket file's 0600 mode and owner are the only boundary.
tw_sock_state() {
  local st
  st="$(python3 -I "$TW_ROUTE_LIB/team-watch-send.py" --check "$1" 2>/dev/null)"
  local rc=$?
  echo "${st:-missing}"
  return "$rc"
}

tw_live() {  # tw_live <role> — active registration, pid alive (when known), socket present
  local f p s
  f="$(tw_receiver_file "$1")"
  [ -f "$f" ] || return 1
  p="$(jq -r 'select(.active == true) | .pid // ""' "$f" 2>/dev/null)" || return 1
  s="$(jq -r 'select(.active == true) | .socket // ""' "$f" 2>/dev/null)" || return 1
  [ -n "$s" ] && [ -S "$s" ] || return 1
  [ -z "$p" ] || kill -0 "$p" 2>/dev/null
}

# tw_self_role → this session's role: TEAM_SESSION_ROLE, else the single-routing receiver (the
# single window). Split routing without a role is an error — never a guess.
tw_self_role() {
  local m
  if tw_role_ok "${TEAM_SESSION_ROLE:-}"; then echo "$TEAM_SESSION_ROLE"; return 0; fi
  m="$(tw_routing)"
  if [ "$m" = split ]; then
    echo "error: TEAM_SESSION_ROLE unset or unknown — split routing needs a role session" \
      "(TEAM_SESSION_ROLE=Supervisor|TeamLead)" >&2
    return 1
  fi
  echo "${m#single }"
}

tw_register() {  # tw_register [--takeover]
  local take=0 role f pid old="" m
  case "${1:-}" in
    "") ;; --takeover) take=1 ;; *) echo "error: unknown flag $1" >&2; return 1 ;;
  esac
  [ ! -f "$root/.agents/team/team.json" ] \
    || { echo "error: team clone — run team-watch from the main checkout" >&2; return 1; }
  [ -n "${CLAUDE_CODE_MESSAGING_SOCKET:-}" ] && [ -n "${CLAUDE_CODE_MESSAGING_TOKEN:-}" ] \
    || { echo "error: CLAUDE_CODE_MESSAGING_SOCKET/TOKEN unset — run in a Claude session" >&2
         return 1; }
  [ -S "$CLAUDE_CODE_MESSAGING_SOCKET" ] \
    || { echo "error: $CLAUDE_CODE_MESSAGING_SOCKET is not a socket" >&2; return 1; }
  role="$(tw_self_role)" || return 1
  f="$(tw_receiver_file "$role")"; pid="$(tw_sock_pid)"
  tw_lock || { echo "error: team-watch state lock busy" >&2; return 1; }
  mkdir -p "$TW_DIR/receivers" && chmod 700 "$TW_DIR/receivers"
  [ ! -f "$f" ] || old="$(jq -r 'select(.active == true) | .pid // empty' "$f" 2>/dev/null)" \
    || old=""
  [ "$old" != "$pid" ] || old=""
  if [ -n "$old" ] && [ "$take" = 0 ] && kill -0 "$old" 2>/dev/null; then
    tw_unlock
    echo "error: $role is held by live pid $old — pass --takeover to move it here" >&2
    return 1
  fi
  if ! tw_write_registration "$f" "$pid" "$(tw_now)-$$" "$role"; then
    tw_unlock; echo "error: cannot write $f" >&2; return 1
  fi
  tw_supersede "$role"
  tw_unlock
  [ -z "$old" ] || echo "team-watch: replaced $role pid $old"
  m="$(tw_routing)"
  if [ "$m" != split ] && [ "$role" != "${m#single }" ]; then
    echo "team-watch: $role registered (standby — routing $m)"
  else
    echo "team-watch: $role registered"
  fi
}

# tw_supersede <role> — caller holds tw_lock. The new registration's `(current state)` replay
# carries the open state, so the old batches must not keep a pickup episode alive.
tw_supersede() {
  local d="$TW_DIR"
  touch "$d/deliveries.jsonl" "$d/acks.jsonl"
  jq -cn --arg r "$1" --arg at "$(team_utc)" --argjson t "$(tw_now)" \
    --slurpfile d "$d/deliveries.jsonl" --slurpfile a "$d/acks.jsonl" '
    [$a[] | select(.to == $r and (.state == "done" or .state == "transferred"
      or .state == "superseded")) | .batch] as $closed
    | [$d[] | select(.to == $r and .transferred != true) | .batch] | unique[]
    | select(. as $b | $closed | index($b) | not)
    | {batch: ., to: $r, state: "superseded", at: $at, t: $t}' >> "$d/acks.jsonl"
  [ "$1" != "$(tw_alarm_target)" ] \
    || rm -f "$d"/alarm.recv.* "$d"/alarm.unpicked.* "$d"/alarm.stalled.*
}

tw_ack() {  # tw_ack picked|done <n>
  local st="$1" n="$2" role verdict
  role="$(tw_self_role)" || return 1
  tw_lock || { echo "error: team-watch state lock busy" >&2; return 1; }
  touch "$TW_DIR/deliveries.jsonl" "$TW_DIR/acks.jsonl"
  verdict="$(jq -rn --argjson n "$n" --arg r "$role" --arg st "$st" \
    --slurpfile d "$TW_DIR/deliveries.jsonl" --slurpfile a "$TW_DIR/acks.jsonl" '
    [$a[] | select(.batch == $n and .to == $r)] as $A
    | if any($d[]; .batch == $n and .to == $r) | not then "foreign"
      elif any($A[]; .state == "transferred") then "transferred"
      elif any($A[]; .state == $st) then "duplicate" else "ok" end')"
  case "$verdict" in
    foreign) tw_unlock; echo "error: batch #$n is not $role's" >&2; return 1 ;;
    transferred) tw_unlock
      echo "error: batch #$n was transferred — handle the (current state) batch instead" >&2
      return 1 ;;
  esac
  jq -cn --argjson n "$n" --arg r "$role" --arg st "$st" --arg at "$(team_utc)" \
    --argjson t "$(tw_now)" '{batch: $n, to: $r, state: $st, at: $at, t: $t}' \
    >> "$TW_DIR/acks.jsonl"
  tw_unlock
  if [ "$verdict" = duplicate ]; then echo "$st #$n (duplicate)"; else echo "$st #$n"; fi
}

# tw_pending <role> [<since UTC>] → batch numbers delivered (at/after since) and neither picked
# nor closed
tw_pending() {
  touch "$TW_DIR/deliveries.jsonl" "$TW_DIR/acks.jsonl" 2>/dev/null || return 0
  jq -rn --arg r "$1" --arg since "${2:-}" --slurpfile d "$TW_DIR/deliveries.jsonl" \
    --slurpfile a "$TW_DIR/acks.jsonl" '
    [$a[] | select(.to == $r) | .batch] as $acked
    | [$d[] | select(.to == $r and .transferred != true
        and ($since == "" or (.delivered_at // "") >= $since)) | .batch] | unique[]
    | select(. as $b | $acked | index($b) | not)' 2>/dev/null || true
}

tw_ping() {  # tw_ping <role> — the end-to-end channel check of one receiver
  local s
  tw_lock || { echo "error: team-watch state lock busy" >&2; return 1; }
  # No seq in the text: a batched ping's header names the batch to ack, not this event.
  if ! s=$(( $(tw_last_seq) + 1 )) || ! tw_append_to "$1" "" \
      "PING $1 — confirm: ack the number in this message's header"; then
    tw_unlock; echo "error: team-watch events.jsonl unreadable — ping not queued" >&2; return 1
  fi
  tw_unlock
  tw_deliver || true
  echo "team-watch: ping $1 queued (seq $s) · socket $(tw_sock_state \
    "$(jq -r '.socket // ""' "$(tw_receiver_file "$1")" 2>/dev/null)")"
}

# tw_alarm <subject role|-> <text> — `-` means the caller already notified (tw_check_peer). The
# target is resolved under the lock, so a handover cannot interleave; a subject never alarms
# itself, so alarms never spawn alarms about alarms.
tw_alarm() {
  local target
  [ "$1" = - ] || tw_notify "alarm" "$2" alarm
  if tw_lock; then
    target="$(tw_alarm_target)"
    if [ "$1" = "$target" ] || ! tw_live "$target"; then tw_unlock; return 0; fi
    tw_append_to "$target" "" "$2" alarm || tw_log "alarm not queued: $2"; tw_unlock
    tw_deliver || true
  elif tw_claim "$TW_DIR/send.d" 1 "$(tw_send_max)"; then
    # A hung holder of the state lock must not silence the alarm; send.d excludes a handover.
    target="$(tw_alarm_target)"
    [ "$1" = "$target" ] || ! tw_live "$target" \
      || { tw_paused "$target" >/dev/null && ! tw_alarms_pass "$target"; } \
      || tw_send "$target" "[team-watch alarm] $2 · handle per $(tw_contract "$target")" \
      || tw_undelivered "$target"
    tw_release "$TW_DIR/send.d"
  fi
}

tw_episode() {  # tw_episode <flag> <on|off> <subject> <alarm text> <recovered text> [id]
  local f="$TW_DIR/$1"
  if [ "$2" = on ]; then
    # The flag keeps the batch that opened the episode: acks between daemon runs close it without
    # an `off` cycle, and a new overdue batch must not be swallowed by the stale flag.
    [ ! -f "$f" ] || [ "$(cat "$f" 2>/dev/null)" != "${6:-}" ] || return 0
    printf '%s' "${6:-}" > "$f"; tw_alarm "$3" "$4"
  elif [ -f "$f" ]; then
    rm -f "$f"; tw_alarm "$3" "$5"
  fi
}

tw_overdue() {  # tw_overdue <role> → "<unpicked batch|-> <age> <stalled batch|->"
  touch "$TW_DIR/deliveries.jsonl" "$TW_DIR/acks.jsonl"
  jq -rn --arg r "$1" --argjson now "$(tw_now)" --argjson pk "$TW_PICKUP" \
    --argjson pg "$TW_PROGRESS" --slurpfile d "$TW_DIR/deliveries.jsonl" \
    --slurpfile a "$TW_DIR/acks.jsonl" '
    [$a[] | select(.to == $r)] as $A
    | def acked($b; $s): any($A[]; .batch == $b and (.state as $x | any($s[]; . == $x)));
    def picked_t($b): [$A[] | select(.batch == $b and .state == "picked") | .t] | min;
    [$d[] | select(.to == $r and .transferred != true)] | unique_by(.batch)
    | map(select(acked(.batch; ["done", "transferred", "superseded"]) | not)) as $open
    | ($open | map(select((acked(.batch; ["picked"]) | not) and $now - .t > $pk)) | first)
      as $u
    | ($open | map(select(acked(.batch; ["picked"]) and $now - picked_t(.batch) > $pg))
      | first) as $s
    | "\($u.batch // "-") \(if $u then $now - $u.t else 0 end) \($s.batch // "-")"'
}

# Per active receiver of the routing: liveness, then pickup and progress of its batches. Every
# receiver is a real role that acks, the single-window Supervisor included.
tw_check_receivers() {
  local m roles r a u age s o
  m="$(tw_routing)"
  if [ "$m" = split ]; then roles="$TW_ROLES"; else roles="${m#single }"; fi
  for r in $roles; do
    a="$(jq -r '.active // false' "$(tw_receiver_file "$r")" 2>/dev/null)" || a=false
    [ "$a" = true ] || continue
    if ! tw_live "$r"; then
      tw_episode "alarm.recv.$r" on "$r" "RECEIVER $r down" ""; continue
    fi
    tw_episode "alarm.recv.$r" off "$r" "" "RECEIVER $r recovered"
    o="$(tw_overdue "$r")" || { tw_log "receiver check: $r ledger unreadable"; continue; }
    read -r u age s <<<"$o" || continue
    [ -n "$s" ] || continue
    if [ "$u" != - ]; then
      tw_episode "alarm.unpicked.$r" on "$r" "UNPICKED $r #$u (${age}s)" "" "$u"
    else
      tw_episode "alarm.unpicked.$r" off "$r" "" "UNPICKED $r recovered"
    fi
    if [ "$s" != - ]; then
      tw_episode "alarm.stalled.$r" on "$r" "STALLED $r #$s" "" "$s"
    else
      tw_episode "alarm.stalled.$r" off "$r" "" "STALLED $r recovered"
    fi
  done
}

tw_transfer() {  # caller holds send.d and tw_lock → prints the number of transferred batches
  local d="$TW_DIR" c='{}' f r res
  for f in "$d"/cursor.*; do
    [ -f "$f" ] || continue
    r="${f##*/cursor.}"
    c="$(jq -c --arg r "$r" --argjson v "$(tw_num "$(cat "$f")" 0 '^[0-9]+$')" \
      '.[$r] = $v' <<<"$c")"
  done
  touch "$d/events.jsonl" "$d/deliveries.jsonl" "$d/acks.jsonl"
  res="$(jq -cn --argjson c "$c" --arg at "$(team_utc)" --argjson t "$(tw_now)" \
    --slurpfile e "$d/events.jsonl" --slurpfile dl "$d/deliveries.jsonl" \
    --slurpfile a "$d/acks.jsonl" '
    [$a[] | select(.state == "done" or .state == "transferred" or .state == "superseded")
      | "\(.to)#\(.batch)"] as $closed
    | ([$dl[] | select(.transferred != true)] | unique_by([.to, .batch])
       | map(select("\(.to)#\(.batch)" as $k | $closed | index($k) | not))) as $open
    | [$e[] | select(.to != null and .seq > ($c[.to] // 0))] as $und
    | {acks: [($open[], $und[]) | {batch: (.batch // .seq), to, state: "transferred",
        at: $at, t: $t}],
       dels: [$und[] | {batch: .seq, to, seqs: [.seq], delivered_at: $at, t: $t,
        transferred: true}]}')" || return 1
  jq -c '.dels[]' <<<"$res" >> "$d/deliveries.jsonl"
  jq -c '.acks[]' <<<"$res" >> "$d/acks.jsonl"
  jq '.acks | length' <<<"$res"
}

# tw_handover split | single <role> — send.d first, then the lock (tw_deliver's order), so no
# send is in flight. Signals are state: the next tick re-delivers them as `(current state)`.
tw_handover() {
  local mode="${1:-}" r="${2:-}" n last f to
  case "$mode" in
    split) [ -z "$r" ] ;;
    single) tw_role_ok "$r" ;;
    *) false ;;
  esac || { echo "error: routing split | routing single <role>" >&2; return 2; }
  tw_claim "$TW_DIR/send.d" "$TW_LOCK_SECS" "$(tw_send_max)" \
    || { echo "error: a delivery is in flight — retry" >&2; return 1; }
  if ! tw_lock; then
    tw_release "$TW_DIR/send.d"; echo "error: team-watch state lock busy" >&2; return 1
  fi
  # Every cursor is reset to the last seq below: an unreadable log aborts before anything changes.
  if ! tw_last_seq >/dev/null; then
    tw_unlock; tw_release "$TW_DIR/send.d"
    echo "error: team-watch events.jsonl unreadable — routing unchanged" >&2; return 1
  fi
  jq -n --arg m "$mode" --arg r "$r" --argjson g "$(( $(tw_gen) + 1 ))" \
    'if $m == "split" then {mode: $m, gen: $g} else {mode: $m, receiver: $r, gen: $g} end' \
    | tw_put "$TW_DIR/routing.json"
  n="$(tw_transfer)" || n="?"
  last="$(tw_last_seq)"
  # Every addressee, registered or not: tw_deliver walks all `.to` values, and a role left at
  # cursor 0 would re-raise UNDELIVERED and re-transfer its events on every later handover.
  for to in $( { jq -r '.to // empty' "$TW_DIR/events.jsonl"
                 for f in "$TW_DIR"/receivers/*.json "$TW_DIR"/cursor.*; do
                   [ ! -f "$f" ] || { f="${f##*/}"; f="${f%.json}"; echo "${f#cursor.}"; }
                 done; } | sort -u); do
    echo "$last" | tw_put "$TW_DIR/cursor.$to"
  done
  echo '{"registrations": {}, "keys": {}}' | tw_put "$TW_DIR/open.json"
  rm -f "$TW_DIR"/alarm.recv.* "$TW_DIR"/alarm.unpicked.* "$TW_DIR"/alarm.stalled.*
  tw_unlock; tw_release "$TW_DIR/send.d"
  echo "team-watch: routing $mode${r:+ $r} — $n batches transferred"
}

tw_stats() {  # tw_stats [--since <UTC>]
  local since=""
  case "${1:-}" in
    "") ;;
    --since) since="${2:-}"; [ -n "$since" ] || { echo "error: --since <UTC>" >&2; return 2; } ;;
    *) echo "error: stats [--since <UTC>]" >&2; return 2 ;;
  esac
  touch "$TW_DIR/deliveries.jsonl" "$TW_DIR/acks.jsonl" "$TW_DIR/events.jsonl"
  jq -rn --arg s "$since" --slurpfile d "$TW_DIR/deliveries.jsonl" \
    --slurpfile a "$TW_DIR/acks.jsonl" --slurpfile e "$TW_DIR/events.jsonl" '
    def p50: sort | if length == 0 then "-" else .[((length - 1) / 2 | floor)] end;
    [$d[] | select(.transferred != true and .delivered_at >= $s)] as $D
    | ($D | map(.to) | unique)[] as $r
    | ($D | map(select(.to == $r)) | unique_by(.batch)) as $B
    | [$a[] | select(.to == $r and .state == "picked")] as $P
    | [$B[] | . as $b | [$P[] | select(.batch == $b.batch) | .t] | min
       | select(. != null) | . - $b.t] as $lat
    | ($B | map(.batch)) as $ids
    | "\($r): delivered=\($B | length)"
      + " picked=\([$P[] | .batch | select(. as $x | $ids | index($x))] | unique | length)"
      + " done=\([$a[] | select(.to == $r and .state == "done") | .batch
          | select(. as $x | $ids | index($x))] | unique | length)"
      + " duplicates=\([$P[] | .batch | select(. as $x | $ids | index($x))]
          | group_by(.) | map(length - 1) | add // 0)"
      + " pickup_p50=\($lat | p50)s pickup_max=\($lat | max // "-")s"
      + " unpicked_alarms=\([$e[] | select(.at >= $s and (.text | startswith("UNPICKED \($r) #")))]
          | length)"
      + " stalled_alarms=\([$e[] | select(.at >= $s and (.text | startswith("STALLED \($r) #")))]
          | length)"'
}

# tw_rotate_file <name> <program> <jq args…> — caller holds send.d and the lock. <program> maps the
# file's lines ($L) to [keep, line]. Dropped lines replace <name>.jsonl.1 (one generation).
tw_rotate_file() {
  local f="$TW_DIR/$1.jsonl" prog="$2" t="$TW_DIR/rotate.$$"
  shift 2
  [ -s "$f" ] || return 0
  jq -cn "$@" --slurpfile L "$f" "$prog" > "$t" || { rm -f "$t"; return 1; }
  if jq -e 'select(.[0] | not)' "$t" >/dev/null; then
    jq -c 'select(.[0] | not) | .[1]' "$t" | tw_put "$f.1"
  fi
  jq -c 'select(.[0]) | .[1]' "$t" | tw_put "$f"
  rm -f "$t"
}

# tw_rotate — bounds events/deliveries/acks once one exceeds TEAM_WATCH_ROTATE_BYTES. send.d, then
# the lock (tw_handover's order): no send or cursor commit runs meanwhile; busy → next cycle.
# Kept: anything an addressee has not consumed (cursor per `.to`, default 0), open batches, the
# last event (tw_last_seq stays monotonic) and everything inside TEAM_WATCH_KEEP_SECS; a delivery
# line also while it carries a seq above its addressee's cursor (a pause-delivered incident).
tw_rotate() {
  local d="$TW_DIR" max keep f r c='{}' big=0 rc=0 now
  max="$(tw_num "${TEAM_WATCH_ROTATE_BYTES:-}" 1048576 '^[0-9]+$')"
  keep="$(tw_num "${TEAM_WATCH_KEEP_SECS:-}" 604800 '^[0-9]+$')"
  for f in events deliveries acks; do
    [ "$(wc -c < "$d/$f.jsonl" 2>/dev/null | tr -d ' ' || echo 0)" -le "$max" ] || big=1
  done
  [ "$big" = 1 ] || return 0
  tw_claim "$d/send.d" "$TW_LOCK_SECS" "$(tw_send_max)" || return 0
  if ! tw_lock; then tw_release "$d/send.d"; return 0; fi
  touch "$d/events.jsonl" "$d/deliveries.jsonl" "$d/acks.jsonl"
  for r in $( { jq -r '.to // empty' "$d/events.jsonl"
                for f in "$d"/cursor.*; do [ ! -f "$f" ] || echo "${f##*/cursor.}"; done; } \
              | sort -u); do
    c="$(jq -c --arg r "$r" --argjson v "$(tw_cursor "$r")" '.[$r] = $v' <<<"$c")"
  done
  now="$(tw_now)"
  tw_rotate_file events '($L | last | .seq) as $last | $L[]
    | [(.seq > ($c[.to // ""] // 0) or .seq == $last
        or $now - (.at | try fromdateiso8601 catch 0) < $keep), .]' \
    --argjson c "$c" --argjson now "$now" --argjson keep "$keep" || rc=1
  # Deliveries go before acks: an ack is kept while its batch's delivery line survives.
  tw_rotate_file deliveries '($a | map(select(.state == "done" or .state == "transferred"
      or .state == "superseded") | {key: "\(.to)#\(.batch)", value: true}) | from_entries)
    as $closed | $L[]
    | [(("\(.to)#\(.batch)" | in($closed) | not) or (.to as $t | any(.seqs[]?; . > ($c[$t] // 0)))
        or $now - (.t // 0) < $keep), .]' \
    --slurpfile a "$d/acks.jsonl" --argjson c "$c" --argjson now "$now" --argjson keep "$keep" \
    || rc=1
  tw_rotate_file acks '($k | map({key: "\(.to)#\(.batch)", value: true}) | from_entries) as $kept
    | $L[] | [(("\(.to)#\(.batch)" | in($kept)) or $now - (.t // 0) < $keep), .]' \
    --slurpfile k "$d/deliveries.jsonl" --argjson now "$now" --argjson keep "$keep" || rc=1
  tw_unlock; tw_release "$d/send.d"
  return "$rc"
}
