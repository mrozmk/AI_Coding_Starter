#!/usr/bin/env bash
# The claim at the start — Check → Claim → Confirm before any clone or branch names a ticket, so a
# second machine (or team) starting the same ticket is refused with the holder's name.
#
# Usage: bash .claude/lib/team-claim.sh <op> …
#   check   <KEY> --who <w> [--branch <b>] [--takeover]   read-only: `free previous=<p>` |
#                                                          `held id=<id> previous=<p>` | `refused: …`
#   claim   <KEY> --who <w> --branch <b> [--takeover]     check, post the claim comment, confirm it is
#                                                          the holder, then (winner only) set-status
#                                                          started → `claimed|held id=… previous=…` +
#                                                          `status: …`
#   release <KEY> --id <id> --reason <r>                  restore the marker's `previous` (only while
#                                                          the claim holds and the status reads
#                                                          started), then the release comment
#   refs    <KEY>                                          `branch <name>` / `pr <url> <relation>` lines
#   body claim --who <w> --branch <b> --previous <p> [--superseded <id|status>] [--id <id>]
#              [--format github|jira]                      a claim comment body on stdout
#   body release --id <id> --reason <r> [--format github|jira]
#   holder --lines <f> [--who <w>]                         `holder id=… self=yes|no` | `holder none`
#
# check/claim/release run for tracker=github (team-tracker.sh and team-pr.sh do every `gh` call —
# none here); tracker=none prints one line and exits 0; tracker=jira is exit 2 — the session's MCP
# runs it with refs, body and holder, which run for every tracker.
#
# Grammar — the LAST line of a claim / release comment (`<!-- … -->` on GitHub, plain on Jira):
#   team:claim v1 id=<machine>.<who>.<UTC> machine=<m> who=<w> branch=<b> at=<ISO> previous=<enc>
#     [takeover=<superseded>]
#   team:claim-released v1 id=<id> reason=<r>
# <enc> is the pre-claim status, percent-encoded (`none`: no status, `no-project`: no board). A Jira
# converter may join the comment's first line onto the marker line; that prefix is allowed.
#
# Holder rule: claim records ordered by the numeric comment id; a release removes its id (and a claim
# whose id was released earlier never counts — an uncertain post can land after its cleanup); a
# claim with `takeover=` clears every earlier claim; the holder is the first claim left.
#
# Exit codes: 0 ok · 1 ticket unusable · 2 usage/profile · 3 refused (held, closed, started, PR,
#   branch, lost race) · 4 recoverable (a failed or partial read or write — never read as "absent").
# Bash 3.2 compatible (macOS /bin/bash).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/team-profile.sh"
root="$(git rev-parse --show-toplevel)"
team_tracker_profile_load "$root"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

die() { echo "error: $2" >&2; exit "$1"; }
trk() { bash "$HERE/team-tracker.sh" "$@"; }
TAB="$(printf '\t')"

# One regex, three readers (holder here, claim_lines here, ownMarker in tracker-snapshot.mjs).
EXTRACT_RE='^((Claimed by|Taken over by|Claim released) .+ )?(<!-- )?team:claim(-released)? v1 id=[^ ]+( [a-z]+=[^ ]+)*( -->)?$'

MACHINE="$(hostname -s 2>/dev/null || hostname)"
MACHINE="${MACHINE//[^A-Za-z0-9-]/-}"

# kv <line> <key> → the value of `<key>=` among the line's words (empty when absent).
kv() {
  local w words
  read -r -a words <<< "$1"
  for w in ${words[@]+"${words[@]}"}; do
    case "$w" in "$2="*) printf '%s' "${w#"$2"=}"; return 0 ;; esac
  done
}
uri_enc() { case "$1" in none|no-project) printf '%s' "$1" ;; *) jq -rn --arg s "$1" '$s|@uri' ;; esac; }
uri_dec() { local s="$1"; printf '%b' "${s//%/\\x}"; }
show_err() { [ ! -s "$1" ] || sed 's/^/  | /' "$1" >&2; }

# ---- body ---------------------------------------------------------------------------------------

