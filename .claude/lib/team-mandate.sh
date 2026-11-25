#!/usr/bin/env bash
# The Operator's mandate to the Supervisor: which classes of a team's pending decisions the
# Supervisor may answer as a delegate, and until when. One file per machine in the main checkout,
# <main>/.agents/team/mandate.json (git-ignored, mode 600) — never in a team clone.
# Usage: bash .claude/lib/team-mandate.sh grant --text "<the Operator's words>"
#        bash .claude/lib/team-mandate.sh show | revoke | answers
#        bash .claude/lib/team-mandate.sh covers <class>[,<class>…]
#   grant: the Operator's message must START with `mandate <class>[,<class>…] for <N>h|<N>d` (any
#   case; at most 7 days); whatever follows is kept as their words. Classes and expiry are read
#   from that message only — there is no flag for them, so the caller cannot widen what the
#   Operator said. Two bindings, as for team-lineage.sh consent: a terminal (the class list typed
#   back; --text is the message), or the Operator's own typed message in the Supervisor window
#   that holds --text (never a doorbell, runner, [peer] or <hc from=…> line; one message grants
#   once, and never one typed before the last grant or revoke). From the window the whole message
#   is parsed and stored, and the expiry counts from the message's time, not from now.
#   Classes: no-rule, lead-unsure (a question the TeamLead escalated) and, only when named,
#   the human-only acts settings, prod-ask, delete, egress. Deny rules, destructive SQL and
#   anything outside these names are never delegable.
#   show: the mandate in force, or `no mandate in force`. revoke: ends it now (anyone may narrow).
#   covers: exit 0 and the mandate id when the mandate in force names every <class>, else 1.
#   answers: every answer the Supervisor gave as a delegate (<main>/.agents/team/delegated/).
# Sourced by team-lead.sh, the runner and team-ask-hook.sh for mandate_current, mandate_verified,
# mandate_covers, mandate_class and mandate_ask_classes.
# Exit 0 ok · 1 no mandate / not covered · 2 usage · 4 state · 7 the Operator's binding is missing
# Contract: .agents/reference/roles/supervisor.md → Mandate
MANDATE_CLASSES="no-rule lead-unsure settings prod-ask delete egress"
MANDATE_MAX_HOURS=168
MANDATE_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mandate_file() { printf '%s/.agents/team/mandate.json' "$1"; }

# mandate_parse <message> → "<classes, sorted, comma-joined>\t<hours>"; rc 1 unless the message,
# trimmed, starts with the phrase, every class is a delegable one and the term is within the cap.
# One parser for the grant and for the re-check of a window grant.
mandate_parse() {
  local lt re list n c hours
  lt="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"; lt="${lt#"${lt%%[![:space:]]*}"}"
  re='^mandate[[:space:]]+([a-z-]+(,[a-z-]+)*)[[:space:]]+for[[:space:]]+([1-9][0-9]{0,3})(h|d)([^a-z0-9]|$)'
  [[ "$lt" =~ $re ]] || return 1
  list="${BASH_REMATCH[1]}"; n="${BASH_REMATCH[3]}"
  hours="$n"; [ "${BASH_REMATCH[4]}" = h ] || hours=$(( n * 24 ))
  [ "$hours" -le "$MANDATE_MAX_HOURS" ] || return 1
  for c in ${list//,/ }; do
    case " $MANDATE_CLASSES " in *" $c "*) ;; *) return 1 ;; esac
  done
  printf '%s\t%s\n' "$(printf '%s\n' ${list//,/ } | sort -u | paste -sd, -)" "$hours"
}

# mandate_words <message> → the message as the file keeps it (the Operator's words, bounded).
mandate_words() { printf '%s' "$1" | tr -d '\r' | cut -c1-2000 | head -n 40; }

