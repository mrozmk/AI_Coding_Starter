#!/usr/bin/env bash
# File inbox of the supervision layer: one directory per address in the main checkout.
# Usage: bash .claude/lib/team-inbox.sh [--main <dir>] write <address> <event> --from <x>
#          --ticket <k> --run <r> [--ref <path>] [--message <one line>]
#        bash .claude/lib/team-inbox.sh [--main <dir>] list <address> | done <address> <file>
#   <main>/.agents/team/inbox/<address>/{tmp,new,done}/; write builds
#   <UTC %Y%m%dT%H%M%SZ>-<from>-<event>.md in tmp/ and renames it into new/, then rings the
#   Supervisor's registered socket (a failed ring is ignored: the file is the truth). The
#   Supervisor address takes only accepted|closed|collision|session_dead; a team address any event.
#   A caller in a team clone passes --main (teamlead.json main_root), never its own git root.
#   e.g. bash .claude/lib/team-inbox.sh --main ~/src/app write Supervisor accepted --from alfa \
#          --ticket 7 --run alfa-20261114-090000 --ref runs/alfa-20261114-090000/acceptance-brief.md
# Contract: .agents/reference/team-lead.md §3
set -euo pipefail

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
LIB="$(cd "$(dirname "$0")" && pwd)"
MAIN=""
if [ "${1:-}" = --main ]; then [ $# -ge 2 ] || usage; MAIN="$2"; shift 2; fi
[ $# -ge 2 ] || usage
cmd="$1" addr="$2"; shift 2
[[ "$addr" =~ ^[A-Za-z0-9-]+$ ]] || { echo "error: address '$addr' must match [A-Za-z0-9-]+" >&2; exit 2; }
if [ -z "$MAIN" ]; then
  MAIN="$(git rev-parse --show-toplevel)"
  [ ! -f "$MAIN/.agents/team/team.json" ] \
    || { echo "error: team clone — pass --main <main checkout>" >&2; exit 2; }
fi
[ -d "$MAIN/.agents" ] || { echo "error: $MAIN is not a checkout with .agents/" >&2; exit 2; }
D="$MAIN/.agents/team/inbox/$addr"

write() {
  local event="$1" from="" ticket="" run="" ref="" msg="" stem f n=1
  shift
  while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || usage
    case "$1" in
      --from) from="$2" ;; --ticket) ticket="$2" ;; --run) run="$2" ;; --ref) ref="$2" ;;
      --message) msg="${2//$'\n'/ }" ;;
      *) usage ;;
    esac
    shift 2
  done
  [[ "$event" =~ ^[a-z][a-z_-]*$ ]] || { echo "error: event '$event' must match [a-z_-]+" >&2; exit 2; }
  [ -n "$from" ] && [[ "$from" =~ ^[A-Za-z0-9-]+$ ]] || { echo "error: --from is required" >&2; exit 2; }
  if [ "$addr" = Supervisor ]; then
    case "$event" in accepted|closed|collision|session_dead) ;;
      *) echo "error: Supervisor takes accepted|closed|collision|session_dead, not $event" >&2; exit 2 ;;
    esac
  fi
  mkdir -p "$D/tmp" "$D/new" "$D/done"
  stem="$(date -u +%Y%m%dT%H%M%SZ)-$from-$event"; f="$stem"
  while [ -e "$D/new/$f.md" ] || [ -e "$D/done/$f.md" ] || [ -e "$D/tmp/$f.md" ]; do
    n=$((n + 1)); f="$stem-$n"
  done
  { printf -- '---\nid: %s\nfrom: %s\nto: %s\nevent: %s\nticket: %s\nrun: %s\nref: %s\n---\n' \
      "$f" "$from" "$addr" "$event" "$ticket" "$run" "$ref"
    printf '%s from %s: ticket %s, run %s%s\n' "$event" "$from" "${ticket:-?}" "${run:-?}" \
      "${ref:+ — $ref}"
    [ -z "$msg" ] || printf '%s\n' "$msg"; } > "$D/tmp/$f.md"
  mv "$D/tmp/$f.md" "$D/new/$f.md"
  echo "$D/new/$f.md"
  local reg="$MAIN/.agents/team/watch/receivers/Supervisor.json"
  if [ "$addr" = Supervisor ] && [ -f "$reg" ]; then
    printf 'inbox: %s %s %s — %s\n' "$event" "$from" "${ticket:-?}" "$D/new/$f.md" \
      | python3 -I "$LIB/team-watch-send.py" "$reg" >/dev/null 2>&1 || true
  fi
}

case "$cmd" in
  write) [ $# -ge 1 ] || usage; write "$@" ;;
  list) [ $# -eq 0 ] || usage; ls -1 "$D/new" 2>/dev/null | sort | sed "s|^|$D/new/|" || true ;;
  done)
    [ $# -eq 1 ] || usage
    f="$(basename "$1")"; [ -f "$D/new/$f" ] || { echo "error: $f is not in $D/new" >&2; exit 1; }
    mkdir -p "$D/done"; mv "$D/new/$f" "$D/done/$f"; echo "$D/done/$f" ;;
  *) usage ;;
esac
