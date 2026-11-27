#!/usr/bin/env bash
# File inbox of the supervision layer: one directory per address in the main checkout.
# Usage: bash .claude/lib/team-inbox.sh [--main <dir>] write <address> <event> --from <x>
#          --ticket <k> --run <r> [--ref <path>] [--message <one line>]
#        bash .claude/lib/team-inbox.sh [--main <dir>] list <address> | done <address> <file>
#        bash .claude/lib/team-inbox.sh [--main <dir>] close-run <address> <run>
#   close-run: a run ended (finalize, the runner's close_run) — its messages (frontmatter `run:`)
#   move from new/ to done/, so the prompt hook and the team's next lead stop counting them.
#        bash .claude/lib/team-inbox.sh [--main <dir>] prune [--days N]
#   prune: housekeeping (/maintain:cleanup-workflow) — deletes done/ messages of every address
#   whose mtime is older than N days (default 30); tmp/ and new/ are never touched.
#   <main>/.agents/team/inbox/<address>/{tmp,new,done}/; write builds
#   <UTC %Y%m%dT%H%M%SZ>-<from>-<event>[-n].md in tmp/, links it into new/, then rings the address's
#   session through session-host.sh send (rc on stderr `ring: <rc>`, never the exit: the file is
#   the truth). Supervisor: a team sender only accepted|closed|collision|session_dead|delegated (a
#   decision the Operator's mandate hands to the Supervisor — team-mandate.sh), decision (a lead's
#   decision that waits for the Operator: the Supervisor shows it as a card) and clearance (#323: a
#   request team-clearance.sh files for the Supervisor), a role or
#   adhoc-* sender also message|advice|clearance, an unknown sender refused. Role/team address: any event.
#   e.g. bash .claude/lib/team-inbox.sh --main ~/src/app write Supervisor accepted --from alfa \
#          --ticket 7 --run alfa-20261114-090000 --ref runs/alfa-20261114-090000/acceptance-brief.md
# Contract: .agents/reference/team-lead.md §3
set -euo pipefail

