#!/usr/bin/env bash
# Offline test of the Operator touch log: .claude/lib/touches.py through touches.sh (add, report,
# report --brief) and the Notification hook (.claude/hooks/touch-notify.sh, touches.py hook
# --global). Run from the repo root. Every fixture — repos, team clone, payloads, transcripts —
# lives in one mktemp -d, and HOME and TMPDIR point inside it. Lines carrying a synthetic secret
# end with the leak scanner's allow mark. Contract: .agents/reference/operator-touches.md
set -uo pipefail
unset ${!HARNESS_@} TEAM_SESSION_ROLE TEAM_RUN_TEAM CLAUDE_PROJECT_DIR TOUCHES_BLOCK_OFF
export TOUCHES_GRACE_S=0
SRC="$PWD"; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd -P)"
export HOME="$T/home" TMPDIR="$T/tmp"; mkdir -p "$HOME" "$TMPDIR" "$T/p"
TS="bash $SRC/.claude/lib/touches.sh"
fail=0; pass=0
ok() { # <description> <exit status of the check>
  if [ "$2" = 0 ]; then pass=$((pass + 1)); echo "PASS $1"; else fail=1; echo "FAIL $1"; fi
}
month() { date -u +%Y-%m; }
mfile() { echo "$1/.agents/touches/$(month).jsonl"; }
count() { if [ -f "$1" ]; then grep -c . "$1" || true; else echo 0; fi; }
mkrepo() { mkdir -p "$1/.agents" && git -C "$1" init -q; }
add_in() { local d="$1"; shift; (cd "$d" && $TS add "$@"); }
MACHINE="$(uname -n | cut -d. -f1 | tr -cd 'A-Za-z0-9._-' | cut -c1-100)"
utc_ago() { date -u -r $(( $(date +%s) - $1 )) +%Y-%m-%dT%H:%M:%SZ; }
entry() { # <at> <who> <where> <kind> <what> <reason> — one hand-written log line
  jq -nc --arg at "$1" --arg who "$2" --arg w "$3" --arg k "$4" --arg what "$5" --arg r "$6" \
    '{at:$at, machine:"m", who:$who, where:$w, kind:$k, what:$what, reason:$r, answer:"", wait_s:null}'
}
payload() { # <file> <notification_type> <cwd> <session_id> [transcript]
  jq -nc --arg ty "$2" --arg c "$3" --arg s "$4" --arg t "${5:-}" \
    '{session_id:$s, notification_type:$ty, message:"Claude needs your permission to use Bash", cwd:$c}
     + (if $t == "" then {} else {transcript_path:$t} end)' > "$1"
}
use() { jq -nc --arg id "$1" --arg c "$2" '{type:"assistant", message:{content:[{type:"tool_use", id:$id, name:"Bash", input:{command:$c}}]}}'; }
result() { jq -nc --arg id "$1" '{type:"user", message:{content:[{type:"tool_result", tool_use_id:$id, content:"ok"}]}}'; }
hook() { # <project dir or ""> <payload file>
  CLAUDE_PROJECT_DIR="$1" bash "$SRC/.claude/hooks/touch-notify.sh" < "$2"
}
hook_global() { # <project dir> <payload file>
  CLAUDE_PROJECT_DIR="$1" python3 -I "$SRC/.claude/lib/touches.py" hook --global < "$2"
}

# Fixtures: a main checkout and a team clone of a lead run whose teamlead.json points at it.
RUN=beta-20261005-120000
mkrepo "$T/main"; printf '.agents/touches/\n' > "$T/main/.gitignore"
mkrepo "$T/clone"; CT="$T/clone/.agents/team"; mkdir -p "$CT/runs/$RUN/asks"
printf '%s\n' '{"team":"beta","ticket":"7"}' > "$CT/team.json"
printf '%s\n' "$RUN" > "$CT/run"
jq -nc --arg r "$RUN" '{team:"beta", ticket:"7", role:"coder", attempt:1, run:$r, session_id:"S-STAGE"}' > "$CT/session.json"
jq -nc --arg r "$RUN" --arg m "$T/main" '{run:$r, session_id:"S-LEAD", main_root:$m}' > "$CT/teamlead.json"
MF="$(mfile "$T/main")"

