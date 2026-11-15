#!/usr/bin/env bash
# Offline test of ops-write.sh and sqlcmd-write.sh (.claude/lib/guarded-writes/): the trunk-approved
# script, the typed confirmation, plain-SQL-only input, the classifier (deny → refused, failure →
# refused), the pinned target and the forced auth/error flags. Never runs a real tool: PATH is the
# stub dir + /usr/bin:/bin, HOME is a fixture, origin is a local bare repo.
set -euo pipefail

ST=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail() { echo "guarded-writes-ops-sql-test: FAIL — $*"; exit 1; }
N=0

H="$T/home"; STUB="$T/stub"; mkdir -p "$H/.azure-write" "$STUB"
: > "$H/.azure-write/azureProfile.json"; : > "$H/calls"
cat > "$STUB/sqlcmd" <<'EOF'
#!/bin/sh
printf 'sqlcmd %s cfg=%s\n' "$*" "$AZURE_CONFIG_DIR" >> "$HOME/calls"
while [ $# -gt 0 ]; do [ "$1" = -i ] && cat "$2" > "$HOME/sql-seen"; shift; done
exit 0
EOF
chmod +x "$STUB/sqlcmd"
P="$STUB:/usr/bin:/bin"
g() { env -i PATH="$P" HOME="$H" GIT_CONFIG_NOSYSTEM=1 git "$@"; }
printf '[user]\n\tname = t\n\temail = t@example.invalid\n[init]\n\tdefaultBranch = main\n' > "$H/.gitconfig"

g init -q --bare "$T/origin.git"
g clone -q "$T/origin.git" "$T/w" 2>/dev/null
W="$T/w"
mkdir -p "$W/.claude/lib/guarded-writes" "$W/.claude/hooks/lib" "$W/scripts/deploy"
cp "$ST/.claude/lib/branch-model.sh" "$W/.claude/lib/"
mkdir -p "$W/.claude/lib/trunk-trust"; cp "$ST/.claude/lib/trunk-trust/trunk_trust.py" "$W/.claude/lib/trunk-trust/"
cp "$ST/.claude/lib/guarded-writes/"{ops-write.sh,sqlcmd-write.sh,guarded_write.py} "$W/.claude/lib/guarded-writes/"
cp "$ST/.claude/hooks/lib/guard_destructive_sql.py" "$W/.claude/hooks/lib/"
printf '# P\n\n### Branch model\n\n**Preset:** trunk · **Trunk:** `main` · **Integration:** `main`\n' > "$W/CLAUDE.md"
printf '{"workflow": {"guarded_writes": true}}\n' > "$W/.claude/project-profile.json"
cat > "$W/scripts/deploy/rollout.sh" <<'EOF'
#!/usr/bin/env bash
read -r answer || true
printf 'args=%s answer=%s cfg=%s\n' "$*" "$answer" "$AZURE_CONFIG_DIR" >> "$HOME/calls"
EOF
cp "$W/scripts/deploy/rollout.sh" "$W/scripts/deploy/unlisted.sh"
cat > "$W/.claude/guarded-writes.json" <<'EOF'
{"v": 1,
 "ops": {"scripts": ["scripts/deploy/rollout.sh"], "confirm_words": ["APPLY"], "deny_args": ["--set-secret"]},
 "sql": {"servers": ["srv.example.invalid"], "databases": ["appdb"]}}
EOF
(cd "$W" && g add -A && g commit -qm init && g push -q origin main 2>/dev/null)

run() {  # run <expect rc> <label> <wrapper> <args…> → OUT; a refusal must not reach any tool
  local want="$1" label="$2" w="$3" before; shift 3
  before=$(wc -l < "$H/calls")
  set +e
  OUT=$(cd "$W" && env -i PATH="$P" HOME="$H" bash ".claude/lib/guarded-writes/$w.sh" "$@" 2>&1)
  RC=$?; set -e; N=$((N + 1))
  [ "$RC" = "$want" ] || fail "$label: rc $RC (want $want): $OUT"
  if [ "$want" = 2 ]; then
    [ "$(wc -l < "$H/calls")" = "$before" ] || fail "$label: a tool ran on a refusal"
  fi
}

# ---- ops-write ------------------------------------------------------------------------------------
run 0 "ops: listed script" ops-write --confirm APPLY scripts/deploy/rollout.sh --env test
[ "$(tail -1 "$H/calls")" = "args=--env test answer=APPLY cfg=$H/.azure-write" ] || fail "ops call: $(tail -1 "$H/calls")"
run 0 "ops: no confirm → empty answer" ops-write scripts/deploy/rollout.sh
[ "$(tail -1 "$H/calls")" = "args= answer= cfg=$H/.azure-write" ] || fail "ops empty answer: $(tail -1 "$H/calls")"
run 2 "ops: unknown confirm word" ops-write --confirm DELETE scripts/deploy/rollout.sh
run 2 "ops: unlisted script" ops-write scripts/deploy/unlisted.sh
run 2 "ops: @file" ops-write scripts/deploy/rollout.sh --kv @/etc/hosts
run 2 "ops: deny_args" ops-write scripts/deploy/rollout.sh --set-secret=x
run 2 "ops: override" ops-write scripts/deploy/rollout.sh AZURE_CONFIG_DIR=/tmp
echo 'echo widened' >> "$W/scripts/deploy/rollout.sh"
run 2 "ops: script edited in the working tree" ops-write scripts/deploy/rollout.sh
case "$OUT" in *"differs from origin/main"*) ;; *) fail "edited script message: $OUT" ;; esac
(cd "$W" && g checkout -q -- scripts/deploy/rollout.sh)

