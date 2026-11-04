#!/usr/bin/env bash
# stale human draft recovery in the role pane.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-lib.sh"
smoke_init
smoke_team AB-1200 chore/AB-1200-draft
RUN_ID=alfa-20261024-000000; echo "$RUN_ID" > "$TD/run"; RD="$TD/runs/$RUN_ID"; mkdir -p "$RD"
Q="bash .claude/lib/team-question.sh"
RULE="$(printf '─%.0s' $(seq 120))"; DASH="$(printf '╌%.0s' $(seq 120))"
export STUB_TMUX_ALIVE=0 STUB_PANE="$WORK/pane"
qid() { head -n 1 "$WORK/out" | cut -d' ' -f1; }
keyc() { grep -c '^tmux send-keys ' "$STUB_LOG" || true; }
keys() { grep '^tmux send-keys ' "$STUB_LOG" | sed 's/^tmux send-keys -t %1 //' | paste -sd '|' -; }
no_keys() { [ "$(keyc)" = 0 ] || fail "$1: keys were sent"; }
setpane() { cp "$1" "$WORK/pane"; }
inputpane() { sed "s/^❯ \$/❯ $2/" "$FIX/idle.txt" > "$1"; }
inputpane "$WORK/draft" half-typed
no_drafts() { [ ! -e "$RD/drafts" ] || fail "$1: a drafts file was written"; }
draft_is() {  # draft_is <label> — exactly one saved draft, holding `half-typed`
  local f; f="$(ls "$RD"/drafts/coder-1-*.txt 2>/dev/null || true)"
  [ "$(wc -l <<<"$f" | tr -d ' ')" = 1 ] && [ -n "$f" ] || fail "$1: drafts: $f"
  [ "$(cat "$f")" = half-typed ] || fail "$1: draft content $(cat "$f")"
}
blocked() {  # blocked <summary> → QS, a blocked q opened on the idle input
  record --verdict blocked --message "$1" >/dev/null
  setpane "$FIX/idle.txt"
  run "$MAIN" $Q alfa open coder --kind blocked --summary "$1"; expect 0 "" "open $1"; QS="$(qid)"
}
say() { run "$MAIN" $Q alfa answer "$QS" --tier 1 --author s --why w --text Counter. --send say; }
perm() {  # perm <file> <description> <command> — a Bash permission prompt in the real layout
  { echo "⏺ Running 1 shell command…"; echo "$RULE"; echo " Bash command"; echo " $2"; echo "$DASH"
    echo " │ $3"; echo "$DASH"; echo " This command requires approval"
    echo " Do you want to proceed?"
    echo " ❯ 1. Yes"; echo "   2. No"; echo " Esc to cancel · Tab to amend"; } > "$1"
}
LAST=""
fresh() {  # fresh <tool_use id> → Q1, a permission q of a new prompt instance
  [ -z "$LAST" ] || tool_done "$SID" "$LAST"
  pending_tool "$SID" "$1" Bash "$(jq -cn '{command: "ls -la", description: "List files"}')"
  LAST="$1"; perm "$WORK/pane" "List files" "ls -la"
  run "$MAIN" $Q alfa open coder --kind permission --anchor "List files" --summary "perm $1"
  expect 0 "" "open permission $1"; Q1="$(qid)"
}

SID=sid-coder-1; session coder 1 "$BASE" "$SID"
mkdir -p "$(dirname "$(transcript "$SID")")"
echo '{"type":"assistant","uuid":"a-w","message":{"content":[{"type":"text","text":"wait"}]}}' \
  > "$(transcript "$SID")"

# ---- (153) say over a single-line draft: saved, cleared, typed once ----------------------------
blocked "say over a draft"; setpane "$WORK/draft"; : > "$STUB_LOG"
STUB_ON_SENDKEYS="[ -e '$WORK/first' ] || ls '$RD/drafts' > '$WORK/first' 2>&1
  case \"\$*\" in *' C-u') cp '$FIX/idle.txt' '$WORK/pane' ;; esac" say
expect 0 "$QS state=sent" "say over a draft"
grep -q "^draft saved: .*/runs/$RUN_ID/drafts/coder-1-" "$WORK/out" \
  || fail "say over a draft: no draft saved line"
draft_is "say over a draft"
grep -q '^coder-1-.*\.txt$' "$WORK/first" || fail "the draft was not saved before the first key"
[ "$(keys)" = "C-e|C-u|-l -- Counter.|Enter" ] || fail "say over a draft: keys $(keys)"
echo "team-smoke-8: (153) say over a draft OK"

