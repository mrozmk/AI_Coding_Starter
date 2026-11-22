#!/usr/bin/env bash
# overwrite prompts, parallel same-file Edits and the wrapped Tip parse and pass the strict
# check against exactly their own pending call; anything contradicting or insufficient stays
# unreadable or refused. Cases (a)-(f).
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-lib.sh"
smoke_init
smoke_team AB-1322 chore/AB-1322-x
RUN_ID=alfa-20261104-000000; echo "$RUN_ID" > "$TD/run"; mkdir -p "$TD/runs/$RUN_ID"
CREAL="$(cd "$CLONE" && pwd -P)"; MREAL="$(cd "$MAIN" && pwd -P)"
L="$SRC/.claude/lib"; PY="python3 -I $L/team_prompt.py"; PC="python3 -I $L/team_prompt_check.py"
RULE="$(printf '─%.0s' $(seq 80))"; DASH="$(printf '╌%.0s' $(seq 80))"
FOOT=" Esc to cancel · Tab to amend"
UNREAD='.kind == "unreadable" and .fp == "v2:unreadable"'
TIP1='Tip: auto mode handles these prompts for you — choose "switch to auto mode"'
TIPW="$TIP1 below"
SID=""; T=""; N=0; ID=""
fresh() {  # fresh <name> — a new role session with an empty transcript
  SID="sid-$1"; session coder 1 "$BASE" "$SID"; T="$(transcript "$SID")"
  mkdir -p "$(dirname "$T")"; : > "$T"
}
call() {  # call <tool> <json input> [cwd] → ID: one more pending call of the role
  N=$((N + 1)); ID="t$N"; pending_tool "$SID" "$ID" "$1" "$2" "${3-$CREAL}"
}
pj() {  # pj <pane> <transcript|-> <jq condition> <label>
  $PY parse --transcript "$2" < "$1" > "$WORK/p.json"
  jq -e "$3" "$WORK/p.json" >/dev/null || { cp "$WORK/p.json" "$WORK/out"; fail "$4: $3"; }
}
chk() {  # chk <rc> <text> <label> [checker args] — the sender's strict check of $WORK/pane
  local rc="$1" text="$2" label="$3"; shift 3
  set +e
  $PC "$CLONE" --strict --transcript "$T" --main "$MAIN" "$@" < "$WORK/pane" > "$WORK/out" 2>&1
  RC=$?; set -e
  expect "$rc" "$text" "$label"
}
opts() {
  echo " ❯ 1. Yes"; echo "   2. Yes, allow all edits during this session (shift+tab)"
  echo "   3. No"; echo "$FOOT"
}
filep() {  # filep <header> <shown path> <question verb> <rows…> — a full Edit/Write prompt
  local h="$1" s="$2" v="$3"; shift 3
  { echo "⏺ Update($s)"; echo "$RULE"; echo " $h"; echo " $s"; echo "$DASH"; printf '%s\n' "$@"
    echo "$DASH"; echo " Do you want to $v $(basename "$s")?"; opts; } > "$WORK/pane"
}
clipp() {  # clipp <question> <rows…> — a prompt whose header and path scrolled off
  local q="$1"; shift
  { printf '%s\n' "$@"; echo "$DASH"; echo " Do you want to $q?"; opts; } > "$WORK/pane"
}
bashp() {  # bashp <command> <description lines…> — a Bash prompt, lines as Ink wrapped them
  local c="$1"; shift
  { echo "$RULE"; echo " Bash command"; printf ' %s\n' "$@"; echo "$DASH"; echo " │ $c"
    echo "$DASH"; echo " This command requires approval"; echo " Do you want to proceed?"
    echo " ❯ 1. Yes"; echo "   2. No"; echo "$FOOT"; } > "$WORK/pane"
}
writei() {  # writei <file_path> <content> — a Write input
  jq -cn --arg f "$1" --arg c "$2" '{file_path: $f, content: $c}'
}
editi() {  # editi <file_path> <old_string> <new_string> — an Edit input
  jq -cn --arg f "$1" --arg o "$2" --arg n "$3" '{file_path: $f, old_string: $o, new_string: $n}'
}

