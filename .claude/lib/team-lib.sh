#!/usr/bin/env bash
# Shared functions for the team pipeline scripts and the dashboard.
# Sourced, never executed; the caller sets `set -euo pipefail`. Contract: .agents/reference/team-mode.md
# Bash 3.2 compatible (macOS /bin/bash): no mapfile, no associative arrays.

# Project values (trunk, tools, clone parent, gates) live in the profile, not here.
# BASH_SOURCE, not $0: the dashboard and the smoke suites source this file from another directory.
. "$(dirname "${BASH_SOURCE[0]}")/team-profile.sh"
# The session-host driver: every tmux call goes through it (the wrappers below keep their names).
[ -n "${SH_LIB:-}" ] || . "$(dirname "${BASH_SOURCE[0]}")/session-host-lib.sh"
. "$(dirname "${BASH_SOURCE[0]}")/team-seed-lib.sh"   # team_seed_files, team_seed_checks

TEAM_ROLES="planner coder qa wrapup"

team_root() {
  git rev-parse --show-toplevel
}

team_dir() {
  echo "$(team_root)/.agents/team"
}

team_json() {
  local f
  f="$(team_dir)/team.json"
  [ -f "$f" ] || { echo "error: $f missing — not a team clone" >&2; return 1; }
  jq -r --arg f "$1" '.[$f] // empty' "$f"
}

session_json() {
  local f
  f="$(team_dir)/session.json"
  [ -f "$f" ] || { echo "error: $f missing — not in team mode" >&2; return 1; }
  jq -r --arg f "$1" '.[$f] // empty' "$f"
}

team_check_name() {
  [[ "$1" =~ ^[a-z0-9-]+$ ]] || { echo "error: name '$1' must match [a-z0-9-]+" >&2; return 1; }
}

# team_tab_clash <team> <main> → prints the roles tab and returns 0 when the team's Herdr tab (named
# after the team) would be a roles tab: Lead, or any teams.sessions place.tab, case-insensitive.
team_tab_clash() {
  local n t
  n="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  for t in Lead $(jq -r '.teams.sessions // {} | .[]? | .place.tab? // empty | strings' \
    "$2/.claude/project-profile.json" 2>/dev/null); do
    [ "$n" != "$(printf '%s' "$t" | tr '[:upper:]' '[:lower:]')" ] || { echo "$t"; return 0; }
  done
  return 1
}

team_cancelled() {
  [ -e "$(team_dir)/cancel" ]
}

# Same four origin forms as /pr-create Step 2; az auto-detection fails on the _git/<repo> form.
team_ado_coords() {
  local url org project repo
  local re_full='^https://([^@/]+@)?dev\.azure\.com/([^/]+)/([^/]+)/_git/([^/]+)$'
  local re_short='^https://([^@/]+@)?dev\.azure\.com/([^/]+)/_git/([^/]+)$'
  local re_ssh='^git@ssh\.dev\.azure\.com:v3/([^/]+)/([^/]+)/([^/]+)$'
  local re_vs='^https://([^@/]+@)?([^./]+)\.visualstudio\.com/(DefaultCollection/)?([^/]+)/_git/([^/]+)$'
  url="$(git -C "$(team_root)" remote get-url origin)" || return 1
  url="${url%.git}"
  if [[ "$url" =~ $re_full ]]; then
    org="${BASH_REMATCH[2]}"; project="${BASH_REMATCH[3]}"; repo="${BASH_REMATCH[4]}"
  elif [[ "$url" =~ $re_short ]]; then
    org="${BASH_REMATCH[2]}"; repo="${BASH_REMATCH[3]}"; project="$repo"
  elif [[ "$url" =~ $re_ssh ]]; then
    org="${BASH_REMATCH[1]}"; project="${BASH_REMATCH[2]}"; repo="${BASH_REMATCH[3]}"
  elif [[ "$url" =~ $re_vs ]]; then
    org="${BASH_REMATCH[2]}"; project="${BASH_REMATCH[4]}"; repo="${BASH_REMATCH[5]}"
  else
    echo "error: origin is not an Azure DevOps repo" >&2
    return 1
  fi
  ADO_ORG_URL="https://dev.azure.com/$org"
  ADO_PROJECT="${project//%20/ }"
  ADO_REPO="${repo//%20/ }"
}

