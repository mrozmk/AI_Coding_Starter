#!/usr/bin/env bash
# wrapped Bash description, transient review frames, footered review, prompt still
# rendering, parser-first snapshot detection.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-lib.sh"
smoke_init
smoke_team AB-1157 chore/AB-1157-parser
RUN_ID=alfa-20261020-110000; echo "$RUN_ID" > "$TD/run"; RD="$TD/runs/$RUN_ID"; mkdir -p "$RD"
PY="$SRC/.claude/lib/team_prompt.py"
RULE="$(printf '─%.0s' $(seq 120))"
export STUB_TMUX_ALIVE=0 STUB_PANE="$WORK/pane"
pj() {  # pj <fixture> <jq condition> — parser output check
  python3 -I "$PY" parse < "$1" > "$WORK/p.json"
  jq -e "$2" "$WORK/p.json" >/dev/null || { cp "$WORK/p.json" "$WORK/out"; fail "parse $1: $2"; }
}
fpof() { python3 -I "$PY" parse < "$1" | jq -r .fp; }

# ---- (110) C2: a wrapped Bash description parses whole --------------------------------------
# perm-desc-wrap.txt is constructed from the real layout of perm-awk.txt (no wrapped capture).
WRAP="Fetch the current description of PR 8583 into the scratchpad so the gate can"
WRAP="$WRAP compare it with the draft"
pj "$FIX/perm-desc-wrap.txt" '.kind == "permission" and .complete and .desc == "'"$WRAP"'"'
pj "$FIX/perm-awk.txt" '.desc == "Fetch current PR 8583 description"'
DASH="$(printf '╌%.0s' $(seq 120))"
{ echo "$RULE"; echo " Bash command"; echo "$DASH"; echo " │ ls"; echo "$DASH"
  echo " Do you want to proceed?"; echo " ❯ 1. Yes"; echo "   2. No"; echo " Esc to cancel"; } \
  > "$WORK/nodesc"
pj "$WORK/nodesc" '.kind == "permission" and .complete and .desc == "" and .command == "ls"'
echo "team-smoke-6: (110) wrapped description OK"

# ---- (111) C3: a transient frame before the review is unreadable ----------------------------
sed 's/^❯ 1\. \[ \] Apple/  1. [ ] Apple/; s/^     Submit$/❯    Submit/' "$FIX/checkbox.txt" \
  > "$WORK/submit-frame"
pj "$WORK/submit-frame" '(.complete | not) and .reason == "unreadable: missing unique Submit row"'
echo "team-smoke-6: (111) transient review frame OK"

# ---- (112) C4: a review that ends in the menu footer ----------------------------------------
# review-footer.txt is constructed from the real layouts of review.txt and checkbox.txt.
pj "$FIX/review-footer.txt" '.kind == "review" and .complete and .review.ready
  and .review.submit_cursor'
[ "$(fpof "$FIX/review-footer.txt")" = "$(fpof "$FIX/review.txt")" ] \
  || fail "the footer changed the review fingerprint"
sed 's/<description>/Review your answers/' "$FIX/checkbox.txt" > "$WORK/quote-review"
pj "$WORK/quote-review" '.kind == "checkbox" and .other == 4'
sed '$d' "$WORK/quote-review" > "$WORK/quote-review-nofooter"
pj "$WORK/quote-review-nofooter" '.kind != "review"'
echo "team-smoke-6: (112) footered review OK"

# ---- (113) C5: a prompt still rendering is not a question yet -------------------------------
# An old prompt left in the scrollback never makes a later, unknown bottom "still rendering".
{ sed '$d' "$FIX/perm-awk.txt"; echo "⏺ Gotowe."; echo " Some dialog"; } > "$WORK/old-out"
pj "$WORK/old-out" '.reason == "unreadable: no idle input surface"'
{ sed '$d' "$FIX/perm-awk.txt"; echo "$RULE alfa-coder ─"; echo "❯ first line of a draft"
  echo "  second line"; echo "$RULE"; } > "$WORK/old-draft"
pj "$WORK/old-draft" '.reason == "unreadable: no idle input surface"'
{ cat "$FIX/idle.txt"; echo "$RULE"; echo " Bash command"; echo " x"; } > "$WORK/rendering"
pj "$WORK/rendering" '(.complete | not)'
echo "team-smoke-6: (113) prompt still rendering OK"

# ---- (114) snapshot detection follows the parse --------------------------------------------
SID=sid-coder-1; session coder 1 "$BASE" "$SID"
mkdir -p "$(dirname "$(transcript "$SID")")"
echo '{"type":"assistant","uuid":"a-c","message":{"content":[{"type":"text","text":"x"}]}}' \
  > "$(transcript "$SID")"
STUB_PANE="$FIX/busy-stale-yes.txt" snap "busy with prompt-like text" \
  'coder | (.prompt_open | not) and (.menu_open | not)'
STUB_PANE="$FIX/perm-awk.txt" snap "permission prompt" \
  'coder | .prompt_open and .status == "attention"
    and .actions == ["bash .claude/lib/session-host.sh hint alfa-coder", "/start-team alfa"]'
STUB_PANE="$FIX/menu-wrapup.txt" snap "menu" 'coder | .menu_open'
STUB_PANE="$FIX/idle.txt" snap "idle" 'coder | (.prompt_open | not) and (.menu_open | not)'
( . "$SRC/.claude/lib/team-lib.sh"; STUB_PANE="$FIX/busy-stale-yes.txt" \
  team_prompt_open alfa-coder ) \
  || fail "busy-stale-yes.txt no longer exercises the regex false positive"
echo "team-smoke-6: (114) parser-first detection OK"

# ---- (115) an unreadable screen falls back to the regexes ---------------------------------
printf 'Bash command\n  ls\nDo you want to proceed?\n❯ 1. Yes\n' > "$WORK/pane-min"
pj "$WORK/pane-min" '(.complete | not)'
STUB_PANE="$WORK/pane-min" snap "unreadable fallback" 'coder | .prompt_open'
echo "team-smoke-6: (115) regex fallback OK"

echo "team-smoke-6: OK"