# (1) add in the main checkout: one line, keys in contract order, where "solo .".
add_in "$T/main" --kind other --reason direct --what "first touch" >/dev/null 2>&1
[ "$(count "$MF")" = 1 ] \
  && [ "$(jq -r 'keys_unsorted | join(",")' "$MF")" = "at,machine,who,where,kind,what,reason,answer,wait_s" ] \
  && [ "$(jq -r .where "$MF")" = "solo ." ] && [ "$(jq -r .wait_s "$MF")" = null ]
ok "1 add in main: one line, contract keys, solo ." $?

# (1b) a relayed decision names who relayed it; an add without the options has neither key.
mkrepo "$T/m1b"; F1B="$(mfile "$T/m1b")"
add_in "$T/m1b" --kind decision --reason human-only --what q --relayed-by Supervisor --relayed-session sup-1 >/dev/null 2>&1
add_in "$T/m1b" --kind decision --reason human-only --what q >/dev/null 2>&1
[ "$(count "$F1B")" = 2 ] \
  && sed -n 1p "$F1B" | jq -e '.relayed_by == "Supervisor" and .relayed_session == "sup-1"' >/dev/null \
  && sed -n 2p "$F1B" | jq -e 'has("relayed_by") or has("relayed_session") | not' >/dev/null
ok "add --relayed-by and --relayed-session are stored" $?

# (2) usage errors exit 2 and write nothing.
mkrepo "$T/m2"; r=""
add_in "$T/m2" --kind nope --reason direct --what x >/dev/null 2>&1; r="$r$?"
add_in "$T/m2" --kind other --reason nope --what x >/dev/null 2>&1; r="$r$?"
add_in "$T/m2" --kind other --reason direct --what x --wait-s -1 >/dev/null 2>&1; r="$r$?"
add_in "$T/m2" --kind other --reason direct --what "" >/dev/null 2>&1; r="$r$?"
[ "$r" = 2222 ] && [ ! -e "$T/m2/.agents/touches" ]
ok "2 bad kind, reason, wait-s, empty what: exit 2, no file" $?

# (3) caps: what at 200, who at 100.
mkrepo "$T/m3"
add_in "$T/m3" --kind other --reason direct --what "$(printf 'a%.0s' $(seq 300))" >/dev/null 2>&1
(cd "$T/m3" && USER="$(printf 'u%.0s' $(seq 150))" $TS add --kind other --reason direct --what w) >/dev/null 2>&1
F3="$(mfile "$T/m3")"
[ "$(count "$F3")" = 2 ] && [ "$(sed -n 1p "$F3" | jq -r '.what | length')" = 200 ] \
  && [ "$(sed -n 2p "$F3" | jq -r '.who | length')" -le 100 ]
ok "3 text capped at 200, who at 100" $?

# (4) secrets in what and answer are masked, also when cut short or JSON-escaped.
mkrepo "$T/m4"
a4() { add_in "$T/m4" --kind other --reason direct "$@" >/dev/null 2>&1; }
a4 --what "curl -H 'Authorization: Bearer abc123' token=xyz ghp_0123456789abcdefghijklmnopqrstuvwxyz" --answer "password=hunter2" # guard-push:allow
a4 --what '{"password": "s3cr"}' # guard-push:allow
a4 --what 'Endpoint=sb://x;AccessKey=k9k9k9;' # guard-push:allow
a4 --what 'https://x/cb?access_token=t0k3n&y=1' # guard-push:allow
a4 --what 'cut short ghp_ab12' # guard-push:allow
a4 --what="--data '{\"password\": \"pp9pp9" # guard-push:allow
a4 --what 'export DB_PASSWORD=dbdb77' # guard-push:allow
a4 --what '{"password": "a\"b7b7"}' # guard-push:allow
a4 --what 'Server=x;Password="c""d8d8";' # guard-push:allow
a4 --what 'deploy --password  ee55ff' # guard-push:allow
a4 --what 'login --token "q\"rr66"' # guard-push:allow
F4="$(mfile "$T/m4")"
[ "$(count "$F4")" = 11 ] \
  && ! jq -r '.what, .answer' "$F4" | grep -qE 'abc123|xyz|hunter2|s3cr|k9k9k9|t0k3n|ab12|pp9pp9|dbdb77|b7b7|d8d8|ee55ff|rr66' # guard-push:allow