team_pr_json() {
  az repos pr show --org "$ADO_ORG_URL" --id "$1" -o json
}

# Usage: team_pr_identity <pr-json> <branch> <line> — needs team_ado_coords first.
team_pr_identity() {
  jq -e --arg repo "$ADO_REPO" --arg src "refs/heads/$2" --arg tgt "refs/heads/$3" \
    '.status == "active" and .repository.name == $repo
     and .sourceRefName == $src and .targetRefName == $tgt' <<<"$1" >/dev/null
}

team_accepted_record() {
  local f
  f="$(ls -1 "$(team_dir)/runs/$1/$2"-*.json.accepted 2>/dev/null | tail -n 1)" || true
  [ -z "$f" ] || echo "${f%.accepted}"
}

# team_run_ref <team dir> <run> → <run>, or <run>/r<n> in rework round n ≥ 2 (<team dir>/round).
team_run_ref() {
  local n; n="$(jq -r --arg r "$2" 'select(.run == $r) | .round' "$1/round" 2>/dev/null)" || n=""
  if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -gt 1 ]; then echo "$2/r$n"; else echo "$2"; fi
}

# team_tmux_name <team> <role> → the ADDRESS <team>-<role>; only the driver knows tmux names (sh_name).
team_tmux_name() { echo "$1-$2"; }
# team_sess <address> → the live session name (sh_target): the main checkout from HARNESS_MAIN, else
# this checkout — a clone shares the committed teams profile, so the same prefix.
team_sess() {
  local m; m="$(sh_main_root 2>/dev/null)" || m="$(git rev-parse --show-toplevel 2>/dev/null)" || return 1
  sh_target "$m" "$1"
}

# Session wrappers by address, over the driver (the record's backend: tmux or herdr). Non-zero =
# gone or the probe failed, as before.
team_main() { sh_main_root 2>/dev/null || git rev-parse --show-toplevel 2>/dev/null; }
team_tmux_alive() {
  local m n; m="$(team_main)" || return 1
  case "$(sh_record_get "$m" "$1" backend)" in
    herdr|none) sh_alive_addr "$m" "$1" 2>/dev/null ;;
    *) n="$(team_sess "$1")" || return 1
       sh_tmux has-session -t "=$n" 2>/dev/null ;;   # in this shell, not a $(…): the caller stays tmux's parent
  esac
}

# Last non-empty lines of a session's screen; empty when the session is gone.
team_pane() {
  local m; m="$(team_main)" || return 0
  sh_read_addr "$m" "$1" "${2:-15}" 2>/dev/null || true
}

# Screen plus scrollback, wrapped lines joined: a long command's start scrolls off the visible pane.
team_pane_history() {
  local m; m="$(team_main)" || return 0
  sh_read_addr "$m" "$1" --history "${2:-200}" 2>/dev/null || true
}

# stdin → stdout with labelled secret values masked. Pattern-based: the floor for signals, not a
# guarantee — an unlabelled bare token passes.
team_redact() {
  perl -pe '
    s/\b(password|passwd|pwd|secret|token|apikey|api_key|accountkey|sharedaccesskey|sig
        |connectionstring|client_secret)(\s*[=:]\s*)("[^"]*"|\x27[^\x27]*\x27|[^\s;&"\x27]+)
      /$1$2***/gix;
    s/(--(?:password|secret|token|sas-token|connection-string|account-key))([ =])
      ("[^"]*"|\x27[^\x27]*\x27|\S+)/$1$2***/gix;
    s/\b(Bearer\s+)\S+/$1***/gi;'
}

# team_pane_anchor <session> → the line naming the open question: the last one ending in `?`, else
# the line after `Bash command`, else the last non-empty line; trimmed, redacted, ≤ 160 chars.
team_pane_anchor() {
  local pane a
  pane="$(team_pane "$1" 25)"
  a="$(grep -E '\?[[:space:]]*$' <<<"$pane" | tail -n 1)" || true
  [ -n "$a" ] || a="$(awk 'f {print; exit} /Bash command/ {f = 1}' <<<"$pane")" || true
  [ -n "$a" ] || a="$(tail -n 1 <<<"$pane")"
  a="$(sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' <<<"$a" | team_redact)"
  printf '%s' "${a:0:160}"
}

