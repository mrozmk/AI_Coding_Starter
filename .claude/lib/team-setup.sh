#!/usr/bin/env bash
# Installs the team harness into another project from `.claude/team/manifest.txt`: copies the
# `own` files, reports `shared` files the project already owns, merges the team hook entries (among
# them the question and memory guards, the attention hook and the team-watch SessionStart
# re-registration — + the egress guard under `Bash` and `WebFetch` and
# the destructive-SQL guard under `Bash`, both guards with `"onFailure": "block"`) and the role
# `permissions.allow` / Operator `ask` rules into `settings.json`, the three trunk writers omitted
# and removed under the profile's `workflow.team_merge: auto` (role sessions are refused them by
# `guard-team-verdict.sh` either way), ignores `.agents/team/` and the fallback mail
# box `.agents/agent-mail/`, and seeds `.claude/codex-profile` and `.claude/claude-profile`. It NEVER overwrites a file the target already has — a difference is a
# `conflict` with a diff, for a hand merge. A `retired` file is deleted only while it is byte for
# byte a version the starter shipped; a changed one is a `conflict`, never deleted.
#
# Usage: bash .claude/lib/team-setup.sh <starter-root> <target-root> [--check]
#   e.g. bash <starter-root>/.claude/lib/team-setup.sh <starter-root> "$PWD"
#   --check: report the plan and write NOTHING (statuses read create|keep|conflict|merge|remove).
#
# Output: one `<status>\t<class>\t<path>` line per path (`created|kept|conflict|merged|removed`,
# class `own|shared|retired|generated`; an absent retired file prints nothing), each own/shared
# conflict followed by `--- conflict <path>` and a unified diff, then
# `summary: created=N kept=N conflict=N merged=N removed=N` and `profile: ok|missing`.
#
# Exit: 0 installed, nothing to decide · 1 conflicts (everything else is installed)
#   2 usage / no jq / target is not a repo root / manifest drift / a core file the harness uses
#     (team-profile.sh, team-tracker.sh, costs/runtime-mark.sh) missing or not the starter's — sync
#     first (nothing written)
#   3 the target profile has no `teams` block — it takes precedence over 1
# Bash 3.2 compatible (macOS /bin/bash).
set -euo pipefail

usage() { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
die() { echo "error: $2" >&2; exit "$1"; }

STARTER=""; TARGET=""; CHECK=""
while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK=1 ;;
    -*) usage ;;
    *) if [ -z "$STARTER" ]; then STARTER="$1"; elif [ -z "$TARGET" ]; then TARGET="$1"; else usage; fi ;;
  esac
  shift
done
[ -n "$STARTER" ] && [ -n "$TARGET" ] || usage
command -v jq >/dev/null 2>&1 || die 2 "jq is required"

MANIFEST="$STARTER/.claude/team/manifest.txt"
[ -f "$MANIFEST" ] || die 2 "no manifest at $MANIFEST"

# The target's repo ROOT, proven before anything is created: installing into a subdirectory would
# scatter `.claude/` where no hook, command or `git check-ignore` would ever look at it.
[ -d "$TARGET" ] || die 2 "$TARGET does not exist"
TARGET="$(cd "$TARGET" && pwd -P)"
top="$(git -C "$TARGET" rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$top" ] || die 2 "$TARGET is not a git repository"
[ "$top" = "$TARGET" ] || die 2 "$TARGET is not the repo root ($top is)"
STARTER_P="$(cd "$STARTER" && pwd -P)"

# Every destination is walked component by component BEFORE the first write. A symlink anywhere in
# the path (`.claude -> ../shared`, a `.gitignore` symlink, a dangling placeholder) would let a
# `cp`, a `>>` or an `mv` land outside the repo we just proved we are allowed to write to.
# `-L` first: a dangling symlink is invisible to `-e`.
walk_guard() {  # walk_guard <path relative to the target root>
  local rest="$1" comp cur="$TARGET"
  while [ -n "$rest" ]; do
    comp="${rest%%/*}"
    if [ "$comp" = "$rest" ]; then rest=""; else rest="${rest#*/}"; fi
    cur="$cur/$comp"
    [ ! -L "$cur" ] || die 2 "refusing to write through the symlink $cur"
    if [ -n "$rest" ]; then
      [ ! -e "$cur" ] || [ -d "$cur" ] || die 2 "$cur is not a directory"
    else
      [ ! -e "$cur" ] || [ -f "$cur" ] || die 2 "$cur is not a regular file"
    fi
  done
}