# ---- (a) a clipped overwrite and a clipped wrapped Edit, recovered from the transcript -------
PRD="$CREAL/.git/PR_DESCRIPTION.md"
CLIPROWS=("  40 +line a" "     +continued" "  41  ctx" "  42 -old" "     -old wrapped")
fresh over; call Write "$(writei "$PRD" $'head\nline a continued\nctx\n')"
clipp "overwrite PR_DESCRIPTION.md" "${CLIPROWS[@]}"; cp "$WORK/pane" "$WORK/clip-over"
pj "$WORK/clip-over" "$T" '.complete and .kind == "permission" and .recovered == "transcript"
  and .header == "Overwrite file" and .cursor == 1 and .body == ["'"$PRD"'"]' "(a) overwrite"
chk 0 "" "(a) checker passes a recovered overwrite in the clone"
fresh clip-edit
call Edit "$(editi "$CREAL/notes.txt" "old line part two" "new line part two")"
clipp "make this edit to notes.txt" "  12 -old line part" "     -two" "  12 +new line part" \
  "     +two"
pj "$WORK/pane" "$T" '.complete and .recovered == "transcript" and .header == "Edit file"' \
  "(a) clipped Edit with wrapped rows"
echo "team-smoke-14: (a) recovered OK"

# ---- (b) a clipped overwrite stays fail-closed -----------------------------------------------
cp "$WORK/clip-over" "$WORK/pane"
fresh b1; call Write "$(writei "$CREAL/OTHER.md" $'line a continued\n')"
pj "$WORK/pane" "$T" "$UNREAD" "(b) pending Write names another file"
fresh b2; call Write "$(writei "$PRD" $'nothing here\n')"
pj "$WORK/pane" "$T" "$UNREAD" "(b) a + row is absent from content"
pj "$WORK/pane" - "$UNREAD" "(b) no transcript"
fresh b3; call Write "$(writei "$PRD" $'line a continued\n')"
call Write "$(writei "$PRD" $'line a continued\n')"
pj "$WORK/pane" "$T" "$UNREAD" "(b) two pending Writes"
fresh b4; call Write "$(writei "$PRD" $'line a continued\n')"; tool_done "$SID" "$ID"
pj "$WORK/pane" "$T" "$UNREAD" "(b) the call already has a tool_result"
fresh b5; call Write "$(writei "$PRD" $'line a continued\n')"
clipp "create PR_DESCRIPTION.md" "${CLIPROWS[@]}"
pj "$WORK/pane" "$T" "$UNREAD" "(b) create verb over diff rows"
clipp "overwrite PR_DESCRIPTION.md" "  42 -old" "     +continued"
pj "$WORK/pane" "$T" "$UNREAD" "(b) a + continuation under a - row"
clipp "overwrite PR_DESCRIPTION.md" "  40 +line a" "     continued"
pj "$WORK/pane" "$T" "$UNREAD" "(b) an unmarked continuation under a + row"
fresh b6; call Write "$(writei "$PRD" $'line a\n')"
clipp "overwrite PR_DESCRIPTION.md" "  40 +line a" "  41  ctx" "     +not in content"
pj "$WORK/pane" "$T" "$UNREAD" "(b) a + continuation under a context row"
clipp "overwrite PR_DESCRIPTION.md" "⏺ Update(PR_DESCRIPTION.md)" "  40 +line a"
pj "$WORK/pane" "$T" "$UNREAD" "(b) a foreign row above the diff"
echo "team-smoke-14: (b) fail-closed OK"

# ---- (c) a full Overwrite file prompt: binding, checker, old refusals, class alias -----------
printf 'keep\nold line\n' > "$CLONE/notes.md"
fresh c1; call Write "$(writei "$CREAL/notes.md" $'keep\nnew line\n')"
filep "Overwrite file" notes.md overwrite "  1  keep" "  2 -old line" "  2 +new line"
pj "$WORK/pane" "$T" '.complete and .kind == "permission" and .header == "Overwrite file"
  and .recovered == null and .desc == "notes.md"' "(c) full overwrite"
