#!/usr/bin/env bash
# deterministic ask-tier classes, runner anchor, settings refusal, clipped-prompt recovery.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-lib.sh"
smoke_init

# ---- (190) static: compile, size caps, class names, runner sources, egress hook test ----------
L="$SRC/.claude/lib"
python3 -I -c 'import sys
for f in sys.argv[1:]:
    compile(open(f, encoding="utf-8").read(), f, "exec")' "$L/team_prompt.py" \
  "$L/team_prompt_check.py" "$L/team_prompt_classes.py" "$L/team_prompt_settings.py" \
  "$L/team_transcript.py" "$SRC/.claude/hooks/lib/guard_team_egress.py" > "$WORK/out" 2>&1 \
  || fail "python compile"
cap() { [ "$(wc -l < "$1")" -le "$2" ] || fail "$(basename "$1") has more than $2 lines"; }
cap "$L/team-run.sh" 500; cap "$L/team_prompt.py" 500; cap "$L/team_transcript.py" 500
for f in team_prompt_check.py team_prompt_classes.py team_prompt_settings.py team-anchor.sh \
  team-answer.sh team-question-lib.sh team-lib.sh team-watch.sh team-new.sh \
  team-next.sh tests/team-smoke-12.sh ../hooks/lib/guard_team_egress.py; do cap "$L/$f" 500; done
[ "$(python3 -I "$L/team_prompt_classes.py" names | tr '\n' ' ' | sed 's/ $//')" \
  = "$(sed -n 's/^TEAM_CLASSES="\(.*\)"$/\1/p' "$L/team-lib.sh")" ] || fail "class names differ"
for t in '. "$root/.claude/lib/team-lib.sh"' '. "$root/.claude/lib/team-anchor.sh"' \
  'team_anchor_launch "$root"' 'team_anchor_planner "$root"'; do
  grep -qF -- "$t" "$L/team-run.sh" || fail "team-run.sh lacks $t"
done
for f in team-run.sh team-merge-check.sh; do grep -qF '. "$root/.claude/lib/team-lib.sh"' "$L/$f" \
  && ! grep -qF '. "$CLONE/.claude/lib/team-lib.sh"' "$L/$f" || fail "$f: clone team-lib.sh"; done
(cd "$SRC" && bash .claude/lib/tests/guard-team-egress-test.sh) > "$WORK/out" 2>&1 \
  || fail "guard-team-egress-test.sh"
echo "team-smoke-12: (190) static OK"

# ---- fixture ----------------------------------------------------------------------------------
smoke_team AB-1248 chore/AB-1248-x
BR=chore/AB-1248-x; LINE=develop
RUN_ID=alfa-20261025-000000; echo "$RUN_ID" > "$TD/run"; RD="$TD/runs/$RUN_ID"; mkdir -p "$RD"
CREAL="$(cd "$CLONE" && pwd -P)"
ANCHOR="$MAIN/.agents/team/anchors/alfa.json"
PC="python3 -I $SRC/.claude/lib/team_prompt_check.py"
Q="bash .claude/lib/team-question.sh"
RULE="$(printf '─%.0s' $(seq 120))"; DASH="$(printf '╌%.0s' $(seq 120))"
export STUB_TMUX_ALIVE=0 STUB_PANE="$WORK/pane"
printf '%s\n' '**Integration:** `develop`' '**Maintenance:** `rc/rc` — old' '**Retired:** `feature/old`' \
  '**Protected:** `develop`, `feature/old`, `rc/rc`, `legacy`, `master`' > "$MAIN/CLAUDE.md"
SETTINGS='{"permissions": {"allow": ["Bash(bash -n:*)"], "ask": ["Bash(git merge --no-ff*)", '
SETTINGS="$SETTINGS"'"Bash(bash scripts/azure/monitoring/x-diagnose.sh*)"], '
SETTINGS="$SETTINGS"'"deny": ["Bash(git rebase*)"]}, "hooks": {}}'
jq '.teams.policy.classes = {merge_line: {enabled: true}, allow_offline: {enabled: true}, add_ask:
  {enabled: true}, prod_diagnose: {enabled: true, dir: "scripts/azure/monitoring/", privileged: "az-write\\.sh"}}' \
  "$MAIN/.claude/project-profile.json" > "$WORK/p" && mv "$WORK/p" "$MAIN/.claude/project-profile.json"
