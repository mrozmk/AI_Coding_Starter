#!/usr/bin/env bash
# Project values for the team harness, read from `.claude/project-profile.json` → `teams`.
# Sourced, never executed; the caller sets `set -euo pipefail`.
# Bash 3.2 compatible (macOS /bin/bash): no mapfile, no associative arrays.
#
# The profile carries VALUES only (tracker, trunk, tools, gates, clone parent). Provider BEHAVIOUR
# lives elsewhere: tracker behaviour is `team-tracker.sh` (github/none; jira stays on the session's
# MCP), PR behaviour is `team-pr.sh` (github) and the `team-lib.sh` helpers (azure-devops), and
# `team_profile_require_supported` refuses what has no merge path at all — it must be called before
# the first side effect (clone, tmux, team.json).
#
# Values are read with `jq -r` only: the profile is never `eval`ed or sourced.

team_profile_die() { echo "error: $*" >&2; exit 2; }

# The effective github block, as one jq expression for every reader (profile, base checks, prompts):
# `teams.github` when present, else the top-level `github` that the single-session path also uses.
TEAM_GH_BLOCK='(.teams.github // .github // {})'

# Usage: team_profile_gh_req <file> <jq path> <field> [regex] [why] [block] → value in
# $TEAM_PROFILE_GH_V. `block` is the name the refusal shows (default `teams.github`).
# A global, not stdout: `$(…)` would run team_profile_die in a subshell and the caller would sail
# on with an empty value. Missing block, empty field and bad format are the same refusal.
# `why` names the setting that made the field required: `repo` is also required by pr_provider=github
# on its own (a live rig runs tracker=none + pr_provider=github), and pointing at the tracker there
# would send the reader to a setting they never touched.
team_profile_gh_req() {
  local f="$1" path="$2" field="$3" re="${4:-}" why="${5:-tracker=github}" blk="${6:-teams.github}"
  TEAM_PROFILE_GH_V="$(jq -r "$path | if . == null then \"\" else tostring end" "$f" \
    2>/dev/null || true)"
  [ -n "$TEAM_PROFILE_GH_V" ] \
    || team_profile_die "$blk.$field is required for $why"
  if [ -n "$re" ]; then
    [[ "$TEAM_PROFILE_GH_V" =~ $re ]] \
      || team_profile_die "$blk.$field is required for $why"
  fi
}

# Usage: team_profile_gh_project <file> <block jq expr> <block name> <why> — the six Project fields,
# in this order, into TEAM_GH_PROJECT_* / TEAM_GH_STATUS_*; the first missing one is the refusal.
team_profile_gh_project() {
  local f="$1" b="$2" n="$3" why="$4"
  team_profile_gh_req "$f" "$b.project_owner" project_owner '' "$why" "$n"
  TEAM_GH_PROJECT_OWNER="$TEAM_PROFILE_GH_V"
  team_profile_gh_req "$f" "$b.project_number" project_number '^[0-9]+$' "$why" "$n"
  TEAM_GH_PROJECT_NUMBER="$TEAM_PROFILE_GH_V"
  team_profile_gh_req "$f" "$b.project_id" project_id '' "$why" "$n"
  TEAM_GH_PROJECT_ID="$TEAM_PROFILE_GH_V"
  team_profile_gh_req "$f" "$b.status_field_id" status_field_id '' "$why" "$n"
  TEAM_GH_STATUS_FIELD_ID="$TEAM_PROFILE_GH_V"
  team_profile_gh_req "$f" "$b.status_options.started" status_options.started '' "$why" "$n"
  TEAM_GH_STATUS_STARTED="$TEAM_PROFILE_GH_V"
  team_profile_gh_req "$f" "$b.status_options.delivered" status_options.delivered '' "$why" "$n"
  TEAM_GH_STATUS_DELIVERED="$TEAM_PROFILE_GH_V"
}

