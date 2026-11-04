#!/usr/bin/env bash
# Shared functions for the team pipeline scripts and the dashboard.
# Sourced, never executed; the caller sets `set -euo pipefail`. Contract: .agents/reference/team-mode.md
# Bash 3.2 compatible (macOS /bin/bash): no mapfile, no associative arrays.

# Project values (trunk, tools, clone parent, gates) live in the profile, not here.
# BASH_SOURCE, not $0: the dashboard and the smoke suites source this file from another directory.
. "$(dirname "${BASH_SOURCE[0]}")/team-profile.sh"

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

team_tmux_name() {
  echo "$1-$2"
}

# `=NAME` is an exact match; a plain target prefix-matches (`alfa` would hit `alfa-coder`).
# Pane commands (capture-pane, send-keys) need `=NAME:` — tmux 3.7 finds no pane for `=NAME`.
team_tmux_alive() {
  tmux has-session -t "=$1" 2>/dev/null
}

# Last non-empty lines of a session's pane; empty when the session is gone.
team_pane() {
  tmux capture-pane -p -t "=$1:" 2>/dev/null | sed '/^[[:space:]]*$/d' | tail -n "${2:-15}" || true
}

# Pane plus scrollback, wrapped lines joined: a long command's start scrolls off the visible pane.
team_pane_history() {
  tmux capture-pane -p -J -S -"${2:-200}" -t "=$1:" 2>/dev/null || true
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

# Usage: team_pane_scroll <pane id> [lines] — the pane plus scrollback (a long command's
# start scrolls off the visible pane), empty lines dropped. The parser reads this capture.
team_pane_scroll() {
  tmux capture-pane -p -J -S -"${2:-200}" -t "$1" 2>/dev/null | sed '/^[[:space:]]*$/d' || true
}

# Usage: team_pane_gen <session> → "<pane_id>@<session_created>"; a replaced session is a new value.
team_pane_gen() {
  local g
  g="$(tmux display-message -p -t "=$1:" '#{pane_id}@#{session_created}' 2>/dev/null)" || return 1
  [ -n "$g" ] || return 1
  echo "$g"
}

# Usage: team_role_transcript <clone> <session_id> → the role's Claude transcript path, or "-".
team_role_transcript() {
  case "${2:--}" in -) echo - ;;
    *) echo "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$(team_project_slug "$1")/$2.jsonl" ;;
  esac
}

# Usage: team_mode_ok <main root> <tier> <send> — the shared tiers/answering state of the main
# checkout (team-watch.sh mode); absent or unreadable = both on. Prints the refusal, rc 1.
team_mode_ok() {
  local mode
  mode="$(jq -r '"\(.tiers // "on") \(.answering // "on")"' \
    "$1/.agents/team/watch/state.json" 2>/dev/null)" || mode="on on"
  case "$mode" in
    *" off") [ "$2" = 3 ] && [ "$3" = none ] || { echo "answering off"; return 1; } ;;
  esac
  case "$mode" in
    "off "*) [ "$2" = 3 ] || { echo "tiers off"; return 1; } ;;
  esac
}

TEAM_CLASSES="merge-line allow-offline add-ask prod-diagnose"

# Usage: team_class_on <main root> <class> — class switch; absent file/key = on, unreadable = off.
team_class_on() {
  local f="$1/.agents/team/watch/state.json" v
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
  local cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  echo "${TEAM_DASH_PROJECT_DIR:-$cfg/projects/$(team_project_slug "$1")}"
}

# team_non_memory_files <from> <to> → changed paths outside .agents/memory/; rc 1 if the diff failed.
# --no-renames: a move from code into memory must list the deleted source path too.
team_non_memory_files() {
  local d
  d="$(git diff --no-renames --name-only "$1" "$2")" || return 1
  printf '%s\n' "$d" | grep -v -e '^\.agents/memory/' -e '^$' || true
}

