#!/usr/bin/env bash
# The order brief of a team's ticket: what was ordered, what was not, what the other teams touch.
# Usage: bash .claude/lib/team-brief.sh inflight <team>                     (main checkout)
#        bash .claude/lib/team-brief.sh write <team> <draft file> [--replace]
#        bash .claude/lib/team-brief.sh check <team>
#   inflight prints the other teams' work from the runner anchors as a Markdown list; write
#   validates the draft (one each of `## Ticket`, `## Not ordered`, `## In-flight work`, every body
#   non-empty — "none" counts) and places it as <clone>/.agents/team/order-brief.md; check
#   validates the placed file. Exit 0 ok · 2 usage · 4 invalid or missing brief.
#   e.g. bash .claude/lib/team-brief.sh write alfa /tmp/brief.md
# Contract: .agents/reference/team-mode.md §2
set -euo pipefail

usage() { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
[ $# -ge 2 ] || usage
. "$(dirname "$0")/team-lib.sh"
cmd="$1" team="$2"; shift 2
team_check_name "$team" || exit 2
root="$(team_root)"
[ ! -f "$root/.agents/team/team.json" ] \
  || { echo "error: team clone — run team-brief.sh from the main checkout" >&2; exit 1; }

# brief_problems <file> → one line per missing or empty required section; nothing when valid.
# Only the three required headings bound a section: the ticket text is pasted verbatim and may
# carry its own `## ` headings, which are body of the current section.
brief_problems() {
  awk '
    BEGIN { n = split("## Ticket|## Not ordered|## In-flight work", req, "|")
            for (i = 1; i <= n; i++) reserved[req[i]] = 1 }
    /^## / { h = $0; sub(/[[:space:]]+$/, "", h)
             if (h in reserved) { cur = h; count[cur]++; next } }
    cur != "" && $0 ~ /[^[:space:]]/ { body[cur] = 1 }
    END {
      for (i = 1; i <= n; i++) {
        h = req[i]
        if (count[h] == 0) print "missing heading: " h
        else if (count[h] > 1) print "heading appears " count[h] " times: " h
        else if (!body[h]) print "empty section: " h " (write \"none\" when nothing applies)"
      }
    }' "$1"
}

clone_of() {
  local c
  c="$(team_clone_dir "$1" "$root")"
  [ -f "$c/.agents/team/team.json" ] || { echo "error: no team clone for $1 at $c" >&2; exit 1; }
  printf '%s\n' "$c"
}

inflight() {
  local a t ticket branch role clone mode found=""
  for a in "$root"/.agents/team/anchors/*.json; do
    [ -f "$a" ] || continue
    t="$(jq -r '.team // empty' "$a" 2>/dev/null)" || continue
    [ -n "$t" ] && [ "$t" != "$team" ] || continue
    ticket="$(jq -r '.ticket // "?"' "$a")"; branch="$(jq -r '.branch // "?"' "$a")"
    role="$(jq -r '.role // "?"' "$a")"; clone="$(jq -r '.clone // empty' "$a")"
    # A team whose clone is gone still shows up; its mode is unknown.
    mode="$(jq -r '.mode // empty' "$clone/.agents/team/team.json" 2>/dev/null || true)"
    echo "- $t: $ticket on $branch (${mode:-?}, stage $role)"
    found=1
  done
  [ -n "$found" ] || echo "- none"
}

write_brief() {
  local draft="$1" replace="${2:-}" clone out p
  [ -r "$draft" ] || { echo "error: draft $draft not readable" >&2; exit 2; }
  p="$(brief_problems "$draft")"
  [ -z "$p" ] || { printf 'error: invalid order brief — %s\n' "$p" >&2; exit 4; }
  clone="$(clone_of "$team")"
  out="$clone/.agents/team/order-brief.md"
  # A resume never rewrites the order silently.
  [ ! -e "$out" ] || [ "$replace" = --replace ] \
    || { echo "error: $out exists — pass --replace to rewrite the order" >&2; exit 4; }
  { echo "ticket: $(jq -r '.ticket // empty' "$clone/.agents/team/team.json")"
    echo "written_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo
    cat "$draft"; } > "$out.tmp.$$"
  mv "$out.tmp.$$" "$out"
  echo "$out"
}

check_brief() {
  local f p
  f="$(clone_of "$team")/.agents/team/order-brief.md"
  [ -f "$f" ] || { echo "error: no order brief at $f" >&2; exit 4; }
  p="$(brief_problems "$f")"
  [ -z "$p" ] || { printf 'error: invalid order brief — %s\n' "$p" >&2; exit 4; }
  echo "order brief ok: $f"
}

case "$cmd" in
  inflight) [ $# -eq 0 ] || usage; inflight ;;
  write)
    [ $# -ge 1 ] && [ $# -le 2 ] || usage
    [ $# -eq 1 ] || [ "$2" = --replace ] || usage
    write_brief "$@" ;;
  check) [ $# -eq 0 ] || usage; check_brief ;;
  *) usage ;;
esac