# mandate_current <main> → the mandate in force as compact JSON; rc 1 when there is none: no file,
# a clone, a malformed file, an unknown class, revoked, or past its expiry.
mandate_current() {
  local f; f="$(mandate_file "$1")"
  [ -f "$f" ] && [ ! -L "$f" ] && [ ! -f "$1/.agents/team/team.json" ] || return 1
  jq -ce --arg known "$MANDATE_CLASSES" '
    ($known | split(" ")) as $k
    | select(type == "object" and ((.id // "") | test("^m-[0-9TZ]+(-[0-9]+)?$"))
        and (.classes | type) == "array" and (.classes | length) > 0
        and all(.classes[]; . as $c | $k | index($c) != null)
        and (.revoked_at // null) == null and ((.words // "") | type) == "string"
        and (((.expires_at // "") | try fromdateiso8601 catch 0) > now)
        and (((.granted_at // "") | try fromdateiso8601 catch (now + 1)) <= now))' "$f" 2>/dev/null \
    || return 1
}

# mandate_verified <main> → as mandate_current, and a grant made from the Supervisor window is
# read back from the Operator's message itself: the typed message at the recorded uuid in that
# session's transcript (the declared Claude profile) must still parse to exactly the file's classes
# and expiry — so an edit of the file cannot widen or extend what the Operator typed. A terminal
# grant has no message to read back (the same-account limit of team-lead.md §7). The two points
# that act on the mandate use this one: the Supervisor's delegated answer and the stage hook.
# Needs team-lib.sh and team-lead-lib.sh (the callers have them).
mandate_verified() {
  local m via cfg t row msg ts p
  m="$(mandate_current "$1")" || return 1
  via="$(jq -r '.granted_via // ""' <<<"$m")"
  case "$via" in
    terminal) ;;
    "supervisor-window "?*)
      command -v team_supervisor_home >/dev/null 2>&1 && command -v team_role_transcript >/dev/null 2>&1 || return 1
      cfg="$(team_supervisor_home "$1")" || return 1
      t="$(team_role_transcript "$(jq -r '.cwd // ""' <<<"$m")" "$(jq -r '.session_id // ""' <<<"$m")" "$cfg")"
      [ -f "$t" ] || return 1
      row="$(jq -c --arg u "${via#supervisor-window }" '
        select(type == "object" and .type == "user" and (.uuid // "") == $u and ((.isMeta // false) | not))
        | {ts: ((.timestamp // "") | sub("\\.[0-9]+Z$"; "Z")),
           m: (.message.content | if type == "string" then . elif type == "array"
             then (map(select(.type == "text") | .text) | join(" ")) else "" end)}' "$t" 2>/dev/null | head -n 1)"
      [ -n "$row" ] || return 1
      msg="$(jq -r .m <<<"$row")"; ts="$(jq -r .ts <<<"$row")"
      p="$(mandate_parse "$msg")" || return 1
      jq -e --arg c "${p%%$'\t'*}" --arg ts "$ts" --argjson h "${p#*$'\t'}" --arg w "$(mandate_words "$msg")" '
        (.classes | sort | join(",")) == $c and .words == $w
        and .expires_at == ((($ts | fromdateiso8601) + $h * 3600) | todateiso8601)' <<<"$m" >/dev/null 2>&1 \
        || return 1 ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$m"
}

# mandate_covers <main> <class>[,<class>…] [<mandate id>] [verified] → the id of the mandate in
# force when it names every class (and is that mandate, when an id is given); rc 1 otherwise.
# `verified` reads a window grant back from the Operator's message (mandate_verified).
mandate_covers() {
  local m
  if [ "${4:-}" = verified ]; then m="$(mandate_verified "$1")" || return 1
  else m="$(mandate_current "$1")" || return 1; fi
  [ -n "$2" ] && jq -er --arg c "$2" --arg i "${3:-}" '
    select(($i == "" or .id == $i) and (.classes as $k | all($c | split(",")[]; . as $x | $k | index($x) != null)))
    | .id' <<<"$m" 2>/dev/null || return 1
}

# mandate_class <ask tier> <causes, one per line> <touch reason> → the mandate classes of a
# decision bound to an ask, sorted and comma-joined, or nothing when no mandate can cover it: an
# operator-tier ask by EVERY cause the checker found (a never-waived refusal, a failed guard or an
# unknown cause among them → nothing); a lead-tier ask by the lead's escalation reason.
mandate_class() {
  local out="" c l
  case "$1" in
    operator)
      [ -n "$2" ] || return 0
      while IFS= read -r l; do
        [ -n "$l" ] || continue
        case "$l" in
          "egress: guard failed"*|"refuse"*) return 0 ;;
          "egress: "*) c=egress ;;
          "settings edit: "*) c=settings ;;
          "production ask: "*) c=prod-ask ;;
          "irreversible delete "*) c=delete ;;
          *) return 0 ;;
        esac
        out="$out$c"$'\n'
      done <<<"$2"
      [ -z "$out" ] || printf '%s' "$out" | sort -u | paste -sd, - ;;
    lead) case "$3" in no-rule|lead-unsure) echo "$3" ;; esac ;;
  esac
}

# mandate_ask_classes <main> <clone> <ask file> <touch reason> → mandate_class of that ask, from
# the main checkout's checker run now on the filed request (never from the ask file's own tier): a
# permission by its tier line and its full `causes:` list, a question, plan or stop as lead tier.
mandate_ask_classes() {
  local tmp out tier="" causes=""
  if [ "$(jq -r '.kind // ""' "$3" 2>/dev/null)" != permission ]; then mandate_class lead "" "$4"; return 0; fi
  tmp="$(mktemp "${TMPDIR:-/tmp}/mandate-ask.XXXXXX")" || return 0
  jq -c .payload "$3" > "$tmp" 2>/dev/null \
    && out="$(python3 -I "$1/.claude/lib/team_prompt_check.py" "$2" --input-json "$tmp" --main "$1" --causes 2>/dev/null)" || out=""
  rm -f "$tmp"
  case "$(sed -n 1p <<<"$out")" in
    "tier: operator — "*) tier=operator
      causes="$(sed -n 's/^causes: //p' <<<"$out" | jq -r 'if type == "array" then .[] else empty end' 2>/dev/null)" ;;
    "tier: lead") tier=lead ;;
  esac
  mandate_class "$tier" "$causes" "$4"
}

[ "${BASH_SOURCE[0]}" = "$0" ] || return 0
set -euo pipefail

usage() { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
die() { echo "error: $2" >&2; exit "$1"; }
[ $# -ge 1 ] || usage
LIB="$MANDATE_LIB"
MAIN="$(git rev-parse --show-toplevel 2>/dev/null)" || die 2 "not inside a git checkout"
[ ! -f "$MAIN/.agents/team/team.json" ] || die 2 "team clone — the mandate lives in the main checkout"
F="$(mandate_file "$MAIN")"; LOG="$MAIN/.agents/team/mandate-log.jsonl"
utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() {  # log <event> <id> <via> — one append-only line per grant and revoke
  ( umask 077; jq -cn --arg e "$1" --arg i "$2" --arg v "$3" --arg at "$(utc)" \
      '{event: $e, id: $i, at: $at, via: $v}' >> "$LOG" )
}

# The Operator's typed message in the Supervisor window that holds $TEXT →
# {uuid, ts, m, session_id, cwd} (the whole message, its time). The Supervisor's registered
# session, under the declared Claude profile (never the caller's environment).
grant_window() {
  local sid cwd cfg t uuid floor
  sid="$(jq -r '.session_id // empty' "$MAIN/.agents/team/registry/Supervisor.json" 2>/dev/null || true)"
  cwd="$(jq -r '.cwd // empty' "$MAIN/.agents/team/registry/Supervisor.json" 2>/dev/null || true)"; cwd="${cwd:-$MAIN}"
  [ -n "$sid" ] || return 0
  cfg="$(team_supervisor_home "$MAIN")" || return 0
  t="$(team_role_transcript "$cwd" "$sid" "$cfg")"
  [ -f "$t" ] || return 0
  # Never a message from before the last grant or revoke: a revoked mandate is not typed back in.
  floor="$(jq -rs 'map(.at // "") | max // ""' "$LOG" 2>/dev/null || true)"
  uuid="$(team_evidence_match "$t" "$TEXT" "$floor" "mandate" "")"
  [ -n "$uuid" ] || return 0
  ! grep -qF "supervisor-window $uuid\"" "$LOG" 2>/dev/null || return 0
  jq -c --arg u "$uuid" --arg s "$sid" --arg c "$cwd" '
    select(type == "object" and .type == "user" and (.uuid // "") == $u)
    | {uuid: $u, session_id: $s, cwd: $c, ts: ((.timestamp // "") | sub("\\.[0-9]+Z$"; "Z")),
       m: (.message.content | if type == "string" then . elif type == "array"
         then (map(select(.type == "text") | .text) | join(" ")) else "" end)}' "$t" 2>/dev/null | head -n 1
}

# One writer at a time: a grant reads the history, publishes the file and logs as one step, so a
# revoke never lands between them and gets undone. A mkdir lock, waited on for 10 s.
LOCKD=""
lock() {
  local l="$MAIN/.agents/team/mandate.lock" n=0
  ( umask 077; mkdir -p "$MAIN/.agents/team" )
  until mkdir "$l" 2>/dev/null; do
    [ "$n" -lt 50 ] || die 4 "the mandate is locked ($l) — another grant or revoke is running; remove the directory if none is"
    sleep 0.2; n=$((n + 1))
  done
  LOCKD="$l"
}
trap '[ -z "$LOCKD" ] || rmdir "$LOCKD" 2>/dev/null' EXIT

cmd="$1"; shift
case "$cmd" in
  grant)
    [ $# -eq 2 ] && [ "$1" = --text ] && [ -n "$2" ] || usage
    TEXT="$2"; sid=""; cwd=""; lock
    need="the Operator's message must start with: mandate <class>[,<class>…] for <N>h|<N>d (classes: $MANDATE_CLASSES; at most $(( MANDATE_MAX_HOURS / 24 )) days)"
    if [ -t 0 ]; then
      words="$TEXT"
      p="$(mandate_parse "$words")" || die 7 "$need — no mandate written"
      list="${p%%$'\t'*}"; hours="${p#*$'\t'}"
      printf 'Operator mandate to the Supervisor: %s for %sh — type the class list to confirm: ' "$list" "$hours" >&2
      IFS= read -r typed || typed=""
      [ "$typed" = "$list" ] || die 7 "the list typed ('$typed') is not $list — no mandate written"
      via=terminal; from="$(utc)"
    else
      . "$LIB/team-lib.sh" && . "$LIB/team-lead-lib.sh" && . "$LIB/team-evidence.sh" \
        || die 4 "team-lib.sh, team-lead-lib.sh or team-evidence.sh missing"
      ev="$(grant_window)"
      [ -n "$ev" ] || die 7 \
        "a mandate is the Operator's: run it in a terminal (stdin is not a TTY) — no new message typed in the Supervisor window holds that text"
      # The whole message is what was granted: it must itself start with the phrase, so a quoted
      # example, a refusal or a condition around it never turns into a grant.
      words="$(jq -r .m <<<"$ev")"
      p="$(mandate_parse "$words")" || die 7 "$need — no mandate written"
      list="${p%%$'\t'*}"; hours="${p#*$'\t'}"
      via="supervisor-window $(jq -r .uuid <<<"$ev")"; from="$(jq -r .ts <<<"$ev")"
      sid="$(jq -r .session_id <<<"$ev")"; cwd="$(jq -r .cwd <<<"$ev")"
    fi
    exp="$(jq -rn --arg t "$from" --argjson h "$hours" '($t | fromdateiso8601) + $h * 3600 | todateiso8601' 2>/dev/null)" \
      || die 7 "the grant's time ($from) cannot be read — no mandate written"
    jq -en --arg e "$exp" '($e | fromdateiso8601) > now' >/dev/null 2>&1 \
      || die 7 "that mandate already expired at $exp — no mandate written"
    id="m-$(date -u +%Y%m%dT%H%M%SZ)-$$"
    ( umask 077; mkdir -p "$(dirname "$F")"
      jq -n --arg id "$id" --arg list "$list" --arg at "$(utc)" --arg exp "$exp" --arg via "$via" \
        --arg s "$sid" --arg c "$cwd" --arg w "$(mandate_words "$words")" \
        '{id: $id, classes: ($list | split(",")), granted_at: $at, expires_at: $exp, granted_via: $via,
          session_id: $s, cwd: $c, words: $w, revoked_at: null}' > "$F.tmp.$$" && mv "$F.tmp.$$" "$F" )
    log grant "$id" "$via"
    echo "mandate $id: $list until $exp ($via)" ;;
  show)
    [ $# -eq 0 ] || usage
    if m="$(mandate_current "$MAIN")"; then
      jq -r '"mandate \(.id): \(.classes | join(",")) until \(.expires_at) (\(.granted_via))\nwords: \(.words)"' <<<"$m"
    else
      echo "no mandate in force"
      [ ! -f "$F" ] || jq -r '"last: \(.id // "?") — \(if .revoked_at then "revoked \(.revoked_at)" else "expired \(.expires_at // "?")" end)"' "$F" 2>/dev/null || true
    fi ;;
  revoke)
    [ $# -eq 0 ] || usage
    lock
    [ -f "$F" ] || { echo "no mandate to revoke"; exit 0; }
    id="$(jq -r '.id // "?"' "$F" 2>/dev/null || echo "?")"
    ( umask 077; jq --arg at "$(utc)" '.revoked_at = (.revoked_at // $at)' "$F" > "$F.tmp.$$" && mv "$F.tmp.$$" "$F" ) \
      || die 4 "$F is unreadable — delete it by hand to end the mandate"
    log revoke "$id" "${TEAM_SESSION_ROLE:-operator}"
    echo "mandate $id revoked" ;;
  covers)
    [ $# -eq 1 ] || usage
    mandate_covers "$MAIN" "$1" ;;
  answers)
    [ $# -eq 0 ] || usage
    for f in "$MAIN"/.agents/team/delegated/*.json; do
      [ -f "$f" ] || continue
      jq -r '"\(.answered_at) \(.team) \(.run) \(.decision) [\(.class), \(.mandate)] \(.reply) — \(.why)"' "$f" 2>/dev/null || true
    done | sort ;;
  *) usage ;;
esac
