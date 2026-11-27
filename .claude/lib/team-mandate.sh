#!/usr/bin/env bash
# The Operator's mandate to the Supervisor: which classes of which teams' pending decisions the
# Supervisor may answer as a delegate, and until when.
# Usage: bash .claude/lib/team-mandate.sh grant | show | pause | answers
#        bash .claude/lib/team-mandate.sh covers <class> <team> <run>
#   The mandate IS the Operator's typed message in the registered Supervisor window — the whole
#   message, exactly:
#       mandate <class>[,<class>…] for <N>h|<N>d team <name>[,<name>…]
#   (any case; at most 7 days; only trailing whitespace or one final period may follow — a
#   qualifier, a condition or any other word refuses, nothing is silently dropped). Classes:
#   no-rule, lead-unsure — a question the TeamLead escalated because no rule answers it or it will
#   not decide. An operator-tier request (settings, production ask, delete, a hard egress class), a
#   deny rule and anything else are never delegable; an operator-tier permission whose only cause
#   is an ask-kind egress the clearance checker does not call hard is (#323 T3). Each named team is
#   covered for the run it is on when
#   the message is typed; its next run is not.
#   The latest instruction in that transcript governs: a later `mandate …` replaces an earlier
#   one, the typed message `revoke mandate` cancels it for good, and any other message that
#   starts with `mandate` or `revoke mandate` cancels it too (an unclear instruction grants
#   nothing). A replaced Supervisor session, or a history that cannot be read whole (a read
#   error, any record that does not parse or is cut), means no mandate — never the last grant
#   that did read.
#   grant: reads that governing message, binds each team to its current run (an absent run
#   refuses), shows the result and writes <main>/.agents/team/mandate.json (git-ignored, mode
#   600, never in a clone). That file is the local record and a cache: every use of the mandate
#   derives it again from the transcript and needs the file to name the same message. The run id
#   shown is the binding: the mandate covers that exact run while it is the team's active one.
#   grant also leaves a marker per bound run (delegated/<team>-<run>.mandated): for the rest of
#   that run an Operator answer needs positive human evidence, whatever becomes of the mandate.
#   show: the mandate in force, or why there is none. pause: removes the file — reversible (grant
#   records the same message again); the durable cancel is the Operator's typed `revoke mandate`.
#   covers: exit 0 and the mandate id when the mandate in force names that class and is bound to
#   exactly that run of the team, else 1.
#   answers: every answer the Supervisor gave as a delegate (<main>/.agents/team/delegated/).
# Sourced by team-lead.sh, the runner, team-answer.sh and team-ask-hook.sh (after team-lib.sh and
# team-lead-lib.sh) for mandate_verified, mandate_covers and mandate_ask_class.
# Exit 0 ok · 1 no mandate / not covered · 2 usage · 4 state · 7 the Operator's binding is missing
# Limit: the same-account model (.agents/reference/roles/supervisor.md → Mandate).
MANDATE_CLASSES="no-rule lead-unsure"
MANDATE_MAX_HOURS=168
MANDATE_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mandate_file() { printf '%s/.agents/team/mandate.json' "$1"; }

# mandate_parse <message> → "<classes>\t<hours>\t<teams>" (comma lists, sorted); rc 1 unless the
# WHOLE message, trimmed, is the grant phrase — a known class list, a term within the cap, a team
# list, at most one final period.
mandate_parse() {
  local lt re c hours
  case "$1" in *$'\n'*) return 1 ;; esac
  lt="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  lt="${lt#"${lt%%[![:space:]]*}"}"; lt="${lt%"${lt##*[![:space:]]}"}"
  re='^mandate[[:space:]]+([a-z-]+(,[a-z-]+)*)[[:space:]]+for[[:space:]]+([1-9][0-9]{0,3})(h|d)[[:space:]]+team[[:space:]]+([a-z0-9-]+(,[a-z0-9-]+)*)\.?$'
  [[ "$lt" =~ $re ]] || return 1
  local list="${BASH_REMATCH[1]}" n="${BASH_REMATCH[3]}" unit="${BASH_REMATCH[4]}" teams="${BASH_REMATCH[5]}"
  hours="$n"; [ "$unit" = h ] || hours=$(( n * 24 ))
  [ "$hours" -le "$MANDATE_MAX_HOURS" ] || return 1
  for c in ${list//,/ }; do
    case " $MANDATE_CLASSES " in *" $c "*) ;; *) return 1 ;; esac
  done
  printf '%s\t%s\t%s\n' "$(printf '%s\n' ${list//,/ } | sort -u | paste -sd, -)" "$hours" \
    "$(printf '%s\n' ${teams//,/ } | sort -u | paste -sd, -)"
}

