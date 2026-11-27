#!/usr/bin/env bash
# Offline test of #323 Supervisor clearance: the clearance checker (guard_team_egress_clear.py) over
# the matrix in fixtures/clearance/inputs.txt, the switch, seal and ledger (team-clearance.sh), the
# role-profile hook (team-clearance-hook.sh, carrier A), the stage carrier (team-ask-hook.sh,
# carrier B), the T3 narrowing, the touch-log kinds and the materialised profiles. The fixture is
# team-batch-test.sh's shape: a main checkout (a copy of this .claude/, its session-host driver a
# stub that records rings), a fixture clone, a starter with registered worktrees, a registered
# Supervisor whose transcript the test appends typed messages and tool calls to, `gh` a stub and
# an offline resolver (fixtures/clearance/drive.py). No screen, no session, no network.
# Usage: bash team-clearance-test.sh [--section <name>]…   (checker classes pass rules shadow enforce
#   refusals switch seal ledger stage write-guard T3 log profiles; default: all)
# Exit 1 on any FAIL, on a fixture setup error, or when the selected sections ran no PASS (R1-12).
set -u
SRC="$(cd "$(dirname "$0")/../../.." && pwd)"
FX="$(cd "$(dirname "$0")" && pwd)/fixtures/clearance"
SECTIONS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --section) [ $# -ge 2 ] || { echo "usage: $0 [--section <name>]…" >&2; exit 2; }; SECTIONS="$SECTIONS $2"; shift 2 ;;
    *) echo "usage: $0 [--section <name>]…" >&2; exit 2 ;;
  esac
done
want() { [ -n "$SECTIONS" ] || return 0; case " $SECTIONS " in *" $1 "*) return 0 ;; esac; return 1; }
T=$(mktemp -d "${TMPDIR:-/tmp}/team-clearance.XXXXXX") || { echo "team-clearance-test: FAIL — mktemp"; exit 1; }
T="$(cd "$T" && pwd -P)"
cleanup() { [ -z "${SUPLOOP:-}" ] || kill "$SUPLOOP" 2>/dev/null
  pkill -9 -f "$T/main/.claude/hooks/" 2>/dev/null; kill $(jobs -p) 2>/dev/null; wait 2>/dev/null
  [ -n "${TEAM_CLEARANCE_KEEP:-}" ] && echo "kept: $T" || rm -rf "$T"; }
trap cleanup EXIT
die() { echo "team-clearance-test: FAIL — fixture setup: $1"; exit 1; }
unset ${!HARNESS_@} TEAM_SESSION_ROLE TEAM_RUN_TEAM TEAM_RUN_ROLE TEAM_RUN_ID TEAM_RUN_ATTEMPT TEAM_CLEARANCE_SEAL \
  TEAM_CLEARANCE_HOST TEAM_CLEARANCE_WAIT TEAM_CLEARANCE_RULES TEAM_CLEARANCE_RESOLVER GH_REPO GH_HOST TOUCHES_BLOCK_OFF \
  CLAUDE_PROJECT_DIR CLAUDE_CONFIG_DIR CLAUDE_CODE_PLUGIN_DIRS CLAUDE_CODE_PLUGIN_CACHE_DIR CLAUDE_CODE_MESSAGING_SOCKET CLAUDE_CODE_MESSAGING_TOKEN TMUX TMUX_PANE
export HOME="$T/home" GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1 TOUCHES_GRACE_S=0
mkdir -p "$HOME" "$T/bin" "$T/cc" || die "dirs"
printf '[user]\n  name = t\n  email = t@example.invalid\n[init]\n  defaultBranch = main\n' > "$GIT_CONFIG_GLOBAL"
n=0; fail=0; passed=0
ok() { n=$((n + 1)); if ! eval "$1"; then echo "FAIL [$2]"; fail=1; else echo "PASS [$2]"; passed=$((passed + 1)); fi; }
j() { jq -r "$2" "$1" 2>/dev/null; }
gcommit() { git -C "$1" add -A >/dev/null && git -C "$1" commit -qm "${2:-c}" >/dev/null; }

# ---- fixture: main checkout, starter + worktrees, clones, side repos ----------------------------
MAIN="$T/main"; CLONE="$T/clone"; CLONE2="$T/clone2"; ST="$T/starter"; RINGS="$T/rings.log"; : > "$RINGS"
WT="$T/starter-beta-9"; WT8="$T/starter-beta-8"; FAKEWT="$T/starter-gamma-9"
LOCK="$T/lock"; LOCK2="$T/lock2"; PIP="$T/pip"; OTHER="$T/other"; AP="$T/askproj"
export STUB_MAIN="$MAIN" STUB_RINGS="$RINGS"
mkdir -p "$MAIN/.agents/team/anchors" "$MAIN/.agents/team/registry" && cp -R "$SRC/.claude" "$MAIN/.claude" || die "main"
cat > "$MAIN/.claude/lib/session-host-lib.sh" <<'EOF' || die "driver stub"
SH_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sh_main_root() { echo "$STUB_MAIN"; }
sh_send() { echo "$1 $2" >> "$STUB_RINGS"; }
sh_kill() { echo "KILL $1" >> "$STUB_RINGS"; }
sh_hint() { echo "hint $1"; }
sh_record_get() { :; }
sh_reg_dir() { echo "$STUB_MAIN/.agents/team/registry"; }
sh_inbox_session() { echo "$2"; }
sh_alive() { [ -e "$STUB_MAIN/.sup-alive" ]; }
EOF
cat > "$T/bin/gh" <<'EOF' || die "gh stub"
#!/bin/sh
echo "{}"
EOF
chmod +x "$T/bin/gh"; export PATH="$T/bin:$PATH"
prof() {  # prof <out> — the fixture's teams profile (own repo acme/widgets, project acme #4)
  jq --arg p "$T" '.teams.pr_provider = "github" | .teams.tracker = "none" | .teams.starter_root = "../starter"
    | .teams.github = {repo: "acme/widgets", project_owner: "acme", project_number: 4}
    | .teams.clone_parent = $p | .teams.clone_name = "clone-{team}"' "$SRC/.claude/project-profile.json.example" > "$1"
}
prof "$MAIN/.claude/project-profile.json" || die "main profile"
printf '{"permissions": {"allow": ["WebFetch(domain:intranet-mirror.acme-docs.com)"]}}\n' > "$MAIN/.claude/settings.local.json"
printf '%s\n' "$T/cc" > "$MAIN/.claude/claude-profile"
printf 'body of the comment\n' > "$MAIN/body.md"
printf '.agents/team/\n.agents/touches/\n' > "$MAIN/.gitignore"
git -C "$MAIN" init -q && git -C "$MAIN" remote add origin https://github.com/acme/widgets && gcommit "$MAIN" main || die "main git"
# The materialised Advisor and Supervisor profiles: the template's rules ∪ the project's (R1-5).
for r in Advisor Supervisor; do
  jq -s '{permissions: {allow: (.[0].permissions.allow // []), deny: ([.[].permissions.deny // [] | .[]] | unique),
      ask: ([.[].permissions.ask // [] | .[]] | unique)}}' "$MAIN/.claude/team/sessions/$r.settings.json" \
    "$MAIN/.claude/settings.json" "$MAIN/.claude/settings.local.json" > "$T/$r.settings.json" || die "$r profile"
done
mkdir -p "$AP/.claude" && cp "$MAIN/.claude/settings.json" "$AP/.claude/settings.json" && prof "$AP/.claude/project-profile.json" || die "askproj"
printf '{"permissions": {"ask": ["WebFetch(domain:docs.python.org)"]}}\n' > "$AP/.claude/settings.local.json"
git -C "$AP" init -q && git -C "$AP" remote add origin https://github.com/acme/widgets && gcommit "$AP" || die "askproj git"
mkdir -p "$ST" && printf 'starter\n' > "$ST/README.md" && git -C "$ST" init -q && gcommit "$ST" starter || die "starter"
git -C "$ST" worktree add -q "$WT" -b wt9 >/dev/null 2>&1 && git -C "$ST" worktree add -q "$WT8" -b wt8 >/dev/null 2>&1 || die "worktrees"
mkdir -p "$FAKEWT" && printf 'a\n' > "$FAKEWT/README.md"
mkclone() {  # mkclone <dir> <team> <ticket> — a team clone with its run, session and anchor
  local c="$1" b
  mkdir -p "$c" && git -C "$c" init -q && cp -R "$SRC/.claude" "$c/.claude" || return 1
  prof "$c/.claude/project-profile.json" || return 1
  printf '{"permissions": {"ask": ["Edit(**/prod-config/**)"]}}\n' > "$c/.claude/settings.local.json"
  printf 'probe\n' > "$c/README.md"; printf '.agents/team/\n' > "$c/.gitignore"
  git -C "$c" remote add origin https://github.com/acme/widgets && gcommit "$c" base || return 1
  b="$(git -C "$c" rev-parse HEAD)"; mkdir -p "$c/.agents/team/runs/$2-20260101-000000"
  jq -n --arg t "$2" --arg k "$3" --arg b "$b" '{team: $t, ticket: $k, branch: "feat/x", line: "main", base_sha: $b, mode: "brainstorm"}' > "$c/.agents/team/team.json"
  echo "$2-20260101-000000" > "$c/.agents/team/run"
  jq -n --arg t "$2" --arg k "$3" --arg r "$2-20260101-000000" '{team: $t, role: "coder", run: $r, round: 1, attempt: 1, session_id: "sid-1", ticket: $k}' > "$c/.agents/team/session.json"
  jq -n --arg t "$2" --arg r "$2-20260101-000000" --arg m "$MAIN" --arg cc "$T/cc" '{team: $t, run: $r, session_id: "lid-1", main_root: $m, claude_config_dir: $cc}' > "$c/.agents/team/teamlead.json"
  jq -n --arg t "$2" --arg k "$3" --arg b "$b" --arg c "$(cd "$c" && pwd -P)" --arg r "$2-20260101-000000" --arg cc "$T/cc" \
    '{team: $t, ticket: $k, branch: "feat/x", line: "main", base_sha: $b, clone: $c, run: $r, role: "coder", attempt: 1,
      session_id: "sid-1", lead_sessions: {run: $r, ids: ["lid-1"], current_id: "lid-1", config_dir: $cc}}' > "$MAIN/.agents/team/anchors/$2.json"
}
mkclone "$CLONE" beta 9 && mkclone "$CLONE2" gamma 9 && ln -s "$CLONE" "$T/clone-beta" || die "clones"
RUN="beta-20260101-000000"
mkrepo() { mkdir -p "$1" && git -C "$1" init -q && { [ -z "${2:-}" ] || git -C "$1" remote add origin "$2"; }; }
mkrepo "$LOCK" && printf '{"name":"w","version":"1.0.0"}\n' > "$LOCK/package.json" && printf '{"lockfileVersion":3}\n' > "$LOCK/package-lock.json" && gcommit "$LOCK" || die "lock"
mkrepo "$LOCK2" && cp "$LOCK/package.json" "$LOCK/package-lock.json" "$LOCK2/" && gcommit "$LOCK2" && printf '{"lockfileVersion":3,"x":1}\n' > "$LOCK2/package-lock.json" || die "lock2"
mkrepo "$PIP" && printf 'six==1.16.0 --hash=sha256:%064d\n' 0 > "$PIP/requirements.txt" && printf -- '-r requirements.txt\n' > "$PIP/nested.txt" && gcommit "$PIP" || die "pip"
mkrepo "$OTHER" https://github.com/evil/other && printf 'x\n' > "$OTHER/f" && gcommit "$OTHER" || die "other"

# ---- the checker CLI ------------------------------------------------------------------------------
fill() { sed -e "s|@MAIN@|$MAIN|g" -e "s|@CLONE@|$CLONE|g" -e "s|@WT8@|$WT8|g" -e "s|@WT@|$WT|g" -e "s|@FAKEWT@|$FAKEWT|g" \
  -e "s|@LOCK2@|$LOCK2|g" -e "s|@LOCK@|$LOCK|g" -e "s|@PIP@|$PIP|g" -e "s|@OTHER@|$OTHER|g" <<<"$1"; }
ctxof() {  # ctxof <ctx> → CP (project) CX (checker ctx) CR (rules file or "") CE (role env)
  case "$1" in
    advisor) CP="$MAIN"; CX=advisor; CR="$T/Advisor.settings.json"; CE=Advisor ;;
    asks) CP="$AP"; CX=advisor; CR="$T/Advisor.settings.json"; CE=Advisor ;;
    supervisor) CP="$MAIN"; CX=supervisor; CR="$T/Supervisor.settings.json"; CE=Supervisor ;;
    teamlead) CP="$CLONE"; CX=teamlead; CR=""; CE=TeamLead ;;
    stage) CP="$CLONE"; CX=stage; CR=""; CE="" ;;
    stage2) CP="$CLONE2"; CX=stage; CR=""; CE="" ;;
    *) return 1 ;;
  esac
}
CK() {  # CK <ctx> <tool> <cwd|-> <tool_input json> [extra args…] → $T/ck.out, CKR (result[:class])
  local ctx="$1" tool="$2" cwd="$3" inp="$4"; shift 4
  ctxof "$ctx" || return 1
  [ "$cwd" != - ] || cwd="$CP"
  jq -n --arg t "$tool" --argjson i "$inp" --arg c "$cwd" '{tool_name: $t, tool_input: $i, cwd: $c}' > "$T/ck.in" || return 1
  (cd "$cwd" && env ${CE:+TEAM_SESSION_ROLE=$CE} CLAUDE_PROJECT_DIR="$CP" python3 -I "$FX/drive.py" "$MAIN/.claude/hooks/lib" \
    classify --input-json "$T/ck.in" --project "$CP" --ctx "$CX" --main "$MAIN" ${CR:+--rules "$CR"} "$@") > "$T/ck.out" 2> "$T/ck.err"
  CKRC=$?
  CKR="$(sed -n 's/^result: //p' "$T/ck.out")"
  [ "$CKR" != clearable ] || CKR="clearable:$(sed -n 's/^class: //p' "$T/ck.out")"
}