anchor() { (. "$MAIN/.claude/lib/team-anchor.sh"; "$@"); }
publish() {  # publish <message> — commit the clone's changes and make them the line, both sides
  git -C "$CLONE" add -A && git -C "$CLONE" commit --quiet -m "$1"
  git -C "$CLONE" push --quiet origin "HEAD:refs/heads/$LINE"
  git -C "$CLONE" fetch --quiet origin && git -C "$MAIN" fetch --quiet origin
}
keyc() { grep -c '^tmux send-keys ' "$STUB_LOG" || true; }
perm() {  # perm <description> <command line>… — a Bash permission prompt in the real layout
  local d="$1" l; shift
  { echo "$RULE"; echo " Bash command"; echo " $d"; echo "$DASH"
    for l in "$@"; do echo " │ $l"; done
    echo "$DASH"; echo " This command requires approval"; echo " Do you want to proceed?"
    echo " ❯ 1. Yes"; echo "   2. No"; echo " Esc to cancel · Tab to amend"; } > "$WORK/pane"
}
LAST=""; N=0
pend() {  # pend <tool> <json input> [cwd] — the role's single pending call
  [ -z "$LAST" ] || tool_done "$SID" "$LAST"
  N=$((N + 1)); LAST="t$N"
  pending_tool "$SID" "$LAST" "$1" "$2" "${3-$CREAL}"
}
bashp() {  # bashp <command> [cwd] — pending Bash call + prompt; a newline shows as two lines
  local IFS=$'\n'
  pend Bash "$(jq -cn --arg c "$1" '{command: $c, description: "Run it"}')" "${2-$CREAL}"
  # shellcheck disable=SC2046
  perm "Run it" $(printf '%s\n' "$1")
}
rows() {  # rows <file> <old> <new> — the whole lines the edit changes, as Claude Code shows them
  python3 -I -c 'import sys
p, o, n = sys.argv[1:]
try:
    t = open(p, encoding="utf-8").read()
except OSError:
    t = o
i = max(t.find(o), 0)
a, b = t.rfind("\n", 0, i) + 1, t.find("\n", i + len(o))
b = len(t) if b < 0 else b
for sign, text in (("-", t[a:b]), ("+", t[a:i] + n + t[i + len(o):b])):
    for line in text.split("\n"):
        print("  1 %s%s" % (sign, line))' "$@"
}
editp() {  # editp <file_path> <old_string> <new_string> [shown name]
  pend Edit "$(jq -cn --arg f "$1" --arg o "$2" --arg n "$3" \
    '{file_path: $f, old_string: $o, new_string: $n}')"
  { echo "$RULE"; echo " Edit file"; echo " ${4:-.claude/settings.json}"; echo "$DASH"
    rows "$1" "$2" "$3"; echo "$DASH"
    echo " Do you want to make this edit to $(basename "$1")?"
    echo " ❯ 1. Yes"; echo "   2. No"; echo " Esc to cancel"; } > "$WORK/pane"
}
writep() {  # writep <content> — a pending Write of the clone settings.json
  pend Write "$(jq -cn --arg f "$CREAL/.claude/settings.json" --arg c "$1" \
    '{file_path: $f, content: $c}')"
  { echo "$RULE"; echo " Write file"; echo " .claude/settings.json"; echo "$DASH"
    echo "  1 ${1:0:1}"; echo "$DASH"; echo " Do you want to make this edit to settings.json?"
    echo " ❯ 1. Yes"; echo "   2. No"; echo " Esc to cancel"; } > "$WORK/pane"
}
cls() {  # cls [checker args] → RC, $WORK/out: the sender's tier-1 policy check
  set +e
  $PC "$CLONE" --strict --transcript "$T" --classes --main "$MAIN" "$@" < "$WORK/pane" \
    > "$WORK/out" 2>&1
  RC=$?; set -e
}
yes_class() { cls; expect 0 "policy-class: $1" "$2"; }
no_class() {  # no_class <label> [text] — refused, so the sender answers 7 (Operator)
  cls; expect 1 "${2:-}" "$1"; ! has "policy-class:" "$WORK/out" || fail "$1: a class was given"
}
SET="$CREAL/.claude/settings.json"
# ---- (191) runner anchor ----------------------------------------------------------------------
jq -e --arg b "$BR" --arg s "$BASE" '.ticket == "AB-1248" and .branch == $b
  and .line == "develop" and .base_sha == $s and (has("run") | not)' "$ANCHOR" \
  >/dev/null || fail "team-new wrote no anchor"
SID=sid-1248; session coder 1 "$BASE" "$SID"; T="$(transcript "$SID")"
anchor team_anchor_launch "$MAIN" alfa "$CLONE" "$RUN_ID" coder 1 "$SID"
jq -e --arg r "$RUN_ID" '.run == $r and .role == "coder" and .attempt == 1
  and .session_id == "sid-1248" and (.mismatch | not)' "$ANCHOR" >/dev/null || fail "anchor launch"
mkrec planner "$BASE"
jq '.artifacts = [".agents/plans/active/p.md"]' "$RD/planner-1-1.json" > "$WORK/r.json"
mv "$WORK/r.json" "$RD/planner-1-1.json"
anchor team_anchor_planner "$MAIN" alfa "$RD/planner-1-1.json"
jq -e --arg s "$BASE" '.planner.record == "planner-1-1.json" and .planner.output_rev == $s' \
  "$ANCHOR" >/dev/null || fail "anchor planner entry"