ok "4 secrets masked in what and answer" $?

# (5) 20 concurrent writers: 20 whole lines.
mkrepo "$T/m5"
for i in $(seq 20); do add_in "$T/m5" --kind other --reason direct --what "writer $i" >/dev/null 2>&1 & done
wait
F5="$(mfile "$T/m5")"; bad=0
while IFS= read -r l; do printf '%s' "$l" | jq -e . >/dev/null 2>&1 || bad=1; done < "$F5"
[ "$(count "$F5")" = 20 ] && [ "$bad" = 0 ]
ok "5 concurrent appends stay whole lines" $?

# (6) a team clone writes into the main checkout, never its own; no teamlead.json → refused.
add_in "$T/clone" --kind other --reason direct --what "from the clone" >/dev/null 2>&1
[ "$(count "$MF")" = 2 ] && [ "$(tail -n 1 "$MF" | jq -r .where)" = "team beta / 7 / coder" ] \
  && [ ! -e "$T/clone/.agents/touches" ]
ok "6a clone add lands in the main checkout's log" $?
mv "$CT/teamlead.json" "$CT/teamlead.json.off"
add_in "$T/clone" --kind other --reason direct --what "no lead" >/dev/null 2>&1; r=$?
mv "$CT/teamlead.json.off" "$CT/teamlead.json"
[ "$r" = 1 ] && [ ! -e "$T/clone/.agents/touches" ] && [ "$(count "$MF")" = 2 ]
ok "6b clone without teamlead.json: exit 1, nothing written" $?

# (7) unsafe targets: a symlinked touches dir, a FIFO month file (promptly).
mkrepo "$T/m7"; mkdir -p "$T/m7-target"; ln -s "$T/m7-target" "$T/m7/.agents/touches"
add_in "$T/m7" --kind other --reason direct --what x >/dev/null 2>&1; r=$?
[ "$r" = 1 ] && [ -z "$(ls -A "$T/m7-target")" ]
ok "7a symlinked .agents/touches refused" $?
mkrepo "$T/m7b"; mkdir -p "$T/m7b/.agents/touches"; mkfifo "$(mfile "$T/m7b")"
( add_in "$T/m7b" --kind other --reason direct --what x >/dev/null 2>&1; echo $? > "$T/m7b.rc" ) &
pid=$!; i=0
while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
kill "$pid" 2>/dev/null
[ "$(cat "$T/m7b.rc" 2>/dev/null)" = 1 ]
ok "7b FIFO month file refused without blocking" $?

# (8) report across months: malformed and ill-typed lines named and skipped, a FIFO month skipped.
mkrepo "$T/m8"; D8="$T/m8/.agents/touches"; mkdir -p "$D8"
{ entry 2026-09-10T10:00:00Z x "solo ." other "sept one" direct
  printf '%s\n' 'not json at all'
  entry 2026-09-11T10:00:00Z x "solo ." other "ill typed" direct | jq -c '.what = null'
  entry 2026-09-12T10:00:00Z y "solo ." permission "sept two" guard; } > "$D8/2026-09.jsonl"
