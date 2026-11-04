#!/usr/bin/env bash
# Offline smoke for the agent-mail channel step: team-mail-setup.sh (fresh / extend / reuse, the
# dry-run, the refusals) and the team-mail.sh client (check, name, --here, send/state, and ps
# bound to ONE box when two projects share role names). Every run uses a throwaway HOME with a
# space in its path; nothing reads or writes the real ~/.agent-mail.
# Bash 3.2 compatible (macOS /bin/bash).
set -euo pipefail

ST=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
SETUP="$ST/.claude/lib/team-mail-setup.sh"
MAIL="$ST/.claude/lib/team-mail.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/team-smoke-mail.XXXXXX")
BG=""
trap '[ -z "$BG" ] || kill "$BG" 2>/dev/null || true; rm -rf "$WORK"' EXIT
export HOME="$WORK/home dir" GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_NOSYSTEM=1
unset AGENT_MAIL_BOX CODEX_HOME
mkdir -p "$HOME"
printf '[user]\n  name = smoke\n  email = smoke@example.invalid\n' > "$GIT_CONFIG_GLOBAL"
REG="$HOME/.agent-mail/projects.json"

fail() { echo "team-smoke-mail: FAIL — $*"; [ ! -f "$WORK/out" ] || sed 's/^/  | /' "$WORK/out"; exit 1; }
has() { grep -qF -- "$1" "$WORK/out"; }
run() {  # run <dir> <cmd...> → RC, $WORK/out
  local d="$1"; shift
  set +e; (cd "$d" && "$@") > "$WORK/out" 2>&1; RC=$?; set -e
}
setup() { run "$1" /bin/bash "$SETUP" "$@"; }
mail() { run "$WORK" /bin/bash "$MAIL" "$@"; }
mkproj() {  # mkproj <name> → a repo with the vendored tool and the team ignore rule
  local p="$WORK/$1"
  mkdir -p "$p/tools"; git -C "$p" init --quiet
  cp -R "$ST/tools/agent_mail" "$p/tools/"
  printf '.agents/team/\n' > "$p/.gitignore"
  printf '%s' "$p"
}
treehash() { (cd "$1" && find . -type f -print | LC_ALL=C sort | while IFS= read -r f; do
  shasum -a 256 "$f"; done | shasum -a 256); }
lines() { grep -c "^$1	" "$WORK/out" || true; }

# ---- (1) fresh, dry-run: the plan, and not one byte written ------------------------------------
P1=$(mkproj p1)
setup "$P1" --dry-run --suffix XY
[ "$RC" = 0 ] || fail "1: fresh dry-run exit $RC"
has "mode	fresh	key p1" || fail "1: no fresh mode line"
has "create	registry" || fail "1: the plan does not create the registry"
[ "$(lines register)" = 3 ] || fail "1: expected 3 role registrations in the plan"
[ -z "$(ls -A "$HOME")" ] || fail "1: dry-run wrote into HOME"
[ ! -e "$P1/.agents" ] || fail "1: dry-run wrote the channel file"

# ---- (2) fresh: registry in the shared schema, box, roles, channel file -----------------------
setup "$P1" --suffix XY
[ "$RC" = 0 ] || fail "2: fresh exit $RC"
BOX1="$HOME/.agent-mail/p1/mail.sqlite"
[ -f "$BOX1" ] && [ -d "$HOME/.agent-mail/p1/decisions" ] || fail "2: no box or decisions dir"
jq -e --arg t "$(cd "$P1/tools/agent_mail" && pwd -P)" --arg b "$BOX1" '.p1 | .tool == $t and .box == $b
  and .suffix == "XY" and .claude_roles == ["Supervisor","TeamLead","Advisor"]
  and .codex_roles == ["Reviewer"] and has("rules") and has("codex_home") and has("repo")' "$REG" \
  >/dev/null || fail "2: registry entry has the wrong shape"
jq -e 'keys == ["AdvisorXY","SupervisorXY","TeamLeadXY"] and all(.[]; .adapter == "monitor")' \
  "$HOME/.agent-mail/p1/recipients.json" >/dev/null || fail "2: roles not registered as monitor"
jq -e --arg b "$BOX1" '.key == "p1" and .box == $b and (.kit_dir | type == "string")
  and has("tool") and has("decisions_dir") and has("codex_home")' \
  "$P1/.agents/team/channel.local.json" >/dev/null || fail "2: channel.local.json shape"