jq '.output_rev = "other" | .seq = 2' "$RD/planner-1-1.json" > "$RD/planner-1-2.json"
anchor team_anchor_planner "$MAIN" alfa "$RD/planner-1-2.json"
jq -e '.planner.record == "planner-1-1.json"' "$ANCHOR" >/dev/null || fail "planner overwritten"
anchor team_anchor_launch "$MAIN" alfa "$CLONE" alfa-20261025-111111 coder 1 "$SID"
jq -e 'has("planner") | not' "$ANCHOR" >/dev/null || fail "a new run kept the planner entry"
anchor team_anchor_launch "$MAIN" alfa "$CLONE" "$RUN_ID" coder 1 "$SID"
echo "team-smoke-12: (191) anchor OK"

printf '%s\n' "$SETTINGS" | jq . > "$CLONE/.claude/settings.json"
publish "fixture settings"
# ---- (192) merge-line -------------------------------------------------------------------------
MERGE="git merge --no-ff origin/$LINE"
bashp "$MERGE"; yes_class merge-line "merge-line positive"
cls --report; expect 0 "class: merge-line" "merge-line report"
bashp "$MERGE --no-edit"; yes_class merge-line "merge-line --no-edit"
for c in "$MERGE -X ours" "git rebase origin/$LINE" "git merge --no-ff
origin/$LINE" "$MERGE &" "$MERGE; true" "($MERGE)"; do
  bashp "$c"; no_class "merge-line negative: $c"
done
bashp "git rebase origin/$LINE"; no_class "rebase" "deny-tier"
git -C "$CLONE" commit --quiet --allow-empty -m other
git -C "$CLONE" fetch --quiet . "HEAD:refs/remotes/origin/$LINE"
bashp "$MERGE"; no_class "rewritten clone origin ref" "differs from the main checkout"
git -C "$CLONE" fetch --quiet origin
git -C "$CLONE" update-ref "refs/replace/$(git -C "$CLONE" rev-parse HEAD)" \
  "$(git -C "$CLONE" rev-parse HEAD~1)"
bashp "$MERGE"; no_class "replace ref" "replace refs"
git -C "$CLONE" update-ref -d "refs/replace/$(git -C "$CLONE" rev-parse HEAD)"
bashp "$MERGE" "$CREAL/scripts"; no_class "cwd off the clone root" "cwd"
cp "$TD/team.json" "$WORK/team.json.bak"; cp "$ANCHOR" "$WORK/anchor.bak"
git -C "$CLONE" switch --quiet -c feature/old
for f in "$TD/team.json" "$ANCHOR"; do
  jq '.branch = "feature/old"' "$f" > "$WORK/j" && mv "$WORK/j" "$f"
done
bashp "$MERGE"; no_class "protected + retired branch" "working branch"
git -C "$CLONE" switch --quiet "$BR"
cp "$WORK/team.json.bak" "$TD/team.json"; cp "$WORK/anchor.bak" "$ANCHOR"
jq '.line = "rc/rc"' "$WORK/team.json.bak" > "$TD/team.json"
bashp "$MERGE"; no_class "clone team.json line forged" "differs from the runner anchor"
jq '.line = "rc/rc" | .ticket = "AB-1"' "$WORK/team.json.bak" > "$TD/team.json"
anchor team_anchor_launch "$MAIN" alfa "$CLONE" "$RUN_ID" qa 1 "$SID"
jq -e '.mismatch == true and .ticket == "AB-1248" and .line == "develop"' "$ANCHOR" \
  >/dev/null || fail "a launch rewrote the anchor from a forged team.json"
cp "$WORK/team.json.bak" "$TD/team.json"
bashp "$MERGE"; no_class "anchor mismatch is sticky" "differs from the runner anchor"
mv "$ANCHOR" "$WORK/anchor.mis"
bashp "$MERGE"; no_class "anchor missing" "no runner anchor"
cp "$WORK/anchor.bak" "$ANCHOR"
session coder 1 "$BASE" sid-other
bashp "$MERGE"; no_class "anchor session differs" "session differs"
session coder 1 "$BASE" "$SID"
bashp "$MERGE"; yes_class merge-line "merge-line restored"
echo "team-smoke-12: (192) merge-line OK"
# ---- (193) allow-offline and the settings refusal ---------------------------------------------
mkdir -p "$CLONE/.claude/lib/tests"
printf '#!/usr/bin/env bash\necho ok\n' > "$CLONE/.claude/lib/tests/x-smoke.sh"
printf 'echo hi\n' > "$CLONE/.claude/lib/x.sh"
A0='"Bash(bash -n:*)"'
allow() { editp "$SET" "$A0" "$A0, $1"; }
allow '"Bash(shellcheck -x .claude/lib/x.sh)"'; yes_class allow-offline "allow-offline positive"
allow '"Bash(bash -n .claude/lib/x.sh)"'; yes_class allow-offline "allow-offline bash -n"
printf '* filter=x\n' > "$CLONE/.gitattributes"; echo changed >> "$CLONE/README"
git -C "$CLONE" config filter.x.clean "touch $WORK/marker; cat"
allow '"Bash(bash -n .claude/lib/x.sh)"'; yes_class allow-offline "allow-offline, clean filter set"
[ ! -e "$WORK/marker" ] || fail "a clone clean filter ran while the diff set was read"
git -C "$CLONE" config --unset filter.x.clean; rm -f "$CLONE/.gitattributes"
git -C "$CLONE" checkout --quiet -- README
for e in '"Bash(bash -n *)"' '"Bash(bash -n README)"' '"Bash(bash -n ../x.sh)"' \
  '"Bash(bash -n:*.sh)"' '"Bash(bash .claude/lib/x.sh)"'; do
  allow "$e"; no_class "allow-offline negative $e" "refuse (settings)"