entry 2026-10-02T10:00:00Z x "solo ." other "oct one" direct > "$D8/2026-10.jsonl"
mkfifo "$D8/2026-08.jsonl"
$TS report --main "$T/m8" --since 2026-08-01 > "$T/r8.out" 2> "$T/r8.err"; r=$?
[ "$r" = 0 ] && grep -q '2026-09.jsonl:2 — bad json' "$T/r8.err" \
  && grep -q '2026-09.jsonl:3 — bad type what' "$T/r8.err" && grep -q '2026-08.jsonl — not a regular file' "$T/r8.err" \
  && grep -q '^Operator touches — 3 since 2026-08-01 (2 files, 2 malformed skipped)' "$T/r8.out"
ok "8a report spans months, names bad lines and the FIFO, exit 0" $?
$TS report --main "$T/m8" --since 2026-10-01 2>/dev/null | grep -q '^Operator touches — 1 since 2026-10-01'
ok "8b --since drops the earlier month" $?
$TS report --main "$T/m8" --since 2026-08-01 --who x 2>/dev/null | grep -q '— 2 since' \
  && $TS report --main "$T/m8" --since 2026-08-01 --reason guard 2>/dev/null | grep -q '— 1 since'
ok "8c --who and --reason filter" $?
$TS report --brief --main "$T/m8" --team beta --ticket 7 --run beta-20260901-000000 >/dev/null 2>&1
ok "8d --brief over malformed lines and a FIFO exits 0" $?

# (9) --brief: the run's count from its timestamp; Recurring only for a >= 3 cluster it joined.
mkrepo "$T/m9"; D9="$T/m9/.agents/touches"; mkdir -p "$D9"; W9="team beta / 7 / coder"
{ entry 2026-08-01T10:00:00Z x "solo ." question "size question 3" no-rule
  entry 2026-08-02T10:00:00Z x "solo ." question "Size question 45" no-rule; } > "$D9/2026-08.jsonl"
{ entry 2026-10-05T11:00:00Z x "$W9" other "pre-start stop" direct
  entry 2026-10-06T09:00:00Z x "$W9" question "size question 12" no-rule
  for n in 1 2 3; do entry "2026-10-06T10:00:0${n}Z" x "$W9" permission "Claude needs your permission" direct; done
  for c in a b c d e; do for n in 1 2 3 4; do
    entry "2026-10-07T1${n}:00:00Z" x "solo ." other "unrelated $c $n" direct; done; done; } > "$D9/2026-10.jsonl"
$TS report --brief --main "$T/m9" --team beta --ticket 7 --run "$RUN" > "$T/r9.out" 2>/dev/null
head -n 1 "$T/r9.out" | grep -q '^Operator touches: 4 — 3× direct (permission), 1× no-rule (question)$' \
  && [ "$(grep -c '^Recurring:' "$T/r9.out")" = 1 ] && grep -q '^Recurring: 3× no-rule — ' "$T/r9.out"
ok "9 --brief counts from the run start, one Recurring line, none for generic or unrelated" $?

# (10) hook, solo: a pending Bash call names the prompt; completed or parallel calls fall back.
mkrepo "$T/h10"; F10="$(mfile "$T/h10")"
use tu1 "git push origin x" > "$T/p/t10.jsonl"
payload "$T/p/p10.json" permission_prompt "$T/h10" S1 "$T/p/t10.jsonl"
hook "" "$T/p/p10.json"
[ "$(count "$F10")" = 1 ] && [ "$(jq -r .kind "$F10")" = permission ] && [ "$(jq -r .reason "$F10")" = direct ] \
  && jq -r .what "$F10" | grep -q '^Bash: git push'
ok "10a solo permission prompt: one line, what from the pending call" $?
{ use tu1 "git push origin x"; result tu1; } > "$T/p/t10b.jsonl"
payload "$T/p/p10b.json" permission_prompt "$T/h10" S1 "$T/p/t10b.jsonl"
hook "" "$T/p/p10b.json"
[ "$(tail -n 1 "$F10" | jq -r .what)" = "Claude needs your permission to use Bash" ]
ok "10b completed call: what is the message" $?
{ use tu1 "git push a"; use tu2 "git push b"; } > "$T/p/t10c.jsonl"
payload "$T/p/p10c.json" permission_prompt "$T/h10" S1 "$T/p/t10c.jsonl"
hook "" "$T/p/p10c.json"
[ "$(count "$F10")" = 3 ] && [ "$(tail -n 1 "$F10" | jq -r .what)" = "Claude needs your permission to use Bash" ]
ok "10c parallel pending calls: what is the message" $?

