#!/usr/bin/env bash
# Project values for the team harness, read from `.claude/project-profile.json` → `teams`.
# Sourced, never executed; the caller sets `set -euo pipefail`.
# Bash 3.2 compatible (macOS /bin/bash): no mapfile, no associative arrays.
#
# The profile carries VALUES only (tracker, trunk, tools, gates, clone parent). Provider BEHAVIOUR
# (Azure DevOps, Jira) is unchanged — `team_profile_require_supported` refuses anything this stage
# cannot run, and it must be called before the first side effect (clone, tmux, team.json).
#
# Values are read with `jq -r` only: the profile is never `eval`ed or sourced.

team_profile_die() { echo "error: $*" >&2; exit 2; }

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
    *) team_profile_die "teams.tracker=${TEAM_TRACKER:-<missing>} must be jira|github" ;;
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

  TEAM_PROFILE_LOADED=1
}

# Refuses what this stage (2a) cannot run — before any side effect.
team_profile_require_supported() {
  [ -n "${TEAM_PROFILE_LOADED:-}" ] || team_profile_load
  [ "$TEAM_TRACKER" = jira ] \
    || team_profile_die "tracker=$TEAM_TRACKER unsupported in 2a"
  [ "$TEAM_PR_PROVIDER" = azure-devops ] \
    || team_profile_die "pr_provider=$TEAM_PR_PROVIDER unsupported in 2a"
}

# Usage: team_clone_glob [root] — the `<parent>/<repo>-` prefix every clone path starts with.
# The caller appends the glob itself: `for d in "$(team_clone_glob "$root")"*/…`.
team_clone_glob() {
  local root
  root="${1:-$(git rev-parse --show-toplevel)}"
  team_profile_load "$root"
  if [ -n "${TEAM_CLONE_PARENT:-}" ]; then
    printf '%s' "$TEAM_CLONE_PARENT/$(basename "$root")-"
  else
    printf '%s' "$(dirname "$root")/$(basename "$root")-"
  fi
}

# Usage: team_clone_dir <team> [root] — the single source of truth for a clone's path.
# A separate, checked assignment: `printf "%s" "$(team_clone_glob …)$team"` would mask the
# resolver's exit status and hand the caller the bare team name as a path.
team_clone_dir() {
  local team="$1" root prefix
  root="${2:-$(git rev-parse --show-toplevel)}"
  prefix="$(team_clone_glob "$root")" || return $?
  [ -n "$prefix" ] || { echo "error: clone path unresolved — no teams profile" >&2; return 2; }
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
    # %q, not "%s": double quotes still expand $(…), backticks and $VAR inside the path.
    printf 'bash %q' "$TEAM_TEST_GATE"
  fi
}
