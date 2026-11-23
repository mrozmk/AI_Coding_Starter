#!/usr/bin/env bash
# Git blob reads and the standards render base shared by the wrapup standards checks
# (team-validate.sh check_wrapup_standards, team-merge-check.sh). Sourced by team-lib.sh; never
# executed. Bash 3.2 compatible.

# team_blob_tmp <rev> <path> → a temp file holding the blob (the caller removes it), or "-" only when
# <rev> is a commit whose tree lists no such path; rc 1 when it cannot be read (an unresolved rev, an
# unreadable tree or blob) — ls-tree's own status counts, as a broken tree prints nothing too.
team_blob_tmp() {
  local t l
  t="$(mktemp)" || return 1
  if git show "$1:$2" > "$t" 2>/dev/null; then echo "$t"; return 0; fi
  rm -f "$t"
  if git rev-parse -q --verify "$1^{commit}" >/dev/null && l="$(git ls-tree "$1" -- "$2" 2>/dev/null)" \
      && [ -z "$l" ]; then
    echo -; return 0
  fi
  echo "team_blob_tmp: cannot read $1:$2" >&2
  return 1
}

# team_rm_blobs <file|->... → removes the temp files team_blob_tmp made ("-" names none).
team_rm_blobs() {
  local x
  for x in "$@"; do [ "$x" = - ] || rm -f "$x"; done
}

# team_standards_render_rev <run dir> <qa rev> [promotion] → the target_rev the standards writer
# recorded for this QA revision (runs/<run>/standards-render.json); nothing when there is no record
# or it is another round's (other qa_rev); with "promotion", only when the record promotes. rc 1 with
# "standards render base unreadable: <why>" on stderr for a record that breaks the shape.
team_standards_render_rev() {
  local f="$1/standards-render.json" run why
  [ -f "$f" ] || return 0
  run="$(basename "$1")"
  why="$(jq -rs --arg run "$run" '
    def sha: type == "string" and test("^[0-9a-f]{40}$");
    if length != 1 then "not one JSON value"
    else .[0] | if type != "object" then "not an object"
      elif .run != $run then "names another run"
      elif (.qa_rev | sha | not) then "qa_rev is not a sha"
      elif (.target_rev | sha | not) then "target_rev is not a sha"
      elif (.promotes | type) != "boolean" then "promotes is not a boolean"
      else "" end
    end' "$f" 2>/dev/null)" || why="not valid JSON"
  if [ -n "$why" ]; then echo "standards render base unreadable: $why ($f)" >&2; return 1; fi
  [ "$(jq -r .qa_rev "$f")" = "$2" ] || return 0
  [ "${3:-}" != promotion ] || [ "$(jq -r .promotes "$f")" = true ] || return 0
  jq -r .target_rev "$f"
}