usage() { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
LIB="$(cd "$(dirname "$0")" && pwd)"
MAIN=""
if [ "${1:-}" = --main ]; then [ $# -ge 2 ] || usage; MAIN="$2"; shift 2; fi
[ $# -ge 1 ] || usage
cmd="$1" addr=""; shift
if [ "$cmd" != prune ]; then
  [ $# -ge 1 ] || usage
  addr="$1"; shift
  [[ "$addr" =~ ^[A-Za-z0-9-]+$ ]] || { echo "error: address '$addr' must match [A-Za-z0-9-]+" >&2; exit 2; }
fi
if [ -z "$MAIN" ]; then
  MAIN="$(git rev-parse --show-toplevel)"
  [ ! -f "$MAIN/.agents/team/team.json" ] \
    || { echo "error: team clone — pass --main <main checkout>" >&2; exit 2; }
fi
[ -d "$MAIN/.agents" ] || { echo "error: $MAIN is not a checkout with .agents/" >&2; exit 2; }
D="$MAIN/.agents/team/inbox/$addr"

write() {
  local event="$1" from="" ticket="" run="" ref="" msg="" stem f tmp n=1
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
    if [ -f "$MAIN/.agents/team/anchors/$from.json" ]; then
      case "$event" in accepted|closed|collision|session_dead|delegated|decision|clearance) ;;
        *) echo "error: Supervisor takes accepted|closed|collision|session_dead|delegated|decision|clearance from a team, not $event" >&2; exit 2 ;;
      esac
    elif [[ "$from" =~ ^adhoc-[A-Za-z0-9-]+$ ]] \
      || (ROLES_ROOT="$MAIN"; . "$LIB/roles-lib.sh" && roles_is_declared "$from") 2>/dev/null; then
      case "$event" in accepted|closed|collision|session_dead|message|advice|clearance) ;;
        *) echo "error: Supervisor takes accepted|closed|collision|session_dead|message|advice|clearance from $from, not $event" >&2; exit 2 ;;
      esac
    else
      echo "error: --from $from is no team, declared role or adhoc-* session" >&2; exit 2
    fi
  fi
  mkdir -p "$D/tmp" "$D/new" "$D/done"
  stem="$(date -u +%Y%m%dT%H%M%SZ)-$from-$event"; f="$stem"
  # Published with ln, which refuses an existing name: a parallel writer that picked the same name
  # makes this one take the next suffix instead of replacing its message (mv would overwrite).
  tmp="$D/tmp/$stem.$$.md"
  while :; do
    if [ ! -e "$D/done/$f.md" ]; then
      { printf -- '---\nid: %s\nfrom: %s\nto: %s\nevent: %s\nticket: %s\nrun: %s\nref: %s\n---\n' \
          "$f" "$from" "$addr" "$event" "$ticket" "$run" "$ref"
        printf '%s from %s: ticket %s, run %s%s\n' "$event" "$from" "${ticket:-?}" "${run:-?}" \
          "${ref:+ — $ref}"
        [ -z "$msg" ] || printf '%s\n' "$msg"; } > "$tmp"
      ln "$tmp" "$D/new/$f.md" 2>/dev/null && break
      # Not a name clash (no hard links here, a permission error): stop instead of trying 100 names.
      [ -e "$D/new/$f.md" ] || [ -e "$D/done/$f.md" ] \
        || { rm -f "$tmp"; echo "error: cannot link $tmp into $D/new" >&2; exit 1; }
    fi
    n=$((n + 1)); f="$stem-$n"
    [ "$n" -le 100 ] || { rm -f "$tmp"; echo "error: no free name for $stem in $D/new" >&2; exit 1; }
  done
  rm -f "$tmp"
  echo "$D/new/$f.md"
  # The doorbell: the address's session (sh_inbox_session) through the driver. Blocked (9), gone (3)
  # or skipped (10) loses nothing — the file is in new/ and the prompt hook counts it.
  local s rc=0
  if [ -f "$LIB/session-host.sh" ] && . "$LIB/session-host-lib.sh" 2>/dev/null; then
    if s="$(sh_inbox_session "$MAIN" "$addr")"; then
      bash "$LIB/session-host.sh" send "$s" "inbox: $event $from ${ticket:-?} — $D/new/$f.md" --main "$MAIN" \
        >/dev/null 2>&1 || rc=$?
    else rc=3; fi
  else rc=127; fi
  echo "ring: $rc" >&2
}

case "$cmd" in
  write) [ $# -ge 1 ] || usage; write "$@" ;;
  list) [ $# -eq 0 ] || usage; ls -1 "$D/new" 2>/dev/null | sort | sed "s|^|$D/new/|" || true ;;
  done)
    [ $# -eq 1 ] || usage
    f="$(basename "$1")"; [ -f "$D/new/$f" ] || { echo "error: $f is not in $D/new" >&2; exit 1; }
    mkdir -p "$D/done"; mv "$D/new/$f" "$D/done/$f"; echo "$D/done/$f" ;;
  close-run)
    [ $# -eq 1 ] && [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]] || usage
    n=0; mkdir -p "$D/done"
    for f in "$D/new"/*.md; do
      [ -f "$f" ] && [ "$(sed -n '/^---$/,/^---$/s/^run: //p' "$f" | head -n 1)" = "$1" ] || continue
      mv "$f" "$D/done/$(basename "$f")" && n=$((n + 1))
    done
    echo "closed: $n message(s) of run $1 → $D/done" ;;
  prune)
    days=30
    while [ $# -gt 0 ]; do
      case "$1" in --days) [ $# -ge 2 ] || usage; days="$2"; shift 2 ;; *) usage ;; esac
    done
    [[ "$days" =~ ^[0-9]+$ ]] || { echo "error: --days must be a whole number, not '$days'" >&2; exit 2; }
    n=0; I="$MAIN/.agents/team/inbox"
    for dd in "$I"/*/done; do
      [ -d "$dd" ] || continue
      while IFS= read -r f; do
        rm -f "$f" && n=$((n + 1))
      done < <(find "$dd" -maxdepth 1 -type f -name '*.md' -mmin +$((10#$days * 1440)))
    done
    echo "pruned: $n done/ message(s) older than $days day(s) under $I" ;;
  *) usage ;;
esac
