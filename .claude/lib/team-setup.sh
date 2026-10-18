#!/usr/bin/env bash
# Installs the team harness into another project from `.claude/team/manifest.txt`: copies the
# `own` files, reports `shared` files the project already owns, merges the three hook entries and
# the role `permissions.allow` rules into `settings.json`, ignores `.agents/team/` and seeds
# `.claude/codex-profile`. It NEVER overwrites a file the target already has — a difference is a
# `conflict` with a diff, for a hand merge.
#
# Usage: bash .claude/lib/team-setup.sh <starter-root> <target-root> [--check]
#   e.g. bash .claude/lib/team-setup.sh ~/Desktop/AI_Coding_Starter "$PWD"
#   --check: report the plan and write NOTHING (statuses read create|keep|conflict|merge).
#
# Output: one `<status>\t<class>\t<path>` line per path (`created|kept|conflict|merged`, class
# `own|shared|generated`), each conflict followed by `--- conflict <path>` and a unified diff,
# then `summary: created=N kept=N conflict=N merged=N` and `profile: ok|missing`.
#
# Exit: 0 installed, nothing to decide · 1 conflicts (everything else is installed)
#   2 usage / no jq / target is not a repo root / manifest drift (nothing written)
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

CREATED=0; KEPT=0; CONFLICT=0; MERGED=0
emit() {  # emit <created|kept|conflict|merged> <class> <path> [status suffix]
  local s="$1"
  case "$1" in
    created) CREATED=$((CREATED + 1)); [ -z "$CHECK" ] || s=create ;;
    kept)    KEPT=$((KEPT + 1));       [ -z "$CHECK" ] || s=keep ;;
    merged)  MERGED=$((MERGED + 1));   [ -z "$CHECK" ] || s=merge ;;
    conflict) CONFLICT=$((CONFLICT + 1)) ;;
  esac
  printf '%s%s\t%s\t%s\n' "$s" "${4:-}" "$2" "$3"
}

# ---- the manifest ------------------------------------------------------------------------------
# Bash 3.2: parallel arrays, no associative ones.
M_CLASS=(); M_PATH=(); EXCL=()
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in ''|'#'*) continue ;; esac
  case "$line" in
    '!'*) EXCL+=("${line#!}") ;;
    'own '*)    M_CLASS+=(own);    M_PATH+=("${line#own }") ;;
    'shared '*) M_CLASS+=(shared); M_PATH+=("${line#shared }") ;;
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

# The destinations the installer writes outside the manifest.
walk_guard .claude/settings.json
walk_guard .claude/codex-profile
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

# ---- settings.json: the three hook entries + the role allow rules ------------------------------
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

hook_merge() {  # hook_merge <id> <event> <command> <required json> <async true|false> <new matcher>
  local id="$1" ev="$2" cmd="$3" req="$4" as="$5" mnew="$6" verdict attach=new
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
    | ({type: "command", command: $cmd} + (if $as == "true" then {async: true} else {} end)) as $item
    | if $attach == "first"
      then ([.hooks[$ev] | to_entries[] | select(.value.matcher | covers(.; $req)) | .key]) as $ix
        | if ($ix | length) > 0 then .hooks[$ev][$ix[0]].hooks += [$item]
          else .hooks[$ev] += [{matcher: $mnew, hooks: [$item]}] end
      else .hooks[$ev] += [{matcher: $mnew, hooks: [$item]}] end' \
    --arg ev "$ev" --arg cmd "$cmd" --argjson req "$req" --arg as "$as" \
    --arg mnew "$mnew" --arg attach "$attach")"
}

H='bash "$CLAUDE_PROJECT_DIR/.claude/hooks'
hook_merge Q PreToolUse "$H/guard-team-question.sh\"" '["AskUserQuestion"]' false AskUserQuestion
hook_merge M PreToolUse "$H/guard-team-memory.sh\"" '["Edit","Write"]' false 'Edit|Write'
hook_merge A Notification "$H/team-attention.sh\"" \
  '["permission_prompt","idle_prompt","elicitation_dialog","agent_needs_input"]' true \
  'permission_prompt|idle_prompt|elicitation_dialog|agent_needs_input'

# The roles run these from the clones; anything wider stays the project's own decision.
NEW="$(printf '%s' "$NEW" | jq '
  ["Bash(bash .claude/lib/team-*.sh*)", "Bash(git switch *)", "Bash(git show *)",
   "Bash(gh pr view*)", "Bash(gh issue view*)", "Bash(bash .claude/lib/codex-bg.sh*)",
   "Bash(PROMPT=* bash .claude/lib/codex-bg.sh*)"] as $want
  # The team-*.sh allow would also cover the supervisor-only trunk writers; `ask` beats `allow`,
  # so a role can never integrate unattended and the supervisor still gets the Operator prompt.
  | ["Bash(bash .claude/lib/team-integrate.sh*)", "Bash(bash .claude/lib/team-integrate-lock.sh*)",
     "Bash(bash .claude/lib/team-merge-check.sh*)"] as $ask
  | .permissions = (.permissions // {})
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

# ---- .gitignore: the harness writes runtime state into .agents/team/ ---------------------------
if git -C "$TARGET" check-ignore -q .agents/team/probe 2>/dev/null; then
  emit kept generated .gitignore
else
  apply sh -c 'printf "\n# Team harness runtime state (team-setup.sh)\n.agents/team/\n" >> "$1"' _ \
    "$TARGET/.gitignore"
  emit merged generated .gitignore
fi

# ---- .claude/codex-profile: the template only, never a value ------------------------------------
CP=".claude/codex-profile"
if [ -e "$TARGET/$CP" ]; then
  emit kept generated "$CP"
else
  apply mkdir -p "$TARGET/.claude"
  apply cp -p "$STARTER/$CP" "$TARGET/$CP"
  emit created generated "$CP"
fi

# ---- the profile: values are the command's job, never guessed here -----------------------------
PROFILE_OK=""
! jq -e '.teams | type == "object"' "$TARGET/.claude/project-profile.json" >/dev/null 2>&1 \
  || PROFILE_OK=1

echo "summary: created=$CREATED kept=$KEPT conflict=$CONFLICT merged=$MERGED"
if [ -z "$PROFILE_OK" ]; then
  echo "profile: missing"
  exit 3
fi
echo "profile: ok"
[ "$CONFLICT" = 0 ] || exit 1
exit 0
