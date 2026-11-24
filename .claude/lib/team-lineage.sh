#!/usr/bin/env bash
# Follow-up chains across tickets: the third follow-up of one origin needs the Operator's consent.
# Usage: bash .claude/lib/team-lineage.sh parse <ticket file>
#        bash .claude/lib/team-lineage.sh check <ticket> [--follow-up-of <key>] [--ticket-file <f>]
#        bash .claude/lib/team-lineage.sh record <ticket> <team> [--follow-up-of <key>] [--ticket-file <f>]
#        bash .claude/lib/team-lineage.sh consent <ticket> --text "<the Operator's words>"
#        bash .claude/lib/team-lineage.sh list [<origin>]
#        bash .claude/lib/team-lineage.sh lineage <ticket> [--follow-up-of <key>] [--ticket-file <f>]
#   A follow-up carries `Follow-up of <parent> · origin <origin>` in its body (or --follow-up-of
#   <parent> names it); its origin is the chain's first ticket. check: exit 9 when the origin
#   already has two started follow-ups and this ticket has no answered consent. record: appends
#   the start to the ledger (once per ticket) and consumes the consent. consent: in a terminal (the
#   key typed back), or the Operator's own message in the Supervisor window, typed after the
#   refusal, that holds --text, and --text holds the phrase `consent <ticket>`.
#   lineage: prints `parent=<k> origin=<k>` (origin = the ticket itself for a chain's first ticket).
# Exit 0 ok · 2 usage or contradiction · 4 state · 7 not a terminal / key not confirmed · 9 consent needed
# Contract: .agents/reference/roles/supervisor.md → Follow-up chains
set -euo pipefail

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
die() { echo "error: $2" >&2; exit "$1"; }
[ $# -ge 1 ] || usage

LIMIT=2   # started follow-ups of one origin that need no consent; the next one does
KEY_RE='^([A-Z]+-[0-9]+|[0-9]+|L[0-9]+)$'   # jira | github | none (team-profile.sh TEAM_KEY_REGEX)
LINE_RE='^Follow-up of #?([A-Za-z0-9-]+) · origin #?([A-Za-z0-9-]+)[[:space:]]*$'

norm() {  # norm <key> → the key without a leading `#`, or exit 2
  local k="${1#\#}"
  [[ "$k" =~ $KEY_RE ]] || die 2 "ticket key '$1' is not a jira, github or none key"
  printf '%s' "$k"
}

main_root() {
  local r
  r="$(git rev-parse --show-toplevel 2>/dev/null)" || die 2 "not inside a git checkout"
  [ ! -f "$r/.agents/team/team.json" ] || die 2 "team clone — run team-lineage.sh from the main checkout"
  printf '%s' "$r"
}

# parse_file <file> → "parent origin", nothing when the ticket is no follow-up; two different
# lines are a contradiction (exit 2).
parse_file() {
  [ -r "$1" ] || die 2 "cannot read ticket file $1"
  local seen="" l p o
  while IFS= read -r l || [ -n "$l" ]; do
    l="${l%$'\r'}"
    [[ "$l" =~ $LINE_RE ]] || continue
    p="$(norm "${BASH_REMATCH[1]}")" || exit 2; o="$(norm "${BASH_REMATCH[2]}")" || exit 2
    [ -z "$seen" ] || [ "$seen" = "$p $o" ] || die 2 "ticket file $1 names two origins ($seen / $p $o)"
    seen="$p $o"
  done < "$1"
  printf '%s' "$seen"
}

# ---- state: <main>/.agents/team/lineage/ (0700), files 0600, keys only — never ticket text ------
D="" LEDGER="" CONSENTS=""
state() {
  D="$(main_root)/.agents/team/lineage"; LEDGER="$D/starts.jsonl"; CONSENTS="$D/consents"
  ( umask 077; mkdir -p "$CONSENTS" ) || die 4 "cannot create $D"
}
ledger_get() {  # ledger_get <ticket> <field> → the field of that ticket's start, or nothing
  [ -f "$LEDGER" ] || return 0
  jq -r --arg t "$1" --arg f "$2" 'select(.ticket == $t) | .[$f] // empty' "$LEDGER" 2>/dev/null | head -n 1
}
started_of() {  # started_of <origin> → the follow-ups of that origin already started, one per line
  [ -f "$LEDGER" ] || return 0
  jq -r --arg o "$1" 'select(.origin == $o and .ticket != $o) | .ticket' "$LEDGER" 2>/dev/null | awk '!s[$0]++'
}

# A mkdir lock with our pid; a dead holder's lock is reclaimed under <lock>.reclaim (the
# roles_lock pattern), a live one is waited on for 10 s.
LOCK=""
lock() {
  local l="$D/lineage.lock" n=0 p
  until mkdir "$l" 2>/dev/null; do
    p="$(cat "$l/pid" 2>/dev/null || true)"
    if [ -n "$p" ] && ! kill -0 "$p" 2>/dev/null && mkdir "$l.reclaim" 2>/dev/null; then
      [ "$(cat "$l/pid" 2>/dev/null || true)" != "$p" ] || rm -rf "$l"
      rmdir "$l.reclaim" 2>/dev/null || true; continue
    fi
    [ "$n" -lt 50 ] || die 4 "lineage ledger is locked by pid ${p:-?}"
    sleep 0.2; n=$((n + 1))
  done
  echo $$ > "$l/pid"; LOCK="$l"
}
trap '[ -z "$LOCK" ] || rm -rf "$LOCK"' EXIT

# resolve <ticket> → PARENT ORIGIN (empty: not a follow-up). The body line and --follow-up-of must
# agree; a parent already in the ledger gives its own origin, and a body line that says otherwise
# is a contradiction.
TICKET="" FOLLOW="" TFILE="" PARENT="" ORIGIN=""
resolve() {
  local line="" lp="" lo="" known
  [ -z "$TFILE" ] || line="$(parse_file "$TFILE")"
  [ -z "$line" ] || { lp="${line% *}"; lo="${line#* }"; }
  if [ -n "$FOLLOW" ] && [ -n "$lp" ] && [ "$FOLLOW" != "$lp" ]; then
    die 2 "$TICKET: --follow-up-of $FOLLOW but the ticket says follow-up of $lp — ask the Operator which"
  fi
  PARENT="${FOLLOW:-$lp}"; ORIGIN=""
  [ -n "$PARENT" ] || return 0
  [ "$PARENT" != "$TICKET" ] || die 2 "$TICKET cannot be a follow-up of itself"
  known="$(ledger_get "$PARENT" origin)"
  if [ -n "$known" ] && [ -n "$lo" ] && [ "$known" != "$lo" ]; then
    die 2 "$TICKET: the ticket says origin $lo, the ledger has $PARENT under origin $known"
  fi
  ORIGIN="${known:-${lo:-$PARENT}}"
}

consent_file() { printf '%s/%s.md' "$CONSENTS" "$1"; }

# consent_window → the uuid of the Operator's typed message in the Supervisor window that holds
# $TEXT, typed after this ticket's first refusal; nothing without a refusal, a Supervisor session
# (its session-host record, sh_record_file) or a match. A uuid that answered another consent counts
# only when the message names this ticket (team-evidence.sh).
consent_window() {
  local r lib rec used="" f sid cwd since
  r="$(main_root)"; lib="$(cd "$(dirname "$0")" && pwd)"; rec="$r/.agents/team/registry/Supervisor.json"
  [ -f "$D/refused/$TICKET" ] || return 0
  since="$(cat "$D/refused/$TICKET")"
  for f in "$CONSENTS"/*.md; do
    [ -f "$f" ] && [ "$f" != "$(consent_file "$TICKET")" ] || continue
    used="$used $(sed -n 's/^answered_via: supervisor-window //p' "$f")"
  done
  sid="$(jq -r '.session_id // empty' "$rec" 2>/dev/null)"; cwd="$(jq -r '.cwd // empty' "$rec" 2>/dev/null)"
  [ -n "$sid" ] || return 0
  # Sourced last: team-lib.sh brings its own helpers into this subshell.
  . "$lib/team-lib.sh" && . "$lib/team-evidence.sh" || return 0
  f="$(team_claude_project_dir "${cwd:-$r}")/$sid.jsonl"
  [ -f "$f" ] || return 0
  team_evidence_match "$f" "$TEXT" "$since" "$TICKET" "$used"
}
consent_status() { sed -n 's/^status: //p' "$(consent_file "$1")" 2>/dev/null | head -n 1; }

# gate → 0 free (prints why when it matters), 9 consent needed
gate() {
  local n list
  if [ -n "$(ledger_get "$TICKET" ticket)" ]; then echo "$TICKET already started — not a new link"; return 0; fi
  [ -n "$ORIGIN" ] || return 0
  list="$(started_of "$ORIGIN")"; n="$(printf '%s' "$list" | grep -c . || true)"
  [ "$n" -ge "$LIMIT" ] || return 0
  if [ "$(consent_status "$TICKET")" = answered ]; then
    echo "follow-up $((n + 1)) of origin $ORIGIN — Operator consent $(consent_file "$TICKET" | sed "s|^$(main_root)/||")"
    return 0
  fi
  # The first refusal's time: the Supervisor-window consent counts only messages typed after it
  # (kept on a re-check, so an answer typed between two checks still counts).
  [ -e "$D/refused/$TICKET" ] || ( umask 077; mkdir -p "$D/refused" \
    && date -u +%Y-%m-%dT%H:%M:%SZ > "$D/refused/$TICKET" ) || true
  echo "follow-up $((n + 1)) of origin $ORIGIN ($(printf '%s' "$list" | paste -sd, - | sed 's/,/, /g') started) — needs the Operator's consent: bash .claude/lib/team-lineage.sh consent $TICKET --text \"<the Operator's words>\"" >&2
  return 9
}

opts() {  # opts <args…> — --follow-up-of / --ticket-file / --text into globals
  TEXT=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --follow-up-of) [ $# -ge 2 ] || usage; FOLLOW="$(norm "$2")"; shift 2 ;;
      --ticket-file) [ $# -ge 2 ] || usage; TFILE="$2"; shift 2 ;;
      --text) [ $# -ge 2 ] || usage; TEXT="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
}

cmd="$1"; shift
case "$cmd" in
  parse)
    [ $# -eq 1 ] || usage
    line="$(parse_file "$1")"
    [ -z "$line" ] || echo "parent=${line% *} origin=${line#* }" ;;
  check)
    [ $# -ge 1 ] || usage
    TICKET="$(norm "$1")"; shift; opts "$@"
    state; resolve; gate ;;
  record)
    [ $# -ge 2 ] || usage
    TICKET="$(norm "$1")" team="$2"; shift 2; opts "$@"
    [[ "$team" =~ ^[a-z][a-z0-9-]*$ ]] || die 2 "team name '$team' is not a team name"
    state; lock; resolve
    if [ -n "$(ledger_get "$TICKET" ticket)" ]; then echo "$TICKET already recorded"; exit 0; fi
    rc=0; why="$(gate)" || rc=$?
    [ "$rc" = 0 ] || exit "$rc"
    c=""; [ "$(consent_status "$TICKET")" != answered ] || c="consents/$TICKET.md"
    ( umask 077
      jq -cn --arg t "$TICKET" --arg p "$PARENT" --arg o "${ORIGIN:-$TICKET}" --arg team "$team" \
        --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg c "$c" \
        '{ticket: $t, parent: (if $p == "" then null else $p end), origin: $o, team: $team,
          started_at: $at, consent: (if $c == "" then null else $c end)}' >> "$LEDGER" )
    if [ -n "$c" ]; then
      f="$(consent_file "$TICKET")"
      ( umask 077; sed "s/^status: answered$/status: consumed/" "$f" > "$f.tmp.$$" \
        && printf 'consumed_at: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$f.tmp.$$" && mv "$f.tmp.$$" "$f" )
    fi
    echo "recorded $TICKET${ORIGIN:+ (origin $ORIGIN)}${c:+ — consent consumed}" ;;
  consent)
    [ $# -ge 1 ] || usage
    TICKET="$(norm "$1")"; shift; opts "$@"
    [ -n "$TEXT" ] || die 2 "consent needs --text \"<the Operator's words>\""
    state
    case "$(consent_status "$TICKET")" in consumed) die 4 "$TICKET already started on a consent" ;; esac
    if [ -t 0 ]; then
      printf 'Operator consent to start follow-up %s — type the ticket key to confirm: ' "$TICKET" >&2
      IFS= read -r typed || typed=""
      [ "${typed#\#}" = "$TICKET" ] || die 7 "the key typed ('$typed') is not $TICKET — no consent written"
      via=terminal
    else
      # The window's counterpart of typing the key back: the phrase `consent <key>` (any case,
      # the key a whole word), so a mere mention of the ticket is never consent.
      lt="$(printf '%s' "$TEXT" | tr '[:upper:]' '[:lower:]')"
      re="(^|[^a-z0-9-])consent[[:space:]]+#?$(printf '%s' "$TICKET" | tr '[:upper:]' '[:lower:]')([^a-z0-9-]|$)"
      [[ "$lt" =~ $re ]] || die 7 \
        "consent is the Operator's: run it in a terminal (stdin is not a TTY), or quote their Supervisor-window words holding 'consent $TICKET'"
      uuid="$(consent_window)"
      [ -n "$uuid" ] || die 7 \
        "consent is the Operator's: run it in a terminal (stdin is not a TTY) — no message typed in the Supervisor window after the refusal holds that text"
      via="supervisor-window $uuid"
    fi
    f="$(consent_file "$TICKET")"
    ( umask 077
      { printf -- '---\nticket: %s\nstatus: answered\nanswered_at: %s\nanswered_via: %s\n---\n\n## Answer\n\n' \
          "$TICKET" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$via"
        printf '%s\n' "$TEXT" | tr -d '\r' | cut -c1-500 | head -n 20; } > "$f.tmp.$$" && mv "$f.tmp.$$" "$f" )
    echo "consent written: .agents/team/lineage/consents/$TICKET.md" ;;
  lineage)
    [ $# -ge 1 ] || usage
    TICKET="$(norm "$1")"; shift; opts "$@"
    state; resolve
    echo "parent=$PARENT origin=${ORIGIN:-$TICKET}" ;;
  list)
    [ $# -le 1 ] || usage
    o=""; [ $# -eq 0 ] || o="$(norm "$1")"
    state; [ -f "$LEDGER" ] || exit 0
    jq -rs --arg o "$o" 'map(select(.ticket != .origin and ($o == "" or .origin == $o)))
      | group_by(.origin)[] | "\(.[0].origin): " + (map("\(.ticket) (\(.team), \(.started_at[0:10])\(if .consent then ", consent" else "" end))") | join(", "))' \
      "$LEDGER" ;;
  *) usage ;;
esac