body_claim() {  # body_claim <id> <previous raw> <superseded|""> → stdout
  local id="$1" prev at marker
  prev="$(uri_enc "$2")"
  at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  marker="team:claim v1 id=$id machine=$MACHINE who=$WHO branch=$BRANCH at=$at previous=$prev"
  if [ -n "$3" ]; then
    marker="$marker takeover=$3"
    echo "Taken over by $WHO on $MACHINE from $3 for branch $BRANCH at $at (--takeover)."
  else
    echo "Claimed by $WHO on $MACHINE for branch $BRANCH at $at."
  fi
  if [ "$FORMAT" = jira ]; then echo "$marker"; else echo "<!-- $marker -->"; fi
}

body_release() {  # body_release <id> <reason> → stdout
  local marker="team:claim-released v1 id=$1 reason=$2"
  echo "Claim released ($2): $1."
  if [ "$FORMAT" = jira ]; then echo "$marker"; else echo "<!-- $marker -->"; fi
}

new_id() { printf '%s.%s.%s' "$MACHINE" "$WHO" "$(date -u +%Y%m%dT%H%M%SZ)"; }

# ---- holder -------------------------------------------------------------------------------------

# holder_judge <lines file> <who> → one `holder …` line. Records are `<created>\t<id>\t<last line>`.
holder_judge() {
  local f="$1" who="$2" bad
  [ -r "$f" ] || die 2 "claim lines file '$f' is not readable"
  bad="$(awk -F "$TAB" 'NF == 0 { next } NF < 3 || $2 !~ /^[0-9]+$/ { print NR; exit }' "$f")"
  [ -z "$bad" ] || die 2 "malformed claim line $bad"
  awk -F "$TAB" 'NF >= 3' "$f" | sort -t "$TAB" -k2,2n | awk -v re="$EXTRACT_RE" \
      -v me="$MACHINE" -v who="$who" '
    function field(m, k,   n, i, a) {
      n = split(m, a, " ")
      for (i = 1; i <= n; i++) if (index(a[i], k "=") == 1) return substr(a[i], length(k) + 2)
      return ""
    }
    {
      p = index($0, "\t"); rest = substr($0, p + 1); p = index(rest, "\t"); line = substr(rest, p + 1)
      if (line !~ re) next
      p = match(line, /team:claim(-released)? v1 id=/); m = substr(line, p); sub(/ -->$/, "", m)
      id = field(m, "id")
      if (m ~ /^team:claim-released /) {
        rel[id] = 1; k = 0
        for (i = 1; i <= n; i++) if (act[i] != id) { k++; act[k] = act[i]; mk[k] = mk[i] }
        n = k; next
      }
      if (id in rel) next
      if (field(m, "takeover") != "") n = 0
      n++; act[n] = id; mk[n] = m
    }
    END {
      if (n < 1) { print "holder none"; exit }
      m = mk[1]; self = (field(m, "machine") == me && field(m, "who") == who) ? "yes" : "no"
      print "holder id=" act[1] " machine=" field(m, "machine") " who=" field(m, "who") \
        " branch=" field(m, "branch") " at=" field(m, "at") " previous=" field(m, "previous") \
        " self=" self
    }'
}