# Usage: team_dash_session <main root> — TEAM_DASH_SESSION, else the newest transcript id.
# Set-but-empty is a pin too: serve.sh found no transcript, so the page must not follow a later one.
team_dash_session() {
  local s="${TEAM_DASH_SESSION-}"
  if [ -z "${TEAM_DASH_SESSION+x}" ]; then
    s="$(ls -1t "$(team_claude_project_dir "$1")"/*.jsonl 2>/dev/null | head -n 1)" || true
    [ -z "$s" ] || s="$(basename "$s" .jsonl)"
  fi
  echo "$s"
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

# Usage: team_q_lock <q file> <team> — the question ledger's lock (team-question, team-escalate).
team_q_lock() {
  local q="$1" id tries=0 max p hint=""
  max=$(( ${TEAM_QUESTION_LOCK_SECS:-30} * 5 ))
  until mkdir "$q.lock" 2>/dev/null; do
    if [ "$tries" -ge "$max" ]; then
      p="$(cat "$q.lock/pid" 2>/dev/null || echo none)"; id="$(basename "$q" .md)"; id="${id#.}"
      kill -0 "$p" 2>/dev/null || hint=" — stale: team-question.sh $2 unlock $id"
      echo "error: $id busy (lock held by pid $p)$hint" >&2
      return 1
    fi
    sleep 0.2; tries=$((tries + 1))
  done
  echo $$ > "$q.lock/pid"
}

# Usage: team_q_state <q file> → "<state>\t<tier>\t<author>"
# Reads the last ## Answer / ## Revoked plus any ## Escalation; once Advisor reported the Operator
# asked (`waiting:`), only a final outcome leaves waiting-operator. Answer states:
# consumed|sent|not-sent-stale|not-sent|unknown|failed|pending|recorded — an unknown
# `delivery:` value reads `unknown`, never `sent`.
team_q_state() {
  awk '
    /^## /     { sec = substr($0, 4)
                 if (sec == "Answer") { h = "answer"; tier = ""; author = ""; dl = ""; cf = 0 }
                 if (sec == "Revoked") { h = "revoked"; dl = "" }
                 next }
    sec == "Answer" && /^tier: /   { tier = substr($0, 7) }
    sec == "Answer" && /^author: / { author = substr($0, 9) }
    sec == "Answer" && /^confirmed: yes/ { cf = 1 }
    (sec == "Answer" || sec == "Revoked") && /^delivery: / { dl = substr($0, 11) }
    sec == "Escalation" && /^(started|reping|retier|resumed): / {
      esc = asked ? "waiting-operator" : "escalating"; next }
    sec == "Escalation" && /^waiting: / { asked = 1; esc = "waiting-operator"; next }
    sec == "Escalation" && /^outcome: (answer|withdrawn)$/ { asked = 0; esc = "escalated"; next }
    sec == "Escalation" && /^outcome: / { esc = asked ? "waiting-operator" : "escalated" }
    END {
      if (h == "revoked") st = "revoked"
      else if (h == "answer") st = (dl == "pending") ? "pending" : (dl == "sent") \
        ? (cf ? "consumed" : "sent") : (dl ~ /^not sent — stale/) ? "not-sent-stale" \
        : (dl ~ /^not sent — /) ? "not-sent" : (dl ~ /^unknown — /) ? "unknown" \
        : (dl ~ /^failed/) ? "failed" : (dl == "recorded only") ? "recorded" : "unknown"
      else st = (esc != "") ? esc : "open"
      printf "%s\t%s\t%s\n", st, (tier == "" ? "-" : tier), (author == "" ? "-" : author)
    }' "$1"
}

# Ticket preflight shared by team-new and team-next; appends to TEAM_PROBLEMS, never exits.
team_ticket_checks() {
  local root="$1" key="$2" branch="$3" base="$4" own="${5:-}" tool other rc types_re clone_prefix
  team_profile_load "$root"
  types_re="$(printf '%s|' "${TEAM_BRANCH_TYPES[@]}")"; types_re="${types_re%|}"
  local branch_re="^(${types_re})/${key}-[a-z0-9-]+\$"
  for tool in "${TEAM_REQUIRED_TOOLS[@]}"; do
    command -v "$tool" >/dev/null 2>&1 || TEAM_PROBLEMS+=("$tool not on PATH (tmux/jq: brew install tmux jq)")
  done
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
# github the whole `teams.github` block must match too: a different project/repo would send
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
      | jq -S -c '.teams.github // {}' 2>/dev/null || true)" \
      = "$(jq -S -c '.teams.github // {}' "$root/.claude/project-profile.json")" ] || bad=1
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
  [ "$(printf '%s' "$prof" | jq -r '.teams.github.repo // empty' 2>/dev/null || true)" \
    = "$TEAM_GH_REPO" ] || bad=1
  [ -z "$bad" ] || TEAM_PROBLEMS+=("base $base cannot run pr_provider=github \
— PR layer/profile missing or different on the base")
}

# Copies, not symlinks: each team gets its own writable credential and permission files.
team_seed_files() {
  local root="$1" dir="$2" f
  team_profile_load "$root"
  # Per-clone excludes (Claude runtime state, handoffs) would otherwise dirty the clone's tree.
  [ ! -f "$root/.git/info/exclude" ] || cp "$root/.git/info/exclude" "$dir/.git/info/exclude"
  for f in ${TEAM_SEED_FILES[@]+"${TEAM_SEED_FILES[@]}"}; do
    if [ -e "$root/$f" ]; then
      mkdir -p "$dir/$(dirname "$f")"
      cp "$root/$f" "$dir/$f"
    fi
    # A seeded credential file stays private to the clone.
    [ "$f" != .env ] || [ ! -f "$dir/.env" ] || chmod 600 "$dir/.env"
  done
}

# Usage: team_seed_checks <root> <base> — refuse a seed that would overwrite a TRACKED file.
# The seed copy lands on top of a fresh checkout of <base>, so seeding a file that <base> tracks
# with different content leaves the clone dirty from its first second: every `git status` gate,
# the merge-check and the integration then read a change nobody made. Untracked or ignored files
# (credentials, settings.local.json) are exactly what seeding is for and never a problem.
team_seed_checks() {
  local root="$1" base="$2" f
  team_profile_load "$root"
  for f in ${TEAM_SEED_FILES[@]+"${TEAM_SEED_FILES[@]}"}; do
    git -C "$root" cat-file -e "$base:$f" 2>/dev/null || continue
    [ -e "$root/$f" ] || continue
    # `if`, not `&& continue`: under `set -e` a failing trailing AND-list would end the caller.
    if git -C "$root" show "$base:$f" 2>/dev/null | cmp -s - "$root/$f"; then continue; fi
    TEAM_PROBLEMS+=("seed file $f is tracked on $base with different content \
— drop it from teams.seed_files")
  done
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
pr_timebox() {  # pr_timebox <secs> <cmd...> → exit 124 on timeout
  perl -e '$t = shift; $p = fork // exit 1;
    if (!$p) { setpgrp(0, 0); exec @ARGV or exit 127 }
    $SIG{ALRM} = sub { kill "KILL", -$p; waitpid $p, 0; exit 124 };
    alarm $t; waitpid $p, 0; exit($? >> 8)' "$@"
}
