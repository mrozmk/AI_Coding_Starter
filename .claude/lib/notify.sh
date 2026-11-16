#!/usr/bin/env bash
# The Operator's notification sender — the only code that creates a notification.
# Usage:
#   notify.sh <event> --project <p> --summary "<line>" --answer <address> [--hint "<line>"]
#             [--team <t>] [--ticket <k>] [--run <r>] [--decision <d-n>] [--ref <abs path>]
#             [--key <k>] [--source <who>] [--main <root>] [--now <epoch>] → written <id> | duplicate <id>
#   notify.sh flush [--now <epoch>]   resume pending deliveries (an interrupted send becomes
#                          outcome_unknown, never re-sent); send held iMessage events after quiet hours
#   notify.sh list [--since <days>]   one line per event: id, event, each channel's state, resolved
#   notify.sh resolve (--team <t> --run <r> --decision <d> | --key <k>) [--project <p>]
#                          the Operator answered elsewhere: no further delivery, the strip drops it
#                          → resolved <id> | already resolved <id> | unknown (each exit 0)
#   notify.sh --check      one line per channel and one for the switch file; never waits for the
#                          outbox lock (prune is skipped while a flush or send holds it)
#   events: human_decision · abandon_decision (need --team --run --decision) ·
#           unrepaired_failure · release (need --key, the operator record id). Nothing else.
#
# One event file per id, published write-once (`ln`) into ~/.agent-comms/outbox/events/ — that is
# the dedup. Delivery state per channel in state/<id>.<channel>: pending → dispatching → outcome
# (submitted | failed | outcome_unknown), plus off / held / spooled / skipped-tmux. Herdr (#39):
# herdr/new/<id>.json for the harness-notify mod, only when the answering session's registry record
# (<main>/.agents/team/registry/<address>.json, read as JSON only) says herdr. iMessage (#40), any
# backend: one osascript send with the recipient and the text as argv only (30 s; a pre-send error is
# `failed`, retried at the next call up to 3 attempts; anything else is final); during quiet hours
# the event is `held`, and the first flush after them sends every held event as one message (the
# kit's launchd job runs that flush at quiet.end: .claude/team/notify-kit). Every call prunes files past
# NOTIFY_KEEP_DAYS (default 7; herdr/done 24 h), never one still pending, held or dispatching.
# Resolve (#97): state/<id>.resolved (write-once) stops every delivery not yet made (`skipped
# resolved`, a held overnight message included); a delivered one is never touched. For a herdr
# event it also publishes herdr/new/<id>.resolve, on which the mod drops the strip item.
# The summary is one line, control characters stripped, cut to 200 characters, and stored only
# when a channel's switch is on. The recipient is never read into any output.
# Callers: the runner (team-run-lead.sh lead_notify, team-run-dialog.sh, team-run-stop.sh) and operator-record.sh — never a model
# session (the role profiles deny it).
# Exit: 0 written, duplicate or done (also when delivery is deferred because a flush holds the lock)
#       · 1 the outbox cannot be written, or flush / list cannot get the lock · 2 usage / unknown event.
# Spec: notification model (epic E2) §1–§4. Bash 3.2 compatible; needs jq.
set -euo pipefail
umask 077

NOTIFY_CONF="$HOME/.agent-comms/notify.json"   # the per-machine switch file — the one place it is named
OUT="$HOME/.agent-comms/outbox"
KEEP_MIN=$(( ${NOTIFY_KEEP_DAYS:-7} * 1440 ))
CHANNELS="herdr imessage"
OSA="${NOTIFY_OSASCRIPT_BIN:-/usr/bin/osascript}"   # tests: a stub
JOB="$HOME/Library/LaunchAgents/harness.notify-flush.plist"   # written by the notify kit
LABELS='{human_decision: "decision", abandon_decision: "abandon?", unrepaired_failure: "failure", release: "release"}'
NOW=""   # --now, else NOTIFY_NOW, else the clock

usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
die() { echo "error: $2" >&2; exit "$1"; }
utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }
crash() { [ "${NOTIFY_CRASH_AT:-}" != "$1" ] || exit 137; }   # tests: kill the process at a boundary
part() { [[ "$2" =~ ^[A-Za-z0-9._-]+$ ]] || die 2 "$1 '$2' must be [A-Za-z0-9._-]+"; }

# ---- the switch file -------------------------------------------------------------------------------
# sw_load → SW_herdr / SW_imessage (on|off), WHY_<ch> (why a requested channel is off), CONF_STATE.
SW_herdr=off; SW_imessage=off; WHY_herdr=""; WHY_imessage=""; CONF_STATE="missing"; QSTART=""; QEND=""; QTZ=""
sw_load() {
  local v tz q
  [ -f "$NOTIFY_CONF" ] || return 0
  if ! jq -e 'type == "object"' "$NOTIFY_CONF" >/dev/null 2>&1; then CONF_STATE="invalid — not a JSON object"; return 0; fi
  v="$(jq -r '.version // empty' "$NOTIFY_CONF")"
  [ "$v" = 1 ] || { CONF_STATE="invalid — version ${v:-missing}, expected 1"; return 0; }
  CONF_STATE="ok"
  [ "$(jq -r '.herdr.enabled == true' "$NOTIFY_CONF")" != true ] || SW_herdr=on
  [ "$(jq -r '.imessage.enabled == true' "$NOTIFY_CONF")" = true ] || return 0
  if [ "$(jq -r '(.imessage.recipient // "") | type == "string" and length > 0' "$NOTIFY_CONF")" != true ]; then
    WHY_imessage="empty recipient"; return 0
  fi
  for q in start end; do
    v="$(jq -r --arg q "$q" '.imessage.quiet[$q] // empty' "$NOTIFY_CONF")"
    [[ "$v" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { WHY_imessage="quiet.$q '${v}' is not HH:MM"; return 0; }
    if [ "$q" = start ]; then QSTART="$v"; else QEND="$v"; fi
  done
  # `TZ=<tz> date` is no check: an unknown zone silently means UTC on macOS.
  tz="$(jq -r '.imessage.quiet.tz // empty' "$NOTIFY_CONF")"
  if ! [[ "$tz" =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ ]] || [ ! -f "${TZDIR:-/usr/share/zoneinfo}/$tz" ]; then
    WHY_imessage="unknown tz ${tz:-(empty)}"; return 0
  fi
  [ -x "$OSA" ] || { WHY_imessage="no osascript (macOS only)"; return 0; }
  QTZ="$tz"; SW_imessage=on
}
sw_warn() {  # one stderr line per process for a channel that was asked for and is off
  local c w
  for c in $CHANNELS; do eval "w=\$WHY_$c"; [ -z "$w" ] || echo "notify: $c off — $w" >&2; done
}
sw() { eval "echo \$SW_$1"; }

# ---- quiet hours (iMessage only) ---------------------------------------------------------------------
now() { echo "${NOW:-${NOTIFY_NOW:-$(date +%s)}}"; }
mins() { echo $(( 10#${1%:*} * 60 + 10#${1#*:} )); }
in_quiet() {  # a window across midnight is allowed; the end is exclusive. QTZ was validated by sw_load.
  local hm m s e
  if date -d @0 +%s >/dev/null 2>&1; then hm="$(TZ="$QTZ" date -d "@$(now)" +%H:%M)"
  else hm="$(TZ="$QTZ" date -r "$(now)" +%H:%M)"; fi
  m="$(mins "$hm")"; s="$(mins "$QSTART")"; e="$(mins "$QEND")"
  if [ "$s" -gt "$e" ]; then [ "$m" -ge "$s" ] || [ "$m" -lt "$e" ]; else [ "$m" -ge "$s" ] && [ "$m" -lt "$e" ]; fi
}
sys_tz() { echo "${NOTIFY_SYSTEM_TZ:-$(readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||')}"; }

# ---- the outbox --------------------------------------------------------------------------------------
outbox() {
  mkdir -p "$OUT/events" "$OUT/state" "$OUT/herdr/new" "$OUT/herdr/done" "$OUT/imessage/held" 2>/dev/null \
    && chmod 700 "$HOME/.agent-comms" "$OUT" "$OUT/events" "$OUT/state" "$OUT/herdr" "$OUT/herdr/new" \
      "$OUT/herdr/done" "$OUT/imessage" "$OUT/imessage/held" 2>/dev/null \
    || die 1 "cannot write the outbox $OUT"
}
LOCK=""
# lock_try <seconds>: the one .flush.lock — delivery and prune never race; a dead holder is reclaimed.
# Writing an event needs no lock (the event file and each first state are write-once).
lock_try() {
  local i=0 p
  until mkdir "$OUT/.flush.lock" 2>/dev/null; do
    p="$(cat "$OUT/.flush.lock/pid" 2>/dev/null || true)"
    if [ -n "$p" ] && ! kill -0 "$p" 2>/dev/null; then rm -rf "$OUT/.flush.lock"; continue; fi
    i=$((i + 1)); [ "$i" -lt $(( $1 * 5 )) ] || return 1
    sleep 0.2
  done
  echo $$ > "$OUT/.flush.lock/pid"; LOCK="$OUT/.flush.lock"
}
lock() { lock_try 30 || die 1 "the outbox lock is held by pid $(cat "$OUT/.flush.lock/pid" 2>/dev/null || echo ?)"; }
trap '[ -z "$LOCK" ] || rm -rf "$LOCK"' EXIT

st_get() { local s; s="$(cut -d' ' -f1 "$OUT/state/$1.$2" 2>/dev/null || true)"; echo "${s:-pending}"; }
st_tries() { local t; t="$(cut -d' ' -f4 "$OUT/state/$1.$2" 2>/dev/null || true)"; echo "${t:-0}"; }
resolved() { [ -e "$OUT/state/$1.resolved" ]; }
st_init() {  # st_init <file id> <channel> — the first state, write-once: never resets a delivery begun
  printf 'pending - %s\n' "$(utc)" > "$OUT/state/.$1.$2.init.$$"
  ln "$OUT/state/.$1.$2.init.$$" "$OUT/state/$1.$2" 2>/dev/null || true
  rm -f "$OUT/state/.$1.$2.init.$$"
}
st_set() {  # st_set <file id> <channel> <state> [code] [attempts] — replaced atomically
  printf '%s %s %s%s\n' "$3" "${4:--}" "$(utc)" "${5:+ $5}" > "$OUT/state/.$1.$2.tmp"
  mv "$OUT/state/.$1.$2.tmp" "$OUT/state/$1.$2"
}

# send_<channel> <event file> → prints the outcome state and code.
# Herdr: one spool entry for the mod (.claude/team/herdr-mod), published write-once with `ln`, so a
# repeat is harmless; the entry's action jumps to the answering session's terminal.
send_herdr() {
  local f="$1" id e
  id="$(basename "$f" .json)"
  [ "$(jq -r '.answer.backend // ""' "$f" 2>/dev/null)" = herdr ] || { echo "skipped-tmux -"; return 0; }
  # The mod takes only ids its ID_RE (spool.js) accepts; any other would sit in new/ unseen.
  [[ "$id" =~ ^[A-Za-z0-9_-][A-Za-z0-9._-]{0,199}$ ]] || { echo "failed spool-id"; return 0; }
  e="$(jq -c --arg id "$id" "($LABELS[.event]) as \$label"'
    | ([.team, .ticket, .decision] | map(select(. != null)) | join(" ")) as $who
    | {id: $id, title: "[\(.project)] \($label)",
       body: ((if $who == "" then "" else $who + " — " end) + (.summary // "") + " — answer: " + .answer.hint),
       action: {name: "agent.focus", args: {terminal: .answer.handle}}, created_at: .created_at}' "$f" 2>/dev/null)" \
    || { echo "failed spool-entry"; return 0; }
  if [ ! -e "$OUT/herdr/new/$id.json" ] && [ ! -e "$OUT/herdr/done/$id.json" ]; then
    printf '%s\n' "$e" > "$OUT/herdr/new/.tmp.$$" && ln "$OUT/herdr/new/.tmp.$$" "$OUT/herdr/new/$id.json" 2>/dev/null || true
    rm -f "$OUT/herdr/new/.tmp.$$"
  fi
  if [ -e "$OUT/herdr/new/$id.json" ] || [ -e "$OUT/herdr/done/$id.json" ]; then echo "spooled -"; else echo "failed spool-write"; fi
}

# iMessage: the fixed script gets the recipient and the text only as argv entries. The recipient goes
# from jq straight into argv — no variable, no output. stderr can echo it, so it is piped into sed
# and only its trailing numeric code (and the rc) survive. perl's alarm survives the exec: 30 s.
IMSG_SCRIPT='on run argv
  tell application "Messages"
    set s to 1st account whose service type = iMessage
    send (item 2 of argv) to participant (item 1 of argv) of s
  end tell
end run'
osa_send() {  # osa_send <text> → submitted - | failed <code> | outcome_unknown <code|timeout|unknown>
  local o r c
  o="$( { r=0; perl -e 'alarm shift; exec @ARGV' "${NOTIFY_SEND_TIMEOUT:-30}" "$OSA" -e "$IMSG_SCRIPT" \
          "$(jq -r '.imessage.recipient' "$NOTIFY_CONF")" "$1" 2>&1 >/dev/null || r=$?; echo "rc=$r"; } \
        | sed -nE 's/.*\((-[0-9]+)\)[[:space:]]*$/c=\1/p; s/^rc=([0-9]+)$/r=\1/p')"
  r="$(printf '%s\n' "$o" | sed -n 's/^r=//p' | tail -1)"; c="$(printf '%s\n' "$o" | sed -n 's/^c=//p' | tail -1)"
  case "$r:$c" in
    0:*) echo "submitted -" ;;
    142:*) echo "outcome_unknown timeout" ;;   # SIGALRM
    *:-1743|*:-1728|*:-600) echo "failed $c" ;;   # Automation permission, no iMessage account, Messages not running
    *) echo "outcome_unknown ${c:-unknown}" ;;
  esac
}
msg_text() {  # the message line of one event (§2): only the summary and the answer hint, never the ref
  jq -r "($LABELS[.event]) as \$label"'
    | ([.team, .ticket, .decision] | map(select(. != null)) | join(" ")) as $who
    | ("[\(.project)] \($label)" + (if $who == "" then "" else ": " + $who end)
       + " — " + (.summary // "") + " — answer: " + .answer.hint) | gsub("[\u0000-\u001f\u007f]+"; " ")' "$1"
}
send_imessage() { osa_send "$(msg_text "$1")"; }

# held_batch: every held event, oldest first, as one message — all `dispatching` before the send, so a
# crash makes the whole batch outcome_unknown and nothing goes twice. A pre-send failure returns them
# to `held` with the attempt count; the third failure is final.
held_batch() {
  local f ids="" id n=0 k=0 t text line max=0
  for f in "$OUT"/events/*.json; do
    [ -f "$f" ] || continue; id="$(basename "$f" .json)"
    # The "t" prefix keeps the sort key a field when created_at is missing, so `read` never takes the id for it.
    [ "$(st_get "$id" imessage)" = held ] || continue
    if resolved "$id"; then st_set "$id" imessage skipped resolved; else printf 't%s %s\n' "$(jq -r '.created_at // ""' "$f")" "$id"; fi
  done | sort > "$OUT/state/.batch.$$"
  while read -r _ id; do ids="$ids $id"; n=$((n + 1)); t="$(st_tries "$id" imessage)"; [ "$t" -le "$max" ] || max="$t"; done < "$OUT/state/.batch.$$"
  rm -f "$OUT/state/.batch.$$"
  [ "$n" -gt 0 ] || return 0
  text="[harness] $n held overnight"
  for id in $ids; do
    line="$(msg_text "$OUT/events/$id.json")"
    if [ $(( ${#text} + ${#line} + 1 )) -gt 980 ] || [ "$k" -gt 0 ]; then k=$((k + 1)); continue; fi
    text="$text
$line"
  done
  [ "$k" -eq 0 ] || text="$text
… and $k more"
  for id in $ids; do st_set "$id" imessage dispatching; done
  crash batch
  set -- $(osa_send "$text"); t=$((max + 1))
  for id in $ids; do
    if [ "$1" != failed ]; then st_set "$id" imessage "$1" "$2"
    elif [ "$t" -lt 3 ]; then st_set "$id" imessage held "$2" "$t"
    else st_set "$id" imessage failed "$2" "$t"; fi
  done
}

deliver() {  # deliver <file id> <channel> — one step of the channel's state machine
  local s r t
  s="$(st_get "$1" "$2")"
  case "$s" in
    dispatching)
      # A spool write is idempotent, so an interrupted Herdr delivery is simply done again.
      if [ "$2" = herdr ]; then st_set "$1" "$2" pending; deliver "$1" "$2"; return; fi
      st_set "$1" "$2" outcome_unknown interrupted ;;
    pending|failed)
      if resolved "$1"; then st_set "$1" "$2" skipped resolved; return 0; fi
      if [ "$(sw "$2")" = off ]; then [ "$s" = failed ] || st_set "$1" "$2" off switch-off; return 0; fi
      t=$(( $(st_tries "$1" "$2") + 1 ))
      [ "$s" = pending ] || [ "$t" -le 3 ] || return 0   # the third failure is final
      # One failed retry per flush: a stuck Messages app costs one timeout, not one per event.
      [ "$s" = pending ] || [ "$RETRIED" = 0 ] || return 0
      if [ "$2" = imessage ] && in_quiet; then
        [ "$s" = failed ] || st_set "$1" "$2" held; return 0
      fi
      [ "$s" = pending ] || RETRIED=1
      st_set "$1" "$2" dispatching; crash dispatching
      r="$("send_$2" "$OUT/events/$1.json")"
      case "$r" in failed*) st_set "$1" "$2" ${r} "$t" ;; *) st_set "$1" "$2" ${r} ;; esac ;;
    held) if resolved "$1"; then st_set "$1" "$2" skipped resolved
          elif [ "$(sw "$2")" = on ]; then :; else st_set "$1" "$2" off switch-off; fi ;;
  esac
}
RETRIED=0
flush() {
  local f n c
  RETRIED=0
  # Older held events go out before anything new (the kit's job runs this at quiet.end).
  if [ "$(sw imessage)" = on ] && ! in_quiet; then held_batch; fi
  for f in "$OUT"/events/*.json; do
    [ -f "$f" ] || continue; n="$(basename "$f" .json)"
    for c in $CHANNELS; do deliver "$n" "$c"; done
  done
}

prune() {
  local f n c keep
  find "$OUT/events" -name '*.json' -mmin +"$KEEP_MIN" 2>/dev/null | while IFS= read -r f; do
    n="$(basename "$f" .json)"; keep=""
    for c in $CHANNELS; do
      case "$(st_get "$n" "$c")" in pending|held|dispatching) keep=1 ;;
        # A failed channel that is switched off is never retried, so it does not hold the event.
        failed) [ "$(sw "$c")" = off ] || [ "$(st_tries "$n" "$c")" -ge 3 ] || keep=1 ;; esac
    done
    # Per channel, not "$n".*: ids may hold dots, and a glob would take another event's state.
    [ -n "$keep" ] || { rm -f "$f" "$OUT/imessage/held/$n"; for c in $CHANNELS; do rm -f "$OUT/state/$n.$c"; done; }
  done || true
  find "$OUT/state" -type f -mmin +"$KEEP_MIN" 2>/dev/null | while IFS= read -r f; do
    n="$(basename "$f")"; [ -f "$OUT/events/${n%.*}.json" ] || rm -f "$f"
  done || true
  find "$OUT/herdr/done" -type f -mmin +1440 -exec rm -f {} + 2>/dev/null || true
  # A resolve marker no strip took (none shown, an older mod) goes after a day as well.
  find "$OUT/herdr/new" -name '*.resolve' -mmin +1440 -exec rm -f {} + 2>/dev/null || true
  # The kit's launchd job logs here; keep the last 64 KB.
  if [ -f "$OUT/flush.log" ] && [ "$(wc -c < "$OUT/flush.log")" -gt 65536 ]; then
    tail -c 32768 "$OUT/flush.log" > "$OUT/.flush.log.tmp" && mv "$OUT/.flush.log.tmp" "$OUT/flush.log"
  fi
}

# ---- commands ----------------------------------------------------------------------------------------
[ $# -ge 1 ] || usage
CMD="$1"; shift
case "$CMD" in
  human_decision|abandon_decision|unrepaired_failure|release|flush|list|resolve|--check) ;;
  *) die 2 "unknown event '$CMD' — human_decision|abandon_decision|unrepaired_failure|release" ;;
esac
sw_load

case "$CMD" in
  --check)
    [ $# -eq 0 ] || usage
    echo "config: $CONF_STATE (~/.agent-comms/notify.json)"
    for c in herdr imessage; do
      eval "w=\$WHY_$c"
      if [ "$c" = herdr ] && [ "$(sw herdr)" = on ]; then
        # The mod touches .mod-alive every 60 s; fan-out does not depend on it.
        # GNU first: GNU `stat -f %m` prints file-system lines to stdout before failing.
        a="$(stat -c %Y "$OUT/herdr/.mod-alive" 2>/dev/null || stat -f %m "$OUT/herdr/.mod-alive" 2>/dev/null || true)"
        if [ -n "$a" ] && [ $(( $(date +%s) - a )) -le 180 ]; then echo "herdr on — mod seen $(( $(date +%s) - a )) s ago"
        else echo "herdr on — mod not seen${a:+ for $(( $(date +%s) - a )) s} (no layout shows the harness-notify strip?)"; fi
      elif [ "$(sw "$c")" = on ]; then
        q="not quiet"; ! in_quiet || q="quiet now"
        h="$(cat "$OUT"/state/*.imessage 2>/dev/null | grep -c '^held ' || true)"
        # The job's state from its plist only — never launchctl.
        if [ ! -f "$JOB" ]; then j="missing (bash .claude/team/notify-kit/install.sh)"
        else
          jp="$(sed -n 's|.*<string>\(.*notify\.sh\)</string>.*|\1|p' "$JOB" | head -1)"
          jh="$(sed -n 's|.*<key>Hour</key><integer>\([0-9]*\)</integer>.*|\1|p' "$JOB" | head -1)"
          jm="$(sed -n 's|.*<key>Minute</key><integer>\([0-9]*\)</integer>.*|\1|p' "$JOB" | head -1)"
          if [ -z "$jp" ] || [ ! -f "$jp" ]; then j="stale path ${jp:-?} (re-run the kit installer)"
          elif [ "$(( ${jh:-99} * 60 + ${jm:-0} ))" != "$(mins "$QEND")" ]; then j="stale time (quiet.end changed; re-run the kit installer)"
          else j="installed"; fi
        fi
        echo "imessage on, recipient set — quiet ${QSTART}–${QEND} $QTZ ($q), $h held, flush job: $j"
        stz="$(sys_tz)"; [ -z "$stz" ] || [ "$stz" = "$QTZ" ] \
          || echo "imessage warning: quiet.tz $QTZ is not the system zone $stz — the flush job fires at ${QEND} system time"
      else echo "$c off${w:+ — $w}"; fi
    done
    # Read-only on a busy outbox: the switches and states are read without the lock, and prune runs
    # only when the lock is free at once — a flush or a send in progress never stalls or fails --check.
    [ ! -d "$OUT/events" ] || { outbox; pr=""; if lock_try 0; then prune; else pr=" (prune skipped: outbox busy)"; fi
      echo "outbox: $(find "$OUT/events" -name '*.json' | wc -l | tr -d ' ') events$pr"; }
    exit 0 ;;
  flush)
    [ $# -eq 0 ] || { [ $# -eq 2 ] && [ "$1" = --now ] && [[ "$2" =~ ^[0-9]+$ ]] || usage; NOW="$2"; }
    sw_warn; outbox; lock; prune; flush; exit 0 ;;
  list)
    since=""
    [ $# -eq 0 ] || { [ $# -eq 2 ] && [ "$1" = --since ] && [[ "$2" =~ ^[0-9]+$ ]] || usage; since="$2"; }
    outbox; lock; prune
    # One path per line, so a HOME with a space in it is read whole.
    { if [ -n "$since" ]; then find "$OUT/events" -name '*.json' -mmin -$((since * 1440)); \
      else find "$OUT/events" -name '*.json'; fi; } | sort | while IFS= read -r f; do
      n="$(basename "$f" .json)"; line="$(jq -r '"\(.id) \(.event)"' "$f")"
      for c in $CHANNELS; do line="$line $c=$(st_get "$n" "$c")"; done
      ! resolved "$n" || line="$line resolved"
      echo "$line"
    done
    exit 0 ;;
  resolve)
    T=""; R=""; D=""; K=""; PR=""
    while [ $# -gt 0 ]; do
      [ $# -ge 2 ] || usage
      case "$1" in --team) T="$2" ;; --run) R="$2" ;; --decision) D="$2" ;; --key) K="$2" ;;
        --project) PR="$2" ;; *) usage ;; esac
      shift 2
    done
    if [ -n "$K" ]; then [ -z "$T$R$D" ] || usage; part --key "$K"
    else [ -n "$T" ] && [ -n "$R" ] && [ -n "$D" ] || usage; part --team "$T"; part --run "$R"; part --decision "$D"; fi
    [ -z "$PR" ] || part --project "$PR"
    [ -d "$OUT/events" ] || { echo unknown; exit 0; }   # nothing was ever sent from here
    outbox; hit=""
    # Matched by the fields every event file keeps (even with every channel off), so a caller needs
    # no project prefix; --key names an operator record (release, unrepaired_failure).
    for f in "$OUT"/events/*.json; do
      [ -f "$f" ] || continue
      jq -e --arg t "$T" --arg r "$R" --arg d "$D" --arg k "$K" --arg p "$PR" '($p == "" or .project == $p)
        and (if $k != "" then (.event == "release" or .event == "unrepaired_failure") and (.id | endswith(":" + $k))
             else .team == $t and .run == $r and .decision == $d end)' "$f" >/dev/null 2>&1 || continue
      n="$(basename "$f" .json)"; id="$(jq -r .id "$f")"; hit=1
      utc > "$OUT/state/.$n.resolved.$$"
      if ln "$OUT/state/.$n.resolved.$$" "$OUT/state/$n.resolved" 2>/dev/null; then
        if [ "$(jq -r '.answer.backend // ""' "$f")" = herdr ] && [ ! -e "$OUT/herdr/done/$n.resolve" ]; then
          : > "$OUT/herdr/new/.tmp.$$" && ln "$OUT/herdr/new/.tmp.$$" "$OUT/herdr/new/$n.resolve" 2>/dev/null || true
          rm -f "$OUT/herdr/new/.tmp.$$"
        fi
        echo "resolved $id"
      else echo "already resolved $id"; fi
      rm -f "$OUT/state/.$n.resolved.$$"
    done
    [ -n "$hit" ] || echo unknown
    exit 0 ;;
esac

# ---- an event --------------------------------------------------------------------------------------
P=""; SUMMARY=""; ANSWER=""; HINT=""; TEAM=""; TICKET=""; RUNID=""; DEC=""; REF=""; KEY=""; SRC=""; MAIN=""
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || usage
  case "$1" in
    --project) P="$2" ;; --summary) SUMMARY="$2" ;; --answer) ANSWER="$2" ;; --hint) HINT="$2" ;;
    --team) TEAM="$2" ;; --ticket) TICKET="$2" ;; --run) RUNID="$2" ;; --decision) DEC="$2" ;;
    --ref) REF="$2" ;; --key) KEY="$2" ;; --source) SRC="$2" ;; --main) MAIN="$2" ;;
    --now) [[ "$2" =~ ^[0-9]+$ ]] || usage; NOW="$2" ;;
    *) usage ;;
  esac
  shift 2
done
[ -n "$P" ] && [ -n "$SUMMARY" ] && [ -n "$ANSWER" ] || die 2 "$CMD needs --project, --summary and --answer"
part --project "$P"
case "$CMD" in
  human_decision|abandon_decision)
    part --team "$TEAM"; part --run "$RUNID"; part --decision "$DEC"; ID="$P:$TEAM:$RUNID:$DEC" ;;
  unrepaired_failure) part --key "$KEY"; ID="$P:failure:$KEY" ;;
  release) part --key "$KEY"; ID="$P:release:$KEY" ;;
esac
FID="$(printf '%s' "$ID" | tr ':/' '__')"

# The answering session's backend and handle: its registry record's JSON only, never the driver.
# No record, another backend or a malformed handle → tmux (the Herdr channel then skips it).
MAIN="${MAIN:-$(git rev-parse --show-toplevel 2>/dev/null || true)}"
BACKEND=tmux; HANDLE="$ANSWER"; RNAME=""
rec="$MAIN/.agents/team/registry/$ANSWER.json"
if [ -n "$MAIN" ] && [[ "$ANSWER" =~ ^[A-Za-z0-9:_-]+$ ]] && [ -f "$rec" ] \
  && [ "$(jq -r '.backend // "" | strings' "$rec" 2>/dev/null)" = herdr ]; then
  h="$(jq -r '.handle // "" | strings' "$rec" 2>/dev/null)"
  if [[ "$h" =~ ^[A-Za-z0-9._-]{1,64}(/[A-Za-z0-9._-]{1,64})?$ ]]; then
    BACKEND=herdr; HANDLE="$h"; RNAME="$(jq -r '.name // "" | strings' "$rec" 2>/dev/null | tr -d '[:cntrl:]')"
  fi
fi
# A herdr session's hint is always built here, from the record alone, in sh_hint's herdr form: a
# caller's hint may be a tmux fallback (lead_notify's `|| h="tmux attach …"`).
if [ "$BACKEND" = herdr ]; then HINT="hc attach $HANDLE · herdr: ${RNAME:-$ANSWER} (in the agent list once placed)"
elif [ -z "$HINT" ]; then HINT="tmux attach -t $ANSWER"; fi
sw_warn; outbox

# No channel on → no question text on disk for nobody.
store=false
for c in $CHANNELS; do [ "$(sw "$c")" = off ] || store=true; done
tmp="$OUT/events/.tmp.$$"
jq -n --arg id "$ID" --arg event "$CMD" --arg project "$P" --arg team "$TEAM" --arg ticket "$TICKET" \
  --arg run "$RUNID" --arg decision "$DEC" --arg summary "$SUMMARY" --arg address "$ANSWER" \
  --arg hint "$HINT" --arg backend "$BACKEND" --arg handle "$HANDLE" --arg ref "$REF" --arg source "${SRC:-runner}" \
  --arg created_at "$(utc)" --argjson store "$store" \
  'def nz: if . == "" then null else . end;
   {id: $id, event: $event, project: $project, team: ($team | nz), ticket: ($ticket | nz),
    run: ($run | nz), decision: ($decision | nz),
    summary: (if $store then ($summary | gsub("[\u0000-\u001f\u007f]+"; " ") | .[0:200]) else null end),
    answer: {address: $address, backend: $backend, handle: $handle, hint: $hint},
    ref: (if $store then ($ref | nz) else null end), source: $source, created_at: $created_at}' \
  > "$tmp" 2>/dev/null || { rm -f "$tmp"; die 1 "cannot write the event file"; }
if ln "$tmp" "$OUT/events/$FID.json" 2>/dev/null; then
  rm -f "$tmp"; crash published
  for c in $CHANNELS; do st_init "$FID" "$c"; done
  res="written $ID"
else
  rm -f "$tmp"
  [ -f "$OUT/events/$FID.json" ] || die 1 "cannot publish the event file"
  res="duplicate $ID"
fi
# The event is on disk whatever happens now. A busy lock (a flush sending) defers delivery to the
# next call or the flush job; a flush that sees this event claims it under the lock (dispatching).
if lock_try "${NOTIFY_LOCK_WAIT:-10}"; then
  echo "$res"; prune; flush
else
  echo "$res (delivery deferred: outbox busy)"
fi