# (11) another notification type is ignored.
payload "$T/p/p11.json" idle_prompt "$T/h10" S1
hook "" "$T/p/p11.json"
[ "$(count "$F10")" = 3 ]
ok "11 idle_prompt writes nothing" $?

# (12) a lead-run stage: a covering permission ask → nothing; otherwise channel-failed.
AK="$CT/runs/$RUN/asks/a-1.json"; n0="$(count "$MF")"
jq -nc '{id:"a-1", kind:"permission", role:"coder", attempt:1, session_id:"S-STAGE", state:"waiting",
  filed_at:"2026-10-05T12:00:00Z", payload:{tool_name:"Bash", tool_input:{command:"x"}}}' > "$AK"
payload "$T/p/p12.json" permission_prompt "$T/clone" S-STAGE
hook "$T/clone" "$T/p/p12.json"
[ "$(count "$MF")" = "$n0" ]
ok "12a covered by a waiting permission ask of the stage: nothing" $?
jq -c '.kind = "question"' "$AK" > "$AK.tmp" && mv "$AK.tmp" "$AK"
hook "$T/clone" "$T/p/p12.json"
[ "$(count "$MF")" = $((n0 + 1)) ] && [ "$(tail -n 1 "$MF" | jq -r .reason)" = channel-failed ]
ok "12b a waiting question does not hide a permission prompt: channel-failed" $?
rm -f "$AK"
hook "$T/clone" "$T/p/p12.json"
[ "$(count "$MF")" = $((n0 + 2)) ] && [ "$(tail -n 1 "$MF" | jq -r .reason)" = channel-failed ] \
  && [ "$(tail -n 1 "$MF" | jq -r .where)" = "team beta / 7 / coder" ]
ok "12c no ask: channel-failed under the stage's where" $?
payload "$T/p/p12l.json" permission_prompt "$T/clone" S-LEAD
hook "$T/clone" "$T/p/p12l.json"
[ "$(count "$MF")" = $((n0 + 3)) ] && [ "$(tail -n 1 "$MF" | jq -r .reason)" = direct ] \
  && tail -n 1 "$MF" | jq -r .where | grep -q '/ TeamLead$'
ok "12d the TeamLead's own prompt: direct, where TeamLead" $?
[ ! -e "$T/clone/.agents/touches" ]
ok "12e the clone never gets its own log" $?

# (12b) the session's project decides the log; a cwd in another repository only names solo ?.
mkrepo "$T/other"; n0="$(count "$MF")"
payload "$T/p/p12p.json" permission_prompt "$T/other" S1
hook "$T/main" "$T/p/p12p.json"
[ "$(count "$MF")" = $((n0 + 1)) ] && [ "$(tail -n 1 "$MF" | jq -r .where)" = "solo ?" ] \
  && [ ! -e "$T/other/.agents/touches" ]
ok "12f project vs cwd: the project's log, where solo ?" $?

# (12c) what is taken before the grace: the call answered meanwhile is still the one named.
n0="$(count "$MF")"
use tuA "echo first-call" > "$T/p/t12c.jsonl"
payload "$T/p/p12c.json" permission_prompt "$T/clone" S-STAGE "$T/p/t12c.jsonl"
( sleep 1; { result tuA; use tuB "echo second-call"; } >> "$T/p/t12c.jsonl" ) &
TOUCHES_GRACE_S=2 hook "$T/clone" "$T/p/p12c.json"
wait
[ "$(count "$MF")" = $((n0 + 1)) ] && tail -n 1 "$MF" | jq -r .what | grep -q 'first-call'
ok "12g the pending call is read before the grace sleep" $?

