#!/usr/bin/env bash
# Offline test of the shared trunk-trust rule (.claude/lib/trunk-trust/trunk_trust.py): the Trunk name
# comes from CLAUDE.md on origin's default branch, parsed by that commit's branch-model.sh in a private
# temp dir — never from the working tree. Fixture repos only: a local bare origin reached through an
# ssh stub (a flag file makes it hang like a dead host), fixture HOME and TMPDIR, no network.
set -euo pipefail

ST=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail() { echo "trunk-trust-test: FAIL — $*"; exit 1; }
N=0

H="$T/home"; STUB="$T/stub"; TMP="$T/tmp"; mkdir -p "$H" "$STUB" "$TMP"
cat > "$STUB/ssh" <<EOF
#!/bin/sh
while [ \$# -gt 0 ]; do case "\$1" in -o|-p) shift 2 ;; -*) shift ;; *) break ;; esac; done
shift
[ -e "$T/hang" ] && exec sleep 60
exec sh -c "\$*"
EOF
chmod +x "$STUB/ssh"
P="$STUB:/usr/bin:/bin"
g() { env -i PATH="$P" HOME="$H" GIT_CONFIG_NOSYSTEM=1 git "$@"; }
printf '[user]\n\tname = t\n\temail = t@example.invalid\n[init]\n\tdefaultBranch = main\n' > "$H/.gitconfig"
cat > "$T/drv.py" <<'EOF'
import sys, types
m = types.ModuleType("trunk_trust")
exec(compile(open(sys.argv[1], "rb").read(), sys.argv[1], "exec"), m.__dict__)
try:
    _, (_, label) = m.config_at_trunk(sys.argv[2], ".claude/kit.json", lambda c: c)
    print("OK " + label)
except m.Refused as e:
    print("REFUSED %s" % e)
EOF
model() { printf '# P\n\n### Branch model\n\n**Preset:** %s · **Trunk:** `%s` · **Integration:** `%s`\n' "$1" "$2" "$3"; }

# project <name>: bare origin + a clone through the ssh stub (an empty clone: no origin/HEAD), main pushed
project() {
  g init -q --bare "$T/$1.git"
  g clone -q "ssh://stub.example.invalid$T/$1.git" "$T/$1" 2>/dev/null
  mkdir -p "$T/$1/.claude/lib"
  cp "$ST/.claude/lib/branch-model.sh" "$T/$1/.claude/lib/"
  model trunk main main > "$T/$1/CLAUDE.md"
  printf '{"v": 1}\n' > "$T/$1/.claude/kit.json"
  (cd "$T/$1" && g add -A && g commit -qm init && g push -q origin main 2>/dev/null)
}
check() {  # check <repo> <OK|REFUSED> <label> [substring] → OUT
  set +e
  OUT=$(cd "$T/$1" && env -i PATH="$P" HOME="$H" TMPDIR="$TMP" TRUNK_TRUST_LS_REMOTE_TIMEOUT="${TO:-2}" \
    python3 -I -B "$T/drv.py" "$ST/.claude/lib/trunk-trust/trunk_trust.py" "$T/$1" 2>&1)
  set -e; N=$((N + 1))
  case "$OUT" in "$2 "*) ;; *) fail "$3: want $2: $OUT" ;; esac
  [ -z "${4:-}" ] || case "$OUT" in *"$4"*) ;; *) fail "$3: no '$4' in: $OUT" ;; esac
}
widen() { printf '{"v": 1, "wider": true}\n' > "$T/$1/.claude/kit.json"; }

# ---- 1. a working-tree CLAUDE.md naming a pushed branch as Trunk changes nothing ------------------
project a
check a OK "baseline" "OK origin/main"
(cd "$T/a" && g checkout -q -b feat/x && model trunk feat/x feat/x > CLAUDE.md && widen a \
  && g commit -qam declare && g push -q origin feat/x 2>/dev/null)
check a REFUSED "1 declared Trunk in the working tree" "differs from origin/main"