# Usage: team_pane_scroll <pane id|herdr handle> [lines] — the screen plus scrollback (a long
# command's start scrolls off the visible pane), empty lines dropped. The parser reads this capture.
team_pane_scroll() {
  sh_read_target "$1" --history "${2:-200}" --squeeze 2>/dev/null || true
}

# Usage: team_pane_gen <address> → "<pane_id>@<session_created>" (tmux) or "<handle>@<created_ms>"
# (herdr); a replaced session is a new value. The part before @ is the target team_pane_scroll takes.
team_pane_gen() {
  local m; m="$(team_main)" || return 1
  sh_gen_addr "$m" "$1" 2>/dev/null
}

# Usage: team_role_transcript <clone> <session_id> [config dir] → the role's Claude transcript path,
# or "-". Pass the session's recorded `claude_config_dir`: the launcher chose it, not this process.
team_role_transcript() {
  case "${2:--}" in -) echo - ;;
    *) echo "${3:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}/projects/$(team_project_slug "$1")/$2.jsonl" ;;
  esac
}

TEAM_CLASSES="merge-line allow-offline add-ask prod-diagnose"

# Usage: team_class_on <main root> <class> — the class is enabled in the committed profile
# (teams.policy.classes.<class with _>.enabled == true; prod-diagnose also names dir + privileged)
# AND its runtime switch is not off (absent state file/key = on, unreadable = off). Same predicate as
# team_prompt_classes.py class_on.
team_class_on() {
  local f="$1/.agents/team/watch/state.json" v
  jq -e --arg k "${2//-/_}" '.teams.policy.classes[$k] | type == "object" and .enabled == true
    and ($k != "prod_diagnose" or ((.dir | type) == "string" and (.privileged | type) == "string"))' \
    "$1/.claude/project-profile.json" >/dev/null 2>&1 || return 1
  [ -e "$f" ] || return 0
  [ -f "$f" ] || return 1
  # Not `// "on"`: that reads an explicit false/null as missing.
  v="$(jq -r --arg n "$2" 'if type != "object" then "off"
    elif has("classes") | not then "on"
    elif (.classes | type) != "object" then "off"
    elif (.classes | has($n)) | not then "on"
    elif .classes[$n] == "on" then "on" else "off" end' "$f" 2>/dev/null)" || return 1
  [ "$v" = on ]
}

# One regex for team-answer and the dashboard: they must agree on "prompt open".
team_prompt_open() {
  team_pane "$1" 25 | grep -Eq 'Do you want to (proceed|make this edit|create|allow)|❯ *1\. Yes'
}

# Usage: team_clone_dissociated <root> <dir> — a self-contained clone of <root>'s origin that
# still borrows <root>'s objects for the transfer (real origin URL: a local-path clone would need
# `git remote set-url`, which is denied).
#
# `-c core.commitGraph=false` is load-bearing. With the alternate attached, git reads the SOURCE
# repo's commit-graph; when that is an incremental chain (.git/objects/info/commit-graphs/, Apple
# git 2.54.0) the clone dies with `fatal: unable to parse commit <sha>` and leaves the checkout
# empty — reproducible on any repo after `git commit-graph write --reachable --split`. Disabling
# the graph for this one process makes git parse the objects themselves; nothing is written to the
# new repo's config, and --dissociate still leaves no objects/info/alternates behind.
team_clone_dissociated() {
  git -c core.commitGraph=false clone --quiet --reference-if-able "$1" --dissociate \
    "$(git -C "$1" remote get-url origin)" "$2"
}

# An AskUserQuestion menu (also a Yes/No one, which team_prompt_open matches too).
team_menu_open() {
  team_pane "$1" 40 | grep -qF 'Enter to select'
}

# Usage: team_clone_dirs <main root> — prints each clone's .agents/team dir that has team.json.
team_clone_dirs() {
  local d prefix
  prefix="$(team_clone_glob "$1")" || return $?
  for d in "$prefix"*/.agents/team; do
    [ ! -f "$d/team.json" ] || echo "$d"
  done
}

