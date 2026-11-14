#!/usr/bin/env bash
# Identify the starter commit this project was created from, for `.claude/.starter-sync.json →
# last_sync_commit`. Exact evidence only, first hit wins:
#   history    — a `git clone` of the starter: the newest starter commit in HEAD's history;
#   root-tree  — "Use this template": the project's root commit has the tree of a starter commit.
# A brownfield copy has neither and gets no answer: a near match (e.g. the same `.claude/` tree)
# would name the wrong base, and a wrong base turns real staleness into "local edits" in the 3-way
# sync, which is worse than the 2-way fallback.
#
#   bash .claude/lib/starter-fork-commit.sh <starter-repo-url-or-path> [ref]
#   stdout: <short-hash> <YYYY-MM-DD> <history|root-tree>
#   exit 0 = found · 1 = no exact match, no commits, or the starter could not be fetched
set -u
repo="${1:-}"; ref="${2:-main}"
[ -n "$repo" ] || { echo "usage: starter-fork-commit.sh <starter-repo> [ref]" >&2; exit 2; }
git rev-parse --verify -q HEAD >/dev/null || { echo "no commits in this repository yet" >&2; exit 1; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/starter-fork.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT
if ! git clone -q --bare --filter=blob:none "$repo" "$tmp/s.git" 2>"$tmp/err"; then
  echo "cannot fetch the starter from $repo: $(tail -1 "$tmp/err")" >&2; exit 1
fi
S() { git -C "$tmp/s.git" "$@"; }
S rev-parse --verify -q "$ref^{commit}" >/dev/null || { echo "starter has no ref $ref" >&2; exit 1; }

found() { S log -1 --format="%h %cs $1" "$2"; exit 0; }

S rev-list "$ref" > "$tmp/starter"
hit=$(git rev-list HEAD | grep -Fx -m1 -f "$tmp/starter")
[ -n "$hit" ] && found history "$hit"

root_tree=$(git rev-parse "$(git rev-list --max-parents=0 HEAD | head -1)^{tree}")
hit=$(S log --format='%H %T' "$ref" | awk -v t="$root_tree" '$2 == t { print $1; exit }')
[ -n "$hit" ] && found root-tree "$hit"

echo "no starter commit matches this repository exactly (history or root tree)" >&2
exit 1