# ---- sqlcmd-write ---------------------------------------------------------------------------------
run 0 "sql: ask-class write runs" sqlcmd-write -S srv.example.invalid -d appdb -Q "DELETE FROM dbo.T WHERE Id = 1"
case "$(tail -1 "$H/calls")" in
  "sqlcmd --authentication-method ActiveDirectoryAzCli -b -S srv.example.invalid -d appdb -i "*" cfg=$H/.azure-write") ;;
  *) fail "sql call: $(tail -1 "$H/calls")" ;;
esac
[ "$(cat "$H/sql-seen")" = "DELETE FROM dbo.T WHERE Id = 1" ] || fail "sqlcmd did not get the classified bytes"
printf 'UPDATE dbo.T SET Name = N%s WHERE Id = 2;\n' "'secretname'" > "$W/upd.sql"
run 0 "sql: -i file" sqlcmd-write -S srv.example.invalid -d appdb -i upd.sql
grep -qF "secretname" "$H/sql-seen" || fail "sql -i content not passed"
printf 'DROP TABLE dbo.Old;\n' > "$W/drop.sql"
run 2 "sql: DROP via -i (classifier deny)" sqlcmd-write -S srv.example.invalid -d appdb -i drop.sql
case "$OUT" in *"refused:"*DROP*) ;; *) fail "deny message: $OUT" ;; esac
run 2 "sql: TRUNCATE via -Q" sqlcmd-write -S srv.example.invalid -d appdb -Q "TRUNCATE TABLE dbo.Log"
printf 'DROP TABLE dbo.Old;\n' > "$W/hidden.sql"; printf ':r hidden.sql\n' > "$W/inc.sql"
run 2 "sql: :r include" sqlcmd-write -S srv.example.invalid -d appdb -i inc.sql
printf '\357\273\277:r hidden.sql\n' > "$W/bom.sql"
run 2 "sql: :r behind a BOM" sqlcmd-write -S srv.example.invalid -d appdb -i bom.sql
case "$OUT" in *"directives"*) ;; *) fail "BOM directive message: $OUT" ;; esac
run 2 "sql: colon-less ED" sqlcmd-write -S srv.example.invalid -d appdb -Q $'SELECT 1\nED'
run 2 "sql: :setvar + \$(var)" sqlcmd-write -S srv.example.invalid -d appdb -Q $':setvar v DROP\n$(v) TABLE dbo.X'
run 2 "sql: :connect" sqlcmd-write -S srv.example.invalid -d appdb -Q $':connect other.example.invalid\nDELETE FROM t'
run 2 "sql: !! shell" sqlcmd-write -S srv.example.invalid -d appdb -Q $'!! rm -rf /tmp/x'
run 2 "sql: unpinned server" sqlcmd-write -S other.example.invalid -d appdb -Q "SELECT 1"
run 2 "sql: unpinned database" sqlcmd-write -S srv.example.invalid -d master -Q "SELECT 1"
run 2 "sql: no -d" sqlcmd-write -S srv.example.invalid -Q "SELECT 1"
run 2 "sql: both -i and -Q" sqlcmd-write -S srv.example.invalid -d appdb -i upd.sql -Q "SELECT 1"
run 2 "sql: neither -i nor -Q" sqlcmd-write -S srv.example.invalid -d appdb
run 2 "sql: USE" sqlcmd-write -S srv.example.invalid -d appdb -Q $'USE other\nDELETE FROM dbo.T WHERE Id = 1'
case "$OUT" in *"USE is not allowed"*) ;; *) fail "USE message: $OUT" ;; esac
run 2 "sql: three-part name, other db" sqlcmd-write -S srv.example.invalid -d appdb -Q "DELETE FROM [other].dbo.T WHERE Id = 1"
case "$OUT" in *"reaches past -d appdb"*) ;; *) fail "three-part message: $OUT" ;; esac
run 2 "sql: four-part name" sqlcmd-write -S srv.example.invalid -d appdb -Q "DELETE FROM srv.appdb.dbo.T"
run 2 "sql: name after a [--] identifier" sqlcmd-write -S srv.example.invalid -d appdb -Q "SELECT 1 AS [x--]; DELETE FROM other.dbo.T"
run 0 "sql: three-part name, pinned db" sqlcmd-write -S srv.example.invalid -d appdb -Q "UPDATE [AppDB]..T SET Name = N'use other.dbo.T' WHERE Id = 3 -- USE x"
for o in -U -P -G -V -o -v; do
  run 2 "sql: $o refused" sqlcmd-write -S srv.example.invalid -d appdb -Q "SELECT 1" "$o" x