# (12d) --global ignores a stale team clone's redirect: only the project's own repository.
mkrepo "$T/g12"; mkrepo "$T/g12-other"; mkdir -p "$T/g12/.agents/team"
printf '%s\n' '{"team":"beta","ticket":"7"}' > "$T/g12/.agents/team/team.json"
jq -nc --arg m "$T/g12-other" '{run:"r-20260101-000000", session_id:"S-X", main_root:$m}' > "$T/g12/.agents/team/teamlead.json"
before="$(cksum < "$T/g12-other/.git/info/exclude" 2>/dev/null)"
payload "$T/p/p12g.json" permission_prompt "$T/g12" S1
hook_global "$T/g12" "$T/p/p12g.json"
[ ! -e "$T/g12-other/.agents/touches" ] && [ "$(cksum < "$T/g12-other/.git/info/exclude" 2>/dev/null)" = "$before" ] \
  && { [ ! -e "$T/g12/.agents/touches" ] || [ "$(count "$(mfile "$T/g12")")" -le 1 ]; }
ok "12h --global never follows teamlead.json main_root" $?

# (13) dedup: a guard line of the last 10 s from the same machine and where suppresses the hook.
mkrepo "$T/h13"; F13="$(mfile "$T/h13")"; mkdir -p "$(dirname "$F13")"
entry "$(utc_ago 0)" x "solo ." permission "egress ask" guard | jq -c --arg m "$MACHINE" '.machine = $m' > "$F13"
payload "$T/p/p13.json" permission_prompt "$T/h13" S1
hook "" "$T/p/p13.json"
[ "$(count "$F13")" = 1 ]
ok "13a a fresh guard line suppresses the prompt line" $?
entry "$(utc_ago 30)" x "solo ." permission "egress ask" guard | jq -c --arg m "$MACHINE" '.machine = $m' > "$F13"
hook "" "$T/p/p13.json"
[ "$(count "$F13")" = 2 ]
ok "13b a guard line 30 s old does not" $?

# (14) --global: stands down beside a project hook, ignores before it writes, refuses unsafe targets.
mkrepo "$T/g14a"; mkdir -p "$T/g14a/.claude/hooks"; : > "$T/g14a/.claude/hooks/touch-notify.sh"
payload "$T/p/p14a.json" permission_prompt "$T/g14a" S1
hook_global "$T/g14a" "$T/p/p14a.json"
[ ! -e "$T/g14a/.agents/touches" ]
ok "14a --global stands down in a project with its own hook" $?
mkrepo "$T/g14b"
payload "$T/p/p14b.json" permission_prompt "$T/g14b" S1
hook_global "$T/g14b" "$T/p/p14b.json"
grep -qxF '.agents/touches/' "$T/g14b/.git/info/exclude" && [ "$(count "$(mfile "$T/g14b")")" = 1 ]
ok "14b --global adds the ignore line, then writes" $?
mkrepo "$T/g14c"; mkdir -p "$T/g14c/.agents/touches"; : > "$(mfile "$T/g14c")"
git -C "$T/g14c" add -f ".agents/touches/$(month).jsonl"
payload "$T/p/p14c.json" permission_prompt "$T/g14c" S1
hook_global "$T/g14c" "$T/p/p14c.json"
[ "$(count "$(mfile "$T/g14c")")" = 0 ]
ok "14c --global never writes a tracked month file" $?
unsafe_ok=0
mkrepo "$T/g14d"; : > "$T/out-d"; rm -f "$T/g14d/.git/info/exclude"; ln -s "$T/out-d" "$T/g14d/.git/info/exclude"
mkrepo "$T/g14e"; mkdir -p "$T/out-e"; : > "$T/out-e/exclude"; mv "$T/g14e/.git/info" "$T/g14e/.git/info.real"
ln -s "$T/out-e" "$T/g14e/.git/info"
mkrepo "$T/g14f"; : > "$T/out-f"; rm -f "$T/g14f/.git/info/exclude"; ln "$T/out-f" "$T/g14f/.git/info/exclude"
for x in d e f; do
  payload "$T/p/p14$x.json" permission_prompt "$T/g14$x" S1
  hook_global "$T/g14$x" "$T/p/p14$x.json"
  [ ! -e "$(mfile "$T/g14$x")" ] || unsafe_ok=1
