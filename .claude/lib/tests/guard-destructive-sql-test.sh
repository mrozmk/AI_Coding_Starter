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
printf 'SELECT 1 AS [x--]; DROP TABLE t;\n' > "$D/bracket-dashes.sql"
printf 'SELECT 1 AS [a]]--b]; DROP TABLE t;\n' > "$D/bracket-escaped.sql"
printf 'SELECT 1 AS "x/*"; DROP TABLE t; -- */\n' > "$D/dquote-block.sql"
printf 'SELECT [x] -- DROP TABLE t\n/* [ */ SELECT "y";\n' > "$D/ident-then-comment.sql"
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
# A construct shlex cannot parse (reduced from a real helper script).
U='X="$X $(sed -n '\''s/"t" *: *"\([^"]*\)"/\1/p'\'' f)"'
printf '%s\necho ok\n' "$U" > "$D/unparsable.sh"
printf '%s\nsqlcmd -Q "SELECT 1"\n' "$U" > "$D/unparsable-select.sh"
printf '%s\nsqlcmd -Q "DELETE FROM dbo.X"\n' "$U" > "$D/unparsable-delete.sh"
printf '%s\nsqlcmd -Q "DROP TABLE dbo.X"\n' "$U" > "$D/unparsable-drop.sh"
printf '%s\nbash ./del.sh\n' "$U" > "$D/unparsable-nested.sh"
printf '%s\nbash \\\n  ./del.sh\n' "$U" > "$D/unparsable-continued.sh"
printf '%s\necho "x ./tool.sh\n' "$U" > "$D/unparsable-ref.sh"
printf '%s\ncd sub\nbash del.sh\n' "$U" > "$D/r/unparsable-cd.sh"
printf 'cd sub\nbash -c "echo it'\''s ok"\nbash del.sh\n' > "$D/r/retry-cd.sh"
printf 'sqlcmd -Q "DROP TABLE dbo.Old"\n' > "$D/r/drop.sh"
printf 'echo read-only\n' > "$D/r/sub/drop.sh"
printf "%s\ncat <<'EOF'\ncd sub\nEOF\nbash ./drop.sh\n" "$U" > "$D/r/unparsable-heredoc-cd.sh"
printf '%s\nif true; then bash ./drop.sh; fi\n' "$U" > "$D/r/unparsable-then.sh"
printf "cat <<EOF\n# \$(sqlcmd -Q \"UPDATE dbo.X SET A=1\")\nIt's text\nEOF\n" > "$D/heredoc-hash.sh"
# The caller continues after an unparsable script; cwd != project in every case.
mkdir -p "$D/a" "$D/b/sub" "$D/c/sub" "$D/n/sub" "$D/e/sub" "$D/i/sub" "$D/t/other/sub" \
  "$D/f" "$D/k" "$D/g/sub"
