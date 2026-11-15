#!/usr/bin/env bash
# The Operator's notification sender — the only code that creates a notification.
# Usage:
#   notify.sh <event> --project <p> --summary "<line>" --answer <address> [--hint "<line>"]
#             [--team <t>] [--ticket <k>] [--run <r>] [--decision <d-n>] [--ref <abs path>]
#             [--key <k>] [--source <who>] [--main <root>]        → written <id> | duplicate <id>
#   notify.sh flush        resume pending deliveries (recovery: an interrupted send becomes
#                          outcome_unknown and is never re-sent)
#   notify.sh list [--since <days>]   one line per event: id, event, each channel's state
#   notify.sh --check      one line per channel and one for the switch file
#   events: human_decision · abandon_decision (need --team --run --decision) ·
#           unrepaired_failure · release (need --key, the operator record id). Nothing else.
#
# One event file per id, published write-once (`ln`) into ~/.agent-comms/outbox/events/ — that is
# the dedup. Delivery state per channel in state/<id>.<channel>: pending → dispatching → outcome
# (submitted | failed | outcome_unknown), plus off / held / spooled / skipped-tmux. Herdr (#39):
# herdr/new/<id>.json for the harness-notify mod, only when the answering session's registry record
# (<main>/.agents/team/registry/<address>.json, read as JSON only) says herdr. iMessage (#40) is not
# built yet and records `off`. Every call prunes files past
# NOTIFY_KEEP_DAYS (default 7; herdr/done 24 h), never one still pending, held or dispatching.
# The summary is one line, control characters stripped, cut to 200 characters, and stored only
# when a channel's switch is on. The recipient is never read into any output.
# Callers: the runner (team-run-lead.sh lead_notify) and operator-record.sh — never a model
# session (the role profiles deny it).
# Exit: 0 written, duplicate or done · 1 the outbox cannot be written · 2 usage / unknown event.
# Spec: notification model (epic E2) §1–§4. Bash 3.2 compatible; needs jq.
set -euo pipefail
umask 077

NOTIFY_CONF="$HOME/.agent-comms/notify.json"   # the per-machine switch file — the one place it is named
OUT="$HOME/.agent-comms/outbox"
KEEP_MIN=$(( ${NOTIFY_KEEP_DAYS:-7} * 1440 ))
CHANNELS="herdr imessage"

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
die() { echo "error: $2" >&2; exit "$1"; }
utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }
crash() { [ "${NOTIFY_CRASH_AT:-}" != "$1" ] || exit 137; }   # tests: kill the process at a boundary

# ---- the switch file -------------------------------------------------------------------------------
# sw_load → SW_herdr / SW_imessage (on|off), WHY_<ch> (why a requested channel is off), CONF_STATE.
SW_herdr=off; SW_imessage=off; WHY_herdr=""; WHY_imessage=""; CONF_STATE="missing"
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
  done
  # `TZ=<tz> date` is no check: an unknown zone silently means UTC on macOS.
  tz="$(jq -r '.imessage.quiet.tz // empty' "$NOTIFY_CONF")"
  if ! [[ "$tz" =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ ]] || [ ! -f "${TZDIR:-/usr/share/zoneinfo}/$tz" ]; then
    WHY_imessage="unknown tz ${tz:-(empty)}"; return 0
  fi
  SW_imessage=on
}
sw_warn() {  # one stderr line per process for a channel that was asked for and is off
  local c w
  for c in $CHANNELS; do eval "w=\$WHY_$c"; [ -z "$w" ] || echo "notify: $c off — $w" >&2; done
}
sw() { eval "echo \$SW_$1"; }

# ---- the outbox --------------------------------------------------------------------------------------
outbox() {
  mkdir -p "$OUT/events" "$OUT/state" "$OUT/herdr/new" "$OUT/herdr/done" "$OUT/imessage/held" 2>/dev/null \
    && chmod 700 "$HOME/.agent-comms" "$OUT" "$OUT/events" "$OUT/state" "$OUT/herdr" "$OUT/herdr/new" \
      "$OUT/herdr/done" "$OUT/imessage" "$OUT/imessage/held" 2>/dev/null \
    || die 1 "cannot write the outbox $OUT"
}
LOCK=""
lock() {  # the one .flush.lock: ingestion, delivery and prune never race; a dead holder is reclaimed
  local i=0 p
  until mkdir "$OUT/.flush.lock" 2>/dev/null; do
    p="$(cat "$OUT/.flush.lock/pid" 2>/dev/null || true)"
    if [ -n "$p" ] && ! kill -0 "$p" 2>/dev/null; then rm -rf "$OUT/.flush.lock"; continue; fi
    i=$((i + 1)); [ "$i" -lt 150 ] || die 1 "the outbox lock is held by pid ${p:-?}"
    sleep 0.2
  done
  echo $$ > "$OUT/.flush.lock/pid"; LOCK="$OUT/.flush.lock"
}
trap '[ -z "$LOCK" ] || rm -rf "$LOCK"' EXIT