# Usage: team_profile_int <file> <key under teams.teamlead> <default> <min> → $TEAM_PROFILE_INT_V.
# A global for the same reason as team_profile_gh_req: a die inside `$(…)` would not stop the caller.
team_profile_int() {
  local f="$1" key="$2" def="$3" min="$4"
  TEAM_PROFILE_INT_V="$(jq -r --arg k "$key" 'getpath(["teams", "teamlead"] + ($k | split(".")))
    | if . == null then "" else tostring end' "$f" 2>/dev/null || echo '!')"
  TEAM_PROFILE_INT_V="${TEAM_PROFILE_INT_V:-$def}"
  if ! [[ "$TEAM_PROFILE_INT_V" =~ ^[0-9]+$ ]] || [ "$TEAM_PROFILE_INT_V" -lt "$min" ]; then
    # With the lead switch off nothing reads these keys: a bad one falls back to its default
    # instead of stopping every command that loads the profile.
    [ "$TEAM_LEAD_ENABLED" = true ] || { TEAM_PROFILE_INT_V="$def"; return 0; }
    if [ "$min" -gt 0 ]; then
      team_profile_die "teams.teamlead.$key=$TEAM_PROFILE_INT_V must be a positive integer"
    fi
    team_profile_die "teams.teamlead.$key=$TEAM_PROFILE_INT_V must be a non-negative integer"
  fi
}

# `~` or `~/…` prefix → $HOME; every other value is verbatim (paths may contain spaces).
team_profile_expand() { printf '%s' "${1/#\~/$HOME}"; }