# ---- (154) the line does not clear: partial, no answer typed -----------------------------------
rm -rf "$RD/drafts"
blocked "draft stays"; setpane "$WORK/draft"; : > "$STUB_LOG"
say
expect 4 "unknown — 2 keys (draft not cleared (saved in " "draft not cleared"
draft_is "draft not cleared"
[ "$(keys)" = "C-e|C-u" ] || fail "draft not cleared: keys $(keys)"
echo "team-smoke-8: (154) draft not cleared OK"

# ---- (155) chips: their content is not on screen, so nothing is saved or sent ------------------
rm -rf "$RD/drafts"
for chip in "paste chip:[Pasted text #1 +12 lines]" "image chip:see [Image #1]"; do
  blocked "${chip%%:*}"; inputpane "$WORK/pane" "${chip#*:}"; : > "$STUB_LOG"
  say
  expect 5 "not sent — unreadable (draft not recoverable (${chip%%:*})" "${chip%%:*}"
  no_keys "${chip%%:*}"; no_drafts "${chip%%:*}"
done
echo "team-smoke-8: (155) chip refusals OK"

# ---- (156) a multi-line draft is no idle input surface -----------------------------------------
blocked "multi-line draft"
{ head -n 2 "$FIX/idle.txt"; echo "$RULE alfa-coder ─"; echo "❯ first line of a draft"
  echo "  second line"; echo "$RULE"; } > "$WORK/pane"; : > "$STUB_LOG"
say
expect 5 "not sent — unreadable (no idle input surface)" "multi-line draft"
no_keys "multi-line"; no_drafts "multi-line"
echo "team-smoke-8: (156) multi-line draft OK"

# ---- (157) the draft changed between the first capture and the last gate -----------------------
for later in "half-typed more" "half-typed [Pasted text #1]"; do
  blocked "draft changed to $later"; setpane "$WORK/draft"; inputpane "$WORK/later" "$later"
  : > "$STUB_LOG"
  STUB_ON_CAPTURE="[ \"\$(grep -c '^tmux capture-pane' \"\$STUB_LOG\")\" -lt 2 ] \
    || cp '$WORK/later' '$WORK/pane'" say
  expect 5 "not sent — changed (draft changed)" "draft changed to $later"
  no_keys "changed to $later"; no_drafts "changed to $later"
  ! grep -q "q=$QS " "$TD/send-coder.log" 2>/dev/null || fail "changed draft: dispatch line written"
done
echo "team-smoke-8: (157) draft changed OK"

# ---- (158) no: Claude Code restores the draft after Escape --------------------------------------
fresh toolu_d1; : > "$STUB_LOG"
STUB_ON_SENDKEYS="case \"\$*\" in *' Escape') cp '$WORK/draft' '$WORK/pane' ;;
  *' C-u') cp '$FIX/idle.txt' '$WORK/pane' ;; esac" \
  run "$MAIN" $Q alfa answer "$Q1" --tier 1 --author s --why w --text "not now" --send no
expect 0 "$Q1 state=sent" "no over a restored draft"
grep -q "^draft saved: .*/runs/$RUN_ID/drafts/coder-1-" "$WORK/out" \
  || fail "no: no draft saved line"
draft_is "no over a restored draft"
k="$(keys)"
[ "${k%%|-l -- *}" = "Escape|C-e|C-u" ] && [ "${k##*|}" = Enter ] \
  && [ "$(grep -c ' Enter$' "$STUB_LOG")" = 1 ] && has "-l -- Rejected by the developer: not now" \
  "$STUB_LOG" || fail "no over a restored draft: keys $k"
echo "team-smoke-8: (158) no over a restored draft OK"

# ---- (159) pick and yes act on the open prompt only --------------------------------------------
rm -rf "$RD/drafts"
fresh toolu_d2; : > "$STUB_LOG"
run "$MAIN" $Q alfa answer "$Q1" --tier 1 --author s --why w --send yes
expect 0 "$Q1 state=" "yes"; [ "$(keys)" = Enter ] || fail "yes: keys $(keys)"
SID=sid-planner-1; session planner 1 "$BASE" "$SID"
mkdir -p "$(dirname "$(transcript "$SID")")"
cp "$FIX/t-menu-pending.jsonl" "$(transcript "$SID")"
setpane "$FIX/menu-phase0.txt"
run "$MAIN" $Q alfa open planner --kind menu --anchor "Phase 0" --summary "phase 0"
expect 0 "" "open menu"; QM="$(qid)"; : > "$STUB_LOG"
run "$MAIN" $Q alfa answer "$QM" --tier 1 --author s --why w --send pick:2
expect 0 "$QM state=" "pick"; [ "$(keys)" = "Down|Enter" ] || fail "pick: keys $(keys)"
no_drafts "pick and yes"
echo "team-smoke-8: (159) pick and yes unaffected OK"

echo "team-smoke-8: OK"