# claim_lines <show.json> → the claim records of every comment whose last non-empty line is an entry.
claim_lines() {
  jq -r --arg re "$EXTRACT_RE" '.comments[]
    | ((.body // "") | gsub("\r"; "") | split("\n") | map(select(test("\\S"))) | last // ""
       | sub("^\\s+"; "") | sub("\\s+$"; "")) as $l
    | select($l | test($re)) | "\(.created)\t\(.id)\t\($l)"' "$1" \
    || die 4 "comments of issue #$KEY are not parseable"
}

# ---- refs ---------------------------------------------------------------------------------------

op_refs() {
  local rc=0
  git ls-remote --heads origin > "$TMP/heads" 2> "$TMP/heads.err" || rc=$?
  [ "$rc" = 0 ] || { show_err "$TMP/heads.err"; die 4 "remote branches cannot be listed — recoverable"; }
  awk -v k="$KEY" '{ b = $2; sub(/^refs\/heads\//, "", b); if (b ~ ("^[^/]+/" k "-")) print "branch " b }' \
    "$TMP/heads"
  local gh_layer=0 url
  if [ -n "${TEAM_TRACKER_TEAMS:-}" ]; then
    [ "${TEAM_PR_PROVIDER:-}" != github ] || gh_layer=1
  else
    url="$(git remote get-url origin 2>/dev/null || true)"
    case "$url" in https://github.com/*|https://*@github.com/*|git@github.com:*|ssh://git@github.com/*) gh_layer=1 ;; esac
  fi
  if [ "$gh_layer" = 0 ]; then
    echo "pr-check skipped (no GitHub PR layer — the branch check stands alone)"
    return 0
  fi
  # team-pr.sh ships with the team harness only; a project without it keeps the branch check.
  if [ ! -f "$HERE/team-pr.sh" ]; then
    echo "pr-check skipped (team-pr.sh not installed — the branch check stands alone)"
    return 0
  fi
  rc=0
  bash "$HERE/team-pr.sh" prs "$KEY" > "$TMP/prs.json" 2> "$TMP/prs.err" || rc=$?
  [ "$rc" = 0 ] || { show_err "$TMP/prs.err"; die 4 "open PRs for $KEY cannot be listed — recoverable"; }
  jq -r '.[] | select(.state == "OPEN" and (.relation == "closes" or .relation == "branch"))
    | "pr \(.url) \(.relation)"' "$TMP/prs.json" || die 4 "the PR list for $KEY is not parseable"
}

# ---- check --------------------------------------------------------------------------------------

# do_check → exits 3 on a refusal; on a pass sets PREV (raw status or none/no-project), OWN_ID,
# OWN_PREV (encoded, from the own claim's marker), FOREIGN_ID, OVERRODE and prints nothing.
PREV=""; OWN_ID=""; OWN_PREV=""; FOREIGN_ID=""; OVERRODE=0
do_check() {
  local rc=0 state status="" started="" delivered="" closed="" status_f="" held_f="" h b
  local findings="" branch_hit=0 kind ref rel
  trk show "$KEY" --out "$TMP/show.json" > "$TMP/show.out" 2> "$TMP/show.err" || rc=$?
  if [ "$rc" = 1 ]; then show_err "$TMP/show.err"; die 1 "issue #$KEY cannot be read"; fi
  [ "$rc" = 0 ] || { show_err "$TMP/show.err"; die 4 "issue #$KEY and its comments cannot be read — recoverable"; }
  state="$(jq -r '.state // ""' "$TMP/show.json")"
  [ "$state" != CLOSED ] || closed="issue is CLOSED"

  if [ -n "$TEAM_GH_PROJECT_ID" ]; then
    rc=0
    trk item-status "$KEY" --out "$TMP/is.json" > "$TMP/is.out" 2> "$TMP/is.err" || rc=$?
    [ "$rc" = 0 ] || { show_err "$TMP/is.err"; die 4 "the board status of #$KEY cannot be read — recoverable"; }
    status="$(jq -r '.status // ""' "$TMP/is.json")"
    started="$(jq -r '.started // ""' "$TMP/is.json")"
    delivered="$(jq -r '.delivered // ""' "$TMP/is.json")"
    PREV="${status:-none}"
    if [ -n "$status" ] && { [ "$status" = "$started" ] || [ "$status" = "$delivered" ]; }; then
      status_f="status $status"
    fi
  else
    PREV=no-project
  fi

  claim_lines "$TMP/show.json" > "$TMP/lines.tsv"
  h="$(holder_judge "$TMP/lines.tsv" "$WHO")"
  if [ "$h" != "holder none" ]; then
    if [ "$(kv "$h" self)" = yes ]; then
      OWN_ID="$(kv "$h" id)"; OWN_PREV="$(kv "$h" previous)"
    else
      FOREIGN_ID="$(kv "$h" id)"
      held_f="held by $(kv "$h" who) on $(kv "$h" machine) since $(kv "$h" at) (claim $FOREIGN_ID)"
    fi
  fi

  op_refs > "$TMP/refs.txt"

  for b in "$closed" "$status_f" "$held_f"; do [ -z "$b" ] || findings="${findings:+$findings; }$b"; done
  while read -r kind ref rel; do
    case "$kind" in
      pr)     findings="${findings:+$findings; }PR $ref" ;;
      branch) findings="${findings:+$findings; }branch $ref"
              [ "$ref" != "$BRANCH" ] || branch_hit=1 ;;
      *)      echo "note: $kind $ref $rel" ;;
    esac
  done < "$TMP/refs.txt"

  # A closed ticket refuses whoever holds it, --takeover included.
  [ -z "$closed" ] || { echo "refused: #$KEY — $findings"; exit 3; }
  if [ -n "$OWN_ID" ]; then
    local own_prev
    own_prev="$(uri_dec "$OWN_PREV")"
    if [ "$PREV" != no-project ] && [ "$PREV" != "$own_prev" ] && [ "$status" != "$started" ]; then
      echo "refused: #$KEY — held by this machine/team but the status moved on to $status"
      exit 3
    fi
    [ -z "$findings" ] || echo "note: $findings"
    return 0
  fi
  if [ "$TAKEOVER" = 1 ]; then
    if [ "$branch_hit" = 1 ]; then
      echo "refused: #$KEY — --takeover still refuses the remote branch $BRANCH"; exit 3
    fi
    [ -z "$findings" ] || OVERRODE=1
    return 0
  fi
  [ -z "$findings" ] || { echo "refused: #$KEY — $findings"; exit 3; }
}