# Claude Code keeps transcripts under the repo path with every non-alphanumeric char → '-'.
team_project_slug() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }
team_claude_project_dir() {
  local cfg
  cfg="$(team_claude_home "$1")" || cfg="${CLAUDE_CONFIG_DIR:-}"
  cfg="${cfg:-$HOME/.claude}"
  echo "${TEAM_DASH_PROJECT_DIR:-$cfg/projects/$(team_project_slug "$1")}"
}

# team_non_memory_files <from> <to> → changed paths outside .agents/memory/ and docs/coding-standards.md
# (check_wrapup_standards judges that one); rc 1 if the diff failed.
# --no-renames: a move from code into memory must list the deleted source path too.
team_non_memory_files() {
  local d
  d="$(git diff --no-renames --name-only "$1" "$2")" || return 1
  printf '%s\n' "$d" | grep -v -e '^\.agents/memory/' -e '^docs/coding-standards\.md$' -e '^$' || true
}

# team_blob_tmp <rev> <path> → a temp file holding the blob, or "-" when the path is absent there
# (the caller removes the file).
team_blob_tmp() {
  local t
  t="$(mktemp)" || return 1
  if git show "$1:$2" > "$t" 2>/dev/null; then echo "$t"; else rm -f "$t"; echo -; fi
}

# team_lead_accepts <run dir> → JSON array of every accepted item in the run's teamlead-wrapup
# verdicts ([] when there is none).
team_lead_accepts() {
  local a
  a="$(cat "$1"/teamlead-wrapup-*.json 2>/dev/null \
    | jq -s '[.[].items // [] | .[] | select(.decision == "accept")]' 2>/dev/null)" || a=""
  printf '%s\n' "${a:-[]}"
}

team_records() {
  local d
  d="$(team_dir)/runs/$1"
  [ -d "$d" ] || return 0
  ( cd "$d" && ls -1 -- "$2-$3-"*.json 2>/dev/null | sort -t- -k3 -n | sed "s|^|$d/|" ) || true
}

# team_newest_record <team dir> <run> <role> <attempt> → basename of the newest record, or empty.
# The sender runs outside the clone, so the team dir is explicit, not team_dir().
team_newest_record() {
  local d="$1/runs/$2"
  ( cd "$d" 2>/dev/null && ls -1 -- "$3-$4-"*.json 2>/dev/null | sort -t- -k3 -n | tail -n 1 ) \
    || true
}