done
writep "$(jq -c '.permissions.allow += ["Bash(bash -n .claude/lib/x.sh)"]
  | .permissions.deny = []' "$CLONE/.claude/settings.json")"
no_class "deny entry removed with an allow entry" "refuse (settings)"
# Decision E: running a script is not offline-provable, even an `echo ok` smoke in the diff.
allow '"Bash(bash .claude/lib/tests/x-smoke.sh)"'
no_class "smoke allow (decision E)" "not an offline check of one file"
echo 'curl https://x' >> "$CLONE/README"  # tracked, edited but not staged
allow '"Bash(bash -n README)"'; yes_class allow-offline "unstaged tracked edit is in the diff"
git -C "$CLONE" checkout --quiet -- README
echo '{}' > "$CLONE/.claude/settings.local.json"
editp "$CREAL/.claude/settings.local.json" '{}' '{"permissions": {"allow": ["Bash(bash -n x)"]}}' \
  .claude/settings.local.json
no_class "settings.local.json edit" "refuse (settings): settings.local.json"
ln -s .claude/settings.json "$CLONE/alias.json"
editp "$CREAL/alias.json" '"hooks": {}' '"hooks": {"x": 1}' alias.json
no_class "symlinked settings alias" "link or alias"
set +e; $PC "$CLONE" --strict --transcript "$T" < "$WORK/pane" > "$WORK/out" 2>&1; RC=$?; set -e
expect 1 "refuse (settings): settings.json" "alias refused without --classes"
echo "team-smoke-12: (193) allow-offline OK"
# ---- (194) add-ask ----------------------------------------------------------------------------
M0='"Bash(git merge --no-ff*)"'
editp "$SET" "$M0" "$M0, \"Bash(az webapp restart*)\""; yes_class add-ask "add-ask positive"
editp "$SET" "$M0, " '"Bash(az webapp restart*)", '; no_class "ask entry removed"
writep "$(jq -c '.permissions.allow += ["Bash(bash -n .claude/lib/x.sh)"]
  | .permissions.ask += ["Bash(az x*)"]' "$CLONE/.claude/settings.json")"
no_class "allow and ask in one edit" "refuse (settings)"
echo "team-smoke-12: (194) add-ask OK"

# ---- (195) settings refusal without --classes and from the screen -----------------------------
allow '"Bash(bash -n *)"'
set +e; $PC "$CLONE" --strict --transcript "$T" < "$WORK/pane" > "$WORK/out" 2>&1; RC=$?; set -e
expect 1 "refuse (settings)" "wildcard allow edit, strict without --classes"
set +e; $PC "$CLONE" < "$WORK/pane" > "$WORK/out" 2>&1; RC=$?; set -e
expect 1 "refuse (settings)" "wildcard allow edit, non-strict"
set +e; $PC "$CLONE" --block < "$WORK/pane" > "$WORK/out" 2>&1; RC=$?; set -e
expect 0 ".claude/settings.json" "--block still prints the settings edit"
bashp "cp /tmp/s .claude/settings.json"; no_class "settings rewrite via Bash" "via Bash"
set +e; $PC "$CLONE" < "$WORK/pane" > "$WORK/out" 2>&1; RC=$?; set -e
expect 1 "refuse (settings)" "settings rewrite via Bash, non-strict"
echo "team-smoke-12: (195) settings refusal OK"

# ---- (195b) review A: quoting and path spelling are removed before the rule match ------------
strict() {  # strict → RC, $WORK/out: the tier-1 check without classes, as the sender runs it
  set +e; $PC "$CLONE" --strict --transcript "$T" --main "$MAIN" < "$WORK/pane" > "$WORK/out" 2>&1
  RC=$?; set -e; }
for c in 'bash "scripts/azure/monitoring/x-diagnose.sh" --env hebe-prod' \
  "git \"merge\" --no-ff origin/$LINE" 'bash ./scripts//azure/monitoring/x-diagnose.sh' \
  "g''it merge --no-ff origin/$LINE" "git merge \\
  --no-ff origin/$LINE" "bash \$'scripts/azure/monitoring/x-diagnose.sh'" \
  "git -c a.b=1 merge --no-ff origin/$LINE" "bash -c \"git merge --no-ff origin/$LINE\"" \
  "git > /dev/null merge --no-ff origin/$LINE" 'bash -- scripts/azure/monitoring/x-diagnose.sh'; do
  bashp "$c"; strict; expect 1 "ask-tier" "quoted or respelled: $c"