op_check() {
  do_check
  if [ -n "$OWN_ID" ]; then echo "held id=$OWN_ID previous=$OWN_PREV"
  else echo "free previous=$(uri_enc "$PREV")"; fi
}

# ---- claim / release ----------------------------------------------------------------------------

# post_release <id> <reason> — the release comment only; returns the comment's rc.
post_release() {
  local rc=0
  FORMAT=github body_release "$1" "$2" > "$TMP/release.md"
  trk comment "$KEY" --marker "$(tail -n 1 "$TMP/release.md")" --body-file "$TMP/release.md" \
    > "$TMP/release.out" 2> "$TMP/release.err" || rc=$?
  [ "$rc" = 0 ] || show_err "$TMP/release.err"
  return "$rc"
}

# release_or_say <id> <reason> → " — release posted" | " — the release comment failed too"
release_or_say() {
  if post_release "$1" "$2"; then printf ' — release posted'
  else printf ' — the release comment failed too: release %s by hand' "$1"; fi
}

op_claim() {
  local id prev rc=0 sup="" h result
  do_check
  if [ -n "$OWN_ID" ]; then
    id="$OWN_ID"; prev="$OWN_PREV"; result=held
  else
    id="$(new_id)"; prev="$(uri_enc "$PREV")"; result=claimed
    if [ "$OVERRODE" = 1 ]; then sup="${FOREIGN_ID:-status}"; fi
    FORMAT=github body_claim "$id" "$PREV" "$sup" > "$TMP/claim.md"
    trk comment "$KEY" --marker "$(tail -n 1 "$TMP/claim.md")" --body-file "$TMP/claim.md" \
      > "$TMP/claim.out" 2> "$TMP/claim.err" || rc=$?
    if [ "$rc" != 0 ]; then
      show_err "$TMP/claim.err"
      die 4 "claim comment not posted$(release_or_say "$id" post-failed)"
    fi
    # Confirm: the first unreleased claim wins — read every comment again.
    rc=0
    trk show "$KEY" --out "$TMP/show2.json" > "$TMP/show2.out" 2> "$TMP/show2.err" || rc=$?
    if [ "$rc" != 0 ]; then
      show_err "$TMP/show2.err"
      die 4 "the claim cannot be confirmed$(release_or_say "$id" not-visible)"
    fi
    claim_lines "$TMP/show2.json" > "$TMP/lines2.tsv"
    h="$(holder_judge "$TMP/lines2.tsv" "$WHO")"
    if [ "$(kv "$h" id)" != "$id" ]; then
      if [ "$h" = "holder none" ] || ! grep -qF "id=$id " "$TMP/lines2.tsv"; then
        die 4 "claim $id is not visible after posting$(release_or_say "$id" not-visible)"
      fi
      # The loser never writes the status.
      echo "refused: #$KEY — lost the race: held by $(kv "$h" who) on $(kv "$h" machine) (claim $(kv "$h" id))$(release_or_say "$id" lost-race)"
      exit 3
    fi
  fi
  rc=0
  trk set-status "$KEY" started > "$TMP/status.out" 2> "$TMP/status.err" || rc=$?
  if [ "$rc" != 0 ]; then
    show_err "$TMP/status.err"
    if grep -q 'not in project' "$TMP/status.err"; then
      echo "hint: add it to the board first — bash .claude/lib/team-tracker.sh project-add $KEY" >&2
    fi
    die 4 "the started status could not be set$(release_or_say "$id" status-failed)"
  fi
  echo "$result id=$id previous=$prev"
  echo "status: $(tail -n 1 "$TMP/status.out")"
}