chk 0 "" "(c) checker passes an overwrite inside the clone"
filep "Overwrite file" notes.md overwrite "  1  keep" "  2 -old line" "  2 +other line"
chk 1 "screen rows differ" "(c) a + row the content lacks"
filep "Overwrite file" notes.md overwrite "  1  keep" "  2 -gone line" "  2 +new line"
chk 1 "screen rows differ" "(c) a - row the file on disk lacks"
filep "Overwrite file" notes.md overwrite "  1  keep" "  2 -old line" "  2 +new" "     +line"
chk 0 "" "(c) a wrapped + row of the content"
filep "Overwrite file" notes.md overwrite "  1  keep" "  2 -old line" "  2 +new" \
  "     +UNRELATED TAIL"
chk 1 "screen rows differ" "(c) a wrapped + row the content lacks"
filep "Overwrite file" notes.md overwrite "  1  keep" "  2 -old line" "     +line"
chk 1 "screen rows differ" "(c) a + continuation under a - row"
filep "Overwrite file" sub/notes.md overwrite "  1  keep" "  2 -old line" "  2 +new line"
chk 1 "screen path differs" "(c) a diverging target"
mkdir -p "$MAIN/x"; printf 'keep\nold line\n' > "$MAIN/x/notes.md"
fresh c2; call Write "$(writei "$MREAL/x/notes.md" $'keep\nnew line\n')"
filep "Overwrite file" "$MREAL/x/notes.md" overwrite "  1  keep" "  2 -old line" "  2 +new line"
chk 1 "refuse (outside clone)" "(c) overwrite outside the clone"
# The class alias: an allow-only settings.json overwrite reaches the existing Write class.
# A filled Branch model (the template's own CLAUDE.md leaves it to /setup:create-CLAUDE_MD).
printf '%s\n' '**Integration:** `develop`' '**Maintenance:** `rc/rc` — an old line' \
  '**Retired:** `feature/old` — locked' \
  '**Protected:** `develop`, `feature/old`, `rc/rc`, `legacy`, `master`' > "$MAIN/CLAUDE.md"
printf 'echo hi\n' > "$CLONE/.claude/lib/x.sh"
SET="$CREAL/.claude/settings.json"
NEWSET="$(jq '.permissions.allow += ["Bash(bash -n .claude/lib/x.sh)"]' "$SET")"
python3 -I -c 'import sys
old, new = open(sys.argv[1], encoding="utf-8").read().split("\n"), sys.argv[2].split("\n")
for line in old:
    if line not in new:
        print("  3 -" + line)
for line in new:
    if line not in old:
        print("  3 +" + line)' "$SET" "$NEWSET" > "$WORK/setrows"
SETROWS=(); while IFS= read -r r; do SETROWS+=("$r"); done < "$WORK/setrows"
fresh c3; call Write "$(writei "$SET" "$NEWSET")"
(. "$MAIN/.claude/lib/team-anchor.sh"
 team_anchor_launch "$MAIN" alfa "$CLONE" "$RUN_ID" coder 1 "$SID")
filep "Overwrite file" .claude/settings.json overwrite "${SETROWS[@]}"
chk 1 "refuse (settings): settings.json" "(c) settings overwrite without classes"
chk 0 "class allow-offline not enabled" "(c) a class the profile does not enable" --classes --report
jq '.teams.policy.classes.allow_offline.enabled = true' "$MAIN/.claude/project-profile.json" > "$WORK/p" \
  && mv "$WORK/p" "$MAIN/.claude/project-profile.json"
chk 0 "class: allow-offline" "(c) overwrite takes the Write class" --classes --report
! has "no class for a Overwrite file prompt" "$WORK/out" || fail "(c) Overwrite file has no class"
clipp "overwrite settings.json" "${SETROWS[@]}"
chk 0 "class: recovered prompt — header off screen" "(c) recovered overwrite takes no class" \
  --classes --report
echo "team-smoke-14: (c) full overwrite OK"

# ---- (d) parallel Edits on one file: only the shown path and diff decide ---------------------
printf 'alpha one\nbeta two\ngamma three\n' > "$CLONE/notes.txt"
NT="$CREAL/notes.txt"
fresh d1; call Edit "$(editi "$NT" "alpha one" "alpha 1")"
call Edit "$(editi "$NT" "beta two" "beta 2")"
call Edit "$(editi "$NT" "gamma three" "gamma 3")"
filep "Edit file" notes.txt "make this edit to" "  1  alpha one" "  2 -beta two" \
  "  2 +beta 2" "  3  gamma three" "  4  "