done
for c in "git -C . rebase -i HEAD~2" "/usr/bin/git rebase origin/$LINE" "git \\
  rebase -i HEAD~3"; do
  bashp "$c"; strict; expect 1 "deny-tier" "respelled deny: $c"
done
bashp 'echo "unbalanced'; no_class "unparsable quoting" "cannot be parsed"
bashp "printf x > .claude/\$'setti\\x6egs.json'"; no_class "ANSI-C escape" "ANSI-C escapes"
bashp "# check the user's config
ls -la"; cls --report; expect 0 "class: not needed" "an apostrophe in a comment parses"
perm "Show the branch's status" "git status"
set +e; $PC "$CLONE" < "$WORK/pane" > "$WORK/out" 2>&1; RC=$?; set -e
expect 0 "" "an apostrophe in the description, non-strict"
echo "team-smoke-12: (195b) canonical command OK"

# ---- (195c) review B: every spelling of a settings write via Bash ----------------------------
for c in 'printf x > .claude/./settings.json' 'printf x > .claude/settings"".json' \
  'cd .claude && jq . settings.json' 'cp /tmp/settings.json .claude/' \
  'cp x .claude/settings.local.json' 'jq --arg f=settings.json . x' \
  'printf x > .claude/settings.js*'; do
  bashp "$c"; no_class "settings via Bash: $c" "refuse (settings)"
done
bashp 'cat AcmeShop2.API/appsettings.json src/local.settings.json'
cls --report; expect 0 "class: not needed" "appsettings.json and local.settings.json pass"
echo "team-smoke-12: (195c) settings via Bash OK"

# ---- (195d) review C: an Edit/Write outside the clone, a Bash path under the main trust dirs --
W0="$MAIN/.agents/team/watch/state.json"; mkdir -p "${W0%/*}"; [ -f "$W0" ] || echo '{}' > "$W0"
for f in "$ANCHOR" "$W0" "$MAIN/.claude/settings.json"; do
  editp "$f" "{" "{ " "$f"; no_class "Edit outside the clone: $f" "refuse (outside clone)"
done
MB="../$(basename "$MAIN")"
for c in "cp /dev/null $ANCHOR" "cat $MB/.claude/lib/team-lib.sh" \
  "touch $MAIN/.agents/team/watch/x" "git -C $MB fetch . HEAD:refs/remotes/origin/$LINE" \
  "printf x >> $MB/CLAUDE.md" "cp x $MAIN/.Agents/team/anchors/alfa.json" \
  "cp x $MB/.agents/tea?/anchors/alfa.json" "bash -c \"touch $MB/.agents/team/watch/x\""; do
  bashp "$c"; no_class "Bash under a main trust dir: $c" "refuse (outside clone)"
done
printf 'a line\n' > "$CLONE/notes.txt"; editp "$CREAL/notes.txt" "a line" "b line" notes.txt
cls --report; expect 0 "class: not needed" "an Edit inside the clone stays tier 1"
echo "team-smoke-12: (195d) outside the clone OK"

# ---- (195e) review D: the prompt is bound to its own pending edit; a recovered one takes none --
editp "$SET" "$A0" "$A0, \"Bash(bash -n .claude/lib/x.sh)\""
pend Edit "$(jq -cn --arg f "$CREAL/notes.txt" '{file_path: $f, old_string: "a line",
  new_string: "b line"}')"
no_class "settings.json prompt, README-like pending edit" "no prompt event"
pend Edit "$(jq -cn --arg f "$SET" --arg o "$A0" '{file_path: $f, old_string: $o,
  new_string: ($o + ", \"Bash(bash -n README)\"")}')"
no_class "same file, other rows on screen" "screen rows differ"
editp "$SET" "$(grep -F 'x-diagnose' "$CLONE/.claude/settings.json")" ""  # an ask entry deleted
pend Edit "$(jq -cn --arg f "$SET" --arg o "$M0" '{file_path: $f, old_string: $o,
  replace_all: true, new_string: ($o + ", \"Bash(az x*)\"")}')"
