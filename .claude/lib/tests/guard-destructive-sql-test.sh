#!/usr/bin/env bash
# Smoke test for .claude/hooks/guard-destructive-sql.sh: run from the repo root.
# Expected verdicts: deny (DROP/TRUNCATE table/database/schema), ask (other writes), none.
set -uo pipefail
H="$PWD/.claude/hooks/guard-destructive-sql.sh"; fail=0
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
mkdir -p "$D/with space" "$D/other" "$D/r/sub"
printf 'sqlcmd -Q "DELETE FROM dbo.X WHERE Id=1"\n' > "$D/del.sh"
printf 'DROP TABLE dbo.Old;\n' > "$D/drop.sql"
printf 'DROP\n  TABLE dbo.Old;\n' > "$D/multiline.sql"
printf 'TRUNCATE TABLE dbo.Log;\n' > "$D/trunc.sql"
printf 'DROP TABLE dbo.Old;\n' > "$D/with space/x.sql"
printf -- '-- DROP TABLE dbo.Old;\n/* DELETE FROM dbo.X */\nSELECT 1;\n' > "$D/commented.sql"
printf 'SELECT COUNT(*) FROM dbo.X;\n' > "$D/read.sql"
printf 'SELECT 1;\n' > "$D/other/drop.sql"
printf 'sqlcmd -Q "DROP TABLE dbo.Old"\n' > "$D/other/del.sh"
printf 'echo read-only\n' > "$D/r/del.sh"
printf 'sqlcmd -Q "DROP TABLE dbo.Old"\n' > "$D/r/sub/del.sh"
printf 'DROP -- explanation\nTABLE dbo.TestFixture;\n' > "$D/inline.sql"
printf "PRINT '--'; DROP TABLE dbo.X;\n" > "$D/quoted-dashes.sql"
printf 'git checkout -- f; sqlcmd -Q "DELETE FROM dbo.X"\n' > "$D/dashes.sh"
printf 'UPDATE dbo.X SET A=1 WHERE Id=1;\n' > "$D/update.sql"
printf 'INSERT INTO dbo.X (A) VALUES (1);\n' > "$D/insert.sql"
printf 'DELETE dbo.X WHERE Id=1;\n' > "$D/delete-nofrom.sql"
printf 'DELETE\nFROM dbo.X WHERE Id=1;\n' > "$D/delete-multiline.sql"
printf 'DROP INDEX IX_X ON dbo.X;\n' > "$D/drop-index.sql"
printf 'CREATE UNIQUE NONCLUSTERED INDEX IX_X ON dbo.X (A);\n' > "$D/create-nonclustered-index.sql"
printf 'DROP DATABASE Old;\n' > "$D/drop-db.sql"
printf 'SELECT * INTO dbo.Copy FROM dbo.X;\n' > "$D/select-into.sql"
printf 'EXEC dbo.usp_Fix 1;\n' > "$D/exec.sql"
printf "EXPECTED=\$'role assignment delete\\nrole assignment delete\nrole definition delete'\ngrep -E \"role assignment delete|delete-policy\" log\n" > "$D/fixture.sh"
printf 'sqlcmd -S s -d db <<EOF\nUPDATE dbo.X SET A=1;\nEOF\n' > "$D/heredoc.sh"
printf 'az webapp update -n x; az group create -n y; exec bash\n' > "$D/az-words.sh"
printf 'SQL="DROP TABLE dbo.X"; sqlcmd -Q "$SQL"\n' > "$D/dynamic.sh"
# an apostrophe in a heredoc body breaks shlex; only quoted `cat` doc heredocs are dropped.
printf "cat <<'EOF'\nIt's the docs\nEOF\necho ok\n" > "$D/doc-heredoc.sh"
printf "cat <<'EOF'\nIt's the docs\nEOF\nsqlcmd -Q \"delete from T\"\n" > "$D/doc-heredoc-sql.sh"
printf "cat <<EOF\nIt's \$(bash ./x.sh)\nEOF\n" > "$D/unquoted-heredoc.sh"
printf "bash <<'EOF'\nit's run\nEOF\n" > "$D/bash-heredoc.sh"
printf "cat <<'EOF' | bash\nit's run\nEOF\n" > "$D/cat-pipe-heredoc.sh"
printf 'sqlcmd -Q "delete from T"\n' > "$D/danger.sh"
printf "bash < <(cat <<'RUN'\nit's run\nbash ./danger.sh\nRUN\n)\n" > "$D/procsub-heredoc.sh"
printf 'sqlcmd -S s <<EOF\ndelete from T\nEOF\n' > "$D/sqlcmd-heredoc.sh"
printf 'cReAtE uNiQuE nOnClUsTeReD iNdEx IX_X ON dbo.X (A);\n' > "$D/index-case.sql"
printf 'CREATE\nUNIQUE\nNONCLUSTERED\nINDEX IX_X ON dbo.X (A);\n' > "$D/index-newline.sql"
printf 'SELECT create_date, [index] AS [unique] FROM sys.objects;\n' > "$D/index-select.sql"
printf -- '-- CREATE UNIQUE NONCLUSTERED INDEX IX_X ON dbo.X (A);\nSELECT 1;\n' > "$D/index-comment.sql"
printf 'CREATE UNIQUE INDEX IX_X ON dbo.X (A);\nDROP TABLE dbo.Old;\n' > "$D/index-drop.sql"
run() { # <expected: deny|ask|none> <description> <command> [cwd]
  out=$(jq -n --arg c "$3" --arg w "${4:-$D}" '{tool_name:"Bash",cwd:$w,tool_input:{command:$c}}' \
    | (cd /tmp && CLAUDE_PROJECT_DIR=/nonexistent bash "$H"))
  got=none
  if [ -n "$out" ]; then
    got=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "invalid"' \
      2>/dev/null || echo invalid)
  fi
  if [ "$got" = "$1" ]; then echo "PASS $2"; else echo "FAIL $2 (got $got, expected $1)"; fail=1; fi
}
# --- deny: DROP/TRUNCATE of table/database/schema, every input form
run deny "sqlcmd -i with DROP"            "sqlcmd -S s -d db -i \"$D/drop.sql\""
run deny "sqlcmd -Q inline DROP"          "sqlcmd -S s -Q \"DROP TABLE dbo.X\""
run deny "sqlcmd -Q mixed case"           "sqlcmd -S s -Q \"Drop Table dbo.X\""
run deny "sqlcmd --input-file"            "sqlcmd --input-file drop.sql"
run deny "sqlcmd < redirect"              "sqlcmd -S s < drop.sql"
run deny "cat file | sqlcmd"              "cat drop.sql | sqlcmd -S s"
run deny "heredoc DROP"                   "sqlcmd -S s <<EOF
DROP TABLE dbo.X;
EOF"
run deny "bash -c nested"                 "bash -c 'sqlcmd -Q \"DROP TABLE dbo.X\"'"
run deny "tmux new-session nested"        "tmux new-session -d -s x 'sqlcmd -Q \"DROP TABLE dbo.X\"'"
run deny "script with DROP -Q"            "bash other/del.sh"
run deny "DROP DATABASE"                  "sqlcmd -i drop-db.sql"
run deny "TRUNCATE in sql file"           "sqlcmd -i trunc.sql"
run deny "multiline DROP TABLE"           "sqlcmd -i multiline.sql"
run deny "quoted path with spaces"        "sqlcmd -i \"$D/with space/x.sql\""
run deny "inline -- comment inside DROP"  "sqlcmd -i inline.sql"
run deny "-- inside SQL string literal"   "sqlcmd -i quoted-dashes.sql"
run deny "cd before relative script"      "cd sub && bash del.sh" "$D/r"
run deny "trailing semicolon"             "sqlcmd -i drop.sql; echo done"
# --- ask: other writes
run ask  "bash script with DELETE"        "bash $D/del.sh"
run ask  "relative path from payload cwd" "bash del.sh"
run ask  "operator ! bash form"           "! bash del.sh"
run ask  "chained after &&"               "cd $D && bash del.sh"
run ask  "dot-slash script"               "./del.sh"
run ask  "newline-separated command"      "echo ready
bash other/../del.sh"
run ask  "-- in shell script not comment" "bash dashes.sh"
run ask  "UPDATE via -i"                  "sqlcmd -i update.sql"
run ask  "INSERT via -i"                  "sqlcmd -i insert.sql"
run ask  "DELETE without FROM"            "sqlcmd -i delete-nofrom.sql"
run ask  "DELETE multiline"               "sqlcmd -i delete-multiline.sql"
run ask  "DROP INDEX is ask, not deny"    "sqlcmd -i drop-index.sql"
run ask  "CREATE with index modifiers"    "sqlcmd -i create-nonclustered-index.sql"
run ask  "SELECT INTO"                    "sqlcmd -i select-into.sql"
run ask  "EXEC procedure"                 "sqlcmd -i exec.sql"
run ask  "UPDATE inline mixed case"       "sqlcmd -Q \"uPdAtE dbo.X SET A=1\""
run ask  "UPDATE inline with tab"         "sqlcmd -Q \"UPDATE	dbo.X SET A=1\""
run ask  "heredoc UPDATE in script"       "bash heredoc.sh"
run ask  "unreadable -i file"             "sqlcmd -i nope.sql"
run ask  "unparsable sqlcmd command"      "sqlcmd -Q \"DROP TABLE x"
# --- none
run none "AB-1034 fixture: delete at eol" "bash fixture.sh"
run none "az words in shell are not SQL"  "bash az-words.sh"
run none "payload cwd decides the file"   "sqlcmd -i drop.sql" "$D/other"
run none "cat of destructive file"        "cat drop.sql"
run none "comment-only DROP ignored"      "sqlcmd -i commented.sql"
run none "read-only sql passes"           "sqlcmd -i read.sql"
run none "read-only inline passes"        "sqlcmd -Q \"SELECT 1\""
run none "missing script passes"          "bash nope.sh"
run none "no script named passes"         "git status"
run none "unparsable non-sql passes"      "echo \"unbalanced"
run deny "dynamic SQL built on the sqlcmd line" "bash dynamic.sh"
run none "doc heredoc with an apostrophe"  "bash doc-heredoc.sh"
run ask  "doc heredoc plus sqlcmd delete"  "bash doc-heredoc-sql.sh"
run ask  "unquoted heredoc stays unparsable" "bash unquoted-heredoc.sh"
run ask  "bash heredoc stays unparsable"   "bash bash-heredoc.sh"
run ask  "cat heredoc piped to bash stays" "bash cat-pipe-heredoc.sh"
run ask  "cat heredoc run via <( ) scanned" "bash procsub-heredoc.sh"
run ask  "sqlcmd heredoc delete"           "bash sqlcmd-heredoc.sh"
run none "team-run.sh status"   "bash .claude/lib/team-run.sh alfa status" "$PWD"
# --- CREATE ... INDEX forms
n=0
for unique in "" "UNIQUE "; do
  for kind in "" "CLUSTERED " "NONCLUSTERED "; do
    stmt="CREATE ${unique}${kind}INDEX IX_X ON dbo.X (A)"
    n=$((n + 1))
    printf '%s;\n' "$stmt" > "$D/index-$n.sql"
    run ask "-i $stmt" "sqlcmd -i index-$n.sql"
    run ask "-Q $stmt" "sqlcmd -Q \"$stmt\""
  done
