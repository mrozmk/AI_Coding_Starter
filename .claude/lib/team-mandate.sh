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
#   not decide. An operator-tier request (settings, production ask, delete, egress), a deny rule
#   and anything else are never delegable. Each named team is covered for the run it is on when
#   the message is typed; its next run is not.
#   The latest instruction in that transcript governs: a later `mandate …` replaces an earlier
#   one, the typed message `revoke mandate` cancels it for good, and any other message that
#   starts with `mandate` or `revoke mandate` cancels it too (an unclear instruction grants
#   nothing). A replaced Supervisor session, or a history that cannot be read whole (a read
#   error, a line that does not parse), means no mandate — never the last grant that did read.
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

# mandate_instruction <message> → 0 when the message is an instruction about the mandate at all
# (it starts with `mandate` or `revoke mandate`), whether or not it is a valid grant.
mandate_instruction() {
  local lt
  lt="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"; lt="${lt#"${lt%%[![:space:]]*}"}"
  case "$lt" in mandate|mandate[[:space:]]*|"revoke mandate"*) return 0 ;; esac
  return 1
}

# mandate_run_start <run id> → the run's start as ISO UTC, from <team>-<YYYYMMDD>-<HHMMSS>; rc 1
# for an id without it (the run cannot be bound to a grant).
mandate_run_start() {
  [[ "$1" =~ -([0-9]{4})([0-9]{2})([0-9]{2})-([0-9]{2})([0-9]{2})([0-9]{2})$ ]] || return 1
  printf '%s-%s-%sT%s:%s:%sZ\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" \
    "${BASH_REMATCH[4]}" "${BASH_REMATCH[5]}" "${BASH_REMATCH[6]}"
}