no_class "replace_all add-ask forged behind a deletion" "screen rows differ"
L0="$(grep -F 'git merge --no-ff' "$CLONE/.claude/settings.json")"
editp "$SET" "$L0" "$L0
${L0%%\"*}\"Bash(az webapp restart*)\","
yes_class add-ask "whole-line add-ask edit, full header"
sed "1,/^$DASH\$/d" "$WORK/pane" > "$WORK/pane-clip"; cp "$WORK/pane-clip" "$WORK/pane"
python3 -I "$SRC/.claude/lib/team_prompt.py" parse --transcript "$T" < "$WORK/pane" \
  | jq -e '.recovered == "transcript"' >/dev/null || fail "the clipped edit was not recovered"
no_class "recovered prompt" "class: recovered prompt — header off screen"
cp "$ANCHOR" "$CLONE/alfa.json"; editp "$ANCHOR" "{" "{ " "$ANCHOR"  # the screen: main's anchor
pend Edit "$(jq -cn --arg f "$CREAL/alfa.json" \
  '{file_path: $f, old_string: "{", new_string: "{ "}')"
no_class "forged pending edit of a clone look-alike" "screen path differs"
pend Write "$(jq -cn --arg f "$CREAL/notes.md" '{file_path: $f, content: "---\ntitle: x\n---\n"}')"
printf '%s\n Create file\n notes.md\n%s\n  1 ---\n  2 title: x\n  3 ---\n%s\n' "$RULE" "$DASH" \
  "$DASH" > "$WORK/pane"
printf ' Do you want to create notes.md?\n ❯ 1. Yes\n   2. No\n Esc to cancel\n' >> "$WORK/pane"
cls --report; expect 0 "class: not needed" "a new file whose rows start with -"
rm -f "$CLONE/notes.txt" "$CLONE/alfa.json"
echo "team-smoke-12: (195e) prompt binding OK"

# ---- (196) prod-diagnose ----------------------------------------------------------------------
git -C "$CLONE" clean --quiet -fd .claude/lib && rm -f "$CLONE/alias.json"
rm -f "$CLONE/.claude/settings.local.json"
M="$CLONE/scripts/azure/monitoring"; mkdir -p "$M/lib" "$M/sql"
printf '#!/usr/bin/env bash\n. "$(dirname "$0")/lib/c.sh"\necho diagnose "$@"\n' \
  > "$M/x-diagnose.sh"
printf 'c() { :; }\n' > "$M/lib/c.sh"; printf 'SELECT 1;\n' > "$M/sql/q.sql"
publish "diagnose script"
DIAG="bash scripts/azure/monitoring/x-diagnose.sh --env hebe --from 2026-10-25T08:00:00Z"
mkdir -p "$CLONE/.agents/plans/active"
printf '# plan\n\nRun `%s` first.\n\n```bash\n%s --last 1h\n```\n' "$DIAG" "$DIAG" \
  > "$CLONE/.agents/plans/active/p.md"
git -C "$CLONE" add -f .agents/plans/active/p.md && git -C "$CLONE" commit --quiet -m plan
PREV="$(git -C "$CLONE" rev-parse HEAD)"
jq --arg r "$PREV" '.output_rev = $r' "$RD/planner-1-1.json" > "$WORK/r.json"
jq 'del(.planner)' "$ANCHOR" > "$WORK/j" && mv "$WORK/j" "$ANCHOR"
anchor team_anchor_planner "$MAIN" alfa "$WORK/r.json"
bashp "$DIAG"; yes_class prod-diagnose "prod-diagnose inline span"
bashp "$DIAG --last 1h"; yes_class prod-diagnose "prod-diagnose fenced line"
printf 'Run `%s --env other`.\n' "$DIAG" >> "$CLONE/.agents/plans/active/p.md"
bashp "$DIAG --env other"; no_class "command only in the working-tree plan" "planner artifacts"
git -C "$CLONE" checkout --quiet -- .agents/plans/active/p.md
bashp "$DIAG --extra"; no_class "extra argument"
bashp "env X=1 $DIAG"; no_class "env wrapper" "ask-tier"
bashp "nohup /bin/$DIAG"; no_class "nohup + shell path" "ask-tier"
bashp "$DIAG &"; no_class "trailing &"
printf 'SELECT 2;\n' > "$M/sql/q.sql"
bashp "$DIAG"; no_class "changed sql input" "differs from the line"
git -C "$CLONE" checkout --quiet -- scripts
touch "$M/extra.sh"
bashp "$DIAG"; no_class "extra untracked monitoring file" "diagnose files differ"
rm -f "$M/extra.sh"
echo scripts/azure/monitoring/ignored.sh >> "$CLONE/.git/info/exclude"; touch "$M/ignored.sh"
bashp "$DIAG"; no_class "git-ignored extra monitoring file" "diagnose files differ"
rm -f "$M/ignored.sh"
GOOD="$(git -C "$CLONE" rev-parse HEAD)"
printf 'echo changed\n' >> "$M/x-diagnose.sh"
git -C "$CLONE" commit --quiet -am "changed script"
git -C "$CLONE" fetch --quiet . "HEAD:refs/remotes/origin/$LINE"
bashp "$DIAG"; no_class "clone origin rewritten to a changed script" "differs from the line"
git -C "$CLONE" checkout --quiet -B "$BR" "$GOOD"; git -C "$CLONE" fetch --quiet origin
git -C "$CLONE" update-ref "refs/replace/$PREV" "$GOOD"
bashp "$DIAG"; no_class "replaced planner commit" "replace refs"
git -C "$CLONE" update-ref -d "refs/replace/$PREV"
cp "$M/x-diagnose.sh" "$WORK/trusted.sh"
printf '*.sh filter=x\n' > "$CLONE/.gitattributes"
git -C "$CLONE" config filter.x.clean "touch $WORK/marker; cat $WORK/trusted.sh"
printf 'echo evil\n' >> "$M/x-diagnose.sh"
bashp "$DIAG"; no_class "clean filter hides a change" "differs from the line"
[ ! -e "$WORK/marker" ] || fail "a clone clean filter ran during classification"
git -C "$CLONE" config --unset filter.x.clean; rm -f "$CLONE/.gitattributes"
cp "$WORK/trusted.sh" "$M/x-diagnose.sh"
bashp "$DIAG"; yes_class prod-diagnose "prod-diagnose restored"
jq 'del(.planner)' "$ANCHOR" > "$WORK/j" && cp "$WORK/j" "$WORK/anchor.np"
cp "$ANCHOR" "$WORK/anchor.pl"; cp "$WORK/anchor.np" "$ANCHOR"
bashp "$DIAG"; no_class "no planner entry in the anchor" "planner artifacts"
cp "$WORK/anchor.pl" "$ANCHOR"
printf 'c() { bash az-write.sh x; }\n' > "$M/lib/c.sh"; publish "write wrapper"
bashp "$DIAG"; no_class "script library names a write wrapper" "write wrapper"
echo "team-smoke-12: (196) prod-diagnose OK"

# ---- (197) class switches ---------------------------------------------------------------------
bashp "$MERGE"
run "$MAIN" bash .claude/lib/team-watch.sh mode class merge-line off
expect 0 "class merge-line off" "switch off"
no_class "class off" "class merge-line off"
run "$MAIN" bash .claude/lib/team-watch.sh mode class merge-line on
yes_class merge-line "class on again"
run "$MAIN" bash .claude/lib/team-watch.sh mode class nope off; expect 2 "" "unknown class"
run "$MAIN" python3 -I .claude/lib/team_prompt_classes.py switches "$MAIN"
has "merge-line=on allow-offline=on add-ask=on prod-diagnose=on" "$WORK/out" \
  || fail "switches lack the classes line"
W="$MAIN/.agents/team/watch/state.json"; cp "$W" "$WORK/state.bak"
check_switch() {  # check_switch <expected on|off> <state.json content | :dir | :absent>
  local py sh=off
  rm -rf "$W"
  case "$2" in :dir) mkdir -p "$W" ;; :absent) ;; *) printf '%s\n' "$2" > "$W" ;; esac
  py="$(python3 -I "$L/team_prompt_classes.py" switches "$MAIN" \
    | sed 's/^merge-line=\([a-z]*\).*/\1/')"
  (. "$L/team-lib.sh"; team_class_on "$MAIN" merge-line) && sh=on
  [ "$py:$sh" = "$1:$1" ] || fail "switch readers for $2: python $py, bash $sh, expected $1"
}
check_switch on :absent; check_switch on '{}'; check_switch on '{"classes":{}}'
check_switch on '{"classes":{"merge-line":"on"}}'
for v in '"off"' false null 1; do check_switch off "{\"classes\":{\"merge-line\":$v}}"; done
check_switch off '{"classes":[]}'; check_switch off 'not json'; check_switch off :dir
rm -rf "$W"; printf 'not json\n' > "$W"
[ "$(python3 -I "$L/team_prompt_classes.py" switches "$MAIN")" = \
  "merge-line=off allow-offline=off add-ask=off prod-diagnose=off" ] || fail "unreadable state"