chk 0 "" "(d) checker passes the bound edit"
filep "Edit file" notes.txt "make this edit to" "  2 -delta four" "  2 +delta 4"
chk 1 "no prompt event" "(d) checker refuses an unbound edit"
mkdir -p "$CLONE/a" "$CLONE/b"; cp "$CLONE/notes.txt" "$CLONE/a/"; cp "$CLONE/notes.txt" "$CLONE/b/"
fresh d5; call Edit "$(editi "$CREAL/a/notes.txt" "beta two" "beta 2")"
call Edit "$(editi "$CREAL/b/notes.txt" "beta two" "beta 2")"
filep "Edit file" b/notes.txt "make this edit to" "  2 -beta two" "  2 +beta 2"
chk 0 "" "(d) checker passes the directory-b edit"
echo "team-smoke-14: (d) parallel edits OK"

# ---- (e) the Tip block: recognised, never cut from a command, unknown extent refuses ---------
fresh e1
call Bash "$(jq -cn '{command: "git status --porcelain",
  description: "Capture tree fingerprint before finders"}')"
bashp "git status --porcelain" "$TIP1" "below" "Capture tree fingerprint before finders"
pj "$WORK/pane" "$T" '.desc == "Capture tree fingerprint before finders"' "(e) wrapped Tip desc"
bashp "git status --porcelain" "$TIPW" "Capture tree fingerprint before finders"
pj "$WORK/pane" "$T" '.desc == "Capture tree fingerprint before finders"' "(e) one-line Tip"
fresh e2; call Bash '{"command":"git status","description":"Check working tree"}'
call Bash '{"command":"git status","description":"working tree"}'
bashp "git status" "$TIPW" "Check working tree"
pj "$WORK/pane" "$T" '.desc == "Check working tree"' "(e) Codex 1, Tip"
bashp "git status" "$TIP1" "below" "Check working tree"
pj "$WORK/pane" "$T" '.desc == "Check working tree"' "(e) Codex 1, wrapped Tip"
bashp "git status" "Tip: something else" "Check working tree"
pj "$WORK/pane" "$T" '.reason == "unreadable: unknown Tip block"' "(e) an unknown Tip"
bashp "git status" "$TIP1" "Check working tree"
pj "$WORK/pane" "$T" '.reason == "unreadable: unknown Tip block"' "(e) a Tip without its end"
fresh e4; call Bash '{"command":"echo Tip: keep me","description":"Say it"}'
bashp "echo Tip: keep me" "$TIPW" "Say it"
pj "$WORK/pane" "$T" '.command == "echo Tip: keep me" and .desc == "Say it"' "(e) literal Tip"
echo "team-smoke-14: (e) Tip OK"

# ---- (f) AC 2: an answered overwrite in the history is never the active prompt ---------------
fresh f1; call Write "$(writei "$CREAL/notes.md" $'keep\nnew line\n')"; tool_done "$SID" "$ID"
filep "Overwrite file" notes.md overwrite "  1  keep" "  2 -old line" "  2 +new line"
cp "$WORK/pane" "$WORK/old"
{ cat "$WORK/old"; echo "⏺ Wrote 2 lines to notes.md"; echo "$RULE"; echo "❯ "; echo "$RULE"
  echo "  ? for shortcuts"; } > "$WORK/pane"
pj "$WORK/pane" "$T" '.kind == "none"' "(f) old overwrite above the idle input"
call Write "$(writei "$PRD" $'head\nline a continued\nctx\n')"
{ cat "$WORK/old"; echo "⏺ Wrote 2 lines to notes.md"; printf '%s\n' "${CLIPROWS[@]}"
  echo "$DASH"; echo " Do you want to overwrite PR_DESCRIPTION.md?"; opts; } > "$WORK/pane"
pj "$WORK/pane" "$T" "$UNREAD" "(f) old overwrite above a clipped new one"
filep "Overwrite file" .git/PR_DESCRIPTION.md overwrite "  40 +line a" "     +continued"
{ cat "$WORK/old"; echo "⏺ Wrote 2 lines to notes.md"; cat "$WORK/pane"; } > "$WORK/both"
pj "$WORK/both" "$T" '.desc == ".git/PR_DESCRIPTION.md"' "(f) the newer full prompt is read"
echo "team-smoke-14: (f) history OK"
echo "team-smoke-14: OK"
