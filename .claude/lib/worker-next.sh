#!/usr/bin/env bash
# Hand the permanent SolTT worker clone from one assignment to the next (TT-849).
#
# Usage: bash .claude/lib/worker-next.sh init <base-ref>
#        bash .claude/lib/worker-next.sh start <TT-key> <branch> <base-ref> --thread <id>
#        bash .claude/lib/worker-next.sh status
#        bash .claude/lib/worker-next.sh check <assignment-id>
#        bash .claude/lib/worker-next.sh release <assignment-id> [--pr <id>] [--abandoned]
#
# Contract: .agents/reference/worker-clone.md. Never resets, cleans or deletes branches.
set -euo pipefail
. "$(dirname "$0")/team-lib.sh"
. "$(dirname "$0")/worker-lib.sh"

WORKER_ARTIFACTS="${WORKER_ARTIFACTS:-$HOME/.agent-mail/taketask-dn/worker}"
WORKER_ARTIFACT_MAX_MB="${WORKER_ARTIFACT_MAX_MB:-50}"
WORKER_LOCK_SECS="${WORKER_LOCK_SECS:-30}"
W_PROBLEMS=()
LOCKED=""
NO_CONTRACT="has no worker contract (AGENTS.md ### Worker clone, worker-next.sh,"
NO_CONTRACT+=" worker-clone.md)"