# mandate_instruction <message> [<word>] → 0 when the message is an instruction about the mandate
# (or the <word> switch, e.g. `clearance`) at all — it starts with `<word>` or `revoke <word>` —,
# whether or not it is a valid grant.
mandate_instruction() {
  local lt w="${2:-mandate}"
  lt="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"; lt="${lt#"${lt%%[![:space:]]*}"}"
  case "$lt" in "$w"|"$w"[[:space:]]*|"revoke $w"*) return 0 ;; esac
  return 1
}

# mandate_run_start <run id> → the run's start as ISO UTC, from <team>-<YYYYMMDD>-<HHMMSS>; rc 1
# for an id without it (the run cannot be bound to a grant).
mandate_run_start() {
  [[ "$1" =~ -([0-9]{4})([0-9]{2})([0-9]{2})-([0-9]{2})([0-9]{2})([0-9]{2})$ ]] || return 1
  printf '%s-%s-%sT%s:%s:%sZ\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" \
    "${BASH_REMATCH[4]}" "${BASH_REMATCH[5]}" "${BASH_REMATCH[6]}"
}

# mandate_transcript <main> → the path of the registered Supervisor session's transcript: the
# registration (<main>/.agents/team/registry/Supervisor.json) and the declared Claude profile.
# rc 1 (reason on stderr): a clone, no registered session, no profile, no transcript; rc 3: a
# library not loaded.
mandate_transcript() {
  local sid cwd cfg t
  command -v team_evidence_machine_line >/dev/null 2>&1 || . "$MANDATE_LIB/team-evidence.sh" 2>/dev/null || true
  command -v team_supervisor_home >/dev/null 2>&1 && command -v team_role_transcript >/dev/null 2>&1 \
    && command -v team_evidence_machine_line >/dev/null 2>&1 \
    || { echo "team-lib.sh, team-lead-lib.sh or team-evidence.sh not loaded" >&2; return 3; }
  [ ! -f "$1/.agents/team/team.json" ] || { echo "a team clone holds no mandate" >&2; return 1; }
  sid="$(jq -r '.session_id // empty' "$1/.agents/team/registry/Supervisor.json" 2>/dev/null || true)"
  cwd="$(jq -r '.cwd // empty' "$1/.agents/team/registry/Supervisor.json" 2>/dev/null || true)"; cwd="${cwd:-$1}"
  [ -n "$sid" ] || { echo "no Supervisor session is registered" >&2; return 1; }
  cfg="$(team_supervisor_home "$1")" || { echo "the Supervisor's Claude profile cannot be resolved" >&2; return 1; }
  t="$(team_role_transcript "$cwd" "$sid" "$cfg")"
  [ -f "$t" ] || { echo "the registered Supervisor session has no transcript" >&2; return 1; }
  printf '%s\n' "$t"
}