# mandate_history <main> → every mandate instruction the Operator typed in the registered
# Supervisor session, one compact JSON row {uuid, ts, m} per line, in transcript order. The
# transcript comes from the registration (<main>/.agents/team/registry/Supervisor.json) and the
# declared Claude profile — never from mandate.json. Typed user messages only (no machine line: a
# doorbell, runner, [peer] or <hc from=…> line). rc 1 (reason on stderr): no registered session
# or no transcript. rc 3: the history is unreadable or incomplete — a read error, a line naming
# the word that does not parse (a half-written one too), an instruction with no uuid or time, a
# library not loaded. Nothing is then taken from the part that did read: an instruction that
# cannot be read may be the revoke.
mandate_history() {
  local sid cwd cfg t raw rc rows row m bad="the Supervisor session's history cannot be read whole — no mandate is taken from a partial history"
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
  [ -r "$t" ] || { echo "$bad" >&2; return 3; }
  # Every line naming the word must parse; then the typed ones among them.
  raw="$(LC_ALL=C grep -ai 'mandate' "$t" 2>/dev/null)"; rc=$?
  [ "$rc" -le 1 ] || { echo "$bad" >&2; return 3; }
  [ -n "$raw" ] || return 0
  # One row out per line in (null for a line that is no typed message): a parse error, or a
  # count that differs (a cut line, lines run together), is an incomplete history.
  rows="$(printf '%s\n' "$raw" | jq -c 'if type == "object" and .type == "user" and ((.isMeta // false) | not)
      and ((.toolUseResult // null) == null)
    then {uuid: (.uuid // "" | tostring), ts: ((.timestamp // "" | tostring) | sub("\\.[0-9]+Z$"; "Z")),
       m: (.message.content | if type == "string" then . elif type == "array"
         then (map(select(type == "object" and .type == "text") | .text | tostring) | join(" ")) else "" end)}
    else null end' 2>/dev/null)" || { echo "$bad" >&2; return 3; }
  [ "$(printf '%s\n' "$rows" | wc -l)" -eq "$(printf '%s\n' "$raw" | wc -l)" ] || { echo "$bad" >&2; return 3; }
  while IFS= read -r row; do
    [ -n "$row" ] && [ "$row" != null ] || continue
    m="$(jq -r .m <<<"$row")"
    ! team_evidence_machine_line "$m" || continue
    mandate_instruction "$m" || continue
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

# mandate_since <main> <mandate id> <floor> → the later of <floor> and the time the Operator typed
# that mandate; rc 1 unless it is the one in force. An answer's evidence is looked up from there:
# a call made under an earlier mandate is no answer under this one.
mandate_since() {
  local m g
  [ -n "$2" ] && m="$(mandate_verified "$1" 2>/dev/null)" || return 1
  g="$(jq -er --arg i "$2" 'select(.id == $i) | .granted_at' <<<"$m" 2>/dev/null)" || return 1
  if [[ "$g" > "$3" ]]; then printf '%s\n' "$g"; else printf '%s\n' "$3"; fi
}

# mandate_run_capable <main> <team> <run> → 0 when the mandate in force is bound to that team's
# run, whatever the class: a run in which a delegated answer can exist now.
mandate_run_capable() {
  local m
  m="$(mandate_verified "$1" 2>/dev/null)" && mandate_bound "$1" "$2" "$3" "$m"
}

# mandate_run_ever <main> <team> <run> → 0 when the run has been delegation-capable at any point,
# whatever the mandate's state now (expired, paused, revoked, replaced). For the rest of such a
# run the Operator's authority is taken only on positive human evidence (a typed message or a
# dialog answer), never from a marker a file carries — team-lead.md §7. Any one is enough: the
# marker `grant` left for the run, a delegated answer on record for it, a mandate bound to it
# now, or a grant in the Supervisor session's history that names the team and was typed once the
# run had started (recorded or not). A history that cannot be read whole counts as capable. An
# empty <team> is read from the run id.
mandate_run_ever() {
  local team="$2" start rows row p x rc=0
  [ -n "$team" ] || team="${3%-*-*}"
  [ -n "$team" ] && [ -n "$3" ] || return 1
  [ ! -e "$1/.agents/team/delegated/$team-$3.mandated" ] || return 0
  for x in "$1/.agents/team/delegated/$team-$3"-d-*.json; do [ ! -e "$x" ] || return 0; done
  ! mandate_run_capable "$1" "$team" "$3" || return 0
  start="$(mandate_run_start "$3")" || return 1
  rows="$(mandate_history "$1" 2>/dev/null)" || rc=$?
  [ "$rc" != 3 ] || return 0
  while IFS= read -r row; do
    [ -n "$row" ] && p="$(mandate_parse "$(jq -r .m <<<"$row")")" || continue
    case ",$(cut -f3 <<<"$p")," in *",$team,"*) ;; *) continue ;; esac
    [[ "$start" > "$(jq -r .ts <<<"$row")" ]] || return 0
  done <<<"$rows"
  return 1
}

# mandate_ask_class <main> <clone> <ask file> <touch reason> → the mandate class of a decision
# bound to that ask, or nothing when no mandate can cover it. Only a lead-tier ask is delegable,
# by the lead's escalation reason (no-rule, lead-unsure): a question or a plan; a permission only
# when the main checkout's checker, run now on the filed request, says `tier: lead` (never the ask
# file's own tier). An operator-tier request and a stop (text) ask — which has no live input to
# verify at delivery — are never delegable.
mandate_ask_class() {
  local tmp out kind
  kind="$(jq -r '.kind // ""' "$3" 2>/dev/null)"
  case "$kind" in
    question|plan) ;;
    permission)
      tmp="$(mktemp "${TMPDIR:-/tmp}/mandate-ask.XXXXXX")" || return 0
      jq -c .payload "$3" > "$tmp" 2>/dev/null \
        && out="$(python3 -I "$1/.claude/lib/team_prompt_check.py" "$2" --input-json "$tmp" --main "$1" 2>/dev/null)" || out=""
      rm -f "$tmp"
      [ "$(sed -n 1p <<<"$out")" = "tier: lead" ] || return 0 ;;
    *) return 0 ;;
  esac
  case "$4" in no-rule|lead-unsure) echo "$4" ;; esac
}

[ "${BASH_SOURCE[0]}" = "$0" ] || return 0
set -euo pipefail

usage() { sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
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
