#!/usr/bin/env bash
# Offline fixture test for .claude/lib/finder-model.sh — evidence is bound to the given
# agent ids in the current session and the active config dir; anything else must not report OK.
# Never reads real transcripts: every case runs with a fixture HOME and CLAUDE_CONFIG_DIR.
set -u
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/finder-model.sh"
EXPECTED_CASES=36
[ -f "$SCRIPT" ] || { echo "finder-model-test: FAIL — $SCRIPT missing"; exit 1; }
T=$(mktemp -d "${TMPDIR:-/tmp}/finder model.XXXXXX") \
  || { echo "finder-model-test: FAIL — mktemp"; exit 1; }
trap 'rm -rf "$T"' EXIT
die() { echo "finder-model-test: FAIL — fixture setup: $1"; exit 1; }

R="$T/fixture repo"; CFG="$T/config dir"; H="$T/home dir"
OPUS=claude-opus-5-5; FABLE=claude-fable-5-1
mkdir -p "$R/.claude/agents" "$CFG" "$H" || die "dirs"
agent() {  # <type> <model> [effort]
  { echo '---'; echo "name: $1"; echo "model: $2"; [ -z "${3:-}" ] || echo "effort: $3"
    echo '---'; echo 'fixture'; } > "$R/.claude/agents/$1.md"
}
agent correctness-reviewer "$OPUS" high || die "agent file"
agent structure-reviewer "$FABLE" high || die "agent file"
agent noeffort-reviewer "$OPUS" || die "agent file"
git -C "$R" init -q && git -C "$R" add .claude \
  && git -C "$R" -c user.email=t@t -c user.name=t commit -q -m init || die "git repo"
root=$(git -C "$R" rev-parse --show-toplevel) || die "toplevel"
mapped=$(printf '%s' "$root" | sed 's/[^A-Za-z0-9]/-/g')

mk() {  # <config dir> <sid> <id> <type> <model> <effort|-> [finished|-] [ending]
  local d="$1/projects/${PROJ:-$mapped}/$2/subagents" m="$5" e="$6"
  mkdir -p "$d" || die "subagent dir"
  jq -n -c --arg t "$4" --arg f "${7:-true}" \
    '{agentType:$t} + (if $f == "-" then {} else {finished:($f | fromjson)} end)' \
    > "$d/agent-$3.meta.json" || die "meta"
  asst() {  # <stop_reason> <content json> — one assistant record on the pinned args
    jq -n -c --arg m "$m" --arg e "$e" --arg s "$1" --argjson c "$2" \
      '{type:"assistant",message:{model:$m,stop_reason:$s,content:$c}}
       + (if $e == "-" then {} else {effort:$e} end)'
  }
  local report='[{"type":"text","text":"=== END CORRECTNESS REPORT ==="}]'
  local plain='[{"type":"text","text":"report sent"}]'
  # The api-request record carries the pinned model and effort as a decoy for text matching.
  { jq -n -c '{type:"user",message:{role:"user",content:"go"}}'
    case "${8:-text}" in
      text) asst end_turn "$report" ;;
      none) asst end_turn "$plain" ;;
      handback)
        asst tool_use '[{"type":"tool_use","id":"hb1","name":"SubagentHandback",
          "input":{"message":"findings === END STRUCTURE REPORT ==="}}]'
        jq -n -c '{type:"user",message:{role:"user",
          content:[{type:"tool_result",tool_use_id:"hb1",content:"ok"}]}}'
        asst end_turn "$plain" ;;
      quoted)
        asst tool_use '[{"type":"text","text":"format: === END CORRECTNESS REPORT ==="},
          {"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]'
        jq -n -c '{type:"user",message:{role:"user",content:"[Request interrupted by user]"}}' ;;
      handback-last)
        asst tool_use '[{"type":"tool_use","id":"hb1","name":"SubagentHandback",
          "input":{"message":"findings === END STRUCTURE REPORT ==="}}]'
        jq -n -c '{type:"user",message:{role:"user",
          content:[{type:"tool_result",tool_use_id:"hb1",content:"ok"}]}}' ;;
      resumed-*)
        asst tool_use '[{"type":"tool_use","id":"hb1","name":"SubagentHandback",
          "input":{"message":"findings === END STRUCTURE REPORT ==="}}]'
        jq -n -c '{type:"user",message:{role:"user",
          content:[{type:"tool_result",tool_use_id:"hb1",content:"ok"}]}}'
        asst end_turn "$plain"
        jq -n -c '{type:"user",message:{role:"user",content:"one more check please"}}'
        case "$8" in
          resumed-working) asst tool_use '[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"ls"}}]' ;;
          resumed-silent) asst end_turn "$plain" ;;
          resumed-reported) asst end_turn "$report" ;;
        esac ;;
      late)
        asst end_turn "$report"
        jq -n -c '{type:"user",message:{role:"user",
          content:"[SYSTEM NOTIFICATION - NOT USER INPUT] background task done"}}' ;;
    esac
    jq -n -c --arg m "$OPUS" '{type:"system",subtype:"api_request",model:$m,effort:"high"}'
  } > "$d/agent-$3.jsonl" || die "jsonl"
}
sub() { echo "$CFG/projects/$mapped/$1/subagents"; }