rm -rf "$W"; cp "$WORK/state.bak" "$W"
echo "team-smoke-12: (197) switches OK"

# ---- (198) ledger end-to-end ------------------------------------------------------------------
bashp "$MERGE"
run "$MAIN" $Q alfa open coder --kind permission --anchor "Do you want to proceed?" \
  --summary "merge the line"
expect 0 "" "open merge prompt"; Q1="$(head -n 1 "$WORK/out" | cut -d' ' -f1)"
run "$MAIN" $Q alfa policy coder; expect 0 "class: merge-line" "policy coder"
has "classes: merge-line=on" "$WORK/out" || fail "policy lacks the classes line"
: > "$STUB_LOG"
run "$MAIN" $Q alfa answer "$Q1" --tier 1 --author supervisor --why "class merge-line: line" \
  --send yes
expect 0 "$Q1 state=sent" "tier-1 class answer"
[ "$(keyc)" = 1 ] || fail "class answer keys $(keyc)"
grep -qx 'class: merge-line' "$RD/questions/$Q1.md" || fail "q lacks class: merge-line"
grep -qF -- "- $Q1 [tier 1, supervisor, class merge-line]" "$RD/notes.md" || fail "notes line"
run "$MAIN" $Q alfa list; expect 0 "$Q1 coder permission tier=1" "list"
has "class=merge-line" "$WORK/out" || fail "list lacks class=merge-line"
bashp "$MERGE"
run "$MAIN" $Q alfa open coder --kind permission --anchor "Do you want to proceed?" \
  --summary "merge again"