# ================================================================================================
if want checker || want classes || want pass || want rules; then
  while IFS='|' read -r exp ctx tool cwd label inp; do
    case "$exp" in ''|'#'*) continue ;; esac
    inp="$(fill "$inp")"; cwd="$(fill "$cwd")"
    CK "$ctx" "$tool" "$cwd" "$inp"
    short="$(jq -r '.command // .url // .file_path // ""' <<<"$inp" | head -n 1 | cut -c1-70)"
    ok '[ "$CKR" = "$exp" ]' "#323 checker: $exp $ctx $tool $short (got ${CKR:-none: rc $CKRC $(head -c 200 "$T/ck.err")}; $(sed -n 's/^reason: //p' "$T/ck.out"))"
    [ -z "$label" ] || ok '[ "$CKR" = "$exp" ]' "$label"
  done < "$FX/inputs.txt"
  # AC-8 and AC-7 by name (the plan's proofs name these cases in this file).
  CK advisor Bash - '{"command":"curl -o f https://docs.python.org/3/"}'
  ok '[ "$CKR" = none ]' "#323 pass: curl -o is not a pass"
  CK asks WebFetch - '{"url":"https://docs.python.org/3/","prompt":"p"}'
  ok '[ "$CKR" = hard ]' "#323 rules: project ask on WebFetch is hard"
