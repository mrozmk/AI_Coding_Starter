#!/usr/bin/env bash
# Offline test for .claude/lib/branch-model.sh: field parsing on the real template layout and the
# one-field-per-line layout, line validation, the default base per type, the recorded line — and that
# a Branch model without Maintenance/Retired behaves exactly as before them. No network: origin is a
# local bare repo. Bash 3.2 compatible.
set -euo pipefail

ST=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
BM="$ST/.claude/lib/branch-model.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_NOSYSTEM=1
printf '[user]\n  name = t\n  email = t@example.invalid\n[init]\n  defaultBranch = main\n' > "$GIT_CONFIG_GLOBAL"

fail() { echo "branch-model-test: FAIL — $*"; exit 1; }
run() {  # run <args…> → RC, OUT, ERR (from the repo $R)
  set +e; OUT=$(cd "$R" && bash "$BM" "$@" 2> "$WORK/err"); RC=$?; set -e; ERR=$(cat "$WORK/err")
}
want() { [ "$RC" = "$1" ] || fail "$2: exit $RC, expected $1 ($ERR)"; }

# A repo with main, develop, rc/1 locally, rc/2 only on origin, and old/x (retired) both places.
R="$WORK/repo"; git init --quiet --bare "$WORK/origin.git"
git init --quiet "$R"; echo a > "$R/f"; git -C "$R" add f; git -C "$R" commit --quiet -m a
git -C "$R" remote add origin "$WORK/origin.git"
for b in develop rc/1 old/x; do git -C "$R" branch "$b"; done
git -C "$R" push --quiet origin main develop old/x "main:refs/heads/rc/2"

# The template's own block, filled the way /setup:create-CLAUDE_MD fills it (combined first line).
template_block() {  # template_block → the filled Branch model section of CLAUDE-template.md
  sed -n '/^### Branch model$/,/^## /p' "$ST/.claude/templates/CLAUDE-template.md" \
    | sed -e '1,/{branch}/s/`{branch}`/`main`/' -e 's/`{branch}`/`develop`/' \
      -e 's/^\*\*Preset:\*\* {[^}]*}/**Preset:** gitflow/' \
      -e 's/^\*\*Protected:\*\* .*/**Protected:** `main`, `develop`, `old\/x`/' \
      -e 's/^\*\*Maintenance:\*\* .*/**Maintenance:** `rc\/1`, `rc\/2` — the 1.x and 2.x lines/' \
      -e 's/^\*\*Retired:\*\* .*/**Retired:** `old\/x` — merged, locked/'
}
{ echo "# CLAUDE.md"; echo; echo '> A note that names **Integration:** `wrong` is not the field.'; echo
  template_block; } > "$R/CLAUDE.md"
grep -qF '**Maintenance:** `rc/1`' "$R/CLAUDE.md" || fail "template: no Maintenance line to fill"
grep -qF '**Retired:** `old/x`' "$R/CLAUDE.md" || fail "template: no Retired line to fill"
WANT='trunk=main
integration=develop
maintenance=rc/1 rc/2
retired=old/x
protected=main develop old/x'
run fields; want 0 "fields (template)"; [ "$OUT" = "$WANT" ] || fail "fields (template): $OUT"

# (1) one field per line gives the same fields
printf '%s\n' '### Branch model' '**Preset:** gitflow' '**Trunk:** `main`' '**Integration:** `develop`' \
  '**Maintenance:** `rc/1`, `rc/2` — the 1.x and 2.x lines' '**Retired:** `old/x` — merged' \
  '**Protected:** `main`, `develop`, `old/x`' > "$R/CLAUDE.md"
run fields; [ "$OUT" = "$WANT" ] || fail "1: one-field layout: $OUT"

# (2) check-line: live (local or origin only), Trunk is live, retired, unknown, missing everywhere
run check-line rc/1; want 0 "2: rc/1"; [ "$OUT" = live ] || fail "2: rc/1 said $OUT"
run check-line rc/2; want 0 "2: rc/2 exists only on origin"
run check-line main; want 0 "2: Trunk is a live line (gitflow hotfix base)"
run check-line old/x; want 4 "2: a retired line"; case "$ERR" in *retired*) ;; *) fail "2: $ERR" ;; esac
run check-line feature/zzz; want 5 "2: not in the model"
run check-line 'bad..name'; want 5 "2: not a branch name"
sed -i.bak 's/`rc\/2` — /`rc\/2`, `rc\/3` — /' "$R/CLAUDE.md"
run check-line rc/3; want 6 "2: in the model, nowhere in git"
git -C "$R" push --quiet origin "main:refs/heads/other/rc/9"
sed -i.bak 's/`rc\/3` — /`rc\/3`, `rc\/9` — /' "$R/CLAUDE.md"
run check-line rc/9; want 6 "2: only other/rc/9 on origin is not rc/9"

# (3) default base per type
run default-base --type hotfix; [ "$OUT" = main ] || fail "3: hotfix → $OUT"
run default-base --type release; [ "$OUT" = main ] || fail "3: release → $OUT"
run default-base --type feature; [ "$OUT" = develop ] || fail "3: feature → $OUT"

# (4) record + read back: the recorded line wins over anything history would suggest — the fresh-cut
# tie (a branch off rc/1 right after rc/1 was cut from develop is as far from develop as from rc/1).
git -C "$R" switch --quiet -c feature/T-1-x rc/1
echo b > "$R/g"; git -C "$R" add g; git -C "$R" commit --quiet -m b
[ "$(git -C "$R" rev-list --count develop..HEAD)" = "$(git -C "$R" rev-list --count rc/1..HEAD)" ] \
  || fail "4: the fixture is not a tie"
run line feature/T-1-x; want 1 "4: nothing recorded yet"
run record feature/T-1-x rc/1; want 0 "4: record"
run line feature/T-1-x; want 0 "4: line"; [ "$OUT" = rc/1 ] || fail "4: read back $OUT"
run record feature/T-1-x old/x; want 4 "4: a retired line is never recorded"
run line feature/T-1-x; [ "$OUT" = rc/1 ] || fail "4: a refused record changed the value"
! grep -rq 'rev-list\|merge-base' "$BM" || fail "4: the helper reads history"

# (5) no Maintenance/Retired: everything as before them
printf '%s\n' '### Branch model' '**Preset:** gitflow · **Trunk:** `main` · **Integration:** `develop`' \
  '**Protected:** `main`, `develop`' > "$R/CLAUDE.md"
run fields; [ "$(printf '%s\n' "$OUT" | sed -n 's/^maintenance=//p;s/^retired=//p' | tr -d '\n')" = "" ] \
  || fail "5: absent fields are not empty: $OUT"
run default-base --type hotfix; [ "$OUT" = main ] || fail "5: hotfix → $OUT (was Trunk)"
run default-base --type feature; [ "$OUT" = develop ] || fail "5: feature → $OUT (was Integration)"
run check-line rc/1; want 5 "5: rc/1 is not live without a Maintenance field"
printf '%s\n' '### Branch model' '**Preset:** trunk · **Trunk:** `main` · **Integration:** `main`' \
  '**Protected:** none' > "$R/CLAUDE.md"
run default-base --type hotfix; [ "$OUT" = main ] || fail "5: trunk preset hotfix → $OUT"

# (6) no block → exit 3 (the command uses its origin/HEAD → main → master fallback)
echo '# CLAUDE.md' > "$R/CLAUDE.md"
run fields; want 3 "6: no block"
run usage-error; want 2 "6: unknown command"

echo "branch-model-test: OK"