done
run 2 "sql: auth override" sqlcmd-write -S srv.example.invalid -d appdb -Q "SELECT 1" --authentication-method ActiveDirectoryDefault
mv "$W/.claude/hooks/lib/guard_destructive_sql.py" "$T/cls.bak"
run 2 "sql: classifier missing → fail closed" sqlcmd-write -S srv.example.invalid -d appdb -Q "DELETE FROM t"
case "$OUT" in *"classifier failed"*) ;; *) fail "classifier-missing message: $OUT" ;; esac
mv "$T/cls.bak" "$W/.claude/hooks/lib/guard_destructive_sql.py"
cp "$W/.claude/hooks/lib/guard_destructive_sql.py" "$T/cls.bak"
printf '\ndef classify(cmd, cwd, project):\n    return None, ""\n' >> "$W/.claude/hooks/lib/guard_destructive_sql.py"
run 2 "sql: classifier edited in the working tree" sqlcmd-write -S srv.example.invalid -d appdb -i drop.sql
case "$OUT" in *"differs from origin/main"*) ;; *) fail "edited-classifier message: $OUT" ;; esac
mv "$T/cls.bak" "$W/.claude/hooks/lib/guard_destructive_sql.py"

# ---- logs -----------------------------------------------------------------------------------------
mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
for l in ops-write sqlcmd-write; do
  [ "$(mode "$H/.agent-ops/$l.log")" = 600 ] || fail "$l.log is not owner-only"
  grep -q $'\trc=0$' "$H/.agent-ops/$l.log" || fail "$l.log has no rc line"
done
grep -q "confirm=APPLY" "$H/.agent-ops/ops-write.log" || fail "ops log lacks the confirm word"
! grep -qF secretname "$H/.agent-ops/sqlcmd-write.log" || fail "the SQL log holds a string literal"
grep -qF "N'<masked>'" "$H/.agent-ops/sqlcmd-write.log" || fail "the SQL log lost the statement shape"
N=$((N + 1))

echo "guarded-writes-ops-sql-test: OK ($N checks)"