# mandate_read <transcript> [<word>] → the typed user messages naming the word (default
# `mandate`; team-clearance.sh reads `clearance`), one {uuid, ts, m} row per line; rc 1 unless the
# WHOLE transcript reads: every record parses (one value out per line in — a cut record, lines run
# together or a blank line change the count) and the last one ends its line. Every record is
# validated before any message is looked at.
mandate_read() {
  local out lines w="${2:-mandate}"
  [ -r "$1" ] || return 1
  [ -s "$1" ] || return 0
  [ -z "$(tail -c 1 "$1" 2>/dev/null)" ] || return 1
  lines="$(wc -l < "$1")" || return 1
  out="$(jq -c --arg w "$w" 'if type == "object" and .type == "user" and ((.isMeta // false) | not)
      and ((.toolUseResult // null) == null)
    then {uuid: (.uuid // "" | tostring), ts: ((.timestamp // "" | tostring) | sub("\\.[0-9]+Z$"; "Z")),
       m: (.message.content | if type == "string" then . elif type == "array"
         then (map(select(type == "object" and .type == "text") | .text | tostring) | join(" ")) else "" end)}
      | if (.m | test($w; "i")) then . else 0 end
    else 0 end' "$1" 2>/dev/null)" || return 1
  [ "$(printf '%s\n' "$out" | wc -l)" -eq "$lines" ] || return 1
  printf '%s\n' "$out" | grep -v '^0$' || true
}

# mandate_session_start <transcript> → the time of the session's first record (seconds, Z); rc 1
# when none can be read.
mandate_session_start() {
  local s
  s="$(head -n 40 "$1" 2>/dev/null | jq -r 'select(type == "object") | .timestamp // empty | tostring' 2>/dev/null | head -n 1)"
  [[ "$s" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2} ]] || return 1
  printf '%sZ\n' "${BASH_REMATCH[0]}"
}

# mandate_history <main> [<transcript>] [<word>] → every mandate instruction (with a word, e.g.
# `clearance`: every instruction about that switch, mandate_instruction) the Operator typed in the
# registered
# Supervisor session, one compact JSON row {uuid, ts, m} per line, in transcript order. The
# transcript comes from the registration (<main>/.agents/team/registry/Supervisor.json) and the
# declared Claude profile — never from mandate.json. Typed user messages only (no machine line: a
# doorbell, runner, [peer] or <hc from=…> line). rc 1 (reason on stderr): no registered session
# or no transcript. rc 3: the history is unreadable or incomplete — a read error, ANY record of
# the transcript that does not parse (whatever it holds: a record cut before its message is one
# too), a last record with no line end, an instruction with no uuid or time, a library not
# loaded. Nothing is then taken from the part that did read: a record that cannot be read may be
# the revoke. A record still being written is retried briefly (TEAM_MANDATE_READ_TRIES, 0.3 s
# apart), and refuses until it reads whole.
mandate_history() {
  local t="${2:-}" w="${3:-mandate}" n=0 rows row m
  local bad="the Supervisor session's history cannot be read whole — no $w is taken from a partial history"
  # A caller that already resolved the registration passes its transcript: one lookup, not two.
  [ -n "$t" ] || t="$(mandate_transcript "$1")" || return
  while ! rows="$(mandate_read "$t" "$w")"; do
    n=$((n + 1)); [ "$n" -lt "${TEAM_MANDATE_READ_TRIES:-4}" ] || { echo "$bad" >&2; return 3; }
    sleep 0.3
  done
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    m="$(jq -r .m <<<"$row")"
    ! team_evidence_machine_line "$m" || continue
    mandate_instruction "$m" "$w" || continue
    jq -e '.uuid != "" and (.ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))' <<<"$row" >/dev/null 2>&1 \
      || { echo "$bad" >&2; return 3; }
    printf '%s\n' "$row"
  done <<<"$rows"
}

# mandate_derive <main> → the governing instruction of the registered Supervisor session as
# compact JSON {id, uuid, session_id, classes, teams, granted_at, expires_at, words}; rc 1 with
# the reason on stderr when there is none. The last instruction of a history that read whole
# (mandate_history) wins; an unreadable or incomplete history grants nothing.
mandate_derive() {
  local sid rows m last p
  rows="$(mandate_history "$1")" || return 1
  sid="$(jq -r '.session_id // empty' "$1/.agents/team/registry/Supervisor.json" 2>/dev/null || true)"
  last="$(tail -n 1 <<<"$rows")"
  [ -n "$last" ] && [ -n "$sid" ] || { echo "no mandate message in the Supervisor window" >&2; return 1; }
  m="$(jq -r .m <<<"$last")"
  p="$(mandate_parse "$m")" || { echo "the Operator's latest mandate instruction is no grant: $(printf '%s' "$m" | head -n 1 | cut -c1-120)" >&2; return 1; }
  jq -cen --argjson r "$last" --arg s "$sid" --arg c "$(cut -f1 <<<"$p")" --argjson h "$(cut -f2 <<<"$p")" \
    --arg t "$(cut -f3 <<<"$p")" '
    (($r.ts | fromdateiso8601) + $h * 3600) as $e
    | select($e > now)
    | {id: ("m-" + $r.uuid), uuid: $r.uuid, session_id: $s, classes: ($c | split(",")),
       teams: ($t | split(",")), granted_at: $r.ts, expires_at: ($e | todateiso8601), words: $r.m}' 2>/dev/null \
    || { echo "the Operator's latest mandate has expired" >&2; return 1; }
}

# mandate_verified <main> → the mandate in force: the governing instruction (mandate_derive), and
# the local record names the very same message (grant was run for it, and it is not paused).
mandate_verified() {
  local d f; f="$(mandate_file "$1")"
  d="$(mandate_derive "$1")" || return 1
  [ -f "$f" ] && [ ! -L "$f" ] && [ "$(jq -r '.id // ""' "$f" 2>/dev/null)" = "$(jq -r .id <<<"$d")" ] \
    || { echo "the mandate is not recorded (bash .claude/lib/team-mandate.sh grant) or is paused" >&2; return 1; }
  jq -c --slurpfile f "$f" '. + {runs: (($f[0].runs // {}) | if type == "object" then . else {} end)}' <<<"$d"
}

# mandate_bound <main> <team> <run> <mandate json> → 0 when that mandate names the team and is
# bound to exactly this run: the run id `grant` showed the Operator for the team (the record's
# runs), which is the team's active run now (the main checkout's anchor) and had started when
# the message was typed. An earlier or a later run of the team is not this one.
mandate_bound() {
  local start
  [ -n "$2" ] && [ -n "$3" ] && start="$(mandate_run_start "$3")" || return 1
  [ "$(jq -r '.run // empty' "$1/.agents/team/anchors/$2.json" 2>/dev/null)" = "$3" ] || return 1
  jq -e --arg t "$2" --arg r "$3" --arg s "$start" '(.teams | index($t) != null)
    and ((.runs // {})[$t] // "") == $r and $s <= .granted_at' <<<"$4" >/dev/null 2>&1
}

# mandate_covers <main> <class> <team> <run> [<mandate id>] → the id of the mandate in force when
# it names that class and is bound to that team's run (mandate_bound: the exact run id, never the
# start time alone); with an id, only that mandate. rc 1 otherwise.
mandate_covers() {
  local m
  [ -n "$2" ] || return 1
  m="$(mandate_verified "$1" 2>/dev/null)" && mandate_bound "$1" "$3" "$4" "$m" || return 1
  jq -er --arg c "$2" --arg i "${5:-}" '
    select(($i == "" or .id == $i) and (.classes | index($c) != null)) | .id' <<<"$m" 2>/dev/null || return 1
}

# mandate_run_capable <main> <team> <run> → 0 when the mandate in force is bound to that team's
# run, whatever the class: a run in which a delegated answer can exist now.
mandate_run_capable() {
  local m
  m="$(mandate_verified "$1" 2>/dev/null)" && mandate_bound "$1" "$2" "$3" "$m"
}

# mandate_run_ever <main> <team> <run> → 0 unless it is KNOWN that the run has never been
# delegation-capable. For the rest of a run that was, or may have been, the Operator's authority
# is taken only on positive human evidence (a typed message or a dialog answer), never from a
# marker a file carries — team-lead.md §7. Capable, by any one: the marker `grant` left for the
# run, a delegated answer on record for it, a mandate bound to it now, or a grant in the
# Supervisor session's history that names the team and was typed once the run had started
# (recorded or not). Uncertain, and counted the same: no registered Supervisor session, no
# transcript, a history that does not read whole, a run id with no start time, or a registered
# session that began after the run did (a rotation: what the earlier session held is not
# readable here, and markers may be gone), or a registration that changed while this ran. rc 1
# only when the registered session has been there since before the run started, its history
# reads whole and holds no such grant, and the registration is still the one read at the start.
# An empty <team> is read from the run id.
mandate_run_ever() {
  local team="$2" start rows row p x t s0 snap reg="$1/.agents/team/registry/Supervisor.json"
  [ -n "$team" ] || team="${3%-*-*}"
  [ -n "$team" ] && [ -n "$3" ] || return 0
  [ ! -e "$1/.agents/team/delegated/$team-$3.mandated" ] || return 0
  for x in "$1/.agents/team/delegated/$team-$3"-d-*.json; do [ ! -e "$x" ] || return 0; done
  ! mandate_run_capable "$1" "$team" "$3" || return 0
  start="$(mandate_run_start "$3")" || return 0
  # One snapshot of the registration: its bytes and the transcript it names. The start time and
  # the history both come from that one transcript, and the registration must still read the
  # same when the answer is given — a session rotated in between is an uncertain lineage.
  snap="$(cat "$reg" 2>/dev/null)" && [ -n "$snap" ] || return 0
  t="$(mandate_transcript "$1" 2>/dev/null)" && rows="$(mandate_history "$1" "$t" 2>/dev/null)" || return 0
  s0="$(mandate_session_start "$t")" && [[ ! "$s0" > "$start" ]] || return 0
  while IFS= read -r row; do
    [ -n "$row" ] && p="$(mandate_parse "$(jq -r .m <<<"$row")")" || continue
    case ",$(cut -f3 <<<"$p")," in *",$team,"*) ;; *) continue ;; esac
    [[ "$start" > "$(jq -r .ts <<<"$row")" ]] || return 0
  done <<<"$rows"
  [ "$(cat "$reg" 2>/dev/null)" = "$snap" ] && [ "$(mandate_transcript "$1" 2>/dev/null)" = "$t" ] || return 0
  return 1
}

# mandate_ask_check <main> <clone> <ask file> → the main checkout's checker lines
# (team_prompt_check.py) for the filed request's payload, run now; nothing on any failure.
mandate_ask_check() {
  local tmp out=""
  tmp="$(mktemp "${TMPDIR:-/tmp}/mandate-ask.XXXXXX")" || return 0
  jq -c .payload "$3" > "$tmp" 2>/dev/null \
    && out="$(python3 -I "$1/.claude/lib/team_prompt_check.py" "$2" --input-json "$tmp" --main "$1" 2>/dev/null)" || out=""
  rm -f "$tmp"
  printf '%s\n' "$out"
}

# mandate_egress_only <checker lines> → 0 when the egress is the request's only cause
# (`batch: eligible`) and no hard egress class: a `clearance:` line of pass, none or a clearable
# class — never hard, never undecided (a guard the checker does not reproduce) — #323 T3.
mandate_egress_only() {
  local c; c="$(sed -n 's/^clearance: //p' <<<"$1")"
  [ "$(sed -n 's/^batch: //p' <<<"$1")" = eligible ] || return 1
  case "$c" in pass|none|"clearable "?*) return 0 ;; esac
  return 1
}

# mandate_ask_class <main> <clone> <ask file> <touch reason> → the mandate class of a decision
# bound to that ask, or nothing when no mandate can cover it. Only a lead-tier ask is delegable,
# by the lead's escalation reason (no-rule, lead-unsure): a question or a plan; a permission only
# when the main checkout's checker, run now on the filed request, says `tier: lead` (never the ask
# file's own tier), or (#323 T3) `tier: operator — egress: …` with `batch: eligible` (the egress
# is the only cause) and a `clearance:` line of pass, none or a clearable class (mandate_egress_only:
# no hard egress class, no undecided guard). Every
# other operator-tier request and a stop (text) ask — which has no live input to verify at
# delivery — are never delegable.
mandate_ask_class() {
  local out kind
  kind="$(jq -r '.kind // ""' "$3" 2>/dev/null)"
  case "$kind" in
    question|plan) ;;
    permission)
      out="$(mandate_ask_check "$1" "$2" "$3")"
      case "$(sed -n 1p <<<"$out")" in
        "tier: lead") ;;
        "tier: operator — egress: "*) mandate_egress_only "$out" || return 0 ;;
        *) return 0 ;;
      esac ;;
    *) return 0 ;;
  esac
  case "$4" in no-rule|lead-unsure) echo "$4" ;; esac
}