n=0; fail=0
run() {  # <exit> <desc> <config dir|UNSET> <sid|UNSET> <arg>…
  local exp="$1" desc="$2" cfg="$3" sid="$4" out got
  shift 4
  local envs=("HOME=$H")
  [ "$cfg" = UNSET ] || envs+=("CLAUDE_CONFIG_DIR=$cfg")
  [ "$sid" = UNSET ] || envs+=("CLAUDE_CODE_SESSION_ID=$sid")
  out=$(cd "$R" && env -u CLAUDE_CONFIG_DIR -u CLAUDE_CODE_SESSION_ID "${envs[@]}" \
    bash "$SCRIPT" "$@" 2>&1)
  got=$?
  n=$((n + 1))
  if [ "$got" != "$exp" ] || { [ "$exp" = 0 ] && ! grep -q 'FINDER MODELS OK' <<<"$out"; }; then
    echo "FAIL [$desc]: exit $got, expected $exp"; printf '%s\n' "$out" | sed 's/^/    /'
    fail=1
  fi
}

mk "$CFG" sess-a a1 correctness-reviewer "$OPUS" high
mk "$CFG" sess-a s1 structure-reviewer "$FABLE" high
run 0 "bound, matching" "$CFG" sess-a correctness-reviewer=a1
run 0 "both finders bound" "$CFG" sess-a correctness-reviewer=a1 structure-reviewer=s1

mk "$CFG" sess-other o1 correctness-reviewer "$OPUS" high
run 2 "matching transcript only in another session (false OK)" "$CFG" sess-a \
  correctness-reviewer=o1

mk "$CFG" sess-b b1 correctness-reviewer claude-sonnet-5-5 high
run 0 "parallel: A bound to its own finder" "$CFG" sess-a correctness-reviewer=a1
run 1 "parallel: B on another model" "$CFG" sess-b correctness-reviewer=b1
run 2 "parallel: A given B's id" "$CFG" sess-a correctness-reviewer=b1

mk "$CFG" sess-a a2 correctness-reviewer "$OPUS" high
mk "$CFG" sess-a a3 correctness-reviewer claude-sonnet-5-5 high
run 0 "same type twice in a session: first ok" "$CFG" sess-a correctness-reviewer=a2
run 1 "same type twice in a session: second mismatched" "$CFG" sess-a correctness-reviewer=a3