done
[ "$unsafe_ok" = 0 ] && [ ! -s "$T/out-d" ] && [ ! -s "$T/out-e/exclude" ] && [ ! -s "$T/out-f" ]
ok "14d symlinked exclude, symlinked info dir, hard-linked exclude: nothing written" $?

# (15) block: a kind-block line in the main checkout; silent no-op without one; report keeps it apart.
mkrepo "$T/m15"; MF15="$(mfile "$T/m15")"
out=$(cd "$T/m15" && $TS block --source guard-x --what "refused one" 2>&1); r=$?
[ "$r" = 0 ] && [ -z "$out" ] && [ "$(count "$MF15")" = 1 ] \
  && [ "$(jq -r '.kind + "|" + .reason + "|" + .what + "|" + .answer + "|" + (.wait_s|tostring) + "|" + .where' "$MF15")" \
       = "block|hook|guard-x: refused one||null|solo ." ]
ok "15a block appends kind=block reason=hook, silent, exit 0" $?
mkdir -p "$T/nogit15"
out=$(cd "$T/nogit15" && CLAUDE_PROJECT_DIR="$T/nogit15" $TS block --source guard-x --what "no main" 2>&1); r=$?
out2=$(cd "$T/m15" && $TS block --what "missing source" 2>&1; cd "$T/m15" && $TS block --source s --what w --bogus x 2>&1); r2=$?
[ "$r" = 0 ] && [ -z "$out" ] && [ "$r2" = 0 ] && [ -z "$out2" ] && [ "$(count "$MF15")" = 1 ] \
  && [ ! -e "$T/nogit15/.agents" ]
ok "15b block without a main checkout or with bad args: exit 0, silent, nothing written" $?
D15="$T/m15/.agents/touches"
{ entry 2026-09-10T10:00:00Z x "solo ." permission "Bash: ls" direct
  for n in 1 2 3; do entry "2026-09-1${n}T10:00:00Z" x "solo ." block "guard-teamlead-bash: cat notes.md $n" hook; done; } > "$D15/2026-09.jsonl"
$TS report --main "$T/m15" --since 2026-09-01 > "$T/r15.out" 2>/dev/null; r=$?
[ "$r" = 0 ] && grep -q '^Operator touches — 1 since 2026-09-01' "$T/r15.out" \
  && ! grep -q '  .*  block  ' "$T/r15.out" \
  && grep -q '^Hook blocks (no human) — 4$' "$T/r15.out" \
  && grep -q '^  3× — "guard-teamlead-bash: cat notes.md 3"$' "$T/r15.out"
ok "15c report: blocks out of the Operator count and groups, own section with Recurring" $?
entry 2026-09-20T10:00:00Z x "team beta / 7 / coder" block "guard-push: secrets" hook >> "$D15/2026-09.jsonl"
$TS report --brief --main "$T/m15" --team beta --ticket 7 --run beta-20260901-000000 2>/dev/null \
  | grep -q '^Operator touches: 0$'
ok "15d --brief never counts blocks" $?
$TS add --kind block --reason hook --what x --main "$T/m15" >/dev/null 2>&1; r=$?
[ "$r" = 2 ]
ok "15e add refuses kind block / reason hook" $?
out=$(cd "$T/m15" && TOUCHES_BLOCK_OFF=1 $TS block --source guard-x --what "suite run" 2>&1); r=$?
[ "$r" = 0 ] && [ -z "$out" ] && [ "$(count "$MF15")" = 1 ]
ok "15f TOUCHES_BLOCK_OFF: block writes nothing" $?

echo "touches-test: $pass passed"
[ "$fail" = 0 ] || { echo "touches-test: FAILED"; exit 1; }