fi
CLEAR="$MAIN/.claude/hooks/lib/guard_team_egress_clear.py"
if want checker; then
  # R1-8: production reads no resolver setting — an unresolvable public name stays none there.
  U='{"command":"curl -s https://zz323-unresolvable-host-example.com/x?y=1"}'
  CK advisor Bash - "$U"; viadrive="$CKR"
  jq -n --argjson i "$U" --arg c "$MAIN" '{tool_name: "Bash", tool_input: $i, cwd: $c}' > "$T/u.json"
  prod="$(cd "$MAIN" && TEAM_CLEARANCE_RESOLVER=stub TEAM_SESSION_ROLE=Advisor python3 -I "$CLEAR" classify --input-json "$T/u.json" \
    --project "$MAIN" --ctx advisor --main "$MAIN" --rules "$T/Advisor.settings.json" | sed -n 's/^result: //p')"
  ok '[ "$viadrive" = clearable:public-get-long ] && [ "$prod" = none ] && ! grep -q "TEAM_CLEARANCE_RESOLVER" "$CLEAR"' \
    "#323 checker: production ignores a resolver env (drive $viadrive, production $prod)"
  # R2-3: the lockfile is compared with HEAD's blob through the hardened reader — no clean filter runs.
  git -C "$LOCK" config filter.x.clean "touch $T/invoked; cat"; printf '* filter=x\n' > "$LOCK/.gitattributes"
  CK advisor Bash "$LOCK" '{"command":"npm ci --ignore-scripts"}'
  ok '[ "$CKR" = clearable:lockfile-install ] && [ ! -e "$T/invoked" ]' "#323 checker: an inert clean filter is never invoked ($CKR)"
  rm -f "$LOCK/.gitattributes"; git -C "$LOCK" config --unset filter.x.clean
  # R1-6: the policy digest covers the load closure of the trusted code; a missing member fails closed.
  d1="$(python3 -I "$CLEAR" digest --main "$MAIN")"; drc=$?
  cp "$MAIN/.claude/hooks/lib/clearance-classes.json" "$T/classes.keep"
  jq '.trusted_code -= [".claude/lib/team_transcript.py"]' "$T/classes.keep" > "$MAIN/.claude/hooks/lib/clearance-classes.json"
  python3 -I "$CLEAR" digest --main "$MAIN" > "$T/d2" 2>&1; d2rc=$?
  # team-lib.sh loads it as `[ -n "${SH_LIB:-}" ] || . "$(dirname "${BASH_SOURCE[0]}")/session-host-lib.sh"`.
  jq '.trusted_code -= [".claude/lib/session-host-lib.sh"]' "$T/classes.keep" > "$MAIN/.claude/hooks/lib/clearance-classes.json"
  python3 -I "$CLEAR" digest --main "$MAIN" > "$T/d3" 2>&1; d3rc=$?
  cp "$T/classes.keep" "$MAIN/.claude/hooks/lib/clearance-classes.json"
  ok '[ "$drc" = 0 ] && [[ "$d1" =~ ^1-[0-9a-f]{16}$ ]] && [ "$d2rc" = 1 ] && grep -q "team_transcript.py" "$T/d2"' \
    "#323 checker: an imported module missing from trusted_code fails closed ($d1; $(cat "$T/d2"))"
  ok '[ "$d3rc" = 1 ] && grep -q "session-host-lib.sh" "$T/d3"' \
    "#323 checker: a library sourced after || with a quoted dirname path fails closed ($(cat "$T/d3"))"
  # R2-8 / R3-1: a launch rule digest that differs, a missing profile, a foreign guard → no decision.
  rd="$(python3 -I "$CLEAR" rules-digest --project "$MAIN" --rules "$T/Advisor.settings.json")"
  CK advisor Bash - '{"command":"gh issue view 1"}' --launch-rules "$rd"; same="$CKR"
  CK advisor Bash - '{"command":"gh issue view 1"}' --launch-rules 0000; other="$CKR"
  ok '[ "$same" = pass ] && [ "$other" = none ] && grep -q "rules changed" "$T/ck.out"' "#323 checker: the profile replaced after launch gives no decision ($same / $other)"
  jq '.hooks.PreToolUse = [{matcher: "Bash", hooks: [{type: "command", command: "python3 -I /x/permission_probe.py hook --log /tmp/p.log"}]}]' \
    "$T/Advisor.settings.json" > "$T/Foreign.settings.json"
  CR_KEEP="$T/Advisor.settings.json"; cp "$T/Foreign.settings.json" "$T/Advisor.settings.json"
  CK advisor Bash - '{"command":"gh issue view 1"}'; fg="$CKR"
  jq 'del(.hooks)' "$T/Foreign.settings.json" > "$T/Advisor.settings.json"
  ok '[ "$fg" = none ] && grep -q "does not reproduce" "$T/ck.out"' "#323 checker: a foreign guard asking on gh issue view gives no decision ($fg)"
  printf '{"permissions": {"ask": ["Bash(gh issue view*)"]}}\n' > "$T/cc/settings.json"
  CK advisor Bash - '{"command":"gh issue view 1"}'; us="$CKR"; rm -f "$T/cc/settings.json"
  ok '[ "$us" = hard ]' "#323 checker: an ask only in the user profile is hard ($us; $(sed -n 's/^reason: //p' "$T/ck.out"))"
  # R3-1: hooks an enabled plugin brings — team-evidence.sh's inventory decides; unknown is no decision.
  PG="$T/plug"; mkdir -p "$PG/mk/.claude-plugin" "$PG/quiet/.claude-plugin" "$PG/asker/.claude-plugin" "$PG/asker/hooks" "$T/cc/plugins"
  printf '{"plugins": [{"name": "quiet"}, {"name": "asker"}]}\n' > "$PG/mk/.claude-plugin/marketplace.json"
  printf '{"name": "quiet"}\n' > "$PG/quiet/.claude-plugin/plugin.json"; printf '{"name": "asker"}\n' > "$PG/asker/.claude-plugin/plugin.json"
  printf '{"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "ask.sh"}]}]}}\n' > "$PG/asker/hooks/hooks.json"
  jq -n --arg m "$PG/mk" '{mk: {installLocation: $m}}' > "$T/cc/plugins/known_marketplaces.json"
  jq -n --arg q "$PG/quiet" --arg a "$PG/asker" '{plugins: {"quiet@mk": [{installPath: $q}], "asker@mk": [{installPath: $a}]}}' > "$T/cc/plugins/installed_plugins.json"
  plug() { printf '{"enabledPlugins": {"%s": true}}\n' "$1" > "$T/cc/settings.json"; CK advisor Bash - '{"command":"gh issue view 1"}'; rm -f "$T/cc/settings.json"; }
  plug quiet@mk; pq="$CKR"; plug asker@mk; pa="$CKR"; pa_why="$(sed -n 's/^reason: //p' "$T/ck.out")"; plug ghost@mk; pg="$CKR"
  ok '[ "$pa" = none ] && grep -q "plugin hooks not reproduced" <<<"$pa_why"' "#323 checker: a plugin with an asking PreToolUse hook gives no decision ($pa; $pa_why)"
  ok '[ "$pq" = pass ]' "#323 checker: a hook-free plugin leaves the decision unchanged ($pq)"
  ok '[ "$pg" = none ]' "#323 checker: an unresolvable plugin gives no decision ($pg)"
  CK advisor Bash - '{"command":"gh issue comment 5 --body x"}' --binding '{"session_id":"s","role":"Advisor"}'
  h1="$(sed -n 's/^hash: //p' "$T/ck.out")"
  CK advisor Bash - '{"command":"gh issue comment 5 --body x"}' --binding '{"session_id":"t","role":"Advisor"}'
  h2="$(sed -n 's/^hash: //p' "$T/ck.out")"
  ok '[[ "$h1" =~ ^[0-9a-f]{64}$ ]] && [ "$h1" != "$h2" ]' "#323 checker: the request hash binds the session"
fi

# ---- the switch, the ledger and the Supervisor's transcript ---------------------------------------
jq -n --arg c "$MAIN" '{address: "Supervisor", session_id: "sup-1", cwd: $c}' > "$MAIN/.agents/team/registry/Supervisor.json"
SUPT="$T/cc/projects/$(printf '%s' "$MAIN" | sed 's/[^A-Za-z0-9]/-/g')/sup-1.jsonl"; mkdir -p "$(dirname "$SUPT")"
jq -nc '{type: "user", uuid: "u-start", timestamp: "2026-01-01T00:00:00Z", message: {role: "user", content: "hello"}}' > "$SUPT"
utc() { date -u -r $(( $(date +%s) + ${1:-0} )) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$(( $(date +%s) + ${1:-0} ))" +%Y-%m-%dT%H:%M:%SZ; }
umsg=0
say_sup() {  # say_sup <text> [<seconds from now>] — the Operator types a whole message in the Supervisor window
  umsg=$((umsg + 1))
  jq -nc --arg u "u-op-$umsg" --arg t "$1" --arg ts "$(utc "${2:-0}")" '{type: "user", uuid: $u, timestamp: $ts, message: {role: "user", content: $t}}' >> "$SUPT"
}
sup_call() {  # sup_call <command> [error] — the Supervisor's own Bash call and its result in its transcript
  umsg=$((umsg + 1))
  jq -nc --arg i "toolu_$umsg" --arg c "$1" --arg ts "$(utc)" '{type: "assistant", uuid: "a-\($i)", timestamp: $ts,
    message: {role: "assistant", content: [{type: "tool_use", id: $i, name: "Bash", input: {command: $c}}]}}' >> "$SUPT"
  jq -nc --arg i "toolu_$umsg" --arg ts "$(utc)" --argjson e "$([ -n "${2:-}" ] && echo true || echo false)" '{type: "user", uuid: "r-\($i)", timestamp: $ts,
    message: {role: "user", content: [{type: "tool_result", tool_use_id: $i, content: "ok", is_error: $e}]}, toolUseResult: {stdout: "ok"}}' >> "$SUPT"
}
CL() { (cd "$MAIN" && env TEAM_SESSION_ROLE=Supervisor bash "$MAIN/.claude/lib/team-clearance.sh" "$@") > "$T/cl.out" 2>&1; CLRC=$?; }
SANS() {  # SANS <id> <verdict> — the Supervisor answers through the script, and the call is in its transcript
  CL answer "$1" "$2"; [ "$CLRC" != 0 ] || sup_call "bash .claude/lib/team-clearance.sh answer $1 $2"
}
LIBRUN() {  # LIBRUN <function> <args…> — a team-clearance.sh helper from the main checkout → $T/lr.out, LRRC
  (cd "$MAIN" && . .claude/lib/team-lib.sh && . .claude/lib/team-lead-lib.sh && . .claude/lib/team-evidence.sh \
    && . .claude/lib/team-clearance.sh && "$@") > "$T/lr.out" 2> "$T/lr.err"; LRRC=$?
}
LV() { python3 -I "$CLEAR" digest --main "$MAIN"; }
shadow_line() {  # shadow_line [host] — one shadow line of the current list version
  LIBRUN clearance_log "$MAIN" shadow Fable "fixture shadow" "" "$(jq -nc --arg v "$(LV)" --arg h "${1:-claude}" '{result: "would-clear", class: "gh-own-repo-write", request_hash: "x", list_version: $v, host: $h}')"
}
seal() { [ -f "$MAIN/.agents/team/clearance.json" ] && shasum -a 256 < "$MAIN/.agents/team/clearance.json" | cut -d' ' -f1; }
mode() { LIBRUN clearance_mode "${2:-claude}" "${1:-$(seal)}" "$MAIN"; cat "$T/lr.out"; }
WHO_ADV="$(jq -nc --arg p "$MAIN" --arg r "$T/Advisor.settings.json" '{ctx: "advisor", project: $p, rules: $r, role: "Fable",
  session_id: "adv-1", team: "", run: "", attempt: "", ticket: "", host: "claude", wait: 120}')"