mk "$CFG" sess-a m1 correctness-reviewer "$OPUS" high
rm -f "$(sub sess-a)/agent-m1.meta.json" || die "rm meta"
run 2 "meta missing" "$CFG" sess-a correctness-reviewer=m1
mk "$CFG" sess-a j1 correctness-reviewer "$OPUS" high
rm -f "$(sub sess-a)/agent-j1.jsonl" || die "rm jsonl"
run 2 "jsonl missing" "$CFG" sess-a correctness-reviewer=j1
run 2 "meta agentType mismatch" "$CFG" sess-a correctness-reviewer=s1
mk "$CFG" sess-a f1 correctness-reviewer "$OPUS" high false
run 2 "meta finished:false" "$CFG" sess-a correctness-reviewer=f1
mk "$CFG" sess-a w1 correctness-reviewer "$OPUS" high - text
run 0 "meta without finished, report in final text" "$CFG" sess-a correctness-reviewer=w1
mk "$CFG" sess-a w2 structure-reviewer "$FABLE" high - handback
run 0 "meta without finished, report via SubagentHandback" "$CFG" sess-a structure-reviewer=w2
mk "$CFG" sess-a w3 correctness-reviewer "$OPUS" high true none
run 2 "finished:true but no report end marker" "$CFG" sess-a correctness-reviewer=w3
mk "$CFG" sess-a w4 correctness-reviewer "$OPUS" high - quoted
run 2 "marker quoted, then tool call interrupted" "$CFG" sess-a correctness-reviewer=w4
mk "$CFG" sess-a w6 structure-reviewer "$FABLE" high - handback-last
run 0 "SubagentHandback is the last record" "$CFG" sess-a structure-reviewer=w6
mk "$CFG" sess-a r1 structure-reviewer "$FABLE" high - resumed-working
run 2 "resumed after a handback, still working" "$CFG" sess-a structure-reviewer=r1
mk "$CFG" sess-a r2 structure-reviewer "$FABLE" high - resumed-silent
run 2 "resumed after a handback, ended without a new report" "$CFG" sess-a structure-reviewer=r2
mk "$CFG" sess-a r3 correctness-reviewer "$OPUS" high - resumed-reported
run 0 "resumed and reported again" "$CFG" sess-a correctness-reviewer=r3
mk "$CFG" sess-a w5 correctness-reviewer "$OPUS" high - late
run 0 "late notification after the report" "$CFG" sess-a correctness-reviewer=w5

mk "$CFG" sess-a tr1 correctness-reviewer "$OPUS" high
printf '{"type":"assistant","message":{"mod' >> "$(sub sess-a)/agent-tr1.jsonl" || die "truncate"
run 2 "truncated jsonl" "$CFG" sess-a correctness-reviewer=tr1

mk "$CFG" sess-a e1 correctness-reviewer "$OPUS" medium
run 1 "effort mismatch" "$CFG" sess-a correctness-reviewer=e1
mk "$CFG" sess-a ne correctness-reviewer "$OPUS" -
run 1 "assistant record without effort" "$CFG" sess-a correctness-reviewer=ne

mk "$CFG" sess-a sy1 correctness-reviewer '<synthetic>' -
run 2 "only <synthetic> models" "$CFG" sess-a correctness-reviewer=sy1
mk "$CFG" sess-a sm1 correctness-reviewer "$OPUS" high
jq -n -c '{type:"assistant",message:{model:"<synthetic>",content:[]}}' \
  >> "$(sub sess-a)/agent-sm1.jsonl" || die "synthetic record"
run 0 "<synthetic> mixed with the pinned model" "$CFG" sess-a correctness-reviewer=sm1

run 2 "session id unset" "$CFG" UNSET correctness-reviewer=a1
run 2 "argument without =" "$CFG" sess-a correctness-reviewer
run 2 "duplicate type" "$CFG" sess-a correctness-reviewer=a1 correctness-reviewer=a2
run 2 "duplicate id" "$CFG" sess-a correctness-reviewer=a1 structure-reviewer=a1
mk "$CFG" sess-a nf1 noeffort-reviewer "$OPUS" high
run 2 "frontmatter without effort:" "$CFG" sess-a noeffort-reviewer=nf1

mk "$H/.claude" sess-h h1 correctness-reviewer "$OPUS" high
run 0 "CLAUDE_CONFIG_DIR unset → HOME/.claude" UNSET sess-h correctness-reviewer=h1
run 2 "CLAUDE_CONFIG_DIR set, missing" "$T/no such config" sess-a correctness-reviewer=a1
run 2 "CLAUDE_CONFIG_DIR set: no fallback to HOME/.claude" "$CFG" sess-h correctness-reviewer=h1

PROJ="$mapped-src" mk "$CFG" sess-sub u1 correctness-reviewer "$OPUS" high
run 0 "session launched from a subdirectory" "$CFG" sess-sub correctness-reviewer=u1
mk "$CFG" sess-dup d1 correctness-reviewer "$OPUS" high
PROJ="$mapped-other" mk "$CFG" sess-dup d1 correctness-reviewer "$OPUS" high
run 2 "session id under two project dirs" "$CFG" sess-dup correctness-reviewer=d1

[ "$n" -eq "$EXPECTED_CASES" ] \
  || { echo "finder-model-test: FAIL — ran $n cases, expected $EXPECTED_CASES"; exit 1; }
[ "$fail" -eq 0 ] || exit 1
echo "finder-model-test: OK ($n checks)"