git -C "$P1" check-ignore -q .agents/team/channel.local.json || fail "2: channel file not ignored"
mail check; [ "$RC" = 0 ] && has "OK registry" || fail "2: registry check"
mail p1 check; [ "$RC" = 0 ] || fail "2: entry check"
run "$P1" /bin/bash "$MAIL" --here name Advisor
[ "$RC" = 0 ] && [ "$(cat "$WORK/out")" = AdvisorXY ] || fail "2: --here name"

# The client forwards with --box and puts the project label where each sub-parser wants it.
mail p1 send --from AdvisorXY --to SupervisorXY --kind turn --thread t1 --body hello
[ "$RC" = 0 ] && has "SENT id=1" || fail "2: send through the client"
mail p1 inbox --for SupervisorXY --unread
has "from=AdvisorXY kind=turn" || fail "2: inbox through the client"
mail p1 state set --expect-version 0 --stage design; [ "$RC" = 0 ] || fail "2: state set"
mail p1 state get --json
has '"project": "p1"' && has '"stage": "design"' || fail "2: state get did not use the label"

# ---- (3) re-run: reuse by repo, nothing new ---------------------------------------------------
H0=$(treehash "$HOME")
setup "$P1"
[ "$RC" = 0 ] && has "mode	reuse	key p1" || fail "3: re-run is not reuse"
[ "$(lines create)$(lines register)$(lines write)$(lines add)" = 0000 ] || fail "3: re-run planned writes"
[ "$(lines keep)" = 6 ] || fail "3: expected tool, box, 3 recipients and channel kept"

# ---- (4) extend: a second project next to the first, the first entry untouched ---------------
E1=$(jq -cS .p1 "$REG")
P2=$(mkproj p2)
setup "$P2" --suffix XY
[ "$RC" = 0 ] && has "mode	extend	key p2" || fail "4: second project is not extend"
has "create	registry" && fail "4: extend re-created the registry"
[ "$(jq -cS .p1 "$REG")" = "$E1" ] || fail "4: extend changed the first entry"
BOX2="$HOME/.agent-mail/p2/mail.sqlite"
[ -f "$BOX2" ] || fail "4: no second box"

# ---- (5) S1: same role names in two boxes — ps and pattern are bound to one box --------------
python3 -I "$P1/tools/agent_mail/agent_mail.py" --box "$BOX1" wait --for TeamLeadXY --timeout 30 \
  >/dev/null 2>&1 &
BG=$!
n=0; until pgrep -f "agent_mail.py --box $BOX1 wait" >/dev/null || [ $n -ge 50 ]; do n=$((n + 1)); sleep 0.1; done
mail p1 ps; grep -q "^$BG " "$WORK/out" || fail "5: ps of p1 misses its own wait loop"
mail p2 ps; grep -q "^$BG " "$WORK/out" && fail "5: ps of p2 lists p1's wait loop"
mail p1 pattern wait TeamLeadXY
pgrep -f "$(cat "$WORK/out")" | grep -qx "$BG" || fail "5: the wait pattern does not match its loop"
mail p2 pattern wait TeamLeadXY
pgrep -f "$(cat "$WORK/out")" | grep -qx "$BG" && fail "5: p2's pattern matches p1's loop"
kill "$BG" 2>/dev/null || true; wait "$BG" 2>/dev/null || true; BG=""

# ---- (6) reuse with a foreign tool: never rewritten, a foreign recipient never overwritten ----
OTHER="$WORK/other-tool"; cp -R "$ST/tools/agent_mail" "$OTHER"
P3=$(mkproj p3)
mkdir -p "$HOME/.agent-mail/shared/decisions"
printf '{"AdvisorQ": {"adapter": "codex-queue", "thread": "uuid-1"}}\n' \
  > "$HOME/.agent-mail/shared/recipients.json"
jq --arg b "$HOME/.agent-mail/shared/mail.sqlite" --arg t "$OTHER" --arg r "$P3" \
  --arg d "$HOME/.agent-mail/shared/decisions" '. + {SH: {box: $b, tool: $t, project_label: "SH",
  suffix: "Q", repo: $r, decisions_dir: $d, claude_roles: ["Owner"], codex_roles: [],
  rules: null, codex_home: null}}' "$REG" > "$WORK/reg" && mv "$WORK/reg" "$REG"