team_next_seq() {
  local last
  last="$(team_records "$1" "$2" "$3" | tail -n 1)"
  [ -n "$last" ] || { echo 1; return; }
  last="$(basename "$last" .json)"
  echo $(( ${last##*-} + 1 ))
}

team_notes_init() {
  local f
  f="$(team_dir)/runs/$1/notes.md"
  mkdir -p "$(dirname "$f")"
  [ -f "$f" ] || printf '## Unattended decisions\n\n## Learnings\n\n## Follow-ups\n\n## Blockers\n' > "$f"
  echo "$f"
}

team_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Ticket preflight shared by team-new and team-next; appends to TEAM_PROBLEMS, never exits.
team_ticket_checks() {
  local root="$1" key="$2" branch="$3" base="$4" own="${5:-}" tool other rc types_re clone_prefix
  team_profile_load "$root"
  types_re="$(printf '%s|' "${TEAM_BRANCH_TYPES[@]}")"; types_re="${types_re%|}"
  local branch_re="^(${types_re})/${key}-[a-z0-9-]+\$"
  for tool in "${TEAM_REQUIRED_TOOLS[@]}"; do
    command -v "$tool" >/dev/null 2>&1 || TEAM_PROBLEMS+=("$tool not on PATH (tmux/jq: brew install tmux jq)")
  done
  # A session host (tmux, or Herdr when chosen): the driver's resolution, not a fixed tool name.
  local host; host="$(sh_check_host --main "$root" 2>/dev/null)" || TEAM_PROBLEMS+=("${host:-no session host: install tmux or Herdr}")
  if [ "$TEAM_PR_PROVIDER" = azure-devops ] \
    && command -v az >/dev/null 2>&1 && ! az account show >/dev/null 2>&1; then
    TEAM_PROBLEMS+=("az is not logged in — run: az login")
  fi
  # `gh` is checked regardless of required_tools: with pr_provider=github the PR layer cannot run
  # without it, and a profile that merely forgot to list the tool would fail inside the clone.
  if [ "$TEAM_PR_PROVIDER" = github ]; then
    if ! command -v gh >/dev/null 2>&1; then
      TEAM_PROBLEMS+=("gh not on PATH — required for pr_provider=github")
    elif ! gh auth status >/dev/null 2>&1; then
      TEAM_PROBLEMS+=("gh is not logged in — run: gh auth login")
    fi
  fi
  [[ "$key" =~ $TEAM_KEY_REGEX ]] || TEAM_PROBLEMS+=("ticket key '$key' must match $TEAM_KEY_REGEX")
  [[ "$branch" =~ $branch_re ]] \
    || TEAM_PROBLEMS+=("branch '$branch' must be <type>/$key-<slug> (types: ${TEAM_BRANCH_TYPES[*]})")
  # The clone resolves base afresh and team.json `line` (the PR target) is base minus `origin/`.
  [[ "$base" =~ ^origin/[A-Za-z0-9._/-]+$ ]] || TEAM_PROBLEMS+=("base-ref '$base' must be origin/<branch>")
  if [ "$TEAM_ENV_REQUIRED" = true ]; then
    if [ ! -f "$root/.env" ]; then
      TEAM_PROBLEMS+=("$root/.env missing")
    elif [ "$(stat -f %Lp "$root/.env")" != 600 ]; then
      TEAM_PROBLEMS+=(".env is not mode 600 — run: chmod 600 .env")
    fi
  fi
  clone_prefix="$(team_clone_glob "$root")"
  for other in "$clone_prefix"*/.agents/team/team.json; do
    [ -f "$other" ] && [ "$(jq -r .team "$other")" != "$own" ] || continue
    [ "$(jq -r .branch "$other")" != "$branch" ] \
      || TEAM_PROBLEMS+=("branch $branch is already used by team $(jq -r .team "$other")")
  done
  if ! git -C "$root" fetch --quiet origin; then
    TEAM_PROBLEMS+=("git fetch origin failed"); return 0
  fi
  set +e
  git -C "$root" ls-remote --exit-code origin "refs/heads/$branch" >/dev/null 2>&1; rc=$?
  set -e
  [ "$rc" = 2 ] || TEAM_PROBLEMS+=("branch $branch already exists on origin (or ls-remote failed, rc=$rc)")
  if ! git -C "$root" rev-parse --verify --quiet "$base^{commit}" >/dev/null; then
    TEAM_PROBLEMS+=("base-ref $base does not resolve")
  elif ! git -C "$root" cat-file -e "$base:.claude/lib/team-record.sh" 2>/dev/null; then
    TEAM_PROBLEMS+=("base has no team harness — only $TEAM_TRUNK and lines carrying .claude/ are supported")
  elif [ "$TEAM_TRACKER" != jira ]; then
    team_base_tracker_check "$root" "$base"
  fi
  # A SEPARATE check, not another `elif`: the PR layer is orthogonal to the tracker, and the live
  # github rig runs tracker=none (which never reaches the branch above).
  if git -C "$root" cat-file -e "$base:.claude/lib/team-record.sh" 2>/dev/null \
    && [ "$TEAM_PR_PROVIDER" = github ]; then
    team_base_pr_check "$root" "$base"
  fi
}

# The clone runs the harness of its BASE, so the base must carry the adapter, the wrapup block and
# the same tracker in its COMMITTED profile — the supervisor's working tree does not travel. For
# github the whole effective github block (`TEAM_GH_BLOCK`: `teams.github`, else the top-level
# `github`) must match too: a different project/repo would send
# `started` and `delivered` to another board. jira keeps the legacy fallback (no block, no adapter).
team_base_tracker_check() {
  local root="$1" base="$2" t="$TEAM_TRACKER" bad="" p
  for p in ".claude/lib/team-tracker.sh" ".claude/team/tracker/$t-wrapup.md"; do
    git -C "$root" cat-file -e "$base:$p" 2>/dev/null || bad=1
  done
  [ "$(git -C "$root" show "$base:.claude/project-profile.json" 2>/dev/null \
    | jq -r '.teams.tracker // empty' 2>/dev/null || true)" = "$t" ] || bad=1
  if [ -z "$bad" ] && [ "$t" = github ]; then
    [ "$(git -C "$root" show "$base:.claude/project-profile.json" 2>/dev/null \
      | jq -S -c "$TEAM_GH_BLOCK" 2>/dev/null || true)" \
      = "$(jq -S -c "$TEAM_GH_BLOCK" "$root/.claude/project-profile.json")" ] || bad=1
  fi
  [ -z "$bad" ] || TEAM_PROBLEMS+=("base $base cannot run tracker=$t \
— tracker adapter/profile missing or different on the base")
}

# Same reasoning as the tracker check, for the PR layer: the clone runs the harness of its BASE, so
# the base must carry the adapter, the github prompt blocks and the same `pr_provider`/repo in its
# COMMITTED profile. `team-pr-render.sh` is deliberately NOT required — the runner loads it from
# `$root` (the main checkout), like team-tracker-render.sh.
team_base_pr_check() {
  local root="$1" base="$2" bad="" p prof
  for p in ".claude/lib/team-pr.sh" ".claude/team/pr/github-create.md"; do
    git -C "$root" cat-file -e "$base:$p" 2>/dev/null || bad=1
  done
  prof="$(git -C "$root" show "$base:.claude/project-profile.json" 2>/dev/null || true)"
  [ "$(printf '%s' "$prof" | jq -r '.teams.pr_provider // empty' 2>/dev/null || true)" = github ] \
    || bad=1
  [ "$(printf '%s' "$prof" | jq -r "$TEAM_GH_BLOCK.repo // empty" 2>/dev/null || true)" \
    = "$TEAM_GH_REPO" ] || bad=1
  [ -z "$bad" ] || TEAM_PROBLEMS+=("base $base cannot run pr_provider=github \
— PR layer/profile missing or different on the base")
}

# Usage: team_write_json <dir> <team> <key> <branch> <base> [mode] [root]
# `cost_key` is the qualified key cost records bind to; `ticket` stays the short one.
team_write_json() {
  local dir="$1" team="$2" key="$3" branch="$4" base="$5" root="${7:-$(git rev-parse --show-toplevel)}"
  mkdir -p "$dir/.agents/team"
  jq -n --arg team "$team" --arg ticket "$key" --arg branch "$branch" --arg line "${base#origin/}" \
    --arg base_ref "$base" --arg base_sha "$(git -C "$dir" rev-parse HEAD)" \
    --arg origin_url "$(git -C "$dir" remote get-url origin)" \
    --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg mode "${6:-brainstorm}" \
    --arg tracker "$TEAM_TRACKER" --arg cost_key "$(team_cost_key "$root" "$key")" \
    '{team: $team, ticket: $ticket, branch: $branch, line: $line, base_ref: $base_ref,
      base_sha: $base_sha, mode: $mode, tracker: $tracker, cost_key: $cost_key,
      origin_url: $origin_url, created_at: $created_at}' \
    > "$dir/.agents/team/team.json"
}

# Usage: team_copy_ticket <ticket.json> <clone dir> — the ticket the supervisor read, into the clone.
team_copy_ticket() {
  local file="$1" dir="$2" src
  src="$(dirname "$file")"
  mkdir -p "$dir/.agents/team"
  cp "$file" "$dir/.agents/team/ticket.json"
  cp "$src/ticket.md" "$dir/.agents/team/ticket.md"
}

# Stock macOS has no `timeout`; the child gets its own process group so az and its children die too.
# A child killed by a signal exits 128+signal like a shell would, never 0: `$? >> 8` alone made a
# killed `claude -p` read as a finished retro. The one copy: tw_timebox (team-watch-lib) calls it.
pr_timebox() {  # pr_timebox <secs> <cmd...> → exit 124 on timeout, 128+n when killed by signal n
  perl -e '$t = shift; $p = fork // exit 1;
    if (!$p) { setpgrp(0, 0); exec @ARGV or exit 127 }
    $SIG{ALRM} = sub { kill "KILL", -$p; waitpid $p, 0; exit 124 };
    alarm $t; waitpid $p, 0; exit($? & 127 ? 128 + ($? & 127) : $? >> 8)' "$@"
}
