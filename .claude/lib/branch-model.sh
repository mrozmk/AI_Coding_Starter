#!/usr/bin/env bash
# Branch-model reader for /start-task, /pr-create and /check-implementation: parses
# `CLAUDE.md → ### Branch model`, validates a line, gives a type's default base, and records/reads the
# line a branch was started from. It never picks a line from git history — that is the user's
# choice, made once by /start-task and read back here.
#
# Usage (run from the repo root):
#   branch-model.sh fields                 trunk=, integration=, maintenance=, retired=, protected=
#                                          (lists space-separated; absent fields are empty)
#   branch-model.sh check-line <L>         `live` when L is Trunk, Integration or a Maintenance line
#                                          that exists locally or on origin
#   branch-model.sh default-base --type T  hotfix/release → Trunk; every other type → Integration
#                                          (each falling back to the other when unset)
#   branch-model.sh record <branch> <L>    git config branch.<branch>.line <L>, after check-line
#   branch-model.sh line <branch>          the recorded line, if any
#
# Fields (CLAUDE-template.md → Branch model): `**Name:**` at the start of a non-blockquote line or
# right after ` · `; the value runs to the next ` · **`; names are the code spans before the first
# ` — ` (Protected: the whole value). Maintenance/Retired absent → empty, nothing else changes.
#
# Exit: 0 ok · 1 `line`: nothing recorded · 2 usage · 3 no Branch model block (the caller uses its
#   own fallback) · 4 L is retired · 5 L is not a live line · 6 L is on neither the local repo nor origin
set -uo pipefail

die() { echo "branch-model: $2" >&2; exit "$1"; }
[ $# -ge 1 ] || die 2 "usage: branch-model.sh fields|check-line|default-base|record|line …"

# field <Name> → the raw value of that field in the block ('' when absent); exit 3 without a block.
BLOCK=""
load() {
  [ -f CLAUDE.md ] || die 3 "no CLAUDE.md in $(pwd)"
  BLOCK="$(awk '/^### Branch model[[:space:]]*$/ { on = 1; next }
    on && /^#/ { exit } on && $0 !~ /^[[:space:]]*>/ { print }' CLAUDE.md)"
  grep -q '\*\*[A-Za-z →]*:\*\*' <<<"$BLOCK" || die 3 "no Branch model block in CLAUDE.md"
}
field() {
  printf '%s\n' "$BLOCK" | awk -v head="**$1:**" '{
    n = split($0, seg, / · \*\*/)
    for (i = 1; i <= n; i++) { s = (i > 1 ? "**" seg[i] : seg[i])
      if (index(s, head) == 1) { print substr(s, length(head) + 1); exit } } }'
}
names() {  # names <Name> → its code-span names, space-separated
  local v; v="$(field "$1")"
  [ "$1" = Protected ] || v="${v%% — *}"
  printf '%s' "$v" | grep -o '`[^`]*`' | tr -d '`' | tr '\n' ' ' | sed 's/ $//'
}
has() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }  # has <word> <list>

cmd="$1"; shift
case "$cmd" in
  fields)
    load
    for f in Trunk Integration Maintenance Retired Protected; do
      printf '%s=%s\n' "$(printf '%s' "$f" | tr 'A-Z' 'a-z')" "$(names "$f")"
    done ;;
  check-line)
    [ $# -eq 1 ] && [ -n "$1" ] || die 2 "usage: check-line <branch>"
    git check-ref-format --branch "$1" >/dev/null 2>&1 || die 5 "\`$1\` is not a branch name"
    load
    has "$1" "$(names Retired)" && die 4 "\`$1\` is retired — see the Branch model in CLAUDE.md"
    has "$1" "$(names Trunk) $(names Integration) $(names Maintenance)" \
      || die 5 "\`$1\` is not a live line — see Trunk / Integration / Maintenance in CLAUDE.md"
    git rev-parse --verify --quiet "refs/heads/$1" >/dev/null \
      || [ -n "$(git ls-remote --heads origin "refs/heads/$1" 2>/dev/null)" ] \
      || die 6 "\`$1\` is in the Branch model but on neither the local repo nor origin"
    echo live ;;
  default-base)
    [ $# -eq 2 ] && [ "$1" = --type ] && [ -n "$2" ] || die 2 "usage: default-base --type <type>"
    load
    t="$(names Trunk)"; i="$(names Integration)"
    case "$2" in hotfix|release) b="${t:-$i}" ;; *) b="${i:-$t}" ;; esac
    [ -n "$b" ] || die 3 "the Branch model names neither Trunk nor Integration"
    echo "${b%% *}" ;;
  record)
    [ $# -eq 2 ] && [ -n "$1" ] || die 2 "usage: record <branch> <line>"
    git check-ref-format --branch "$1" >/dev/null 2>&1 || die 2 "\`$1\` is not a branch name"
    bash "$0" check-line "$2" >/dev/null || exit $?
    git config "branch.$1.line" "$2" || die 2 "git config failed"
    echo "recorded $1 → $2" ;;
  line)
    [ $# -eq 1 ] && [ -n "$1" ] || die 2 "usage: line <branch>"
    git config --get "branch.$1.line" || exit 1 ;;
  *) die 2 "unknown command $cmd" ;;
esac