st_get() { local s; s="$(cut -d' ' -f1 "$OUT/state/$1.$2" 2>/dev/null || true)"; echo "${s:-pending}"; }
st_set() {  # st_set <file id> <channel> <state> [code] — replaced atomically
  printf '%s %s %s\n' "$3" "${4:--}" "$(utc)" > "$OUT/state/.$1.$2.tmp"
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
  e="$(jq -c --arg id "$id" '
    ({human_decision: "decision", abandon_decision: "abandon?", unrepaired_failure: "failure",
      release: "release"}[.event]) as $label
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
send_imessage() { echo "off not-built"; }

deliver() {  # deliver <file id> <channel> — one step of the channel's state machine
  local s r
  s="$(st_get "$1" "$2")"
  case "$s" in
    dispatching)
      # A spool write is idempotent, so an interrupted Herdr delivery is simply done again.
      if [ "$2" = herdr ]; then st_set "$1" "$2" pending; deliver "$1" "$2"; return; fi
      st_set "$1" "$2" outcome_unknown interrupted ;;
    pending)
      if [ "$(sw "$2")" = on ]; then
        st_set "$1" "$2" dispatching; crash dispatching
        r="$("send_$2" "$OUT/events/$1.json")"; st_set "$1" "$2" ${r}
      else st_set "$1" "$2" off switch-off; fi ;;
    held) [ "$(sw "$2")" = on ] || st_set "$1" "$2" off switch-off ;;
  esac
}
flush() {
  local f n c
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
      case "$(st_get "$n" "$c")" in pending|held|dispatching) keep=1 ;; esac
    done
    # Per channel, not "$n".*: ids may hold dots, and a glob would take another event's state.
    [ -n "$keep" ] || { rm -f "$f" "$OUT/imessage/held/$n"; for c in $CHANNELS; do rm -f "$OUT/state/$n.$c"; done; }
  done || true
  find "$OUT/state" -type f -mmin +"$KEEP_MIN" 2>/dev/null | while IFS= read -r f; do
    n="$(basename "$f")"; [ -f "$OUT/events/${n%.*}.json" ] || rm -f "$f"
  done || true
  find "$OUT/herdr/done" -type f -mmin +1440 -exec rm -f {} + 2>/dev/null || true
}

# ---- commands ----------------------------------------------------------------------------------------
[ $# -ge 1 ] || usage
CMD="$1"; shift
case "$CMD" in
  human_decision|abandon_decision|unrepaired_failure|release|flush|list|--check) ;;
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
        echo "$c on, recipient set — not built yet (#40), records off"
      else echo "$c off${w:+ — $w}"; fi
    done
    [ ! -d "$OUT/events" ] || { outbox; lock; prune
      echo "outbox: $(find "$OUT/events" -name '*.json' | wc -l | tr -d ' ') events"; }
    exit 0 ;;
  flush)
    [ $# -eq 0 ] || usage
    sw_warn; outbox; lock; prune; flush; exit 0 ;;
  list)
    since=""
    [ $# -eq 0 ] || { [ $# -eq 2 ] && [ "$1" = --since ] && [[ "$2" =~ ^[0-9]+$ ]] || usage; since="$2"; }
    outbox; lock; prune
    for f in $(if [ -n "$since" ]; then find "$OUT/events" -name '*.json' -mmin -$((since * 1440)); \
               else find "$OUT/events" -name '*.json'; fi | sort); do
      n="$(basename "$f" .json)"; line="$(jq -r '"\(.id) \(.event)"' "$f")"
      for c in $CHANNELS; do line="$line $c=$(st_get "$n" "$c")"; done
      echo "$line"
    done
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
    *) usage ;;
  esac
  shift 2
done
[ -n "$P" ] && [ -n "$SUMMARY" ] && [ -n "$ANSWER" ] || die 2 "$CMD needs --project, --summary and --answer"
part() { [[ "$2" =~ ^[A-Za-z0-9._-]+$ ]] || die 2 "$1 '$2' must be [A-Za-z0-9._-]+"; }
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
sw_warn; outbox; lock; prune

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
  for c in $CHANNELS; do st_set "$FID" "$c" pending; done
  echo "written $ID"
else
  rm -f "$tmp"
  [ -f "$OUT/events/$FID.json" ] || die 1 "cannot publish the event file"
  echo "duplicate $ID"
fi
flush