# Usage: team_profile_load [root] — parse + validate the `teams` block once per process.
team_profile_load() {
  [ -z "${TEAM_PROFILE_LOADED:-}" ] || return 0
  local root f v
  root="${1:-$(git rev-parse --show-toplevel)}"
  f="$root/.claude/project-profile.json"
  [ -f "$f" ] || team_profile_die "no teams profile — run /setup:teams"
  jq -e '.teams | type == "object"' "$f" >/dev/null 2>&1 \
    || team_profile_die "no teams profile — run /setup:teams"

  TEAM_TRACKER="$(jq -r '.teams.tracker // empty' "$f" 2>/dev/null || true)"
  case "$TEAM_TRACKER" in
    jira)   TEAM_KEY_REGEX='^[A-Z]+-[0-9]+$' ;;
    github) TEAM_KEY_REGEX='^[0-9]+$' ;;
    none)   TEAM_KEY_REGEX='^L[0-9]+$' ;;
    *) team_profile_die "teams.tracker=${TEAM_TRACKER:-<missing>} must be jira|github|none" ;;
  esac

  TEAM_PR_PROVIDER="$(jq -r '.teams.pr_provider // empty' "$f" 2>/dev/null || true)"
  case "$TEAM_PR_PROVIDER" in
    azure-devops|none|github) ;;
    *) team_profile_die \
      "teams.pr_provider=${TEAM_PR_PROVIDER:-<missing>} must be azure-devops|none|github" ;;
  esac

  TEAM_GATES="$(jq -r '.teams.gates // empty' "$f" 2>/dev/null || true)"
  case "$TEAM_GATES" in
    auto|manual-mql5) ;;
    *) team_profile_die "teams.gates=${TEAM_GATES:-<missing>} must be auto|manual-mql5" ;;
  esac

  TEAM_TRUNK="$(jq -r '.teams.trunk // empty' "$f" 2>/dev/null || true)"
  [ -n "$TEAM_TRUNK" ] || team_profile_die "teams.trunk is required"

  TEAM_BUILD_CHECK="$(jq -r '.teams.build_check // empty' "$f" 2>/dev/null || true)"
  [ -n "$TEAM_BUILD_CHECK" ] || team_profile_die "teams.build_check is required"

  # A script path (run as `bash <path>`) or the literal `none` (the gate step is skipped).
  v="$(jq -r '.teams.test_gate // empty' "$f" 2>/dev/null || true)"
  [ -n "$v" ] || team_profile_die "teams.test_gate is required (a path or none)"
  if [ "$v" = none ]; then
    TEAM_TEST_GATE=none          # a sentinel, never a file — no expansion
  else
    TEAM_TEST_GATE="$(team_profile_expand "$v")"
  fi

  # `// empty` would swallow a legitimate `false` — jq treats it as an empty alternative.
  v="$(jq -r '.teams.env_file_required | if . == null then "" else tostring end' "$f" \
    2>/dev/null || true)"
  case "$v" in
    true|false) TEAM_ENV_REQUIRED="$v" ;;
    *) team_profile_die "teams.env_file_required=${v:-<missing>} must be true|false" ;;
  esac

  # Optional: absent → clones are siblings of the repo (today's behaviour).
  v="$(jq -r '.teams.clone_parent // empty' "$f" 2>/dev/null || true)"
  TEAM_CLONE_PARENT="$(team_profile_expand "$v")"

  # Optional clone-directory template; absent → `<repo dir>-{team}`, today's behaviour. The team
  # placeholder must END the template and be the only one: the clone glob is a PREFIX
  # (team_clone_dirs, the collision scan in team_ticket_checks), so anything after the team name
  # would make every clone invisible to its own harness.
  v="$(jq -r '.teams.clone_name // empty' "$f" 2>/dev/null || true)"
  if [ -z "$v" ]; then
    TEAM_CLONE_NAME="$(basename "$root")-{team}"
  else
    case "$v" in
      *'{team}'|*'{Team}') ;;
      *) team_profile_die "teams.clone_name=$v must end with {team} or {Team} (no '/')" ;;
    esac
    # The prefix left once the trailing placeholder is gone: non-empty, no second placeholder,
    # no path separator.
    case "${v%\{[tT]eam\}}" in
      ''|*'{team}'*|*'{Team}'*|*/*)
        team_profile_die "teams.clone_name=$v must end with {team} or {Team} (no '/')" ;;
    esac
    TEAM_CLONE_NAME="$v"
  fi

  # The per-run TeamLead. Off by default: the global TeamLead runs unchanged until it is retired.
  v="$(jq -r '.teams.teamlead.enabled | if . == null then "false" else tostring end' "$f" \
    2>/dev/null || true)"
  case "$v" in
    true|false) TEAM_LEAD_ENABLED="$v" ;;
    *) team_profile_die "teams.teamlead.enabled=${v:-<invalid>} must be true|false" ;;
  esac
  team_profile_int "$f" revise_limit 3 1; TEAM_LEAD_REVISE_LIMIT="$TEAM_PROFILE_INT_V"
  team_profile_int "$f" rework_budget.brainstorm 2 0
  TEAM_LEAD_BUDGET_BRAINSTORM="$TEAM_PROFILE_INT_V"
  team_profile_int "$f" rework_budget.quick 1 0; TEAM_LEAD_BUDGET_QUICK="$TEAM_PROFILE_INT_V"
  # Rule-group tokens only the Operator decides; absent = the two default groups.
  TEAM_LEAD_HUMAN_ONLY="$(jq -r '.teams.teamlead.human_only
    | if . == null then "settings-profiles\nprod-ask"
      elif type == "array" and length > 0 and all(.[]; type == "string" and length > 0)
      then join("\n") else "!" end' "$f" 2>/dev/null || echo '!')"
  if [ "$TEAM_LEAD_HUMAN_ONLY" = '!' ]; then
    [ "$TEAM_LEAD_ENABLED" != true ] \
      || team_profile_die "teams.teamlead.human_only must be a non-empty list of rule-group names"
    TEAM_LEAD_HUMAN_ONLY="$(printf 'settings-profiles\nprod-ask')"
  fi
  # The per-run launcher's model/effort (teams.sessions.TeamLead, a standing:false role in
  # roles-lib.sh; its defaults here are the per-run ones).
  TEAM_LEAD_MODEL="$(jq -r '.teams.sessions.TeamLead.model // empty | strings' "$f" \
    2>/dev/null || true)"
  TEAM_LEAD_MODEL="${TEAM_LEAD_MODEL:-fable}"
  [[ "$TEAM_LEAD_MODEL" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}(\[[0-9a-z]+\])?$ ]] \
    || team_profile_die "teams.sessions.TeamLead.model=$TEAM_LEAD_MODEL is not a model name"
  TEAM_LEAD_EFFORT="$(jq -r '.teams.sessions.TeamLead.effort // empty | strings' "$f" \
    2>/dev/null || true)"
  TEAM_LEAD_EFFORT="${TEAM_LEAD_EFFORT:-high}"
  case "$TEAM_LEAD_EFFORT" in
    low|medium|high|xhigh|max) ;;
    *) team_profile_die \
      "teams.sessions.TeamLead.effort=$TEAM_LEAD_EFFORT must be low|medium|high|xhigh|max" ;;
  esac

  # Bash 3.2: no mapfile — read the jq lines into the array by hand.
  TEAM_BRANCH_TYPES=()
  while IFS= read -r v; do [ -z "$v" ] || TEAM_BRANCH_TYPES+=("$v"); done \
    < <(jq -r '.teams.branch_types[]? // empty' "$f" 2>/dev/null)
  [ ${#TEAM_BRANCH_TYPES[@]} -gt 0 ] || team_profile_die "teams.branch_types must not be empty"

  TEAM_REQUIRED_TOOLS=()
  while IFS= read -r v; do [ -z "$v" ] || TEAM_REQUIRED_TOOLS+=("$v"); done \
    < <(jq -r '.teams.required_tools[]? // empty' "$f" 2>/dev/null)
  [ ${#TEAM_REQUIRED_TOOLS[@]} -gt 0 ] || team_profile_die "teams.required_tools must not be empty"

  # May be empty: a project that seeds nothing into its clones.
  TEAM_SEED_FILES=()
  while IFS= read -r v; do [ -z "$v" ] || TEAM_SEED_FILES+=("$v"); done \
    < <(jq -r '.teams.seed_files[]? // empty' "$f" 2>/dev/null)

  # The github block: `teams.github`, else the top-level `github` (TEAM_GH_BLOCK — the whole block
  # wins, never a per-field merge). `repo` is required by EITHER tracker=github (the issue/project board)
  # or pr_provider=github (the PR layer) — the live rig combines tracker=none with pr_provider=github.
  # The Project fields stay tracker-only: a PR provider never writes a board. Always initialized —
  # the callers run under `set -u`.
  TEAM_GH_REPO=""; TEAM_GH_PROJECT_OWNER=""; TEAM_GH_PROJECT_NUMBER=""
  TEAM_GH_PROJECT_ID=""; TEAM_GH_STATUS_FIELD_ID=""
  TEAM_GH_STATUS_STARTED=""; TEAM_GH_STATUS_DELIVERED=""
  TEAM_PROFILE_GH_V=""
  if [ "$TEAM_TRACKER" = github ] || [ "$TEAM_PR_PROVIDER" = github ]; then
    if [ "$TEAM_TRACKER" = github ]; then
      team_profile_gh_req "$f" "$TEAM_GH_BLOCK"'.repo' repo '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'
    else
      team_profile_gh_req "$f" "$TEAM_GH_BLOCK"'.repo' repo \
        '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' 'pr_provider=github'
    fi
    TEAM_GH_REPO="$TEAM_PROFILE_GH_V"
  fi
  [ "$TEAM_TRACKER" != github ] || team_profile_gh_project "$f" "$TEAM_GH_BLOCK" teams.github tracker=github

  TEAM_PROFILE_LOADED=1
}

# Usage: team_tracker_profile_load [root] — what `team-tracker.sh` needs, for a project with OR
# without teams. A `teams` block → team_profile_load, full validation, unchanged. None → only the
# top-level `tracker` (jira|github|none, missing = none) and, for github, the top-level `github`
# block: `repo` required; the Project fields all present (validated) or all absent (no Project).
# Its own flag: TEAM_PROFILE_LOADED means "the whole teams block was validated", and setting it
# here would let a later team_profile_load skip that.
team_tracker_profile_load() {
  [ -z "${TEAM_TRACKER_PROFILE_LOADED:-}" ] || return 0
  local root f n
  root="${1:-$(git rev-parse --show-toplevel)}"
  f="$root/.claude/project-profile.json"
  if [ -f "$f" ] && jq -e '.teams | type == "object"' "$f" >/dev/null 2>&1; then
    team_profile_load "$root"
    TEAM_TRACKER_TEAMS=1; TEAM_TRACKER_PROFILE_LOADED=1
    return 0
  fi
  TEAM_TRACKER_TEAMS=""
  TEAM_TRACKER="$( [ ! -f "$f" ] || jq -r '.tracker // empty' "$f" 2>/dev/null || true)"
  case "${TEAM_TRACKER:=none}" in
    jira)   TEAM_KEY_REGEX='^[A-Z]+-[0-9]+$' ;;
    github) TEAM_KEY_REGEX='^[0-9]+$' ;;
    none)   TEAM_KEY_REGEX='^L[0-9]+$' ;;
    *) team_profile_die "tracker=$TEAM_TRACKER must be jira|github|none" ;;
  esac
  TEAM_GH_REPO=""; TEAM_GH_PROJECT_OWNER=""; TEAM_GH_PROJECT_NUMBER=""
  TEAM_GH_PROJECT_ID=""; TEAM_GH_STATUS_FIELD_ID=""
  TEAM_GH_STATUS_STARTED=""; TEAM_GH_STATUS_DELIVERED=""
  if [ "$TEAM_TRACKER" = github ]; then
    team_profile_gh_req "$f" '.github.repo' repo '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' \
      tracker=github github
    TEAM_GH_REPO="$TEAM_PROFILE_GH_V"
    n="$(jq -r '[.github.project_owner, .github.project_number, .github.project_id,
                 .github.status_field_id, .github.status_options.started,
                 .github.status_options.delivered] | map(select(. != null and . != "")) | length' \
      "$f" 2>/dev/null || echo 0)"
    if [ "$n" != 0 ]; then
      # A partial Project is a typo, not "no Project": refuse it, naming the first missing field.
      team_profile_gh_project "$f" '.github' github 'a github Project'
    fi
  fi
  TEAM_TRACKER_PROFILE_LOADED=1
}

# Usage: team_cost_key <root> <short key> — the key cost records are bound to. The short key stays
# in the branch and team.json; costs need one that is unique across projects (same `#4` elsewhere).
team_cost_key() {
  local root="$1" key="$2"
  [ -n "${TEAM_PROFILE_LOADED:-}" ] || team_profile_load "$root"
  case "$TEAM_TRACKER" in
    github) printf '%s#%s' "$TEAM_GH_REPO" "$key" ;;
    none)   # `-` LAST in the tr set: `.-\n` would be a reversed range and tr would fail.
            printf '%s:%s' "$(printf '%s' "$(basename "$root")" | tr -c 'A-Za-z0-9_.-' '-')" "$key" ;;
    *)      printf '%s' "$key" ;;
  esac
}

# Usage: team_claude_home <repo root> → the Claude config dir this project's sessions run on: the
# first value line of <root>/.claude/claude-profile (`~/` → $HOME), else the caller's
# CLAUDE_CONFIG_DIR (empty = Claude's default). A declared dir that does not resolve → message, rc 1.
# Launchers pass it per session: a tmux session inherits the server's environment, which may be
# another project's.
team_claude_home() {
  local want real
  want="$(sed -n '/^[[:space:]]*$/d; /^#/d; p; q' "$1/.claude/claude-profile" 2>/dev/null || true)"
  if [ -z "$want" ]; then printf '%s' "${CLAUDE_CONFIG_DIR:-}"; return 0; fi
  case "$want" in "~/"*) want="$HOME/${want#\~/}" ;; esac
  real="$(cd "$want" 2>/dev/null && pwd -P || true)"
  if [ -z "$real" ]; then
    echo "error: Claude profile $want from .claude/claude-profile does not resolve — no session launched"
    return 1
  fi
  printf '%s' "$real"
}

# Usage: team_gh_origin_require [root] → the origin's owner/repo in $TEAM_GH_ORIGIN.
# The ONE parser of the origin URL, shared with `team-pr.sh coords`: if these two disagree, a team
# clones, runs, and only at PR time finds out its origin is not the repo the profile names. Globals,
# not stdout: `$(…)` would run team_profile_die in a subshell and the caller would sail on.
TEAM_GH_ORIGIN=""
team_gh_origin_require() {
  local root="${1:-}" url o
  if [ -n "$root" ]; then url="$(git -C "$root" remote get-url origin 2>/dev/null || true)"
  else url="$(git remote get-url origin 2>/dev/null || true)"; fi
  url="${url%.git}"
  case "$url" in
    https://github.com/*)   o="${url#https://github.com/}" ;;
    https://*@github.com/*) o="${url#*@github.com/}" ;;
    git@github.com:*)       o="${url#git@github.com:}" ;;
    ssh://git@github.com/*) o="${url#ssh://git@github.com/}" ;;
    *) team_profile_die "origin is not a github.com repo" ;;
  esac
  [[ "$o" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
    || team_profile_die "origin is not a github.com repo"
  [ "$o" = "$TEAM_GH_REPO" ] \
    || team_profile_die "origin $o is not teams.github.repo $TEAM_GH_REPO"
  TEAM_GH_ORIGIN="$o"
}

# Refuses a profile with no merge path at all — before any side effect.
team_profile_require_supported() {
  [ -n "${TEAM_PROFILE_LOADED:-}" ] || team_profile_load
  # Every tracker runs (jira via MCP, github/none via team-tracker.sh) and both PR providers run
  # (azure-devops via the team-lib.sh helpers, github via team-pr.sh). `none` is a valid profile —
  # the PR layer is off (setup, channel, kit and supervision work) — but every caller of this
  # check publishes or merges a PR, so it is refused here, not halfway through a run.
  case "$TEAM_PR_PROVIDER" in
    azure-devops) ;;
    # Checked HERE, before the clone: a profile pointing at another repo would open the team's PRs
    # somewhere else, and finding that out after the clone/tmux/team.json is already a mess.
    github) team_gh_origin_require ;;
    none) team_profile_die "teams.pr_provider=none: the PR layer is off — team runs, PRs and merges need github or azure-devops" ;;
  esac
}

# Usage: team_clone_glob [root] — the `<parent>/<prefix>` every clone path starts with, where
# <prefix> is `teams.clone_name` minus its trailing {team}/{Team} placeholder.
# The caller appends the glob itself: `for d in "$(team_clone_glob "$root")"*/…`.
team_clone_glob() {
  local root parent prefix
  root="${1:-$(git rev-parse --show-toplevel)}"
  team_profile_load "$root"
  if [ -n "${TEAM_CLONE_PARENT:-}" ]; then
    parent="$TEAM_CLONE_PARENT"
  else
    parent="$(dirname "$root")"
  fi
  prefix="${TEAM_CLONE_NAME%\{team\}}"
  prefix="${prefix%\{Team\}}"
  printf '%s' "$parent/$prefix"
}

# Usage: team_clone_dir <team> [root] — the single source of truth for a clone's path.
# A separate, checked assignment: `printf "%s" "$(team_clone_glob …)$team"` would mask the
# resolver's exit status and hand the caller the bare team name as a path.
team_clone_dir() {
  local team="$1" root prefix
  root="${2:-$(git rev-parse --show-toplevel)}"
  # In THIS shell, not only inside the `$(…)` below: the template is read here, and a load that
  # happened in the subshell would leave TEAM_CLONE_NAME unset in the caller (`set -u`).
  team_profile_load "$root"
  prefix="$(team_clone_glob "$root")" || return $?
  [ -n "$prefix" ] || { echo "error: clone path unresolved — no teams profile" >&2; return 2; }
  # `{Team}` capitalizes the first letter — Bash 3.2 has no `${t^}`.
  case "$TEAM_CLONE_NAME" in
    *'{Team}') team="$(printf '%s' "${team%"${team#?}"}" | tr '[:lower:]' '[:upper:]')${team#?}" ;;
  esac
  printf '%s\n' "$prefix$team"
}

# Usage: team_base_ref [root] — the line every new team branch is cut from.
team_base_ref() {
  team_profile_load "${1:-$(git rev-parse --show-toplevel)}"
  printf '%s\n' "origin/$TEAM_TRUNK"
}

# Usage: team_gate_sentence — the test-gate step as a prompt/report sentence, already quoted.
team_gate_sentence() {
  [ -n "${TEAM_PROFILE_LOADED:-}" ] || team_profile_load
  if [ "$TEAM_TEST_GATE" = none ]; then
    printf '%s' "test gate: none — skip"
  else
    # %q, not "%s": double quotes still expand $(…), backticks and $VAR inside the path. The
    # wrapper queues the run behind the machine gate lock; the project gate follows as a comment.
    printf 'bash .claude/lib/test-gate.sh  # runs bash %q under the machine gate lock' \
      "$TEAM_TEST_GATE"
  fi
}