usage() {
  sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

die() { echo "error: $*" >&2; exit 1; }

w_flush() {
  [ ${#W_PROBLEMS[@]} -gt 0 ] || return 0
  for p in "${W_PROBLEMS[@]}"; do echo "error: $p" >&2; done
  exit 1
}

# State sits in the clone's git dir: it never dirties the tree and team_clone_dirs never sees it.
w_paths() {
  ROOT="$(git rev-parse --show-toplevel)"
  GD="$(git rev-parse --absolute-git-dir)"
  WD=""
  if [ -d "$GD/taketask-worker" ]; then
    INCLONE=1; DIR="$ROOT"; WD="$GD/taketask-worker"
  else
    INCLONE=0; DIR="$(dirname "$ROOT")/$(basename "$ROOT")-sol"
    [ ! -e "$DIR/.git" ] || WD="$(git -C "$DIR" rev-parse --absolute-git-dir)/taketask-worker"
  fi
}

w_supervisor_only() {
  [ "$INCLONE" = 0 ] || die "$1 is a supervisor command — run it from the main checkout"
}

w_require_clone() {
  [ -n "$WD" ] && [ -f "$WD/provisioned.json" ] || die "no worker clone at $DIR — run init"
}

w_lock() {
  local tries=0 max p hint=""
  max=$(( WORKER_LOCK_SECS * 5 ))
  until mkdir "$WD/op.lock" 2>/dev/null; do
    if [ "$tries" -ge "$max" ]; then
      p="$(cat "$WD/op.lock/pid" 2>/dev/null || echo none)"
      kill -0 "$p" 2>/dev/null \
        || hint=" — stale: check no worker-next.sh runs, then remove $WD/op.lock"
      die "worker clone busy (op.lock held by pid $p)$hint"
    fi
    sleep 0.2; tries=$((tries + 1))
  done
  echo $$ > "$WD/op.lock/pid"
  LOCKED="$WD/op.lock"
}

w_get() { jq -r --arg f "$2" '.[$f] // empty' "$1"; }

# Atomic: a reader never sees a half-written state file.
w_write() {  # w_write <file> <jq args...>
  local f="$1"; shift
  jq "$@" > "$f.tmp.$$" && mv "$f.tmp.$$" "$f"
}

# find, not a glob: right after init history/ is empty and `cat <glob>` would kill the script.
w_last_release() {
  find "$WD/history" -name release.json -exec cat {} + | jq -cs 'sort_by(.seq) | last // empty'
}

w_settled_tip() {
  local t
  t="$(w_last_release | jq -r '.tip // empty')"
  [ -n "$t" ] || t="$(w_get "$WD/provisioned.json" tip)"
  echo "$t"
}

w_contract_ok() {  # w_contract_ok <repo> <rev>
  local agents
  git -C "$1" cat-file -e "$2:.claude/lib/worker-next.sh" 2>/dev/null || return 1
  git -C "$1" cat-file -e "$2:.agents/reference/worker-clone.md" 2>/dev/null || return 1
  agents="$(git -C "$1" show "$2:AGENTS.md" 2>/dev/null)" || return 1
  grep -qx '### Worker clone' <<<"$agents"
}

w_settled_ok() {
  local head settled
  head="$(git -C "$DIR" rev-parse HEAD)"; settled="$(w_settled_tip)"
  [ "$head" = "$settled" ] || W_PROBLEMS+=("HEAD $head is not the last settled tip $settled\
 — a commit after release, or an unreleased assignment")
}

cmd_init() {
  [ $# -eq 1 ] || usage
  local base="$1" ex
  w_supervisor_only init
  [ ! -e "$DIR" ] || W_PROBLEMS+=("$DIR exists — the worker clone is provisioned once")
  jq --version >/dev/null 2>&1 || W_PROBLEMS+=("jq is required — install it before init")
  # Flushed here so the profile gate (which needs jq) runs before the first `git fetch`, while
  # the jq-missing refusal keeps its own message.
  w_flush
  team_profile_load "$ROOT"
  team_profile_require_supported
  if [[ ! "$base" =~ ^origin/[A-Za-z0-9._/-]+$ ]]; then
    W_PROBLEMS+=("base-ref '$base' must be origin/<branch>")
  elif ! git -C "$ROOT" fetch --quiet origin; then
    W_PROBLEMS+=("git fetch origin failed")
  elif ! git -C "$ROOT" rev-parse --verify --quiet "$base^{commit}" >/dev/null; then
    W_PROBLEMS+=("base-ref $base does not resolve")
  elif ! w_contract_ok "$ROOT" "$base"; then
    W_PROBLEMS+=("base $base $NO_CONTRACT")
  fi
  w_flush
  team_clone_dissociated "$ROOT" "$DIR"
  # Detached: the fresh clone already has a local line branch, so `switch -c <line>` would fail.
  git -C "$DIR" switch --quiet --detach "$base"
  ex="$(git -C "$ROOT" rev-parse --path-format=absolute --git-path info/exclude)"
  [ ! -f "$ex" ] || cp "$ex" "$DIR/.git/info/exclude"
  WD="$(git -C "$DIR" rev-parse --absolute-git-dir)/taketask-worker"
  mkdir -p "$WD/history"
  w_lock
  w_write "$WD/provisioned.json" -n --arg b "$base" --arg t "$(git -C "$DIR" rev-parse HEAD)" \
    --arg c "$(team_utc)" '{base_ref: $b, tip: $t, created_at: $c}'
  echo "clone:    $DIR"
  echo "tip:      $(git -C "$DIR" rev-parse HEAD) (detached at $base)"
  echo "next:     Operator checklist (.agents/reference/worker-clone.md → Provisioning):"
  echo "  1. give SolTT's Codex host write access to $DIR and $WORKER_ARTIFACTS only"
  echo "     (a narrow writable root or the thread cwd, no global widening)"
  echo "  2. SolTT runs worker-next.sh status and the build check in the clone: $TEAM_BUILD_CHECK"
  echo "  3. only then the first worker-next.sh start"
}

cmd_start() {
  [ $# -eq 5 ] && [ "$4" = --thread ] || usage
  local key="$1" branch="$2" base="$3" thread="$5" a st id
  # Before the lock, the branch switch and the published assignment.
  team_profile_load "$ROOT"
  team_profile_require_supported
  [[ "$thread" =~ ^[A-Za-z0-9._:-]+$ ]] || die "thread '$thread' must match [A-Za-z0-9._:-]+"
  w_supervisor_only start
  w_require_clone
  w_lock
  a="$WD/active/assignment.json"
  # Dispatch before the fresh checks: they would refuse the system's own half-done transition.
  if [ -e "$WD/active" ]; then
    st="$(w_get "$a" state)"; id="$(w_get "$a" id)"
    if [ "$st" = switching ]; then
      if [ "$(w_get "$a" ticket)" = "$key" ] && [ "$(w_get "$a" branch)" = "$branch" ] \
        && [ "$(w_get "$a" base_ref)" = "$base" ] && [ "$(w_get "$a" thread)" = "$thread" ]; then
        start_resume "$a"
        return 0
      fi
      die "interrupted transition $id pending — rerun: worker-next.sh start" \
        "$(w_get "$a" ticket) $(w_get "$a" branch) $(w_get "$a" base_ref)" \
        "--thread $(w_get "$a" thread)"
    fi
    if [ "$(w_get "$a" ticket)" = "$key" ] && [ "$(w_get "$a" branch)" = "$branch" ] \
      && [ "$(w_get "$a" base_ref)" != "$base" ]; then
      die "base change for active assignment $id returns to the supervisor"
    fi
    die "assignment $id ($(w_get "$a" ticket)) is active — release it first"
  fi
  git -C "$DIR" fetch --quiet origin || W_PROBLEMS+=("git fetch origin failed in $DIR")
  start_checks "$key" "$branch" "$base"
  w_flush
  start_publish "$key" "$branch" "$base" "$thread"
}

start_checks() {
  local key="$1" branch="$2" base="$3" live types_re
  types_re="$(printf '%s|' "${TEAM_BRANCH_TYPES[@]}")"; types_re="${types_re%|}"
  local branch_re="^(${types_re})/${key}-[a-z0-9-]+\$"
  [[ "$key" =~ $TEAM_KEY_REGEX ]] || W_PROBLEMS+=("ticket key '$key' must match $TEAM_KEY_REGEX")
  [[ "$branch" =~ $branch_re ]] \
    || W_PROBLEMS+=("branch '$branch' must be <type>/$key-<slug> (types: ${TEAM_BRANCH_TYPES[*]})")
  [[ "$base" =~ ^origin/[A-Za-z0-9._/-]+$ ]] \
    || W_PROBLEMS+=("base-ref '$base' must be origin/<branch>")
  w_tree_clean "clone $DIR has uncommitted or untracked changes"
  w_settled_ok
  ! git -C "$DIR" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null \
    || W_PROBLEMS+=("branch $branch already exists in the worker clone")
  if live="$(w_live_ref "$branch")"; then
    [ "$live" = absent ] || W_PROBLEMS+=("branch $branch already exists on origin")
  else
    W_PROBLEMS+=("ls-remote failed for $branch")
  fi
  w_probe
  if ! BASE_SHA="$(git -C "$DIR" rev-parse --verify --quiet "$base^{commit}")"; then
    W_PROBLEMS+=("base-ref $base does not resolve")
  elif ! w_contract_ok "$DIR" "$BASE_SHA"; then
    W_PROBLEMS+=("base $base $NO_CONTRACT")
  fi
}

start_publish() {
  local key="$1" branch="$2" base="$3" thread="$4" stem id n=1 s
  # A suffix, safe under op.lock: an `empty` release lets the same ticket restart within a second.
  stem="$key-$(date -u +%Y%m%d-%H%M%S)"; id="$stem"
  while [ -e "$WD/history/$id" ] || [ -e "$WD/staging-$id" ] || [ -e "$WORKER_ARTIFACTS/$id" ]; do
    n=$((n + 1)); id="$stem-$n"
  done
  s="$WD/staging-$id"
  mkdir "$s"
  w_write "$s/assignment.json" -n --arg id "$id" --arg t "$key" --arg b "$branch" \
    --arg l "${base#origin/}" --arg r "$base" --arg sha "$BASE_SHA" --arg th "$thread" \
    --arg art "$WORKER_ARTIFACTS/$id" --arg at "$(team_utc)" \
    '{id: $id, ticket: $t, branch: $b, line: $l, base_ref: $r, base_sha: $sha, thread: $th,
      state: "switching", artifacts: $art, started_at: $at}'
  [ ! -e "$WD/active" ] || die "an assignment became active meanwhile — staging-$id kept"
  mv "$s" "$WD/active"
  git -C "$DIR" switch --quiet --no-track -c "$branch" "$BASE_SHA"
  w_activate
}

# base_sha comes from the record, never re-resolved: the origin may have moved since.
start_resume() {
  local a="$1" id branch bsha have=""
  id="$(w_get "$a" id)"; branch="$(w_get "$a" branch)"; bsha="$(w_get "$a" base_sha)"
  w_tree_clean "uncommitted or untracked changes — interrupted start $id kept for the supervisor"
  w_probe
  ! git -C "$DIR" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null || have=1
  [ -n "$have" ] || w_settled_ok
  w_flush
  if [ -n "$have" ]; then
    if [ "$(git -C "$DIR" rev-parse "refs/heads/$branch")" != "$bsha" ] \
      || [ "$(w_head_branch)" != "$branch" ]; then
      die "branch $branch moved during an interrupted start $id — supervisor decides"
    fi
  else
    git -C "$DIR" switch --quiet --no-track -c "$branch" "$bsha"
  fi
  w_activate
}

# The artifacts dir exists before the record says active, so no interruption leaves one without it.
w_activate() {
  local a="$WD/active/assignment.json" art
  art="$(w_get "$a" artifacts)"
  mkdir -p "$art"
  w_write "$a" '.state = "active"' "$a"
  echo "id:        $(w_get "$a" id)"
  echo "clone:     $DIR"
  echo "ticket:    $(w_get "$a" ticket)"
  echo "branch:    $(w_get "$a" branch)"
  echo "base sha:  $(w_get "$a" base_sha)"
  echo "thread:    $(w_get "$a" thread)"
  echo "artifacts: $art"
  echo "next:      hand these to SolTT; SolTT runs worker-next.sh check $(w_get "$a" id)"
}

cmd_status() {
  local a last s
  if [ -z "$WD" ] || [ ! -f "$WD/provisioned.json" ]; then
    echo "state: no clone at $DIR"
    return 0
  fi
  a="$WD/active/assignment.json"
  if [ -f "$a" ]; then
    echo "state: $(w_get "$a" state)"
    jq -r 'to_entries[] | select(.key != "state") | "\(.key): \(.value)"' "$a"
  else
    echo "state: idle"
    last="$(w_last_release)"
    if [ -n "$last" ]; then
      echo "last: $(jq -r '"\(.id) \(.outcome) \(.tip)"' <<<"$last")"
    else
      echo "last: none (provisioned at $(w_get "$WD/provisioned.json" tip))"
    fi
  fi
  for s in "$WD"/staging-*; do
    [ -d "$s" ] || continue
    echo "leftover: $(basename "$s") (interrupted before publication)"
  done
}

# Mirrors tree-fingerprint.sh: NUL-safe, a symlink is hashed by its target text.
w_untracked_hashes() {
  local f
  while IFS= read -r -d '' f; do
    if [ -L "$f" ]; then printf 'link %s %s\n' "$(readlink "$f")" "$f"
    elif [ -f "$f" ]; then shasum -a 256 "$f" || return 1
    else printf 'other %s\n' "$f"; fi
  done
}

w_diff_sha() {
  ( cd "$DIR" || exit 1
    { git diff --binary "$1" && git ls-files -o --exclude-standard -z | w_untracked_hashes; } \
      | shasum -a 256 | cut -d' ' -f1 )
}

cmd_check() {
  [ $# -eq 1 ] || usage
  local a aid st branch bsha hb diff
  a="$WD/active/assignment.json"
  [ -n "$WD" ] && [ -f "$a" ] || die "no active assignment — message is stale"
  aid="$(w_get "$a" id)"
  [ "$aid" = "$1" ] || die "stale: active assignment is $aid"
  st="$(w_get "$a" state)"
  [ "$st" = active ] || die "assignment $1 is $st"
  branch="$(w_get "$a" branch)"; bsha="$(w_get "$a" base_sha)"; hb="$(w_head_branch)"
  [ "$hb" = "$branch" ] || die "HEAD is on ${hb:-a detached commit}, not $branch"
  git -C "$DIR" merge-base --is-ancestor "$bsha" HEAD \
    || die "base $bsha is not an ancestor of HEAD — base changed"
  grep -qx '### Worker clone' "$DIR/AGENTS.md" 2>/dev/null \
    || die "checkout has no worker contract (AGENTS.md ### Worker clone)"
  diff="$(w_diff_sha "$bsha")" || die "diff hash failed"
  echo "id:       $aid"
  echo "ticket:   $(w_get "$a" ticket)"
  echo "branch:   $branch"
  echo "base sha: $bsha"
  echo "head:     $(git -C "$DIR" rev-parse HEAD)"
  echo "diff sha: $diff"
}

cmd_release() {
  [ $# -ge 1 ] || usage
  local id="$1" a st h art key_re
  shift
  team_profile_load "$ROOT"
  # The assignment id is "<ticket key>-<yyyymmdd>-<hhmmss>[-<n>]": the key regex without anchors.
  key_re="${TEAM_KEY_REGEX#^}"; key_re="${key_re%$}"
  PR=""; ABANDONED=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --pr) [ $# -ge 2 ] || usage; PR="$2"; shift 2 ;;
      --abandoned) ABANDONED=1; shift ;;
      *) usage ;;
    esac
  done
  [ -z "$PR" ] || [[ "$PR" =~ ^[0-9]+$ ]] || die "PR id '$PR' must be digits"
  [[ "$id" =~ ^${key_re}-[0-9]{8}-[0-9]{6}(-[0-9]+)?$ ]] \
    || die "assignment id '$id' must be <key>-<yyyymmdd>-<hhmmss>[-<n>]"
  w_supervisor_only release
  w_require_clone
  w_lock
  h="$WD/history/$id/release.json"
  if [ -f "$h" ]; then
    art="$(w_get "$WD/history/$id/assignment.json" artifacts)"
    # Re-copies a deleted artifacts copy, or finishes a pre-TT-876 release cut between mv and cp.
    [ ! -d "$art" ] || cp "$h" "$art/"
    echo "already released: $(jq -r '"\(.outcome) \(.tip)"' "$h")"
    return 0
  fi
  a="$WD/active/assignment.json"
  [ -f "$a" ] || die "no active assignment"
  [ "$(w_get "$a" id)" = "$id" ] || die "stale: active assignment is $(w_get "$a" id)"
  st="$(w_get "$a" state)"
  [ "$st" = active ] || die "assignment $id is $st"
  BRANCH="$(w_get "$a" branch)"; LINE="$(w_get "$a" line)"; BSHA="$(w_get "$a" base_sha)"
  w_tree_clean "clone $DIR has uncommitted or untracked changes"
  [ "$(w_head_branch)" = "$BRANCH" ] || W_PROBLEMS+=("HEAD of $DIR is not on $BRANCH")
  w_probe
  if ! TIP="$(git -C "$DIR" rev-parse --verify --quiet "refs/heads/$BRANCH")"; then
    W_PROBLEMS+=("branch $BRANCH is missing in $DIR — recreate it at its pushed or reflog tip\
 (git -C $DIR branch $BRANCH <sha>), switch to it, then rerun release")
    w_flush
  fi
  OUTCOME=""; SRC=""; PRSTATUS=""
  if ! LIVE="$(w_live_ref "$BRANCH")"; then
    LIVE=unknown; W_PROBLEMS+=("ls-remote failed — PR state unknown")
  fi
  release_settle
  release_artifacts "$(w_get "$a" artifacts)"
  w_flush
  release_record "$id" "$(w_get "$a" artifacts)"
}

# Exact tip, not ancestry: a squash merge is never an ancestor of the worker branch.
release_settle() {
  local pr="" here after n
  if [ -z "$PR" ]; then
    if [ "$TIP" != "$BSHA" ]; then
      n="$(git -C "$DIR" rev-list --count "$BSHA..$TIP")"
      W_PROBLEMS+=("$n commits on $BRANCH but no PR — pass --pr")
    elif [ "$LIVE" != absent ] && [ "$LIVE" != "$TIP" ]; then
      W_PROBLEMS+=("remote $BRANCH is at $LIVE, not $TIP — reconcile before release")
    else
      OUTCOME=empty
    fi
    return 0
  fi
  if [ "$TEAM_PR_PROVIDER" = github ]; then
    pr="$(cd "$DIR" && bash "$ROOT/.claude/lib/team-pr.sh" state "$PR")" || pr=""
    [ -n "$pr" ] || { W_PROBLEMS+=("PR #$PR state unknown"); return 0; }
    if ! jq -e --arg repo "$TEAM_GH_REPO" --arg src "refs/heads/$BRANCH" \
      --arg tgt "refs/heads/$LINE" \
      '.repo == $repo and .source_ref == $src and .target_ref == $tgt' <<<"$pr" >/dev/null; then
      W_PROBLEMS+=("PR #$PR is not $BRANCH → $LINE in $TEAM_GH_REPO"); return 0
    fi
    SRC="$(jq -r '.source_sha // ""' <<<"$pr")"
    PRSTATUS="$(jq -r '.status // ""' <<<"$pr")"
  else
    # team_ado_coords reads the cwd's origin and sets ADO_REPO, so no subshell here.
    here="$PWD"; cd "$DIR"
    if team_ado_coords && pr="$(team_pr_json "$PR")"; then :; else pr=""; fi
    cd "$here"
    [ -n "$pr" ] || { W_PROBLEMS+=("PR #$PR state unknown"); return 0; }
    if ! jq -e --arg repo "$ADO_REPO" --arg src "refs/heads/$BRANCH" --arg tgt "refs/heads/$LINE" \
      '.repository.name == $repo and .sourceRefName == $src and .targetRefName == $tgt' \
      <<<"$pr" >/dev/null; then
      W_PROBLEMS+=("PR #$PR is not $BRANCH → $LINE in $ADO_REPO"); return 0
    fi
    SRC="$(jq -r '.lastMergeSourceCommit.commitId // ""' <<<"$pr")"
    PRSTATUS="$(jq -r '.status // ""' <<<"$pr")"
  fi
  after="commits after PR #$PR (tip $TIP, PR source ${SRC:-none}, remote $LIVE)"
  case "$PRSTATUS" in
    completed)
      if [ "$SRC" = "$TIP" ] && { [ "$LIVE" = absent ] || [ "$LIVE" = "$TIP" ]; }; then
        OUTCOME=merged
      else W_PROBLEMS+=("$after"); fi ;;
    abandoned)
      if [ -z "$ABANDONED" ]; then
        W_PROBLEMS+=("PR #$PR is abandoned — not merged; pass --abandoned\
 to close the assignment keeping $BRANCH")
      elif [ "$LIVE" = "$TIP" ] || { [ "$LIVE" = absent ] && [ "$SRC" = "$TIP" ]; }; then
        OUTCOME=abandoned
      else W_PROBLEMS+=("$after"); fi ;;
    *) W_PROBLEMS+=("PR #$PR is ${PRSTATUS:-unknown} — merge or abandon it first") ;;
  esac
}

release_artifacts() {
  local art="$1" kb max top partial="" bins
  [ -d "$art" ] || return 0
  max=$(( WORKER_ARTIFACT_MAX_MB * 1024 ))
  # A failing du may still print a partial sum: a lower bound, so over-limit stays real.
  kb="$(du -sk "$art" 2>/dev/null | cut -f1)" || partial=1
  if [[ ! "$kb" =~ ^[0-9]+$ ]]; then
    echo "warning: artifacts $art could not be measured" >&2
  else
    [ -z "$partial" ] || echo "warning: artifacts $art could not be fully measured\
 — size check is a lower bound" >&2
    if [ "$kb" -gt "$max" ]; then
      top="$(du -sk "$art"/* 2>/dev/null | sort -rn | head -5 | tr '\n' ' ')" || true
      W_PROBLEMS+=("artifacts $art hold $kb KB, over $max KB — largest: $top")
    fi
  fi
  if ! bins="$(find "$art" -type d \( -name bin -o -name obj \) 2>/dev/null)"; then
    echo "warning: artifacts $art could not be fully searched for bin/ or obj/" >&2
  fi
  [ -z "$bins" ] || W_PROBLEMS+=("artifacts $art contain bin/ or obj/ — move them out")
}

# seq, assigned under op.lock, orders releases: released_at has one-second precision.
release_record() {
  local id="$1" art="$2" seq r="$WD/active/release.json"
  seq="$(find "$WD/history" -name release.json -exec cat {} + | jq -s 'map(.seq) | max // 0')"
  w_write "$r" -n --arg id "$id" --argjson seq "$((seq + 1))" --arg o "$OUTCOME" --arg t "$TIP" \
    --arg pr "$PR" --arg ps "$PRSTATUS" --arg src "$SRC" --arg live "$LIVE" --arg at "$(team_utc)" \
    '{id: $id, seq: $seq, outcome: $o, tip: $t,
      pr_id: (if $pr == "" then null else ($pr | tonumber) end), pr_status: $ps,
      pr_source: $src, remote: $live, released_at: $at}'
  [ "$(w_get "$WD/active/assignment.json" id)" = "$id" ] \
    || die "active assignment changed during release"
  [ ! -e "$WD/history/$id" ] || die "history/$id already exists — release record left in active/"
  # Copied before the move, so a failed copy leaves the assignment active for a rerun.
  [ ! -d "$art" ] || cp "$r" "$art/" \
    || die "cannot copy release.json to $art — release not recorded; fix the artifacts dir,\
 then rerun release"
  mv "$WD/active" "$WD/history/$id"
  echo "released:    $id"
  echo "outcome:     $OUTCOME"
  echo "tip:         $TIP"
  echo "pr:          ${PR:-none}"
  echo "branch kept: $BRANCH"
}

trap '[ -z "${LOCKED:-}" ] || { rm -f "$LOCKED/pid"; rmdir "$LOCKED"; } 2>/dev/null || true' EXIT

case "${1:-}" in
  init|start|status|check|release) sub="$1"; shift; w_paths; "cmd_$sub" "$@" ;;
  *) usage ;;
esac