# Every writer goes through here: `--check` must leave the target byte-identical.
apply() { [ -n "$CHECK" ] || "$@"; }

TMPF=""
trap '[ -z "$TMPF" ] || rm -f "$TMPF"' EXIT

CREATED=0; KEPT=0; CONFLICT=0; MERGED=0; REMOVED=0
emit() {  # emit <created|kept|conflict|merged|removed> <class> <path> [status suffix]
  local s="$1"
  case "$1" in
    created) CREATED=$((CREATED + 1)); [ -z "$CHECK" ] || s=create ;;
    kept)    KEPT=$((KEPT + 1));       [ -z "$CHECK" ] || s=keep ;;
    merged)  MERGED=$((MERGED + 1));   [ -z "$CHECK" ] || s=merge ;;
    removed) REMOVED=$((REMOVED + 1)); [ -z "$CHECK" ] || s=remove ;;
    conflict) CONFLICT=$((CONFLICT + 1)) ;;
  esac
  printf '%s%s\t%s\t%s\n' "$s" "${4:-}" "$2" "$3"
}

# ---- the manifest ------------------------------------------------------------------------------
# Bash 3.2: parallel arrays, no associative ones.
M_CLASS=(); M_PATH=(); EXCL=(); R_PATH=(); R_SUMS=()
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in ''|'#'*) continue ;; esac
  case "$line" in
    '!'*) EXCL+=("${line#!}") ;;
    'own '*)    M_CLASS+=(own);    M_PATH+=("${line#own }") ;;
    'shared '*) M_CLASS+=(shared); M_PATH+=("${line#shared }") ;;
    'retired '*)
      set -- ${line#retired }
      [ $# -ge 2 ] || die 2 "manifest drift: retired line '$line' names no blob id"
      R_PATH+=("$1"); shift; R_SUMS+=(" $* ") ;;
    *) die 2 "manifest drift: unparsable line '$line'" ;;
  esac
done < "$MANIFEST"
[ ${#M_PATH[@]} -gt 0 ] || die 2 "manifest drift: no entries"

i=0
while [ $i -lt ${#M_PATH[@]} ]; do
  p="${M_PATH[$i]}"
  # A manifest entry is a path RELATIVE to both roots. An absolute path or a `..` component would
  # read from, and write to, anywhere on the disk.
  case "$p" in
    /*) die 2 "manifest drift: $p is an absolute path" ;;
    ..|../*|*/../*|*/..) die 2 "manifest drift: $p leaves the manifest root" ;;
  esac
  [ -f "$STARTER/$p" ] || die 2 "manifest drift: $p"
  # And the source itself must really live inside the starter — not behind a symlink out of it.
  [ ! -L "$STARTER/$p" ] || die 2 "manifest drift: $p is a symlink"
  sd="$(cd "$STARTER/$(dirname "$p")" 2>/dev/null && pwd -P || true)"
  [ -n "$sd" ] || die 2 "manifest drift: $p"
  case "$sd/" in "$STARTER_P/"*) ;; *) die 2 "manifest drift: $p resolves outside $STARTER_P" ;; esac
  for g in ${EXCL[@]+"${EXCL[@]}"}; do
    # The glob is intentionally unquoted on the right: it is a pattern, not a literal.
    case "$p" in $g) die 2 "manifest drift: $p is excluded by !$g" ;; esac
  done
  walk_guard "$p"
  i=$((i + 1))
done

# A retired path: relative, gone from the starter (so never also own/shared), a 40-hex blob id each.
i=0
while [ $i -lt ${#R_PATH[@]} ]; do
  p="${R_PATH[$i]}"
  case "$p" in
    /*|..|../*|*/../*|*/..) die 2 "manifest drift: retired $p leaves the manifest root" ;;
  esac
  [ ! -e "$STARTER/$p" ] || die 2 "manifest drift: retired $p still exists in the starter"
  for h in ${R_SUMS[$i]}; do
    [[ "$h" =~ ^[0-9a-f]{40}$ ]] || die 2 "manifest drift: retired $p: '$h' is not a blob id"
  done
  walk_guard "$p"
  i=$((i + 1))
done

# The destinations the installer writes outside the manifest.
walk_guard .claude/settings.json
walk_guard .claude/codex-profile
walk_guard .claude/claude-profile
walk_guard .gitignore

# The merge rewrites settings.json wholesale, so it must be exactly ONE JSON object to begin with.
# Checked here, in the preflight: finding out after 100 files were copied would leave a half
# install behind. An absent file is fine — the merge starts from `{}`.
S_DST="$TARGET/.claude/settings.json"
if [ -e "$S_DST" ]; then
  jq -e -s 'length == 1 and (.[0] | type == "object")' "$S_DST" >/dev/null 2>&1 \
    || die 2 ".claude/settings.json is not a single JSON object"
  CUR="$(cat "$S_DST")"
else
  CUR='{}'
fi

# Core files the harness sources or calls but this installer never copies: they are the starter's core and
# reach a project with the starter itself and its syncs (the manifest's `!` core lines). Missing or
# different from the starter's copy → the project has not synced, and the newer team scripts would
# fail on its old adapter/profile. Refused here, before any write.
for p in .claude/lib/team-profile.sh .claude/lib/team-tracker.sh .claude/lib/costs/runtime-mark.sh \
         .claude/hooks/lib/guard_destructive_sql.py; do
  [ -f "$TARGET/$p" ] || die 2 "core file $p is missing — run /maintain:sync-from-starter first"
  cmp -s "$STARTER/$p" "$TARGET/$p" \
    || die 2 "core file $p differs from the starter's — run /maintain:sync-from-starter first"
done

# ---- the files ---------------------------------------------------------------------------------
i=0
while [ $i -lt ${#M_PATH[@]} ]; do
  cls="${M_CLASS[$i]}"; p="${M_PATH[$i]}"; src="$STARTER/$p"; dst="$TARGET/$p"
  i=$((i + 1))
  if [ ! -e "$dst" ]; then
    apply mkdir -p "$(dirname "$dst")"
    apply cp -p "$src" "$dst"
    emit created "$cls" "$p"
  elif cmp -s "$src" "$dst"; then
    # Same bytes but the project's copy lost its executable bit (a zip/copy round-trip).
    if [ -x "$src" ] && [ ! -x "$dst" ]; then
      apply chmod +x "$dst"
      emit merged "$cls" "$p"
    else
      emit kept "$cls" "$p"
    fi
  else
    if [ "$cls" = shared ]; then
      emit conflict "$cls" "$p" " (shared — merge by hand)"
    else
      emit conflict "$cls" "$p"
    fi
    echo "--- conflict $p"
    diff -u "$dst" "$src" || true
  fi
done

# ---- retired files: deleted only while they are exactly a version the starter shipped -------------
i=0
while [ $i -lt ${#R_PATH[@]} ]; do
  p="${R_PATH[$i]}"; sums="${R_SUMS[$i]}"; dst="$TARGET/$p"
  i=$((i + 1))
  [ -e "$dst" ] || continue   # walk_guard already refused a symlink or a directory here
  h="$(git -C "$TARGET" hash-object -- "$dst" 2>/dev/null || true)"
  if [ -n "$h" ] && case "$sums" in *" $h "*) true ;; *) false ;; esac; then
    apply rm -f "$dst"
    emit removed retired "$p"
  else
    emit conflict retired "$p" " (retired — changed locally; delete or keep it by hand)"
  fi
done

# ---- settings.json: the team hook entries + the role allow rules -------------------------------
SET=".claude/settings.json"
JQ_LIB='
def tokens(m): if (m == null or m == "" or m == "*") then "ALL" else (m | split("|")) end;
def covers(m; req): tokens(m) as $t
  | if $t == "ALL" then true
    else (all($t[]; test("^[A-Za-z_][A-Za-z0-9_]*$"))
          and all(req[]; . as $r | any($t[]; . == $r))) end;
'
NEW="$CUR"
S_CONFLICTS=""

# An empty <new matcher> writes no matcher (events without one: SessionStart, Stop); [extra json]
# is merged into the new hook item (e.g. {"timeout":5}).
hook_merge() {  # hook_merge <id> <event> <command> <required json> <async true|false> <new matcher> [extra json]
  local id="$1" ev="$2" cmd="$3" req="$4" as="$5" mnew="$6" extra="${7:-}" verdict attach=new
  [ -n "$extra" ] || extra='{}'
  [ "$id" != M ] || attach=first
  verdict="$(printf '%s' "$NEW" | jq -r "$JQ_LIB"'
    def asyncok(h): if $as == "true" then (h.async == true) else (h.async == null or h.async == false) end;
    (.hooks // {}) as $H
    | ([$H[$ev][]? | select(covers(.matcher; $req)) | .hooks[]?
        | select(.command == $cmd and asyncok(.))] | length) as $good
    | if $good > 0 then "ok"
      else ([$H | to_entries[] | .key as $ev2 | .value[]? | . as $e | $e.hooks[]?
             | select(.command == $cmd) | {ev: $ev2, m: $e.matcher, a: (.async // false)}]) as $occ
        | if ($occ | length) == 0 then "missing"
          else $occ[0] as $o
            | "conflict:" + (if $o.ev != $ev then "registered under \($o.ev), not \($ev)"
                elif ($as == "false" and $o.a == true) then "registered with async: true"
                elif ($as == "true" and $o.a != true) then "registered without async: true"
                else "matcher \"\($o.m // "")\" does not cover \($req | join(", "))" end)
          end
      end' --arg ev "$ev" --arg cmd "$cmd" --argjson req "$req" --arg as "$as")"
  [ "$verdict" != ok ] || return 0
  if [ "$verdict" != missing ]; then
    S_CONFLICTS="$S_CONFLICTS$id"
    CONFLICT=$((CONFLICT + 1))
    echo "conflict settings.json $id: ${verdict#conflict:}"
  fi
  NEW="$(printf '%s' "$NEW" | jq "$JQ_LIB"'
    .hooks = (.hooks // {}) | .hooks[$ev] = (.hooks[$ev] // [])
    | ({type: "command", command: $cmd} + (if $as == "true" then {async: true} else {} end)
       + $extra) as $item
    | (if $mnew == "" then {hooks: [$item]} else {matcher: $mnew, hooks: [$item]} end) as $entry
    | if $attach == "first"
      then ([.hooks[$ev] | to_entries[] | select(.value.matcher | covers(.; $req)) | .key]) as $ix
        | if ($ix | length) > 0 then .hooks[$ev][$ix[0]].hooks += [$item]
          else .hooks[$ev] += [$entry] end
      else .hooks[$ev] += [$entry] end' \
    --arg ev "$ev" --arg cmd "$cmd" --argjson req "$req" --arg as "$as" \
    --arg mnew "$mnew" --arg attach "$attach" --argjson extra "$extra")"
}

H='bash "$CLAUDE_PROJECT_DIR/.claude/hooks'
hook_merge Q PreToolUse "$H/guard-team-question.sh\"" '["AskUserQuestion"]' false AskUserQuestion
hook_merge M PreToolUse "$H/guard-team-memory.sh\"" '["Edit","Write"]' false 'Edit|Write'
hook_merge V PreToolUse "$H/guard-team-verdict.sh\"" '["Bash"]' false Bash
hook_merge A Notification "$H/team-attention.sh\"" \
  '["permission_prompt","idle_prompt","elicitation_dialog","agent_needs_input"]' true \
  'permission_prompt|idle_prompt|elicitation_dialog|agent_needs_input'
# team-watch: re-point a role's receiver after /clear or resume (inside the 5 s timeout). It exits at once outside a role session or a main checkout.
hook_merge W SessionStart "$H/team-watch-session.sh\"" '["startup","resume","clear","compact"]' false '' \
  '{"timeout":5}'

# The egress and destructive-SQL guards are the team layer's, so they are registered here (one
# opt-in step) rather than shipped in the template's shared settings. The runner's auto-mode
# preflight (team-roles.sh auto_blocker) looks for the egress guard under the exact matchers `Bash`
# and `WebFetch` with `"onFailure": "block"`, so a guard joins only an entry with exactly that
# matcher (or adds one); without the egress guard the runner launches manual and warns.
egress_merge() {  # egress_merge <matcher> [<command> <conflict id>] — default: the egress guard
  local m="$1" cmd="${2:-$EGRESS}" id="${3:-E}" verdict
  verdict="$(printf '%s' "$NEW" | jq -r --arg m "$m" --arg cmd "$cmd" '
    [.hooks.PreToolUse[]? | select(.matcher == $m) | .hooks[]? | select(.command == $cmd)] as $h
    | if any($h[]; .onFailure == "block" and (.async // false) == false) then "ok"
      elif ($h | length) > 0 then "conflict"
      else "missing" end')"
  [ "$verdict" != ok ] || return 0
  if [ "$verdict" = conflict ]; then
    S_CONFLICTS="${S_CONFLICTS}$id"
    CONFLICT=$((CONFLICT + 1))
    echo "conflict settings.json $id: $m registers $(basename "${cmd%\"}" .sh) without \"onFailure\": \"block\""
  fi
  NEW="$(printf '%s' "$NEW" | jq --arg m "$m" --arg cmd "$cmd" '
    .hooks = (.hooks // {}) | .hooks.PreToolUse = (.hooks.PreToolUse // [])
    | {type: "command", command: $cmd, onFailure: "block"} as $item
    | ([.hooks.PreToolUse | to_entries[] | select(.value.matcher == $m) | .key]) as $ix
    | if ($ix | length) > 0 then .hooks.PreToolUse[$ix[0]].hooks += [$item]
      else .hooks.PreToolUse += [{matcher: $m, hooks: [$item]}] end')"
}
EGRESS="$H/guard-team-egress.sh\""
egress_merge Bash
egress_merge WebFetch
egress_merge Bash "$H/guard-destructive-sql.sh\"" D
# A synchronous hook registered under several entries (one command, many events), which hook_merge
# (one registration per command) cannot express. Identified per event and exact matcher; it must run
# synchronously (async events can land out of order) and carry its exact `if` filter when it has one —
# otherwise a conflict, and a correct entry is added next to it.
sync_merge() {  # sync_merge <id> <command> <timeout> <event> <matcher|''> [<if rule>]
  local id="$1" cmd="$2" to="$3" ev="$4" m="$5" cond="${6:-}" verdict n
  n="${cmd%\"}"; n="${n##*/}"; n="${n%.sh}"
  verdict="$(printf '%s' "$NEW" | jq -r --arg ev "$ev" --arg m "$m" --arg cmd "$cmd" --arg cond "$cond" '
    [.hooks[$ev][]? | select((.matcher // "") == $m) | .hooks[]? | select(.command == $cmd)] as $h
    | if any($h[]; (.async // false) == false and (.if // "") == $cond) then "ok"
      elif ($h | length) > 0 then "conflict"
      else "missing" end')"
  [ "$verdict" != ok ] || return 0
  if [ "$verdict" = conflict ]; then
    S_CONFLICTS="${S_CONFLICTS}$id"
    CONFLICT=$((CONFLICT + 1))
    if [ -n "$cond" ]; then
      echo "conflict settings.json $id: $ev${m:+ $m} registers $n async or without the filter $cond"
    else
      echo "conflict settings.json $id: $ev${m:+ $m} registers $n async"
    fi
  fi
  NEW="$(printf '%s' "$NEW" | jq --arg ev "$ev" --arg m "$m" --arg cmd "$cmd" --arg cond "$cond" --argjson to "$to" '
    .hooks = (.hooks // {}) | .hooks[$ev] = (.hooks[$ev] // [])
    | ({type: "command", command: $cmd, timeout: $to} + (if $cond == "" then {} else {if: $cond} end)) as $item
    | .hooks[$ev] += [(if $m == "" then {} else {matcher: $m} end) + {hooks: [$item]}]')"
}
# The token-usage stage hook (`.agents/reference/token-usage.md` → Runtime log): three entries; the
# Bash entry carries the end step's exact `if` filter.
STAGE="$H/stage-mark.sh\""
sync_merge K "$STAGE" 5 PreToolUse Skill
sync_merge B "$STAGE" 5 PreToolUse Bash 'Bash(bash .claude/lib/costs/runtime-mark.sh stage end *)'
sync_merge U "$STAGE" 5 UserPromptExpansion ''
# The session-host state hook (team-status.sh): a role or stage session's state file for the
# driver's `status`/`send`, plus the OSC write until step 8. Synchronous, so events land in order;
# silent unless the driver started the session (HARNESS_REGISTRY/HARNESS_ADDRESS).
TSTAT="$H/team-status.sh\""
sync_merge T "$TSTAT" 3 PostToolUse ''
sync_merge N "$TSTAT" 3 Notification 'permission_prompt|idle_prompt|elicitation_dialog|agent_needs_input'
sync_merge P "$TSTAT" 3 UserPromptSubmit ''
sync_merge O "$TSTAT" 3 Stop ''
sync_merge X "$TSTAT" 3 SessionEnd ''

# hook_retire <command> — drop every hook item whose command is exactly <command> (a hook this
# installer used to register; hook_merge matches by command, so a renamed hook would stay behind).
# An entry left without hooks goes too; a foreign command that only contains the name stays.
hook_retire() {
  local cmd="$1" n
  n="$(printf '%s' "$NEW" | jq --arg c "$cmd" '[.hooks[]?[]?.hooks[]? | select(.command == $c)] | length')"
  [ "$n" != 0 ] || return 0
  NEW="$(printf '%s' "$NEW" | jq --arg c "$cmd" '
    .hooks |= with_entries(.value |= (map(if has("hooks") then .hooks |= map(select(.command != $c)) else . end)
      | map(select((.hooks // [0]) | length > 0))))')"
  n="${cmd%\"}"; echo "retired settings.json: ${n##*/}"
}

# The session registry (roles, stages, ad-hoc sessions, and the per-run TeamLead's identity refresh
# and socket registration, which teamlead-register.sh did before; the role contract line, which
# session-role.sh did before) and the prompt-time inbox count; the role wake loop's Stop hook,
# retired with the loop.
hook_retire "$H/teamlead-register.sh\""
hook_retire "$H/session-role.sh\""
hook_retire "$H/monitoring-rearm.sh\""
hook_merge L SessionStart "$H/session-registry.sh\"" '["startup","resume","clear","compact"]' false '' \
  '{"timeout":5}'
hook_merge I UserPromptSubmit "$H/inbox-count.sh\"" '[]' false '' '{"timeout":3}'
# The same registry hook on SessionEnd marks an ad-hoc conversation that ended normally (after L, so
# L's own check sees its SessionStart entry first).
sync_merge E "$H/session-registry.sh\"" 5 SessionEnd ''

# The owner's /setup:start answer; a missing or unreadable profile keeps the prompts (confirm).
TEAM_MERGE="$(jq -r '.workflow.team_merge // "confirm"' "$TARGET/.claude/project-profile.json" 2>/dev/null || echo confirm)"

# The roles run these from the clones; anything wider stays the project's own decision.
NEW="$(printf '%s' "$NEW" | jq --arg tm "$TEAM_MERGE" '
  ["Bash(bash .claude/lib/team-*.sh*)", "Bash(git switch *)", "Bash(git show *)",
   "Bash(gh pr view*)", "Bash(gh issue view*)", "Bash(bash .claude/lib/codex-bg.sh*)",
   "Bash(PROMPT=* bash .claude/lib/codex-bg.sh*)",
   "Bash(bash .claude/lib/monitoring.sh*)",
   # The role-session support verbs; its Operator actions are on the ask list below.
   "Bash(bash .claude/lib/supervisor-sessions.sh check*)",
   "Bash(bash .claude/lib/supervisor-sessions.sh preflight*)", "Bash(bash .claude/lib/supervisor-sessions.sh materialize*)",
   "Bash(bash .claude/lib/supervisor-sessions.sh reviewer*)", "Bash(bash .claude/lib/supervisor-sessions.sh freeze on *)",
   "Bash(bash .claude/lib/supervisor-sessions.sh freeze status*)",
   "Bash(printenv TEAM_SESSION_ROLE)",
   # /roles: start, list, stop and place the role sessions; taking a window (here) is asked.
   "Bash(bash .claude/lib/roles.sh)", "Bash(bash .claude/lib/roles.sh up*)",
   "Bash(bash .claude/lib/roles.sh status*)", "Bash(bash .claude/lib/roles.sh stop *)",
   "Bash(bash .claude/lib/roles.sh place *)",
   # test-gate.sh is not matched by team-*.sh.
   "Bash(bash .claude/lib/test-gate.sh*)",
   # The cost writer; the core settings allow only its no-op stage end step.
   "Bash(bash .claude/lib/costs/runtime-mark.sh:*)"] as $want
  # The team-*.sh allow would also cover the supervisor-only trunk writers; `ask` beats `allow`,
  # so a role can never integrate unattended and the supervisor still gets the Operator prompt.
  # Under workflow.team_merge=auto (the owner answer to /setup:start) the three are left out and
  # removed — the roles in the clones lose the prompt, but guard-team-verdict.sh refuses the trunk
  # writers (and team-automerge-check.sh) from any role session.
  | ["Bash(bash .claude/lib/team-integrate.sh*)", "Bash(bash .claude/lib/team-integrate-lock.sh*)",
     "Bash(bash .claude/lib/team-merge-check.sh*)"] as $merge
  | ((if $tm == "auto" then [] else $merge end) + [
     # The channel step writes the machine registry and boxes outside the repo.
     "Bash(bash .claude/lib/team-mail-setup.sh*)",
     # The operator kit is installed outside the repo by the Operator only.
     "Bash(bash .claude/team/sessions/operator-kit/install.sh*)",
     # team-watch verbs only the Operator may trigger: routing, stop, a takeover, the
     # answering and class switches.
     "Bash(bash .claude/lib/team-watch.sh routing*)", "Bash(bash .claude/lib/team-watch.sh stop*)",
     "Bash(bash .claude/lib/team-watch.sh register --takeover*)",
     "Bash(bash .claude/lib/team-watch.sh mode answering*)",
     "Bash(bash .claude/lib/team-watch.sh mode class*)",
     # the role-session Operator actions: clearing a freeze, the rollback, taking a window (here).
     "Bash(bash .claude/lib/supervisor-sessions.sh freeze off*)",
     "Bash(bash .claude/lib/supervisor-sessions.sh rollback*)",
     "Bash(bash .claude/lib/roles.sh here *)"]) as $ask
  # Rules this installer added for the launcher verbs step 9a removed, the retired role wake loop and the retired answer verb (exact strings only; a rule worded any other way stays).
  | ((["status*", "start *", "stop *", "up*", "here *"]
     | map("Bash(bash .claude/lib/supervisor-sessions.sh " + . + ")"))
     + ["Bash(bash .claude/lib/session-wake.sh*)", "Bash(bash .claude/lib/supervisor-sessions.sh answer *)"]) as $gone
  | .permissions = (.permissions // {})
  | .permissions.allow = ((.permissions.allow // []) - $gone)
  | .permissions.ask = ((.permissions.ask // []) - $gone - (if $tm == "auto" then $merge else [] end))
  | .permissions.allow = ((.permissions.allow // []) + ($want - (.permissions.allow // [])))
  | .permissions.ask = ((.permissions.ask // []) + ($ask - (.permissions.ask // [])))')"

if [ "$NEW" = "$CUR" ]; then
  emit kept generated "$SET"
else
  if [ -z "$CHECK" ]; then
    mkdir -p "$(dirname "$S_DST")"
    # mktemp, never a fixed name: a pre-planted `settings.json.<fixed>` symlink would turn the
    # redirect into a write to whatever it points at (settings.local.json, a file outside the repo).
    # The temp file is created inside the already-validated `.claude/`, so the `mv` is atomic.
    TMPF="$(mktemp "$TARGET/.claude/.team-setup.XXXXXX")"
    printf '%s\n' "$NEW" > "$TMPF"
    mv "$TMPF" "$S_DST"
    TMPF=""
  fi
  emit merged generated "$SET"
fi

# ---- .gitignore: runtime state in .agents/team/, the tool's fallback mail box in .agents/agent-mail/
IGN=""
for d in .agents/team/ .agents/agent-mail/; do
  git -C "$TARGET" check-ignore -q "${d}probe" 2>/dev/null || IGN="$IGN$d\n"
done
if [ -z "$IGN" ]; then
  emit kept generated .gitignore
else
  apply sh -c 'printf "\n# Team harness runtime state (team-setup.sh)\n$2" >> "$1"' _ \
    "$TARGET/.gitignore" "$IGN"
  emit merged generated .gitignore
fi

# ---- .claude/codex-profile, .claude/claude-profile: the templates only, never a value -----------
for CP in .claude/codex-profile .claude/claude-profile; do
  if [ -e "$TARGET/$CP" ]; then
    emit kept generated "$CP"
  else
    apply mkdir -p "$TARGET/.claude"
    apply cp -p "$STARTER/$CP" "$TARGET/$CP"
    emit created generated "$CP"
  fi
done

# ---- the profile: values are the command's job, never guessed here -----------------------------
PROFILE_OK=""
! jq -e '.teams | type == "object"' "$TARGET/.claude/project-profile.json" >/dev/null 2>&1 \
  || PROFILE_OK=1

echo "summary: created=$CREATED kept=$KEPT conflict=$CONFLICT merged=$MERGED removed=$REMOVED"
if [ -z "$PROFILE_OK" ]; then
  echo "profile: missing"
  exit 3
fi
echo "profile: ok"
[ "$CONFLICT" = 0 ] || exit 1
exit 0
