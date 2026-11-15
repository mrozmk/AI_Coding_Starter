#!/usr/bin/env bash
# The Supervisor's only path to the Operator: an operator record, then one notification.
# Usage: bash .claude/lib/operator-record.sh failure|release --summary "<line>" [--team <t>] [--ref <file>]
#        bash .claude/lib/operator-record.sh close <id>
#   failure — a failure the Supervisor tried and could not repair (a stage or TeamLead that will not
#   restart, a broken main it cannot fix); release — a release step that waits for the Operator.
#   Writes .agents/team/operator/<UTC>-<event>-<4 hex>.md in the main checkout (frontmatter id,
#   event, status: open, team, ref, created_at; body = the summary) and calls notify.sh
#   unrepaired_failure|release with --key <record id> and --answer Supervisor. An open record with
#   the same event, team and summary is reused (printed, nothing sent) until it is closed; after
#   `close` the same text is a new record and a new event. The summary is one line, control
#   characters stripped, cut to 200 characters; --ref must be a file inside the main checkout.
#   Prints `recorded <id>`, `open <id> (coalesced)` or `closed <id>`.
# Exit: 0 ok · 1 not the main checkout / no such record · 2 usage.
#   e.g. bash .claude/lib/operator-record.sh failure --team alfa --summary "alfa-lead will not restart"
# Spec: notification model (epic E2) §3. Bash 3.2 compatible; needs jq.
set -euo pipefail
umask 077

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
die() { echo "error: $2" >&2; exit "$1"; }
[ $# -ge 1 ] || usage
LIB="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die 1 "not in a git checkout"
[ ! -f "$ROOT/.agents/team/team.json" ] || die 1 "run from the main checkout, not a team clone"
DIR="$ROOT/.agents/team/operator"
fm() { sed -n '/^---$/,/^---$/p' "$1" | sed -n "s/^$2: *//p" | head -n 1; }

CMD="$1"; shift
case "$CMD" in
  close)
    [ $# -eq 1 ] && [[ "$1" =~ ^[0-9TZ]+-(failure|release)-[0-9a-f]{4}$ ]] || usage
    f="$DIR/$1.md"; [ -f "$f" ] || die 1 "no operator record $1"
    if [ "$(fm "$f" status)" != closed ]; then
      awk -v t="$(date -u +%Y-%m-%dT%H:%M:%SZ)" '/^---$/ { n++; if (n == 2) print "closed_at: " t }
        n == 1 && /^status: / { print "status: closed"; next } { print }' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    fi
    echo "closed $1"; exit 0 ;;
  failure) EVENT=unrepaired_failure ;;
  release) EVENT=release ;;
  *) usage ;;
esac

SUMMARY=""; TEAM=""; REF=""
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || usage
  case "$1" in --summary) SUMMARY="$2" ;; --team) TEAM="$2" ;; --ref) REF="$2" ;; *) usage ;; esac
  shift 2
done
SUMMARY="$(jq -rn --arg s "$SUMMARY" '$s | gsub("[\u0000-\u001f\u007f]+"; " ") | sub("^ +"; "") | sub(" +$"; "") | .[0:200]')"
[ -n "$SUMMARY" ] || die 2 "--summary is required (one line)"
[ -z "$TEAM" ] || [[ "$TEAM" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die 2 "--team '$TEAM' is not a team name"
if [ -n "$REF" ]; then
  r="$(cd "$(dirname "$REF")" 2>/dev/null && pwd -P)/$(basename "$REF")" || r=""
  case "$r" in "$(cd "$ROOT" && pwd -P)"/*) [ -f "$r" ] || r="" ;; *) r="" ;; esac
  [ -n "$r" ] || die 2 "--ref must be a file inside the main checkout"
  REF="$r"
fi

mkdir -p "$DIR" && chmod 700 "$DIR"
# Coalesce: one open record per event, team and summary.
for f in "$DIR"/*-"$CMD"-*.md; do
  [ -f "$f" ] && [ "$(fm "$f" status)" = open ] && [ "$(fm "$f" team)" = "$TEAM" ] \
    && [ "$(sed '1,/^---$/d' "$f" | head -n 1)" = "$SUMMARY" ] || continue
  echo "open $(basename "$f" .md) (coalesced)"; exit 0
done

ID="$(date -u +%Y%m%dT%H%M%SZ)-$CMD-$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')"
{ echo "---"; echo "id: $ID"; echo "event: $CMD"; echo "status: open"; echo "team: $TEAM"
  echo "ref: $REF"; echo "created_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"; echo "---"; echo "$SUMMARY"
} > "$DIR/.$ID.tmp"
mv "$DIR/.$ID.tmp" "$DIR/$ID.md"
echo "recorded $ID"

P="$(bash "$LIB/team-channel.sh" get tmux_prefix 2>/dev/null || true)"
[ -n "$P" ] || P="$(basename "$ROOT" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9._-\n' '-')"
S="$(bash "$LIB/team-channel.sh" name Supervisor 2>/dev/null || true)"; S="${S:-$P-supervisor}"
args=(--project "$P" --summary "$SUMMARY" --answer Supervisor --hint "tmux attach -t $S" --key "$ID"
  --source operator-record)
[ -z "$TEAM" ] || args+=(--team "$TEAM")
[ -z "$REF" ] || args+=(--ref "$REF")
bash "$LIB/notify.sh" "$EVENT" "${args[@]}" >/dev/null || echo "warn: notify.sh failed for $ID — the record stands" >&2