op_release() {
  local id="$1" reason="$2" rc=0 m h prev status started why="" done_as=""
  trk show "$KEY" --out "$TMP/show.json" > "$TMP/show.out" 2> "$TMP/show.err" || rc=$?
  if [ "$rc" = 1 ]; then show_err "$TMP/show.err"; die 1 "issue #$KEY cannot be read"; fi
  [ "$rc" = 0 ] || { show_err "$TMP/show.err"; die 4 "issue #$KEY and its comments cannot be read — recoverable"; }
  claim_lines "$TMP/show.json" > "$TMP/lines.tsv"
  m="$(awk -F "$TAB" -v id="$id" '{ p = index($0, "team:claim v1 id=" id " ") } p { print substr($0, p) }' \
    "$TMP/lines.tsv" | tail -n 1)"
  m="${m% -->}"
  if [ -z "$m" ]; then
    why="claim $id is not on the ticket"
  else
    h="$(holder_judge "$TMP/lines.tsv" "$WHO")"
    prev="$(kv "$m" previous)"
    if [ "$(kv "$h" id)" != "$id" ]; then
      why="claim $id is no longer the holder"
    elif [ "$prev" = no-project ] || [ -z "$TEAM_GH_PROJECT_ID" ]; then
      why="no board status to restore"
    else
      rc=0
      trk item-status "$KEY" --out "$TMP/is.json" > "$TMP/is.out" 2> "$TMP/is.err" || rc=$?
      [ "$rc" = 0 ] || { show_err "$TMP/is.err"; die 4 "the board status of #$KEY cannot be read — nothing posted, rerun"; }
      status="$(jq -r '.status // ""' "$TMP/is.json")"
      started="$(jq -r '.started // ""' "$TMP/is.json")"
      if [ "$status" != "$started" ]; then
        why="status is ${status:-none}, not $started"
      else
        prev="$(uri_dec "$prev")"; rc=0
        if [ "$prev" = none ]; then
          trk set-status "$KEY" --clear > "$TMP/st.out" 2> "$TMP/st.err" || rc=$?
        else
          trk set-status "$KEY" --name "$prev" > "$TMP/st.out" 2> "$TMP/st.err" || rc=$?
        fi
        [ "$rc" = 0 ] || { show_err "$TMP/st.err"; die 4 "the status could not be restored to $prev — nothing posted, rerun"; }
        done_as="restored $prev"
      fi
    fi
  fi
  [ -n "$done_as" ] || echo "note: $why — status not restored"
  post_release "$id" "$reason" || die 4 "the release comment of claim $id was not posted — rerun"
  echo "released id=$id status: ${done_as:-not restored — $why}"
}

# ---- dispatch -----------------------------------------------------------------------------------

op="${1:-}"; [ $# -eq 0 ] || shift
case "$op" in
  check|claim|release|refs|body|holder) ;;
  *) die 2 "usage: team-claim.sh check|claim|release|refs|body|holder …" ;;
esac

case "$op" in
  check|claim|release)
    if [ "$TEAM_TRACKER" = none ]; then
      echo "skipped (tracker=none) — no shared signal; the start continues as before"
      exit 0
    fi
    [ "$TEAM_TRACKER" != jira ] \
      || die 2 "jira runs the claim through the session's MCP — use refs, body and holder" ;;
esac

