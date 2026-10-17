#!/usr/bin/env bash
# Shared functions for the team pipeline scripts and the dashboard.
# Sourced, never executed; the caller sets `set -euo pipefail`. Contract: .agents/reference/team-mode.md
# Bash 3.2 compatible (macOS /bin/bash): no mapfile, no associative arrays.

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

# One regex for team-answer and the dashboard: they must agree on "prompt open".
team_prompt_open() {
  team_pane "$1" 25 | grep -Eq 'Do you want to (proceed|make this edit|create|allow)|❯ *1\. Yes'
}

# Usage: team_clone_dirs <main root> — prints each clone's .agents/team dir that has team.json.
team_clone_dirs() {
  local d
  for d in "$(dirname "$1")/$(basename "$1")"-*/.agents/team; do
    [ ! -f "$d/team.json" ] || echo "$d"
  done
}

# Claude Code keeps transcripts under the repo path with every non-alphanumeric char → '-'.
team_project_slug() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }
team_claude_project_dir() {
  echo "${TEAM_DASH_PROJECT_DIR:-$HOME/.claude/projects/$(team_project_slug "$1")}"
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
      p="$(cat "$q.lock/pid" 2>/dev/null || echo none)"; id="$(basename "$q" .md)"
      kill -0 "$p" 2>/dev/null || hint=" — stale: team-question.sh $2 unlock $id"
      echo "error: $id busy (lock held by pid $p)$hint" >&2
      return 1
    fi
    sleep 0.2; tries=$((tries + 1))
  done
  echo $$ > "$q.lock/pid"
}

# Usage: team_q_state <q file> → "<state>\t<tier>\t<author>"
# Reads the last ## Answer / ## Revoked plus any ## Escalation; once FableTT reported the Operator
# asked (`waiting:`), only a final outcome leaves waiting-operator.
team_q_state() {
  awk '
    /^## /     { sec = substr($0, 4)
                 if (sec == "Answer") { h = "answer"; tier = ""; author = ""; dl = "" }
                 if (sec == "Revoked") { h = "revoked"; dl = "" }
                 next }
    sec == "Answer" && /^tier: /   { tier = substr($0, 7) }
    sec == "Answer" && /^author: / { author = substr($0, 9) }
    (sec == "Answer" || sec == "Revoked") && /^delivery: / { dl = substr($0, 11) }
    sec == "Escalation" && /^(started|reping|retier|resumed): / {
      esc = asked ? "waiting-operator" : "escalating"; next }
    sec == "Escalation" && /^waiting: / { asked = 1; esc = "waiting-operator"; next }
    sec == "Escalation" && /^outcome: (answer|withdrawn)$/ { asked = 0; esc = "escalated"; next }
    sec == "Escalation" && /^outcome: / { esc = asked ? "waiting-operator" : "escalated" }
    END {
      if (h == "revoked") st = "revoked"
      else if (h == "answer") st = (dl == "pending") ? "pending" : (dl ~ /^failed/) ? "failed" \
        : (dl == "recorded only") ? "recorded" : "sent"
      else st = (esc != "") ? esc : "open"
      printf "%s\t%s\t%s\n", st, (tier == "" ? "-" : tier), (author == "" ? "-" : author)
    }' "$1"
}

# Ticket preflight shared by team-new and team-next; appends to TEAM_PROBLEMS, never exits.
team_ticket_checks() {
  local root="$1" key="$2" branch="$3" base="$4" own="${5:-}" tool other rc
  local branch_re="^(feature|bugfix|hotfix|chore|refactor)/${key}-[a-z0-9-]+\$"
  for tool in git jq tmux claude codex az dotnet; do
    command -v "$tool" >/dev/null 2>&1 || TEAM_PROBLEMS+=("$tool not on PATH (tmux/jq: brew install tmux jq)")
  done
  if command -v az >/dev/null 2>&1 && ! az account show >/dev/null 2>&1; then
    TEAM_PROBLEMS+=("az is not logged in — run: az login")
  fi
  [[ "$key" =~ ^[A-Z]+-[0-9]+$ ]] || TEAM_PROBLEMS+=("ticket key '$key' must look like TT-123")
  [[ "$branch" =~ $branch_re ]] \
    || TEAM_PROBLEMS+=("branch '$branch' must be <type>/$key-<slug> (types: feature bugfix hotfix chore refactor)")
  # The clone resolves base afresh and team.json `line` (the PR target) is base minus `origin/`.
  [[ "$base" =~ ^origin/[A-Za-z0-9._/-]+$ ]] || TEAM_PROBLEMS+=("base-ref '$base' must be origin/<branch>")
  if [ ! -f "$root/.env" ]; then
    TEAM_PROBLEMS+=("$root/.env missing")
  elif [ "$(stat -f %Lp "$root/.env")" != 600 ]; then
    TEAM_PROBLEMS+=(".env is not mode 600 — run: chmod 600 .env")
  fi
  for other in "$(dirname "$root")/$(basename "$root")"-*/.agents/team/team.json; do
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
    TEAM_PROBLEMS+=("base has no team harness — only develop-netcore7 and lines carrying .claude/ are supported")
  fi
}

# Copies, not symlinks: each team gets its own writable credential and permission files.
team_seed_files() {
  local root="$1" dir="$2" f
  # Per-clone excludes (Claude runtime state, handoffs) would otherwise dirty the clone's tree.
  [ ! -f "$root/.git/info/exclude" ] || cp "$root/.git/info/exclude" "$dir/.git/info/exclude"
  for f in .env .claude/settings.local.json .agents/memory/user-profile.md; do
    if [ -e "$root/$f" ]; then
      mkdir -p "$dir/$(dirname "$f")"
      cp "$root/$f" "$dir/$f"
    fi
  done
  [ ! -f "$dir/.env" ] || chmod 600 "$dir/.env"
}

team_write_json() {
  local dir="$1" team="$2" key="$3" branch="$4" base="$5"
  mkdir -p "$dir/.agents/team"
  jq -n --arg team "$team" --arg ticket "$key" --arg branch "$branch" --arg line "${base#origin/}" \
    --arg base_ref "$base" --arg base_sha "$(git -C "$dir" rev-parse HEAD)" \
    --arg origin_url "$(git -C "$dir" remote get-url origin)" \
    --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg mode "${6:-brainstorm}" \
    '{team: $team, ticket: $ticket, branch: $branch, line: $line, base_ref: $base_ref,
      base_sha: $base_sha, mode: $mode, origin_url: $origin_url, created_at: $created_at}' \
    > "$dir/.agents/team/team.json"
}