[ "${BASH_SOURCE[0]}" = "$0" ] || return 0
set -euo pipefail

usage() { sed -n '2,35p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
die() { echo "error: $2" >&2; exit "$1"; }
[ $# -ge 1 ] || usage
MAIN="$(git rev-parse --show-toplevel 2>/dev/null)" || die 2 "not inside a git checkout"
[ ! -f "$MAIN/.agents/team/team.json" ] || die 2 "team clone — the mandate lives in the main checkout"
. "$MANDATE_LIB/team-lib.sh" && . "$MANDATE_LIB/team-lead-lib.sh" && . "$MANDATE_LIB/team-evidence.sh" \
  || die 4 "team-lib.sh, team-lead-lib.sh or team-evidence.sh missing"
F="$(mandate_file "$MAIN")"
NEED="the Operator types, as a whole message in the Supervisor window: mandate <class>[,<class>…] for <N>h|<N>d team <name>[,<name>…] (classes: $MANDATE_CLASSES; at most $(( MANDATE_MAX_HOURS / 24 )) days)"

cmd="$1"; shift
case "$cmd" in
  grant)
    [ $# -eq 0 ] || usage
    d="$(mandate_derive "$MAIN" 2> "${TMPDIR:-/tmp}/mandate-why.$$")" || {
      why="$(cat "${TMPDIR:-/tmp}/mandate-why.$$" 2>/dev/null)"; rm -f "${TMPDIR:-/tmp}/mandate-why.$$"
      die 7 "no mandate written — $why. $NEED"; }
    rm -f "${TMPDIR:-/tmp}/mandate-why.$$"
    # Each team is bound to the run it is on now, which must have started before the message.
    runs='{}'
    for t in $(jq -r '.teams[]' <<<"$d"); do
      r="$(jq -r '.run // empty' "$MAIN/.agents/team/anchors/$t.json" 2>/dev/null || true)"
      [ -n "$r" ] && s="$(mandate_run_start "$r")" && [[ ! "$s" > "$(jq -r .granted_at <<<"$d")" ]] \
        || die 7 "no mandate written — team $t has no run that was going when the Operator typed the mandate (run: ${r:-none}); the Operator types it again once the run is on"
      runs="$(jq -c --arg t "$t" --arg r "$r" '. + {($t): $r}' <<<"$runs")"
    done
    # The marker of each bound run outlives the mandate (mandate_run_ever).
    ( umask 077; mkdir -p "$(dirname "$F")" "$MAIN/.agents/team/delegated"
      for t in $(jq -r 'keys[]' <<<"$runs"); do : > "$MAIN/.agents/team/delegated/$t-$(jq -r --arg t "$t" '.[$t]' <<<"$runs").mandated"; done
      jq --argjson runs "$runs" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '. + {runs: $runs, recorded_at: $at}' \
        <<<"$d" > "$F.tmp.$$" && mv "$F.tmp.$$" "$F" )
    jq -r '"mandate \(.id): \(.classes | join(",")) until \(.expires_at)\n"
      + (.runs | to_entries | map("  team \(.key) → run \(.value) (this run only)") | join("\n"))
      + "\nwords: \(.words)"' "$F" ;;
  show)
    [ $# -eq 0 ] || usage
    if m="$(mandate_verified "$MAIN" 2> "${TMPDIR:-/tmp}/mandate-why.$$")"; then
      jq -r --slurpfile f "$F" '"mandate \(.id): \(.classes | join(",")) until \(.expires_at)\n"
        + (($f[0].runs // {}) | to_entries | map("  team \(.key) → run \(.value) (this run only)") | join("\n"))
        + "\nwords: \(.words)"' <<<"$m"
    else
      echo "no mandate in force — $(cat "${TMPDIR:-/tmp}/mandate-why.$$" 2>/dev/null)"
    fi
    rm -f "${TMPDIR:-/tmp}/mandate-why.$$" ;;
  pause)
    [ $# -eq 0 ] || usage
    rm -f "$F"
    echo "mandate paused — the local record is removed; grant records the Operator's message again. Only the Operator's typed \"revoke mandate\" cancels it for good." ;;
  covers)
    [ $# -eq 3 ] || usage
    mandate_covers "$MAIN" "$1" "$2" "$3" ;;
  answers)
    [ $# -eq 0 ] || usage
    for f in "$MAIN"/.agents/team/delegated/*.json; do
      [ -f "$f" ] || continue
      jq -r '"\(.answered_at) \(.team) \(.run) \(.decision) [\(.class), \(.mandate)] \(.reply) — \(.why)"' "$f" 2>/dev/null || true
    done | sort ;;
  *) usage ;;
esac