expect 0 "" "open second merge prompt"; Q2="$(head -n 1 "$WORK/out" | cut -d' ' -f1)"
: > "$STUB_LOG"
run "$MAIN" $Q alfa answer "$Q2" --tier 3 --author operator --why "operator" --send yes
expect 5 "not sent — policy" "tier 3 takes no class"; [ "$(keyc)" = 0 ] || fail "tier 3 keys"
! grep -q '^class: ' "$RD/questions/$Q2.md" || fail "tier 3 recorded a class"
echo "team-smoke-12: (198) ledger OK"

# ---- (199) re-bind before the first key -------------------------------------------------------
bashp "$MERGE"
run "$MAIN" $Q alfa open coder --kind permission --anchor "Do you want to proceed?" \
  --summary "merge, then the prompt changes"
expect 0 "" "open re-bind prompt"; Q3="$(head -n 1 "$WORK/out" | cut -d' ' -f1)"
perm "Run it" "git status" > /dev/null; cp "$WORK/pane" "$WORK/pane2"
perm "Run it" "$MERGE"
: > "$STUB_LOG"; echo 0 > "$WORK/capn"
# The sender's second capture is the re-bind: the stub swaps the prompt just before it.
{ echo "n=\$(( \$(cat '$WORK/capn') + 1 )); echo \"\$n\" > '$WORK/capn'"
  echo "[ \"\$n\" -lt 2 ] || cp '$WORK/pane2' '$WORK/pane'"; } > "$WORK/oncap.sh"
export STUB_ON_CAPTURE="bash $WORK/oncap.sh"
run "$MAIN" $Q alfa answer "$Q3" --tier 1 --author supervisor --why "class merge-line" --send yes
unset STUB_ON_CAPTURE
expect 5 "prompt changed during classification" "prompt replaced during classification"
[ "$(keyc)" = 0 ] || fail "re-bind refusal sent keys"
echo "team-smoke-12: (199) re-bind OK"

# ---- (200) point (a): a clipped prompt read from the role transcript --------------------------
PY="$SRC/.claude/lib/team_prompt.py"; CLIP="$FIX/perm-clipped.txt"
SID=sid-clip; session coder 1 "$BASE" "$SID"; T="$(transcript "$SID")"; LAST=""
sed -n 's/^ *│ \{0,1\}//p' "$CLIP" > "$WORK/visible"
pj() {  # pj <pane> <transcript|-> <jq condition>
  python3 -I "$PY" parse --transcript "$2" < "$1" > "$WORK/p.json"
  jq -e "$3" "$WORK/p.json" >/dev/null || { cp "$WORK/p.json" "$WORK/out"; fail "parse: $3"; }
}
UNREAD='.fp == "v2:unreadable" and .reason == "unreadable: prompt header not on screen"'
pend Bash "$(jq -cn --rawfile v "$WORK/visible" '{command: ("S=/x; PROMPT=\"head\n" + $v + "\""),
  description: "Codex review"}')"
pj "$CLIP" "$T" '.complete and .kind == "permission" and .recovered == "transcript"
  and .header == "Bash command" and .cursor == 1 and (.fp | startswith("v2:"))
  and .fp != "v2:unreadable"'
FPA="$(jq -r .fp "$WORK/p.json")"
cp "$CLIP" "$WORK/pane"
run "$MAIN" $Q alfa open coder --kind permission --anchor "Do you want to proceed?" \
  --summary "clipped prompt"
expect 0 "" "open clipped prompt"; Q4="$(head -n 1 "$WORK/out" | cut -d' ' -f1)"
grep -qx "fingerprint: $FPA" "$RD/questions/$Q4.md" || fail "open and the sender parse differ"
pj "$CLIP" - "$UNREAD"; pj "$CLIP" "$WORK/missing.jsonl" "$UNREAD"
pend Bash "$(jq -cn --rawfile v "$WORK/visible" \
  '{command: ($v | split("\n") | reverse | join("\n"))}')"
pj "$CLIP" "$T" "$UNREAD"
pend Bash "$(jq -cn --rawfile v "$WORK/visible" '{command: $v}')"
pending_tool "$SID" t-extra Edit '{"file_path":"/x/a.txt","old_string":"a","new_string":"b"}'
pj "$CLIP" "$T" "$UNREAD"
tool_done "$SID" t-extra
{ echo "  12 -old line"; echo "  12 +new line"; echo "$DASH"
  echo " Do you want to make this edit to settings.json?"
  echo " ❯ 1. Yes"; echo "   2. No"; echo " Esc to cancel"; } > "$WORK/clip-edit"
pend Edit '{"file_path":"/x/.claude/settings.json","old_string":"old line","new_string":"new line"}'
pj "$WORK/clip-edit" "$T" '.complete and .header == "Edit file" and .recovered == "transcript"
  and .body == ["/x/.claude/settings.json"]'
pend Edit '{"file_path":"/x/.claude/other.json","old_string":"old line","new_string":"new line"}'
pj "$WORK/clip-edit" "$T" "$UNREAD"
tool_done "$SID" "$LAST"
echo "team-smoke-12: (200) clipped prompt OK"
echo "team-smoke-12: OK"