H0=$(treehash "$HOME")
setup "$P3" --dry-run
[ "$RC" = 0 ] && has "mode	reuse	key SH" || fail "6: foreign entry not reused by repo"
has "keep	tool	$OTHER" || fail "6: dry-run does not keep the entry's tool"
has "note	tool" || fail "6: no note that the vendored copy is unused"
has "keep	recipient	AdvisorQ (codex-queue)" || fail "6: an existing recipient is not kept"
[ "$(lines register)" = 2 ] || fail "6: expected the two missing roles only"
has "offer	roles" || fail "6: role names not offered"
[ "$(lines create)$(lines add)" = 00 ] || fail "6: reuse dry-run plans a new tool/box/entry"
[ "$(treehash "$HOME")" = "$H0" ] || fail "6: dry-run changed HOME"
setup "$P3" --add-roles
[ "$RC" = 0 ] || fail "6: reuse exit $RC"
jq -e --arg t "$OTHER" '.SH.tool == $t and .SH.claude_roles == ["Owner","Supervisor","TeamLead","Advisor"]
  and .SH.codex_roles == ["Reviewer"]' "$REG" >/dev/null || fail "6: tool rewritten or roles not appended"
jq -e '.AdvisorQ == {"adapter": "codex-queue", "thread": "uuid-1"} and .SupervisorQ.adapter == "monitor"' \
  "$HOME/.agent-mail/shared/recipients.json" >/dev/null || fail "6: recipients overwritten or missing"
[ -f "$HOME/.agent-mail/shared/mail.sqlite" ] || fail "6: the entry's tool did not open its box"

# ---- (7) refusals write nothing ---------------------------------------------------------------
P4=$(mkproj p4)
mkdir -p "$HOME/.agent-mail/p4"; : > "$HOME/.agent-mail/p4/mail.sqlite"
H0=$(treehash "$HOME")
setup "$P4"
[ "$RC" = 1 ] && has "no registry entry names it" || fail "7: an unregistered box was adopted"
[ "$(treehash "$HOME")" = "$H0" ] || fail "7: the refusal wrote"
setup "$P4" --key p1
[ "$RC" = 0 ] && has "mode	reuse	key p1" || fail "7: --key does not select an existing entry"
rm -rf "$P4/.agents"
setup "$P4" --key SH --slug p4b --dry-run
[ "$RC" = 0 ] || fail "7: --key of an existing entry with a slug"
cp "$REG" "$WORK/reg.ok"
jq '.p2.tool = "/elsewhere"' "$REG" > "$WORK/reg" && mv "$WORK/reg" "$REG"
mail check
[ "$RC" = 1 ] && has "one tool per box" && fail "7: different boxes reported as shared"
jq --arg b "$BOX1" '.p2.box = $b' "$REG" > "$WORK/reg" && mv "$WORK/reg" "$REG"
mail check; [ "$RC" = 1 ] && has "one tool per box" || fail "7: two tools on one box not caught"
jq 'del(.p2.tool)' "$WORK/reg.ok" > "$REG"
mail check; [ "$RC" = 1 ] && has "p2: missing tool" || fail "7: missing tool not caught"
H0=$(treehash "$HOME")
setup "$(mkproj p5)"
[ "$RC" = 1 ] && has "fails the schema check" || fail "7: wrote into an invalid registry"
[ "$(treehash "$HOME")" = "$H0" ] || fail "7: the schema refusal wrote"
cp "$WORK/reg.ok" "$REG"
P7=$(mkproj p7); mkdir -p "$P7/.claude"
printf '{"teams":{"channel":{"project_code":"p1"}}}\n' > "$P7/.claude/project-profile.json"
H0=$(treehash "$HOME")
setup "$P7"
[ "$RC" = 1 ] && has "key p1 already names the entry of" || fail "7: a taken key was not refused"
[ "$(treehash "$HOME")" = "$H0" ] || fail "7: the key refusal wrote"
jq '.p1.tool = "/nonexistent"' "$REG" > "$WORK/reg" && mv "$WORK/reg" "$REG"
mail p1 check; [ "$RC" = 1 ] && has "has no agent_mail.py" || fail "7: entry check misses the tool"
cp "$WORK/reg.ok" "$REG"

# ---- (8) profile names and the solo policy ---------------------------------------------------
P6=$(mkproj p6)
mkdir -p "$P6/.claude"
printf '{"schema":1,"teams":{"channel":{"project_code":"ZZ","mail_suffix":"Zz","advisor":"solo"}}}\n' \
  > "$P6/.claude/project-profile.json"
setup "$P6" --dry-run
[ "$RC" = 0 ] && has "mode	extend	key ZZ" && has "AdvisorZz (monitor)" || fail "8: profile names unused"
has "reviewer: none" || fail "8: solo still prints the Reviewer bring-up"

echo "team-smoke-mail: OK"