mkreq() {  # mkreq <tool> <tool_input json> [<who json>] [cwd] → RID (empty when none was filed), RP its payload file
  umsg=$((umsg + 1)); RP="$T/req-$umsg.json"
  jq -n --arg t "$1" --argjson i "$2" --arg c "${4:-$MAIN}" '{tool_name: $t, tool_input: $i, cwd: $c}' > "$RP"
  LIBRUN clearance_open "$MAIN" "$RP" "${3:-$WHO_ADV}"; RID="$(cat "$T/lr.out")"
}
claim() { LIBRUN clearance_claim "$MAIN" "$1" "${2:-$RP}"; CLM="$(cat "$T/lr.out")"; }
GHW='{"command":"gh issue comment 5 --body-file '"$MAIN"'/body.md"}'
grant_now() {  # grant_now — a fresh typed switch for claude and its grant, the shadow floor met
  say_sup "clearance enforce claude for 2d" 1; CL grant
}

if want switch || want seal || want refusals || want ledger; then
  rm -f "$MAIN"/.agents/touches/*.jsonl
  say_sup "please clearance enforce claude for 2d"; CL grant; g0="$CLRC"
  say_sup "clearance enforce claude for 2d, then stop"; CL grant; g1="$CLRC"; g1o="$(cat "$T/cl.out")"
  ok '[ "$g0" = 7 ] && [ "$g1" = 7 ] && grep -q "no grant" "$T/cl.out" && [ ! -e "$MAIN/.agents/team/clearance.json" ]' \
    "#323 switch: grant needs the whole typed message ($g0/$g1: $g1o)"
  say_sup "clearance enforce claude,codex for 1d"; CL grant
  ok '[ "$CLRC" = 7 ] && grep -q "shadow only (#323)" "$T/cl.out"' "#323 switch: codex refused ($(cat "$T/cl.out"))"
  say_sup "clearance enforce claude for 2d"; CL grant
  ok '[ "$CLRC" = 1 ] && grep -q "no shadow line" "$T/cl.out" && [ ! -e "$MAIN/.agents/team/clearance.json" ]' "#323 switch: grant needs a shadow line ($(cat "$T/cl.out"))"
  shadow_line; CL grant
  ok '[ "$CLRC" = 1 ] && grep -q "predates the first shadow line" "$T/cl.out"' "#323 switch: a message older than the first shadow line refuses ($(cat "$T/cl.out"))"
  grant_now
  ok '[ "$CLRC" = 0 ] && [ "$(stat -f %Lp "$MAIN/.agents/team/clearance.json" 2>/dev/null || stat -c %a "$MAIN/.agents/team/clearance.json")" = 600 ] && [ "$(mode)" = enforce ]' \
    "#323 switch: a typed switch after a shadow line grants and enforces ($(cat "$T/cl.out"))"
  # R1-7: a policy change needs a new typed message, newer than the new version's first shadow line.
  cp "$MAIN/.claude/hooks/lib/clearance-classes.json" "$T/classes.keep"; printf '\n' >> "$MAIN/.claude/hooks/lib/clearance-classes.json"
  m1="$(mode)"; shadow_line; CL grant; r1="$CLRC"
  grant_now; r2="$CLRC"; m2="$(mode)"
  ok '[ "$m1" = shadow ] && [ "$r1" = 1 ]' "#323 switch: old message cannot re-grant after a policy change ($m1/$r1)"
  ok '[ "$r2" = 0 ] && [ "$m2" = enforce ]' "#323 switch: new message re-grants ($r2/$m2)"
  cp "$T/classes.keep" "$MAIN/.claude/hooks/lib/clearance-classes.json"; shadow_line; grant_now
  say_sup "revoke clearance"; m3="$(mode)"
  ok '[ "$m3" = shadow ]' "#323 switch: revoke clearance stops enforce ($m3)"
  grant_now; m4="$(mode)"; CL pause; m5="$(mode)"
  ok '[ "$m4" = enforce ] && [ "$m5" = shadow ]' "#323 switch: pause stops enforce ($m4/$m5)"
  say_sup "clearance enforce claude for 1h" -7200; CL grant; m6="$(mode)"
  ok '[ "$CLRC" = 7 ] && grep -q "expired" "$T/cl.out" && [ "$m6" = shadow ]' "#323 switch: expired switch is shadow ($(cat "$T/cl.out"))"
  grant_now; s0="$(seal)"
  ok '[ "$(mode off)" = shadow ] && [ "$(mode 0000)" = shadow ] && [ "$(mode "$s0")" = enforce ] && [ "$(mode "$s0" codex)" = shadow ]' \
    "#323 seal: switch after launch stays shadow (seal off or another record → shadow)"
fi

if want refusals; then
  mkreq Bash "$GHW"; R1="$RID"
  SANS "$R1" allow; claim "$R1"; c1="$CLM"; claim "$R1"; c2="$CLM:$LRRC"
  ok '[[ "$R1" =~ ^c-[0-9]+-[0-9a-f]{16}$ ]] && [ "$c1" = allow ]' "#323 refusals: a transcript-evidenced answer is claimed ($R1 → $c1)"
  ok '[ "$c2" = ":1" ]' "#323 refusals: replayed clearance ($c2)"
  cp "$MAIN/.agents/team/clearance/used/$R1.json" "$T/ans.keep"; rm -f "$MAIN/.agents/team/clearance/answers/$R1.json"
  cp "$T/ans.keep" "$MAIN/.agents/team/clearance/answers/$R1.json"; claim "$R1"; CL answer "$R1" allow
  ok '[ -z "$CLM" ] && [ "$CLRC" = 1 ]' "#323 refusals: an answer restored after a claim is refused ($(cat "$T/cl.out"))"
  W1="$(jq -c '.wait = 1' <<<"$WHO_ADV")"; mkreq Bash "$GHW" "$W1"; sleep 2; SANS "$RID" allow
  e1="$CLRC"
  ok '[ "$e1" = 1 ] && grep -q "expired" "$T/cl.out"' "#323 refusals: expired clearance ($(cat "$T/cl.out"))"
  mkreq Bash "$GHW"; R3="$RID"
  jq -n --arg id "$R3" --arg h "$(j "$MAIN/.agents/team/clearance/requests/$R3.json" .request_hash)" --arg s "$(j "$MAIN/.agents/team/clearance.json" .id)" \
    --arg lv "$(LV)" '{id: $id, request_hash: $h, verdict: "allow", list_version: $lv, switch_id: $s, answered_at: "x", session_id: "sup-1"}' \
    > "$MAIN/.agents/team/clearance/answers/$R3.json"
  claim "$R3"
  ok '[ -z "$CLM" ]' "#323 refusals: forged clearance (no transcript)"
  mkreq Bash "$GHW"; R4="$RID"; SANS "$R4" allow; a4="$CLRC"
  jq '.request_hash = "0000"' "$MAIN/.agents/team/clearance/answers/$R4.json" > "$T/a4" && cat "$T/a4" > "$MAIN/.agents/team/clearance/answers/$R4.json"
  claim "$R4"
  ok '[ "$a4" = 0 ] && [ -z "$CLM" ]' "#323 refusals: forged clearance (wrong hash)"
  mkreq Bash "$GHW"; R5="$RID"; mkreq Bash "$GHW"; R5b="$RID"
  sup_call "bash .claude/lib/team-clearance.sh answer $R5b allow"
  jq -n --arg id "$R5" --arg h "$(j "$MAIN/.agents/team/clearance/requests/$R5.json" .request_hash)" --arg s "$(j "$MAIN/.agents/team/clearance.json" .id)" \
    --arg lv "$(LV)" '{id: $id, request_hash: $h, verdict: "allow", list_version: $lv, switch_id: $s, answered_at: "x", session_id: "sup-1"}' \
    > "$MAIN/.agents/team/clearance/answers/$R5.json"
  claim "$R5"; f5="$CLM"
  CL answer "c-999-$(printf '%016d' 0)" allow; f5b="$CLRC"
  ok '[ -z "$f5" ] && [ "$f5b" = 1 ]' "#323 refusals: forged clearance (wrong id) — the evidence names another request; an id with no request is refused"
  mkreq Bash "$GHW"; R6="$RID"; RQ="$MAIN/.agents/team/clearance/requests/$R6.json"
  jq '.payload.tool_input.command = "gh pr merge 3"' "$RQ" > "$T/r6" && cat "$T/r6" > "$RQ"; CL answer "$R6" allow
  ok '[ "$CLRC" = 1 ] && grep -q "re-derives to hard" "$T/cl.out" && [ ! -e "$MAIN/.agents/team/clearance/answers/$R6.json" ]' "#323 refusals: hard class ($(cat "$T/cl.out"))"
  revoked() {  # revoked <label> <change cmd> <restore cmd>
    mkreq Bash "$GHW"; local r="$RID"; SANS "$r" allow; local a="$CLRC"; eval "$2"; claim "$r"; local got="$CLM"; eval "$3"
    ok '[ -n "$r" ] && [ "$a" = 0 ] && [ -z "$got" ]' "#323 refusals: revoked list ($1)"
  }
  revoked "typed revoke" 'say_sup "revoke clearance"' 'grant_now'
  revoked "paused switch" 'CL pause' 'grant_now'
  for f in hooks/lib/clearance-classes.json lib/team_prompt_check.py team/baseline-ask.json lib/team_prompt_settings.py; do cp "$MAIN/.claude/$f" "$T/keep.$(basename "$f")"; done
  revoked "class file changed" 'printf "\n" >> "$MAIN/.claude/hooks/lib/clearance-classes.json"' 'cp "$T/keep.clearance-classes.json" "$MAIN/.claude/hooks/lib/clearance-classes.json"'
  revoked "trusted code changed" 'printf "\n# x\n" >> "$MAIN/.claude/lib/team_prompt_check.py"' 'cp "$T/keep.team_prompt_check.py" "$MAIN/.claude/lib/team_prompt_check.py"'
  revoked "baseline changed" 'jq ". + [\"Bash(x*)\"]" "$T/keep.baseline-ask.json" > "$MAIN/.claude/team/baseline-ask.json"' 'cp "$T/keep.baseline-ask.json" "$MAIN/.claude/team/baseline-ask.json"'
  revoked "helper changed" 'printf "\n# x\n" >> "$MAIN/.claude/lib/team_prompt_settings.py"' 'cp "$T/keep.team_prompt_settings.py" "$MAIN/.claude/lib/team_prompt_settings.py"'
  mkreq Bash "$GHW"; R7="$RID"; SANS "$R7" allow; a7="$CLRC"; cp "$MAIN/body.md" "$T/body.keep"; printf 'another body\n' > "$MAIN/body.md"; claim "$R7"
  p7="$CLM"; cp "$T/body.keep" "$MAIN/body.md"
  ok '[ -n "$R7" ] && [ "$a7" = 0 ] && [ -z "$p7" ]' "#323 refusals: pin changed after answer"
  mkreq Bash "$GHW"; R8="$RID"; (cd "$MAIN" && env -u TEAM_SESSION_ROLE bash "$MAIN/.claude/lib/team-clearance.sh" answer "$R8" allow) > "$T/cl.out" 2>&1; a8=$?
  ok '[ "$a8" = 1 ] && [ ! -e "$MAIN/.agents/team/clearance/answers/$R8.json" ]' "#323 refusals: only the Supervisor answers"
  mkreq Bash '{"command":"gh pr merge 3"}'
  ok '[ -z "$RID" ]' "#323 refusals: a hard payload files no request"
fi

if want ledger; then
  WHO_ST="$(jq -nc --arg p "$CLONE" --arg r "$RUN" '{ctx: "stage", project: $p, rules: "", role: "coder", session_id: "sid-1",
    team: "beta", run: $r, attempt: 1, ticket: "9", host: "claude", wait: 120}')"
  mkreq Edit "$(jq -nc --arg f "$WT/README.md" '{file_path: $f, old_string: "starter", new_string: "starter, edited by the stage"}')" "$WHO_ST" "$CLONE"
  R9="$RID"; CL pending
  ok '[ -n "$R9" ] && grep -qF "$R9 — class starter-worktree-edit" "$T/cl.out" && grep -q "starter, edited by the stage" "$T/cl.out" && grep -q "answer $R9 allow|deny|unsure" "$T/cl.out"' \
    "#323 ledger: pending renders the edit and the full id ($(head -c 300 "$T/cl.out"))"
  mkreq Bash "$GHW"; CL pending
  ok 'grep -q "body: body of the comment" "$T/cl.out" && grep -q "pin: .*body.md" "$T/cl.out"' "#323 ledger: pending renders the body file and its pin"
  ok '[ "$(stat -f %Lp "$MAIN/.agents/team/clearance/requests" 2>/dev/null || stat -c %a "$MAIN/.agents/team/clearance/requests")" = 700 ]' "#323 ledger: the state dir is private"
fi

# ---- carrier A: the role-profile hook ---------------------------------------------------------------
PROFD="$MAIN/.agents/team/watch/profiles"; mkdir -p "$PROFD"
cp "$T/Advisor.settings.json" "$PROFD/Fable.settings.json"; cp "$T/Supervisor.settings.json" "$PROFD/Supervisor.settings.json"
RDF="$(python3 -I "$CLEAR" rules-digest --project "$MAIN" --rules "$PROFD/Fable.settings.json")"
RDS="$(python3 -I "$CLEAR" rules-digest --project "$MAIN" --rules "$PROFD/Supervisor.settings.json")"
hp() {  # hp <event> <tool> <tool_input json> → $T/hp.json, a hook payload of session adv-1 in the main checkout
  jq -n --arg e "$1" --arg t "$2" --argjson i "$3" --arg c "$MAIN" '{session_id: "adv-1", hook_event_name: $e, cwd: $c,
    tool_name: $t, tool_input: $i}' > "$T/hp.json"
}
HK() {  # HK <name> [env…] — the hook on $T/hp.json → $T/<name>.out, HRC, HOUT (the decision behavior or the PreToolUse decision)
  local nm="$1"; shift
  (cd "$MAIN" && env CLAUDE_PROJECT_DIR="$MAIN" TEAM_SESSION_ROLE="${HROLE:-Fable}" TEAM_CLEARANCE_SEAL="${HSEAL:-off}" \
    TEAM_CLEARANCE_RULES="${HRULES:-$RDF}" TEAM_CLEARANCE_WAIT="${HWAIT:-30}" TEAM_CLEARANCE_POLL=1 "$@" \
    bash "$MAIN/.claude/hooks/team-clearance-hook.sh" < "$T/hp.json" > "$T/$nm.out" 2> "$T/$nm.err"); HRC=$?
  HOUT="$(jq -r '.hookSpecificOutput.decision.behavior // .hookSpecificOutput.permissionDecision // empty' "$T/$nm.out" 2>/dev/null)"
}
shadows() { cat "$MAIN"/.agents/touches/*.jsonl 2>/dev/null | jq -s 'map(select(.kind == "shadow")) | length'; }
lastshadow() { cat "$MAIN"/.agents/touches/*.jsonl 2>/dev/null | jq -rs 'map(select(.kind == "shadow")) | last | .clearance.result'; }
suploop() {  # the Supervisor: answers each new request with the verdict in $T/sup-verdict, through its own call
  local f id v
  while :; do
    for f in "$MAIN"/.agents/team/clearance/requests/c-*.json; do
      [ -f "$f" ] || continue
      id="$(basename "$f" .json)"; [ ! -e "$T/seen.$id" ] || continue
      v="$(cat "$T/sup-verdict" 2>/dev/null)"; [ -n "$v" ] && [ "$v" != none ] || continue
      touch "$T/seen.$id"
      (cd "$MAIN" && env TEAM_SESSION_ROLE=Supervisor bash "$MAIN/.claude/lib/team-clearance.sh" answer "$id" "$v") > "$T/loop.out" 2>&1 || continue
      jq -nc --arg i "toolu_loop_$id" --arg c "bash .claude/lib/team-clearance.sh answer $id $v" --arg ts "$(utc)" '{type: "assistant",
        uuid: "a-\($i)", timestamp: $ts, message: {role: "assistant", content: [{type: "tool_use", id: $i, name: "Bash", input: {command: $c}}]}}' >> "$SUPT"
      jq -nc --arg i "toolu_loop_$id" --arg ts "$(utc)" '{type: "user", uuid: "r-\($i)", timestamp: $ts,
        message: {role: "user", content: [{type: "tool_result", tool_use_id: $i, content: "ok"}]}}' >> "$SUPT"
    done
    sleep 0.5
  done
}
GH5='{"command":"gh issue comment 5 --body x"}'

if want shadow; then
  CL pause; rm -f "$MAIN"/.agents/touches/*.jsonl
  for c in 'pass|{"command":"gh issue view 1"}|would-pass' 'hard|{"command":"gh pr merge 3"}|hard' \
           "clearable|$GH5|would-clear" 'none|{"command":"rm x"}|none'; do
    hp PermissionRequest Bash "$(cut -d'|' -f2 <<<"$c")"; s0="$(shadows)"; HK sh
    ok '[ "$HRC" = 0 ] && [ ! -s "$T/sh.out" ] && [ "$(shadows)" = $((s0 + 1)) ] && [ "$(lastshadow)" = "$(cut -d"|" -f3 <<<"$c")" ]' \
      "#323 shadow: no output for every result — $(cut -d'|' -f1 <<<"$c") logs $(lastshadow)"
  done
  ok '[ "$(shadows)" = 4 ]' "#323 shadow: one shadow line per call"
  shadow_line; grant_now; hp PermissionRequest Bash "$GH5"; HK sx TEAM_CLEARANCE_HOST=codex HSEAL="$(seal)"
  HSEAL="$(seal)" HK sx2 TEAM_CLEARANCE_HOST=codex
  ok '[ "$(mode)" = enforce ] && [ ! -s "$T/sx2.out" ] && [ "$(lastshadow)" = would-clear ] && cat "$MAIN"/.agents/touches/*.jsonl | jq -se "map(select(.kind == \"shadow\")) | last | .clearance.host == \"codex\"" >/dev/null' \
    "#323 shadow: codex is always shadow (a verified switch and its seal)"
  hp PermissionRequest Bash "$GH5"; HRULES=0000 HSEAL="$(seal)" HK sr
  ok '[ ! -s "$T/sr.out" ]' "#323 shadow: a launch rule digest that differs never allows"
fi

if want enforce; then
  rm -f "$MAIN"/.agents/touches/*.jsonl; shadow_line; grant_now; S="$(seal)"; touch "$MAIN/.sup-alive"
  suploop & SUPLOOP=$!
  hp PermissionRequest Bash '{"command":"gh issue view 1"}'; HSEAL="$S" HK e1
  ok '[ "$HOUT" = allow ]' "#323 enforce: pass allows ($(cat "$T/e1.out"))"
  hp PermissionRequest Bash '{"command":"gh pr merge 3"}'; HSEAL="$S" HK e2
  ok '[ ! -s "$T/e2.out" ]' "#323 enforce: hard gives no output"
  hp PermissionRequest Bash '{"command":"rm x"}'; HSEAL="$S" HK e3
  ok '[ ! -s "$T/e3.out" ]' "#323 enforce: none gives no output"
  echo allow > "$T/sup-verdict"; : > "$RINGS"; hp PermissionRequest Bash "$GH5"; HSEAL="$S" HK e4
  ok '[ "$HOUT" = allow ] && ls "$MAIN"/.agents/team/inbox/Supervisor/new/*-Fable-clearance.md >/dev/null 2>&1 && grep -q "Supervisor inbox: clearance" "$RINGS" && cat "$MAIN"/.agents/touches/*.jsonl | jq -se "map(select(.kind == \"cleared\" and .answer == \"allow\" and .clearance.authority == \"supervisor (cleared)\")) | length == 1" >/dev/null' \
    "#323 enforce: Supervisor allow allows (request, doorbell, cleared line) ($(cat "$T/e4.out" "$T/loop.out" 2>/dev/null | head -c 300))"
  echo deny > "$T/sup-verdict"; hp PermissionRequest Bash "$GH5"; HSEAL="$S" HK e5
  ok '[ "$HOUT" = deny ] && jq -e ".hookSpecificOutput.decision.message | test(\"the Supervisor denied this request \\\\(c-\")" "$T/e5.out" >/dev/null' \
    "#323 enforce: Supervisor deny denies ($(cat "$T/e5.out"))"
  echo unsure > "$T/sup-verdict"; hp PermissionRequest Bash "$GH5"; HSEAL="$S" HK e6
  ok '[ ! -s "$T/e6.out" ]' "#323 enforce: unsure gives no output"
  echo none > "$T/sup-verdict"; hp PermissionRequest Bash "$GH5"; t0=$(date +%s); HWAIT=3 HSEAL="$S" HK e7; t1=$(date +%s)
  ok '[ ! -s "$T/e7.out" ] && [ $((t1 - t0)) -lt 25 ]' "#323 enforce: timeout gives no output ($((t1 - t0)) s)"
  rm -f "$MAIN/.sup-alive"; n0="$(ls "$MAIN/.agents/team/clearance/requests" | wc -l | tr -d ' ')"
  echo allow > "$T/sup-verdict"; hp PermissionRequest Bash "$GH5"; HSEAL="$S" HK e8
  ok '[ ! -s "$T/e8.out" ] && [ "$(ls "$MAIN/.agents/team/clearance/requests" | wc -l | tr -d " ")" = "$n0" ]' "#323 enforce: absent Supervisor gives no output (no request filed)"
  touch "$MAIN/.sup-alive"; hp PermissionRequest Bash "$GH5"; HROLE=Supervisor HRULES="$RDS" HSEAL="$S" HK e9
  ok '[ ! -s "$T/e9.out" ] && [ "$(lastshadow)" = own ] && [ "$(ls "$MAIN/.agents/team/clearance/requests" | wc -l | tr -d " ")" = "$n0" ]' \
    "#323 enforce: own Supervisor request is own"
  # R1-9: an answer whose transcript evidence arrives late still allows before the deadline.
  : > "$T/sup-verdict"; hp PermissionRequest Bash "$GH5"
  ( sleep 4; for f in "$MAIN"/.agents/team/clearance/requests/c-*.json; do id="$(basename "$f" .json)"
      [ -e "$MAIN/.agents/team/clearance/answers/$id.json" ] || [ -e "$T/seen.$id" ] || { touch "$T/seen.$id"
        (cd "$MAIN" && env TEAM_SESSION_ROLE=Supervisor bash "$MAIN/.claude/lib/team-clearance.sh" answer "$id" allow) >/dev/null 2>&1
        sleep 3; sup_call "bash .claude/lib/team-clearance.sh answer $id allow"; }; done ) &
  HSEAL="$S" HK e10; wait $! 2>/dev/null
  ok '[ "$HOUT" = allow ]' "#323 enforce: delayed transcript evidence still allows"
  ok '! grep -l "updatedInput\|updatedPermissions" "$T"/e*.out >/dev/null 2>&1 && ! grep -q "updatedInput\|updatedPermissions" "$MAIN/.claude/hooks/team-clearance-hook.sh"' \
    "#323 enforce: never updatedInput"
  kill "$SUPLOOP" 2>/dev/null; wait "$SUPLOOP" 2>/dev/null; SUPLOOP=""
fi

if want write-guard; then
  wg() {  # wg <name> <tool> <path> → HOUT
    hp PreToolUse "$2" "$(jq -nc --arg f "$3" '{file_path: $f, content: "x", old_string: "a", new_string: "b"}')"; HK "$1"
  }
  wg w1 Edit "$MAIN/.claude/settings.json"
  ok '[ "$HOUT" = ask ]' "#323 write guard: settings edit asks"
  wg w2 Edit "$MAIN/.claude/lib/team_prompt_check.py"
  ok '[ "$HOUT" = ask ] && grep -q "trusted clearance code" "$T/w2.out"' "#323 write guard: trusted code edit asks"
  wg w3 Write "$MAIN/.agents/team/clearance/answers/c-1-0000000000000000.json"
  wg w3b Write "$MAIN/.agents/team/clearance.json"; h3b="$HOUT"
  ok '[ "$h3b" = deny ] && jq -e ".hookSpecificOutput.permissionDecision == \"deny\"" "$T/w3.out" >/dev/null' "#323 write guard: clearance ledger denied"
  wg w4 Edit "$MAIN/.claude/hooks/guard-push.sh"
  ok '[ "$HOUT" = ask ]' "#323 write guard: other hook edit asks"
  wg w5 Write "$MAIN/.claude/hooks/new-hook.sh"
  ok '[ "$HOUT" = ask ]' "#323 write guard: new hook asks"
  wg w6 Write "$MAIN/.codex/hooks.json"; h6="$HOUT"; wg w7 Edit "$MAIN/.claude/team/sessions/Advisor.settings.json"; h7="$HOUT"
  ok '[ "$h6" = ask ] && [ "$h7" = ask ]' "#323 write guard: .codex/hooks.json and a role profile ask"
  wg w8 Write "$MAIN/docs/notes.md"
  ok '[ "$HRC" = 0 ] && [ ! -s "$T/w8.out" ]' "#323 write guard: an ordinary file passes through"
  hp PreToolUse Edit '{"old_string": "a"}'; HK w9
  ok '[ "$HRC" = 2 ]' "#323 write guard: no file path fails closed"
fi

# ---- carrier B: the stage hook (a lead run of team beta in the fixture clone) -----------------------
TD="$CLONE/.agents/team"; RD="$TD/runs/$RUN"; AD="$RD/asks"; DDIR="$RD/decisions"
LT="$T/cc/projects/$(printf '%s' "$CLONE" | sed 's/[^A-Za-z0-9]/-/g')/lid-1.jsonl"; mkdir -p "$(dirname "$LT")"; : > "$LT"
sp() {  # sp <tool> <tool_input json> → $T/sp.json, a stage PermissionRequest of session sid-1 in the clone
  jq -n --arg t "$1" --argjson i "$2" --arg c "$CLONE" '{session_id: "sid-1", hook_event_name: "PermissionRequest", cwd: $c,
    tool_name: $t, tool_input: $i}' > "$T/sp.json"
}
SH() {  # SH <name> [env…] — the stage hook on $T/sp.json → $T/<name>.out, SHRC, SHOUT
  local nm="$1"; shift
  (cd "$CLONE" && env CLAUDE_PROJECT_DIR="$CLONE" TEAM_ASK_TIMEOUT="${STO:-24}" TEAM_CLEARANCE_SEAL="${SSEAL:-off}" \
    TEAM_CLEARANCE_POLL=1 "$@" bash "$MAIN/.claude/hooks/team-ask-hook.sh" < "$T/sp.json" > "$T/$nm.out" 2> "$T/$nm.err"); SHRC=$?
  SHOUT="$(jq -r '.hookSpecificOutput.decision.behavior // .hookSpecificOutput.permissionDecision // empty' "$T/$nm.out" 2>/dev/null)"
}
TL() { (cd "$CLONE" && env TEAM_SESSION_ROLE=TeamLead TEAM_RUN_TEAM=beta bash "$MAIN/.claude/lib/team-lead.sh" "$@") > "$T/tl.out" 2>&1; TLRC=$?; }
L() { (cd "$CLONE" && env TEAM_SESSION_ROLE=TeamLead TEAM_RUN_TEAM=beta bash "$MAIN/.claude/lib/team-answer.sh" beta "$@") > "$T/l.out" 2>&1; LRC=$?; }
did() { sed -n 's/^\[\(d-[0-9]*\)\].*/\1/p' "$T/tl.out" | head -n 1; }
say_op() { jq -nc --arg u "$1" --arg t "$2" --arg ts "$(utc)" '{type: "user", uuid: $u, timestamp: $ts, message: {role: "user", content: $t}}' >> "$LT"; }
asks() { ls "$AD" 2>/dev/null | grep -c '^a-[0-9]*\.json$' || true; }
reqs() { ls "$MAIN/.agents/team/clearance/requests" 2>/dev/null | grep -c '^c-' || true; }
WTE="$(jq -nc --arg f "$WT/README.md" '{file_path: $f, old_string: "starter", new_string: "starter (stage)"}')"
STAGE_ON() { rm -f "$MAIN"/.agents/touches/*.jsonl; shadow_line; grant_now; SSEAL="$(seal)"; touch "$MAIN/.sup-alive"; }

if want stage; then
  STAGE_ON; echo allow > "$T/sup-verdict"; rm -f "$T"/seen.*; suploop & SUPLOOP=$!
  : > "$RINGS"; a0="$(asks)"; sp Edit "$WTE"; STO=90 SH s1   # a 37 s clearance window: room under load
  ok '[ "$SHOUT" = allow ] && grep -q "clearance c-[0-9]*-[0-9a-f]* — authority supervisor (cleared)" "$RD/answers.md" && [ "$(asks)" = "$a0" ] && ! ls "$DDIR"/d-*.md >/dev/null 2>&1' \
    "#323 stage: enforce allow is supervisor (cleared) ($(cat "$T/s1.out" "$T/s1.err" | head -c 300))"
  ok 'ls "$MAIN"/.agents/team/inbox/Supervisor/new/*-beta-clearance.md >/dev/null 2>&1 && grep -q "^Supervisor inbox: clearance beta" "$RINGS"' \
    "#323 stage: doorbell reaches the Supervisor inbox (from the clone cwd)"
  echo deny > "$T/sup-verdict"; n0="$(grep -c 'authority supervisor (cleared)' "$RD/answers.md")"
  sp Edit "$(jq -nc --arg f "$WT/README.md" '{file_path: $f, old_string: "starter", new_string: "starter (denied)"}')"; STO=90 SH s1d
  ok '[ "$SHOUT" = deny ] && grep -q "Supervisor denied" "$T/s1d.out" && [ "$(grep -c "authority supervisor (cleared)" "$RD/answers.md")" = "$n0" ]' \
    "#323 stage: a Supervisor deny writes no cleared answers.md line ($(cat "$T/s1d.out" | head -c 200))"
  echo none > "$T/sup-verdict"; a0="$(asks)"
  sp Edit "$(jq -nc --arg f "$WT/README.md" '{file_path: $f, old_string: "starter", new_string: "starter (unanswered)"}')"; SH s2
  ok '[ "$SHOUT" = deny ] && [ "$(asks)" = $((a0 + 1)) ] && jq -e ".tier == \"operator\"" "$AD/a-$((a0 + 1)).json" >/dev/null && grep -q "No Operator answer" "$T/s2.out"' \
    "#323 stage: no answer keeps the existing path (ask filed, tier operator)"
  kill "$SUPLOOP" 2>/dev/null; wait "$SUPLOOP" 2>/dev/null; SUPLOOP=""
  rm -f "$MAIN/.sup-alive"; r0="$(reqs)"; a0="$(asks)"
  sp Edit "$(jq -nc --arg f "$WT/README.md" '{file_path: $f, old_string: "starter", new_string: "starter (no supervisor)"}')"; SH s2b
  ok '[ "$(reqs)" = "$r0" ] && [ "$(asks)" = $((a0 + 1)) ]' \
    "#323 stage: no live Supervisor files no clearance request (reqs ${r0} to $(reqs), asks ${a0} to $(asks))"
  touch "$MAIN/.sup-alive"
  WTE3="$(jq -nc --arg f "$WT/README.md" '{file_path: $f, old_string: "starter", new_string: "starter (shadow)"}')"
  CL pause; s0="$(shadows)"; r0="$(reqs)"; a0="$(asks)"; sp Edit "$WTE3"; SH s3
  ok '[ "$(shadows)" = $((s0 + 1)) ] && [ "$(lastshadow)" = would-clear ] && [ "$(asks)" = $((a0 + 1)) ] && [ "$(reqs)" = "$r0" ]' \
    "#323 stage: shadow logs and keeps the existing path (shadows ${s0} to $(shadows) $(lastshadow), asks ${a0} to $(asks), reqs ${r0} to $(reqs))"
  # A retry of the same request with an Operator deny waiting: the waiting answer is delivered.
  A="a-$(asks)"; TL decision open beta --ask "$A" --options "allow|deny"; DA="$(did)"
  say_op "u-deny-$DA" "$DA deny: not now"; TL decision answer beta "$DA" --text "$DA deny: not now" --tuning none --why w
  L "$A" --deny "not now" --authority operator --decision "$DDIR/$DA.md" --why w
  grant_now; SSEAL="$(seal)"; echo allow > "$T/sup-verdict"; suploop & SUPLOOP=$!; r0="$(reqs)"; sp Edit "$WTE3"; SH s4
  ok '[ "$SHOUT" = deny ] && grep -q "not now" "$T/s4.out" && [ "$(reqs)" = "$r0" ]' \
    "#323 stage: waiting Operator deny wins over clearance ($(cat "$T/s4.out" "$T/l.out" | head -c 300))"
  kill "$SUPLOOP" 2>/dev/null; wait "$SUPLOOP" 2>/dev/null; SUPLOOP=""
  echo none > "$T/sup-verdict"; sp Edit "$(jq -nc --arg f "$WT/README.md" '{file_path: $f, old_string: "starter", new_string: "starter (cancel)"}')"
  ( sleep 5; touch "$TD/cancel" ) & STO=60 SH s5; rm -f "$TD/cancel"
  ok '[ "$SHOUT" = deny ] && grep -q "the team was stopped" "$T/s5.out"' "#323 stage: cancel during clearance wait stops ($(cat "$T/s5.out"))"
  jq -n --arg f "$MAIN/.agents/team/clearance/answers/c-1-0000000000000000.json" --arg c "$CLONE" '{session_id: "sid-1",
    hook_event_name: "PreToolUse", cwd: $c, tool_name: "Write", tool_input: {file_path: $f, content: "{}"}}' > "$T/sp.json"; SH s6
  ok '[ "$SHOUT" = deny ] && grep -q "clearance ledger" "$T/s6.out"' "#323 write guard: stage clearance ledger denied"
  jq '.tool_name = "MultiEdit" | .tool_input = {file_path: "'"$MAIN"'/.agents/team/clearance.json", edits: []}' "$T/sp.json" > "$T/sp2.json" && mv "$T/sp2.json" "$T/sp.json"; SH s7
  ok '[ "$SHOUT" = deny ]' "#323 write guard: a stage MultiEdit of the switch record is denied"
fi

if want T3; then
  CL pause; STAGE_ON; CL pause   # shadow: the ask path, a switch record that is not in force
  MF="$MAIN/.agents/team/mandate.json"
  TM() { (cd "$MAIN" && env TEAM_SESSION_ROLE=Supervisor bash "$MAIN/.claude/lib/team-mandate.sh" "$@") > "$T/tm.out" 2>&1 < /dev/null; TMRC=$?; }
  dig() { jq -cS .payload "$AD/$1.json" | shasum -a 256 | cut -d' ' -f1; }
  MID() { jq -r .id "$MF"; }
  say_call() { jq -nc --arg u "$1" --arg c "$2" --arg w "$MAIN" --arg ts "$(utc 1)" '{type: "assistant", uuid: $u, timestamp: $ts, cwd: $w,
    message: {role: "assistant", content: [{type: "tool_use", id: "t", name: "Bash", input: {command: $c}}]}}' >> "$SUPT"; }
  SD() {  # SD <d-n> <a-n> <reply> — the Supervisor's delegated answer, its call in its own transcript first
    local args
    args="$(printf 'decision answer beta %s --delegated --run %s --ask %s --attempt 1 --session sid-1 --request %s --mandate %s --class no-rule --text "%s" --why "inside the mandate"' \
      "$1" "$RUN" "$2" "$(dig "$2")" "$(MID)" "$3")"
    say_call "cm-$1" "bash .claude/lib/team-lead.sh $args"
    (cd "$MAIN" && env TEAM_SESSION_ROLE=Supervisor CLAUDE_CODE_SESSION_ID=sup-1 TEAM_DELEGATE_WAIT_SECS=0 \
      bash "$MAIN/.claude/lib/team-lead.sh" decision answer beta "$1" --delegated --run "$RUN" --ask "$2" --attempt 1 --session sid-1 \
        --request "$(dig "$2")" --mandate "$(MID)" --class no-rule --text "$3" --why "inside the mandate") > "$T/sd.out" 2>&1; SDRC=$?
  }
  echo "- **Delegated to the Supervisor.** apply it" > "$RD/lead-1.prompt.md"
  say_sup "mandate no-rule for 1d team beta"; TM grant
  sp Bash "$GH5"; cp "$T/sp.json" "$T/sp-t1.json"
  (cd "$CLONE" && env CLAUDE_PROJECT_DIR="$CLONE" TEAM_ASK_TIMEOUT=120 bash "$MAIN/.claude/hooks/team-ask-hook.sh" < "$T/sp-t1.json" > "$T/t1.out" 2> "$T/t1.err") & HP=$!
  A="a-$(( $(asks) + 1 ))"; i=0; while [ ! -e "$AD/$A.json" ] && [ "$i" -lt 100 ]; do sleep 0.2; i=$((i + 1)); done
  TL decision open beta --ask "$A" --options "allow|deny" --reason no-rule; D1="$(did)"; o1="$TLRC"
  TL decision list beta; lst="$(cat "$T/tl.out")"
  SD "$D1" "$A" "$D1 allow"; s1="$SDRC"
  L "$A" --allow --authority delegated --decision "$DDIR/$D1.md" --why "Supervisor (delegated)"; wait "$HP"
  ok '[ "$TMRC" = 0 ] && [ "$o1" = 0 ] && grep -qx "delegate: supervisor" "$DDIR/$D1.md" && grep -q "^$D1 pending \[delegated to the Supervisor\]" <<<"$lst" && [ "$s1" = 0 ] && [ "$(j "$T/t1.out" .hookSpecificOutput.decision.behavior)" = allow ]' \
    "#323 T3: ask-kind egress delegable — open, mandate routing, delegated answer, delivery ($(head -c 200 "$T/tm.out") | $(head -c 200 "$T/sd.out") | $(head -c 200 "$T/l.out"))"
  # A guard the checker does not reproduce leaves no egress-only proof: `clearance: undecided`.
  CSL="$CLONE/.claude/settings.local.json"; [ ! -f "$CSL" ] || cp "$CSL" "$T/csl.keep"
  printf '%s\n' '{"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "python3 -I /x/permission_probe.py hook"}]}]}}' > "$CSL"
  jq -c '{tool_name, tool_input, cwd}' "$T/sp-t1.json" > "$T/t1-in.json"
  python3 -I "$MAIN/.claude/lib/team_prompt_check.py" "$CLONE" --input-json "$T/t1-in.json" --main "$MAIN" > "$T/t1-check.out" 2>&1
  if [ -f "$T/csl.keep" ]; then mv "$T/csl.keep" "$CSL"; else rm -f "$CSL"; fi
  eo() { (cd "$MAIN" && . .claude/lib/team-mandate.sh && mandate_egress_only "$1"); }
  ok 'grep -qx "clearance: undecided" "$T/t1-check.out" && ! eo "$(cat "$T/t1-check.out")" && ! eo "$(printf "batch: eligible\nclearance: hard")" && eo "$(printf "batch: eligible\nclearance: none")" && eo "$(printf "batch: eligible\nclearance: clearable public-get-long")" && ! eo "$(printf "batch: no\nclearance: none")"' \
    "#323 T3: a guard the checker does not reproduce is not delegable ($(tr '\n' ' ' < "$T/t1-check.out" | head -c 300))"
  sp Bash '{"command":"gh pr merge 3"}'; cp "$T/sp.json" "$T/sp-t2.json"
  (cd "$CLONE" && env CLAUDE_PROJECT_DIR="$CLONE" TEAM_ASK_TIMEOUT=60 bash "$MAIN/.claude/hooks/team-ask-hook.sh" < "$T/sp-t2.json" > "$T/t2.out" 2> "$T/t2.err") & HP=$!
  A="a-$(( $(asks) + 1 ))"; i=0; while [ ! -e "$AD/$A.json" ] && [ "$i" -lt 100 ]; do sleep 0.2; i=$((i + 1)); done
  TL decision open beta --ask "$A" --options "allow|deny" --reason no-rule
  ok '[ "$TLRC" = 2 ] && grep -q "stays human-only unless its only cause is a non-hard egress" "$T/tl.out"' "#323 T3: hard egress not delegable ($(cat "$T/tl.out"))"
  ok '[ "$TLRC" = 2 ]' "#323 T3: merge never delegable"
  TL decision open beta --ask "$A" --options "allow|deny"; D2="$(did)"
  ok '[ "$TLRC" = 0 ] && grep -qx "touch_reason: human-only" "$DDIR/$D2.md" && ! grep -q "^delegate" "$DDIR/$D2.md"' "#323 T3: human-only kept ($(cat "$T/tl.out"))"
  kill "$HP" 2>/dev/null; wait "$HP" 2>/dev/null
fi

if want profiles; then
  printf '{"id": "s-fixture"}\n' > "$MAIN/.agents/team/clearance.json"; SL="$(seal)"
  (cd "$MAIN" && bash "$MAIN/.claude/lib/supervisor-sessions.sh" materialize Fable) > "$T/m1.out" 2>&1; m1=$?
  PF="$MAIN/.agents/team/watch/profiles/Fable.settings.json"
  pcmd() { jq -r '.hooks.PermissionRequest[0].hooks[0].command // ""' "$1" 2>/dev/null; }
  rd="$(python3 -I "$CLEAR" rules-digest --project "$MAIN" --rules "$PF" --main "$MAIN")"
  want="TEAM_CLEARANCE_SEAL=$SL TEAM_CLEARANCE_RULES=$rd bash \"$MAIN/.claude/hooks/team-clearance-hook.sh\""
  ok '[ "$m1" = 0 ] && [ "$(jq -r ".hooks.PermissionRequest[0].matcher" "$PF")" = "Bash|WebFetch|Edit|Write|MultiEdit|NotebookEdit" ] && [ "$(pcmd "$PF")" = "$want" ] && jq -e ".hooks.PreToolUse[0].hooks[0].onFailure == \"block\"" "$PF" >/dev/null' \
    "#323 profiles: materialised profiles carry the seal — role ($(cat "$T/m1.out"); $(pcmd "$PF"))"
  ok '[[ "$rd" =~ ^[0-9a-f]{64}$ ]] && [[ "$(pcmd "$PF")" == *"TEAM_CLEARANCE_RULES=$rd "* ]]' "#323 profiles: the role profile's rules digest is the launch rules'"
  (cd "$MAIN" && bash "$MAIN/.claude/lib/team-lead.sh" materialize beta) > "$T/m2.out" 2>&1; m2=$?
  LP="$CLONE/.agents/team/teamlead.settings.json"
  ok '[ "$m2" = 0 ] && [[ "$(pcmd "$LP")" =~ ^TEAM_CLEARANCE_SEAL=$SL\ TEAM_CLEARANCE_RULES=[0-9a-f]{64}\ bash ]] && [ "$(jq -r ".hooks.PermissionRequest[0].matcher" "$LP")" = "Bash|WebFetch|Edit|Write|MultiEdit|NotebookEdit" ]' \
    "#323 profiles: materialised profiles carry the seal — lead ($(cat "$T/m2.out"))"
  (cd "$MAIN" && root="$MAIN" TD="$TD" bash -c '. "$1/.claude/lib/team-run-asks.sh" >/dev/null 2>&1; stage_hooks_materialise' _ "$MAIN") > "$T/m3.out" 2>&1; m3=$?
  ok '[ "$m3" = 0 ] && jq -e --arg s "$SL" ".hooks.PermissionRequest[0].hooks[0].command | test(\"TEAM_CLEARANCE_SEAL=\" + \$s + \" bash\")" "$TD/stage-hooks.settings.json" >/dev/null && jq -e ".hooks.PreToolUse | map(.matcher) | index(\"Edit|Write|MultiEdit|NotebookEdit\") != null" "$TD/stage-hooks.settings.json" >/dev/null' \
    "#323 profiles: materialised profiles carry the seal — stage ($(cat "$T/m3.out"))"
  rm -f "$MAIN/.agents/team/clearance.json"
  (cd "$MAIN" && bash "$MAIN/.claude/lib/supervisor-sessions.sh" materialize Fable) >/dev/null 2>&1
  ok '[[ "$(pcmd "$PF")" == "TEAM_CLEARANCE_SEAL=off "* ]]' "#323 profiles: no switch record → the seal is off"
  (cd "$MAIN" && bash "$MAIN/.claude/lib/team-lead.sh" preflight beta) > "$T/pf.out" 2>&1
  ok 'grep -q "ask provenance: clean" "$T/pf.out"' "#323 profiles: lead preflight clean with clearance hook ($(cat "$T/pf.out"))"
  for f in Advisor Supervisor TeamLead; do
    ok 'jq -e ".hooks.PermissionRequest[0].matcher == \"Bash|WebFetch|Edit|Write|MultiEdit|NotebookEdit\"" "$SRC/.claude/team/sessions/'"$f"'.settings.json" >/dev/null' \
      "#323 profiles: the $f template registers the clearance hook"
  done
fi

echo "team-clearance-test: $n checks, $passed passed"
[ "$fail" = 0 ] && [ "$passed" -gt 0 ] || exit 1
