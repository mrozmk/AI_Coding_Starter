#!/usr/bin/env bash
# The escalation adapter of the operator kit: carries a team question from team-escalate.sh to the
# Advisor (and, under advisor: pair, the Reviewer) over agent-mail, and the reply back.
#
# Usage (from the main checkout, as escalation.local.json renders it):
#   escalate.sh send|wait|peek|opinion <payload> <team> <role> <qid> <thread> <seq>
#   send     mails the protocol + payload to the Advisor (+ Reviewer), --awaiting the Advisor,
#            dedup key <thread>-<seq>; the CLI's `SENT id=<n> …` is the last stdout line
#   wait     polls this role's inbox (and TEAM_MAIL_LEGACY's) for the Advisor's reply on the thread,
#            stages it to <dir of payload>/<qid>.reply-<id>.md (operator-ref verified), acks, prints
#   peek     one pass of wait: a reply as wait prints it, or exactly one line EMPTY (exit 0)
#   opinion  read-only: the Reviewer's newest message on the thread, staged to
#            <dir>/<qid>.opinion-<id>.md and printed; nothing when none; never acks
#            (refused, exit 2, under advisor: solo — there is no Reviewer)
# Every address comes from the channel config (team_channel_load): the box and tool through
# team-mail.sh, the recipient names from the roles + mail_suffix; SELF is TEAM_SESSION_ROLE
# (default Supervisor, the single-routing receiver). While TEAM_MAIL_LEGACY (default Supervisor)
# differs from SELF, wait also polls that inbox, so a reply on a thread opened before a routing
# switch is not lost. Exit: 0 ok · 1 error · 2 usage / refused.
set -uo pipefail
op="${1:-}" qfile="${2:-}" team="${3:-}" role="${4:-}" qid="${5:-}" thread="${6:-}" seq="${7:-}"
die() { echo "escalate.sh: $*" >&2; exit 1; }
case "$op" in send|wait|peek|opinion) ;; *)
  echo "usage: escalate.sh send|wait|peek|opinion <payload> <team> <role> <qid> <thread> <seq>" >&2
  exit 2 ;;
esac
[ -n "$qfile" ] && [ -n "$qid" ] && [ -n "$thread" ] && [ -n "$seq" ] || {
  echo "escalate.sh: $op needs <payload> <team> <role> <qid> <thread> <seq>" >&2; exit 2; }

root="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside the main checkout"
. "$root/.claude/lib/team-channel.sh" || die "no team-channel.sh in $root"
err="$(team_channel_load "$root" 2>&1)" || die "channel: ${err#error: team channel: }"
team_channel_load "$root"
SELF="$(team_channel_role "${TEAM_SESSION_ROLE:-Supervisor}")" || exit 2
LEGACY="$(team_channel_role "${TEAM_MAIL_LEGACY:-Supervisor}")" || exit 2
ADV="$TEAM_CHANNEL_ADVISOR_NAME" REV="$TEAM_CHANNEL_REVIEWER"
C="$(dirname "$TEAM_CHANNEL_BOX")" D="$TEAM_CHANNEL_DECISIONS"

bounded() { perl -e 'alarm shift; exec @ARGV' 60 "$@"; }
mail() { bounded bash "$root/.claude/lib/team-mail.sh" "$TEAM_CHANNEL_KEY" "$@"; }

protocol() {
  cat <<EOF
Team escalation from $SELF: team $team, role $role, question $qid, thread $thread, seq $seq.
$ADV: $( [ "$TEAM_CHANNEL_ADVISOR" = pair ] && echo "consult $REV and answer" || echo "answer (advisor solo — no Reviewer; say reviewer: none)" ) on thread $thread. When the decision belongs to the Operator (tier 3), ask the Operator yourself.
Reply format — the first lines, then a blank line, then the text for the team:
- "status: answer"; optionally "author: <names>"; "decided-by: analysts", or for an Operator decision
  "decided-by: operator" + "operator-ref: <note> sha256:<prefix, at least 8 hex>". The note lies in the
  channel's decisions/ and contains the exact line "thread: $thread" and a line "Operator decision: <the Operator's words>".
- "status: pending-operator" (optionally "eta: <when>") — only once the Operator was really asked;
  it unblocks nothing, the team keeps waiting.
- "status: withdrawn" — the question is no longer relevant.
Analyst disagreement: both positions + a recommendation go to the Operator. No reply and no error is ever consent.
"reping-kind: transport" in a request header = a repeated delivery, not a new decision request.
Contract: .agents/reference/team-advisor.md (main checkout).
EOF
}