# ---- 2. a working-tree branch-model.sh printing another Trunk changes nothing ---------------------
(cd "$T/a" && g checkout -q main && model trunk feat/x feat/x > CLAUDE.md && widen a)
printf '#!/usr/bin/env bash\necho trunk=feat/x; exit 0\n' > "$T/a/.claude/lib/branch-model.sh"
check a REFUSED "2 edited parser in the working tree" "differs from origin/main"
(cd "$T/a" && g checkout -q -- .)
check a OK "2 restored"

# ---- 3. Trunk != default: the declaration is read from the default branch -------------------------
project b
(cd "$T/b" && g checkout -q -b develop && model gitflow main develop > CLAUDE.md \
  && g commit -qam develop && g push -q origin develop 2>/dev/null)
g --git-dir="$T/b.git" symbolic-ref HEAD refs/heads/develop
(cd "$T/b" && g checkout -q main)
check b OK "3 config on main, Trunk per develop" "OK origin/main (Trunk per CLAUDE.md on origin/develop)"
(cd "$T/b" && g checkout -q develop && widen b && g commit -qam wide && g push -q origin develop 2>/dev/null)
check b REFUSED "3 config only on develop" "differs from origin/main (Trunk per CLAUDE.md on origin/develop)"
(cd "$T/b" && g checkout -q main)

# ---- 4. no local origin/HEAD: online works, a dead origin is refused with the fix -----------------
project c
g -C "$T/c" symbolic-ref -q refs/remotes/origin/HEAD >/dev/null && fail "fixture: c has origin/HEAD"
check c OK "4 no origin/HEAD, online"
TO=0 check c OK "4 a zero timeout does not force the offline rule"
: > "$T/hang"
check c REFUSED "4 no origin/HEAD, hung origin" "git remote set-head origin"
rm -f "$T/hang"

# ---- 5. origin changed its default; a stale local origin/HEAD does not matter online --------------
project d
g -C "$T/d" remote set-head origin main
(cd "$T/d" && g checkout -q -b develop && model gitflow main develop > CLAUDE.md \
  && g commit -qam develop && g push -q origin develop 2>/dev/null && g checkout -q main)
g --git-dir="$T/d.git" symbolic-ref HEAD refs/heads/develop
check d OK "5 origin's default followed" "on origin/develop"

# ---- 6. a default branch without a Branch model is refused, naming it -----------------------------
project e
(cd "$T/e" && g checkout -q -b docs && printf '# docs\n' > CLAUDE.md && g commit -qam docs \
  && g push -q origin docs 2>/dev/null && g checkout -q main)
g --git-dir="$T/e.git" symbolic-ref HEAD refs/heads/docs
check e REFUSED "6 no Branch model on the default branch" "CLAUDE.md on origin/docs"

# ---- 7. a local origin/<default> behind origin is refused -----------------------------------------
project f
g clone -q "ssh://stub.example.invalid$T/f.git" "$T/f2" 2>/dev/null
(cd "$T/f2" && printf 'x\n' > other && g add other && g commit -qm other && g push -q origin main 2>/dev/null)
check f REFUSED "7 local origin/main behind origin" "does not match what origin has"

# ---- 8. offline with a local origin/HEAD: today's verdicts -----------------------------------------
project h
g -C "$T/h" remote set-head origin main
: > "$T/hang"
check h OK "8 offline, origin/HEAD set" "OK origin/main"
widen h
check h REFUSED "8 offline, edited config" "differs from origin/main"
rm -f "$T/hang"

# ---- the default branch's parser may not source other files; the temp dir never stays -------------
project k
(cd "$T/k" && printf '#!/usr/bin/env bash\nsource ./extra.sh\n' > .claude/lib/branch-model.sh \
  && g commit -qam sourcing && g push -q origin main 2>/dev/null)
check k REFUSED "parser sourcing a file" "sources ./extra.sh"
ls "$TMP" | grep -q '^trunk-trust-' && fail "a trunk-trust temp dir was left behind"
N=$((N + 1))

echo "trunk-trust-test: OK ($N checks)"