done
run ask  "index mixed case -i"            "sqlcmd -i index-case.sql"
run ask  "index mixed case -Q"            "sqlcmd -Q \"cReAtE uNiQuE cLuStErEd iNdEx IX_X ON dbo.X (A)\""
run ask  "index newlines -i"              "sqlcmd -i index-newline.sql"
run ask  "index newlines -Q"              "sqlcmd -Q \"CREATE
UNIQUE
NONCLUSTERED
INDEX IX_X ON dbo.X (A)\""
run none "SELECT with the words -i"       "sqlcmd -i index-select.sql"
run none "SELECT with the words -Q"       "sqlcmd -Q \"SELECT create_date, [index] AS [unique] FROM sys.objects\""
run none "CREATE INDEX in a comment -i"   "sqlcmd -i index-comment.sql"
run none "CREATE INDEX in a comment -Q"   "sqlcmd -Q \"/* CREATE UNIQUE INDEX IX_X ON dbo.X (A) */ SELECT 1\""
run deny "CREATE INDEX plus DROP TABLE -i" "sqlcmd -i index-drop.sql"
run deny "CREATE INDEX plus DROP TABLE -Q" "sqlcmd -Q \"CREATE INDEX IX_X ON dbo.X (A); DROP TABLE dbo.Old\""
# The shared wrapper table and shell -c flag forms (S5)
run deny "bash -lc nests sqlcmd"            "bash -lc \"sqlcmd -Q 'DROP TABLE t'\""
run deny "timeout with a duration"          "timeout 5 sqlcmd -Q \"DROP TABLE t\""
run deny "env with an option"               "env -i sqlcmd -Q \"DROP TABLE t\""
run deny "env -S splits its string"         "env -S \"sqlcmd -Q 'DROP TABLE t'\""
run ask  "stdbuf wrapper"                   "stdbuf -o0 sqlcmd -Q \"DELETE FROM dbo.X WHERE Id=1\""
run none "a wrapped read"                   "timeout 5 sqlcmd -Q \"SELECT 1\""
# Command substitution and sqlcmd long options (R1)
run deny "backtick glued to the verb"       'echo `sqlcmd -S h -Q "DROP TABLE t"`'
run deny "backtick as the first word"       '`sqlcmd -S h -Q "DROP TABLE t"`'
run deny "backtick in an assignment"        'x=`sqlcmd -Q "DROP TABLE t"`'
run deny "backtick inside double quotes"    "echo \"\`sqlcmd -Q 'DROP TABLE t'\`\""
run deny "\$() inside double quotes"         "echo \"\$(sqlcmd -Q 'DROP TABLE t')\""
run deny "\$() in double quotes, inner double quotes" 'x="$(sqlcmd -S h -Q "DROP TABLE t")"'
run deny "nested \$() in double quotes"      'echo "$(echo "$(sqlcmd -Q "DROP TABLE t")")"'
run ask  "\$() in double quotes with a write" 'x="$(sqlcmd -Q "DELETE FROM dbo.X")"'
run none "\$() in double quotes with a read"  'x="$(sqlcmd -Q "SELECT 1")"'
run none "\$() in single quotes is text"      "echo '\$(sqlcmd -Q \"DROP TABLE t\")'"
run ask  "unterminated \$() around sqlcmd"    'x="$(sqlcmd -Q "DROP TABLE t"'
run ask  "unterminated \$() inside one string" "echo \"\$(sqlcmd -Q 'DROP TABLE t'\""
run deny "a ) inside the inner quotes"        'x="$(sqlcmd -Q "DROP TABLE t /* ) */")"'
run ask  "backtick with a write"            'echo `sqlcmd -Q "DELETE FROM dbo.X"`'
run none "backtick with a read"             'echo `sqlcmd -Q "SELECT 1"`'
run none "backtick without sqlcmd"          'echo `date`'
run deny "--query value"                    'sqlcmd -S h --query "DROP TABLE t"'
run deny "--query=value"                    'sqlcmd -S h --query="DROP TABLE t"'
run ask  "--query=value with a write"       'sqlcmd --query="DELETE FROM dbo.X"'
run deny "--input-file=file"                "sqlcmd --input-file=drop.sql"
run ask  "unparsed long option asks"        'sqlcmd -S h --format vert -Q "SELECT 1"'
# An unreadable payload fails closed (S9): ask, never silence.
for bad in 'not json' '[1,2]'; do
  out=$(printf '%s' "$bad" | (cd /tmp && CLAUDE_PROJECT_DIR=/nonexistent bash "$H"))
  got=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "none"' 2>/dev/null || echo none)
  if [ "$got" = ask ]; then echo "PASS unreadable payload $bad asks"
  else echo "FAIL unreadable payload $bad (got $got, expected ask)"; fail=1; fi
done
exit $fail