DEL='sqlcmd -Q "DELETE FROM dbo.X"'; DROP='sqlcmd -Q "DROP TABLE dbo.X"'; RO='echo read-only'
printf '%s\ncat <<EOF\ncd nowhere\nEOF\n' "$U" > "$D/a/u.sh"
printf '%s\n' "$DEL" > "$D/a/del.sh"
printf '%s\ncd sub\n' "$U" > "$D/b/s.sh"
printf '%s\n' "$DROP" > "$D/b/sub/del.sh"
printf '%s\ncd sub\n' "$U" > "$D/c/s.sh"
printf '%s\n' "$DEL" > "$D/c/del.sh"
printf '%s\n' "$DROP" > "$D/c/sub/del.sh"
printf '%s\ncat <<EOF\ncd sub\nEOF\n' "$U" > "$D/n/u.sh"
printf '%s\n' "$DROP" > "$D/n/del.sh"
printf '%s\n' "$DEL" > "$D/n/sub/del.sh"
printf '%s\ncd sub\necho "x ./t.sh\n' "$U" > "$D/e/s.sh"
printf '%s\n' "$DROP" > "$D/e/del.sh"
printf '%s\n' "$RO" > "$D/e/sub/del.sh"
printf '%s\ncat <<EOF\ncd nowhere\nEOF\ncd sub\nbash del.sh\n' "$U" > "$D/i/u.sh"
printf '%s\n' "$DROP" > "$D/i/sub/del.sh"
printf '%s\ncd other\n' "$U" > "$D/t/s.sh"
cp "$D/r/retry-cd.sh" "$D/t/other/retry.sh"
printf '%s\n' "$DROP" > "$D/t/other/sub/del.sh"
# Only the `cd` form of U: two unbalanced lines together would parse as a whole.
printf '%s\necho ok\n' "${U/X=/cd }" > "$D/f/s.sh"
printf '%s\n' "$RO" > "$D/f/ok.sh"
printf '%s\ncat <<EOF\ncd a\ncd b\ncd c\ncd d\nEOF\n' "$U" > "$D/k/u.sh"
printf '%s\n' "$RO" > "$D/k/ok.sh"
printf '%s\n(cd sub && echo ok)\n' "$U" > "$D/g/u.sh"
mkdir -p "$D/h/sub" "$D/m/sub"
printf '%s\ncd sub\n# helper: y.sh\n' "$U" > "$D/h/u.sh"
printf 'cd other\n' > "$D/h/sub/y.sh"
printf '%s\n' "$DROP" > "$D/h/sub/del.sh"
printf '%s\ncd sub\n' "$U" > "$D/m/s.sh"
printf 'cd x\n' > "$D/m/y.sh"
printf 'bash del.sh\n' > "$D/m/sub/y.sh"
printf '%s\n' "$DROP" > "$D/m/sub/del.sh"
printf "bash <<'EOF'\nit's run\nEOF\nsqlcmd -Q \"SELECT 1\"\n" > "$D/bash-heredoc-sql.sh"
printf "cat <<'EOF' | bash\nit's run\nEOF\nsqlcmd -Q \"SELECT 1\"\n" > "$D/cat-pipe-heredoc-sql.sh"
# A script name with a space inside $(…), and an unreadable namesake among candidate dirs.
mkdir -p "$D/sp/with space" "$D/ur/sub"
printf '%s\n' "$DROP" > "$D/sp/with space/danger.sh"
printf '%s\necho "$(bash '\''./with space/danger.sh'\'')"\n' "$U" > "$D/sp/u.sh"
printf '%s\ncd sub\n' "$U" > "$D/ur/s.sh"
printf 'SELECT 1;\n' > "$D/ur/drop.sql"
printf 'DROP TABLE dbo.X;\n' > "$D/ur/sub/drop.sql"
chmod 000 "$D/ur/sub/drop.sql"
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
run deny "-- inside a [quoted identifier]" "sqlcmd -i bracket-dashes.sql"
run deny "]] escape inside [identifier]"  "sqlcmd -i bracket-escaped.sql"
run deny "/* inside a \"quoted identifier\"" "sqlcmd -i dquote-block.sql"
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
run none "fixture: delete at eol"    "bash fixture.sh"
run none "az words in shell are not SQL"  "bash az-words.sh"
run none "payload cwd decides the file"   "sqlcmd -i drop.sql" "$D/other"
run none "comments after quoted identifiers" "sqlcmd -i ident-then-comment.sql"
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
run none "bash heredoc without SQL passes" "bash bash-heredoc.sh"
run none "cat heredoc to bash without SQL passes" "bash cat-pipe-heredoc.sh"
run ask  "bash heredoc + sqlcmd stays unparsable" "bash bash-heredoc-sql.sh"
run ask  "cat heredoc to bash + sqlcmd stays" "bash cat-pipe-heredoc-sql.sh"
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
# --- Unparsable scripts ask only when they name SQL or an unresolvable script
run none "unparsable script without SQL"        "bash unparsable.sh"
run ask  "unparsable + read-only sqlcmd"        "bash unparsable-select.sh"
run ask  "unparsable + sqlcmd DELETE"           "bash unparsable-delete.sh"
run deny "unparsable + sqlcmd DROP TABLE"       "bash unparsable-drop.sh"
run ask  "unparsable + nested SQL script"       "bash unparsable-nested.sh"
run ask  "unparsable + continued nested call"   "bash unparsable-continued.sh"
run ask  "unparsable line naming a script"      "bash unparsable-ref.sh"
run deny "unparsable + cd before nested script" "bash unparsable-cd.sh" "$D/r"
run ask  "sqlcmd on a # line of an expanding heredoc" "bash heredoc-hash.sh"
run deny "cd not re-applied by a retried pass" "bash retry-cd.sh" "$D/r"
run deny "unparsable + literal cd in a heredoc"  "bash unparsable-heredoc-cd.sh" "$D/r"
run deny "unparsable + script after then"        "bash unparsable-then.sh" "$D/r"
# --- After an unparsable script cwd is restored and every possible dir is scanned
run ask  "A: literal heredoc cd, then caller script"  "bash u.sh && bash del.sh" "$D/a"
run deny "B: real cd in a sourced script"             "source s.sh && bash del.sh" "$D/b"
run deny "namesake: sub DROP beats caller DELETE"     "source s.sh && bash del.sh" "$D/c"
run deny "namesake: caller DROP beats sub DELETE"     "bash u.sh && bash del.sh" "$D/n"
run deny "early return restores cwd"                  "bash s.sh && bash del.sh" "$D/e"
run deny "literal then real cd inside the fallback"   "bash u.sh" "$D/i"
run deny "retry keeps candidate dirs unshifted"       "source s.sh && bash retry.sh" "$D/t"
run ask  "unreadable cd line asks for later scripts"  "bash s.sh && bash ok.sh" "$D/f"
run ask  "too many candidate dirs ask"                "bash u.sh && bash ok.sh" "$D/k"
run none "target: subshell cd alone"                  "bash u.sh" "$D/g"
run none "target: no cd, harmless chain"              "bash unparsable.sh && bash r/del.sh"
run deny "re-scanned helper keeps the real cd dir"    "source u.sh && bash del.sh" "$D/h"
run deny "namesakes each start from the caller dirs"  "source s.sh && bash y.sh" "$D/m"
run deny "joined -Qtext"                              "sqlcmd -Q\"DROP TABLE dbo.X\""
run deny "joined -ifile"                              "sqlcmd -idrop.sql"
# --- Hardening found while merging
run deny "script with a space in \$() of an unparsable script" "bash u.sh" "$D/sp"
run deny "script with a space in \$()"            "echo \"\$(bash './with space/danger.sh')\"" "$D/sp"
run ask  "unreadable namesake among candidate dirs" "source s.sh && sqlcmd -i drop.sql" "$D/ur"
exit $fail