WHO=""; BRANCH=""; TAKEOVER=0; ID=""; REASON=""; LINES=""; PREVIOUS=""
FORMAT=github; SUPERSEDED=""; POS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --who)        WHO="${2:-}"; shift 2 || die 2 "--who needs a name" ;;
    --branch)     BRANCH="${2:-}"; shift 2 || die 2 "--branch needs a branch" ;;
    --takeover)   TAKEOVER=1; shift ;;
    --id)         ID="${2:-}"; shift 2 || die 2 "--id needs a claim id" ;;
    --reason)     REASON="${2:-}"; shift 2 || die 2 "--reason needs a word" ;;
    --lines)      LINES="${2:-}"; shift 2 || die 2 "--lines needs a file" ;;
    --previous)   PREVIOUS="${2:-}"; shift 2 || die 2 "--previous needs a status" ;;
    --format)     FORMAT="${2:-}"; shift 2 || die 2 "--format needs github|jira" ;;
    --superseded) SUPERSEDED="${2:-}"; shift 2 || die 2 "--superseded needs an id" ;;
    -*)           die 2 "unknown option '$1'" ;;
    *)            POS+=("$1"); shift ;;
  esac
done
set -- ${POS[@]+"${POS[@]}"}

case "$FORMAT" in github|jira) ;; *) die 2 "--format must be github|jira" ;; esac
[ -z "$WHO" ] || [[ "$WHO" =~ ^[a-z0-9-]+$ ]] || die 2 "--who '$WHO' must match ^[a-z0-9-]+$"
[ -z "$BRANCH" ] || [[ "$BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]] || die 2 "--branch '$BRANCH' has characters outside [A-Za-z0-9._/-]"
[ -z "$REASON" ] || [[ "$REASON" =~ ^[a-z-]+$ ]] || die 2 "--reason '$REASON' must match ^[a-z-]+$"
[ -z "$ID" ] || [[ "$ID" =~ ^[A-Za-z0-9.-]+$ ]] || die 2 "--id '$ID' is not a claim id"
[ -z "$SUPERSEDED" ] || [[ "$SUPERSEDED" =~ ^[A-Za-z0-9.-]+$ ]] || die 2 "--superseded '$SUPERSEDED' is not a claim id"

KEY=""
need_key() {
  [ $# -eq 1 ] || die 2 "$op needs one ticket key"
  KEY="${1#\#}"
  [[ "$KEY" =~ $TEAM_KEY_REGEX ]] || die 1 "ticket key '$1' must match $TEAM_KEY_REGEX"
}

case "$op" in
  check)
    need_key "$@"
    [ -n "$WHO" ] || die 2 "check needs --who <team|solo>"
    op_check ;;
  claim)
    need_key "$@"
    [ -n "$WHO" ] || die 2 "claim needs --who <team|solo>"
    [ -n "$BRANCH" ] || die 2 "claim needs --branch <branch>"
    op_claim ;;
  release)
    need_key "$@"
    [ -n "$ID" ] || die 2 "release needs --id <claim id>"
    [ -n "$REASON" ] || die 2 "release needs --reason <word>"
    op_release "$ID" "$REASON" ;;
  refs)
    need_key "$@"
    op_refs ;;
  body)
    [ $# -eq 1 ] || die 2 "usage: body claim|release …"
    case "$1" in
      claim)
        [ -n "$WHO" ] || die 2 "body claim needs --who"
        [ -n "$BRANCH" ] || die 2 "body claim needs --branch"
        [ -n "$PREVIOUS" ] || die 2 "body claim needs --previous <status|none|no-project>"
        body_claim "${ID:-$(new_id)}" "$PREVIOUS" "$SUPERSEDED" ;;
      release)
        [ -n "$ID" ] || die 2 "body release needs --id"
        [ -n "$REASON" ] || die 2 "body release needs --reason"
        body_release "$ID" "$REASON" ;;
      *) die 2 "usage: body claim|release …" ;;
    esac ;;
  holder)
    [ $# -eq 0 ] || die 2 "holder takes no ticket key"
    [ -n "$LINES" ] || die 2 "holder needs --lines <file>"
    holder_judge "$LINES" "$WHO" ;;
esac