verify_ref() {  # verify_ref <reply file> — 0 when operator-ref names a matching decision note
  local ref note prefix real dreal sum
  ref="$(awk '/^$/{exit} /^operator-ref: /{print substr($0, 15); exit}' "$1")"
  note="${ref% sha256:*}"; prefix="${ref##* sha256:}"
  [ -n "$ref" ] && [ "$note" != "$ref" ] || return 1
  [[ "$prefix" =~ ^[0-9a-f]{8,}$ ]] || return 1
  case "$note" in /*) ;; *) if [ -e "$C/$note" ]; then note="$C/$note"; else note="$D/$note"; fi ;; esac
  real="$(cd "$(dirname "$note")" 2>/dev/null && pwd -P)/$(basename "$note")" || return 1
  dreal="$(cd "$D" 2>/dev/null && pwd -P)" || return 1
  case "$real" in "$dreal"/*) ;; *) return 1 ;; esac
  [ -f "$real" ] || return 1
  sum="$(shasum -a 256 "$real" | cut -d' ' -f1)"
  case "$sum" in "$prefix"*) ;; *) return 1 ;; esac
  grep -qxF "thread: $thread" "$real" && grep -q '^Operator decision: .' "$real"
}

pick() {  # pick <sender> <json files…> → "<id>\n<body>" of the newest message from <sender> on the thread
  python3 -I -c '
import json, sys
t, s = sys.argv[1], sys.argv[2]
m = [x for f in sys.argv[3:] for x in json.load(open(f)) if x["thread"] == t and x["sender"] == s]
if m:
    x = max(m, key=lambda x: int(x["id"])); print(x["id"]); print(x["body"])
' "$thread" "$@"
}

poll_once() {  # one pass over SELF's (and the legacy) inbox: an Advisor reply → printed, exit 0; none → rc 1
  local dir boxes box js out id tmp final
  dir="$(dirname "$qfile")"
  boxes="$SELF"; [ "$LEGACY" = "$SELF" ] || boxes="$SELF $LEGACY"
  for box in $boxes; do
    js="$(mktemp)" || die "mktemp failed"
    mail inbox --for "$box" --unread --json --limit 0 > "$js" || { rm -f "$js"; die "inbox failed"; }
    out="$(pick "$ADV" "$js")" || { rm -f "$js"; die "inbox JSON unreadable"; }
    rm -f "$js"
    [ -n "$out" ] || continue
    id="$(printf '%s\n' "$out" | head -n 1)"
    tmp="$dir/$qid.reply-$id.md.tmp"; final="$dir/$qid.reply-$id.md"
    { echo "mail-id: $id"; printf '%s\n' "$out" | tail -n +2; } > "$tmp" || die "cannot stage the reply"
    if awk '/^$/{exit} /^decided-by: operator$/{f = 1} END{exit !f}' "$tmp" && ! verify_ref "$tmp"; then
      awk '!d && /^status: /{print "status: unverified-operator-ref"; d = 1; next} {print}' "$tmp" > "$tmp.v" \
        && mv "$tmp.v" "$tmp" || die "cannot mark the reply unverified"
    fi
    mv "$tmp" "$final" || die "cannot publish the staged reply"
    mail ack "$id" --by "$box" >/dev/null || die "ack failed"
    cat "$final"
    exit 0
  done
  return 1
}

case "$op" in
  send)
    tmp="$(mktemp)" || die "mktemp failed"
    { protocol; printf '\n--- payload ---\n'; cat "$qfile"; } > "$tmp" || { rm -f "$tmp"; die "cannot read $qfile"; }
    to=(--to "$ADV"); [ "$TEAM_CHANNEL_ADVISOR" != pair ] || to+=(--to "$REV")
    mail send --from "$SELF" "${to[@]}" --kind turn --awaiting "$ADV" \
      --thread "$thread" --dedup-key "$thread-$seq" --body-file "$tmp"
    rc=$?; rm -f "$tmp"
    [ "$rc" = 0 ] || die "send failed (rc $rc)" ;;
  wait) while :; do poll_once; sleep "${TEAM_ESCALATE_ADAPTER_POLL:-20}"; done ;;
  peek) poll_once; echo EMPTY ;;
  opinion)
    [ "$TEAM_CHANNEL_ADVISOR" = pair ] || { echo "escalate.sh: no Reviewer (advisor solo)" >&2; exit 2; }
    # Never acks: the Reviewer's mail to the Advisor is the Advisor's to handle.
    dir="$(dirname "$qfile")"
    js="$(mktemp -d)" || die "mktemp failed"
    boxes="$ADV"; [ "$SELF" = "$ADV" ] || boxes="$ADV $SELF"
    for box in $boxes; do
      mail inbox --for "$box" --json --limit 0 > "$js/$box.json" || { rm -rf "$js"; die "inbox failed"; }
    done
    out="$(pick "$REV" "$js"/*.json)"; rc=$?; rm -rf "$js"
    [ "$rc" = 0 ] || die "inbox JSON unreadable"
    [ -n "$out" ] || exit 0
    id="$(printf '%s\n' "$out" | head -n 1)"
    tmp="$dir/$qid.opinion-$id.md.tmp"; final="$dir/$qid.opinion-$id.md"
    { echo "mail-id: $id"; printf '%s\n' "$out" | tail -n +2; } > "$tmp" && mv "$tmp" "$final" \
      || die "cannot stage the opinion"
    cat "$final" ;;
esac
