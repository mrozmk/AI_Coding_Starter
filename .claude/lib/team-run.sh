#!/usr/bin/env bash
# Stage runner for a team clone: planner → coder → qa → wrapup, each a fresh Claude session in tmux.
#
# Usage: bash .claude/lib/team-run.sh <team> [status|stop|unlock]
#   e.g. tmux new-session -d -s alfa-runner "bash .claude/lib/team-run.sh alfa; read"
#   internal: bash .claude/lib/team-run.sh <team> check <record>   (validate one record)
#   bash .claude/lib/team-run.sh <team> roles <role>=[<model>][/<effort>]… | --clear
#   bash .claude/lib/team-run.sh <team> summary   (post-run summary sources for /monitor)
#   modes (team.json .mode, set by team-new/next): brainstorm · quick · cli
#
# Env: TEAM_ATTACH=all|planner (default all) — all roles, or only the attended planner and wrapup.
# Exit: 0 ready/advanced · 1 failed record · 2 blocked · 3 stalled · 4 validation failed
#       5 partial work after a dead session · 6 cancelled · 7 orphan role session
set -euo pipefail

if [ $# -lt 1 ] || { [ $# -gt 3 ] && [ "${2:-}" != roles ]; }; then
  sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
fi
TEAM="$1"; CMD="${2:-advance}"

root="$(git rev-parse --show-toplevel)"; ORIG_PWD="$PWD"
# Before the runner lock, session.json and any tmux session: the profile decides what 2a can run.
. "$root/.claude/lib/team-profile.sh"
team_profile_load "$root"
team_profile_require_supported
CLONE="$(team_clone_dir "$TEAM" "$root")"
case "$CLONE" in *"'"*) echo "error: clone path contains a quote: $CLONE" >&2; exit 1 ;; esac
[ -f "$CLONE/.agents/team/team.json" ] || { echo "error: no team clone at $CLONE" >&2; exit 1; }
cd "$CLONE"
. "$CLONE/.claude/lib/team-lib.sh"
# From the main checkout, like roles.json: a clone on an older base lacks this file.
. "$root/.claude/lib/team-roles.sh"
. "$root/.claude/lib/team-modes.sh"
. "$root/.claude/lib/team-validate.sh"
. "$root/.claude/lib/team-tracker-render.sh"

TD="$CLONE/.agents/team"
# Read from the main checkout so a local edit applies at the next launch, without a PR.
ROLES="$root/.claude/team/roles.json"; [ -f "$ROLES" ] || ROLES="$CLONE/.claude/team/roles.json"
ROLES_OVERRIDE="$TD/roles.override.json"
POLL="${TEAM_POLL_SECS:-30}"
ADO_WAIT="${TEAM_ADO_WAIT_SECS:-300}"
ADO_POLL="${TEAM_ADO_POLL_SECS:-20}"
EXIT_WAIT="${TEAM_EXIT_WAIT_SECS:-60}"
STOP_WAIT="${TEAM_STOP_WAIT_SECS:-90}"
ATTACH="${TEAM_ATTACH:-all}"
case "$ATTACH" in all|planner) ;; *) echo "error: TEAM_ATTACH must be all or planner, got $ATTACH" >&2; exit 2 ;; esac
BRANCH="$(team_json branch)"; LINE="$(team_json line)"
RUN=""; ROLE=""; OWN_LOCK=0
MODE="$(team_mode "$TD/team.json")" || { echo "error: cannot read the mode of $TD/team.json" >&2; exit 1; }

# The runner lives in a hidden tmux session, so every stop and every wait is also a macOS notification.
notify() {
  [ "${TEAM_NOTIFY:-1}" = 1 ] && command -v osascript >/dev/null 2>&1 || return 0
  osascript -e "display notification \"${2//\"/}\" with title \"team $TEAM: $1\"" >/dev/null 2>&1 || true
}
die() { echo "$2" >&2; [ "$1" = 6 ] || notify "stopped ($1)" "$2"; exit "$1"; }
rec() { jq -r --arg f "$2" '.[$f] // empty | if type == "array" then join(",") else . end' "$1"; }
sess_name() { team_tmux_name "$TEAM" "$1"; }
# The planner and the wrapup are attended: the developer answers them in their window.
attended() { case "$1" in planner|wrapup) ;; *) return 1 ;; esac; }
artifact() { jq -r --arg p "$2" '[.artifacts[] | select(startswith($p))][0] // empty' "$1"; }

end_session() {
  local name waited=0
  name="$(sess_name "$1")"
  team_tmux_alive "$name" || return 0
  tmux send-keys -t "=$name:" "/exit" Enter || true
  while team_tmux_alive "$name" && [ "$waited" -lt "$EXIT_WAIT" ]; do sleep 1; waited=$((waited + 1)); done
  team_tmux_alive "$name" && tmux kill-session -t "=$name" || true
  ! team_tmux_alive "$name" || die 1 "error: session $name did not end"
}

cancel_exit() {
  [ -z "$ROLE" ] || end_session "$ROLE"
  die 6 "cancelled by stop — session.json kept for the next run"
}

accepted_record() { team_accepted_record "$RUN" "$1"; }

last_blocker() {
  awk '/^## Blockers/{b=1; next} /^## /{b=0} b && /^- /{l=$0} END{print l}' "$TD/runs/$RUN/notes.md" 2>/dev/null || true
}

# ---- stages -----------------------------------------------------------------------------------

new_record() {
  local role="$1" attempt="$2" last ackseq=0 acked=""
  [ -f "$TD/acked" ] && acked="$(cat "$TD/acked")"
  case "$acked" in "$role-$attempt-"*) ackseq="${acked#"$role-$attempt-"}"; ackseq="${ackseq%.json}" ;; esac
  last="$(team_records "$RUN" "$role" "$attempt" | tail -n 1)"
  [ -n "$last" ] || return 0
  [ "$(rec "$last" seq)" -gt "$ackseq" ] && echo "$last" || true
}

accept() {
  local r="$1"
  end_session "$ROLE"
  team_cancelled && cancel_exit
  touch "$r.accepted"
  rm -f "$TD/session.json"
  echo "accepted: $(basename "$r")"
}

handle_record() {
  local r="$1"
  case "$(rec "$r" verdict)" in
    done) validate_record "$r" || die 4 "record $(basename "$r") rejected — session left alive: tmux attach -t $(sess_name "$ROLE")"
          accept "$r" ;;
    blocked|failed)
      basename "$r" > "$TD/acked"
      echo "$(rec "$r" verdict): $(last_blocker)"
      echo "answer in: tmux attach -t $(sess_name "$ROLE")"
      notify "$(rec "$r" verdict)" "$(last_blocker) — /start-team $TEAM after answering"
      [ "$(rec "$r" verdict)" = blocked ] && exit 2 || exit 1 ;;
    *) die 4 "record $(basename "$r") has an unknown verdict" ;;
  esac
}

input_rev_for() {
  case "$1" in
    planner|cli) team_json base_sha ;;
    coder) rec "$(accepted_record planner)" output_rev ;;
    qa) rec "$(accepted_record coder)" output_rev ;;
    wrapup) rec "$(accepted_record qa)" output_rev ;;
  esac
}

render_prompt() {
  local role="$1" attempt="$2" out="$3" p planner coder qa plan="" spec="" pr="" report=""
  planner="$(accepted_record planner)"; coder="$(accepted_record coder)"; qa="$(accepted_record qa)"
  if [ -n "$planner" ]; then
    spec="$(artifact "$planner" .agents/specs/)"; plan="$(artifact "$planner" .agents/plans/active/)"
  fi
  if { [ "$role" = qa ] || [ "$role" = wrapup ]; } && [ -n "$coder" ]; then
    plan="$(artifact "$coder" .agents/plans/done/)"; pr="$(rec "$coder" pr_id)"
  fi
  [ -z "$qa" ] || report=".agents/team/runs/$RUN/qa-report-$(rec "$qa" attempt).md"
  team_ado_coords
  if [ "$MODE" = quick ] && [ -z "$spec" ]; then spec="none (quick mode)"; fi
  p="$(cat "$CLONE/.claude/team/prompts/$(team_prompt_name "$MODE" "$role")")"
  # Before `put TEAM`: the tracker blocks carry {{TICKET}}/{{RUN}} of their own. An empty tracker
  # field (a team.json written before 2b) renders as jira.
  p="$(team_tracker_render "$(team_json tracker || true)" "$CLONE/.claude/team/tracker" "$p")" \
    || die 4 "cannot render the tracker blocks of the $role prompt"
  put() { local k="{{$1}}"; p="${p//"$k"/$2}"; }
  put TEAM "$TEAM"; put TICKET "$(team_json ticket)"; put BRANCH "$BRANCH"; put LINE "$LINE"
  put BASE_SHA "$(team_json base_sha)"; put RUN "$RUN"; put ATTEMPT "$attempt"
  put PLAN "$plan"; put SPEC "$spec"; put PR "$pr"; put ORG_URL "$ADO_ORG_URL"; put QA_REPORT "$report"
  # Project gates come from the profile; TEST_GATE is a ready sentence, never a raw path.
  put BUILD_CHECK "$TEAM_BUILD_CHECK"; put TEST_GATE "$(team_gate_sentence)"
  printf '%s\n' "$p" > "$out"
}

role_flags() {
  local flags
  if [ "$1" = cli ]; then
    printf -- "--model '%s' --effort '%s' " "$TEAM_CLI_MODEL" "$TEAM_CLI_EFFORT"; return 0
  fi
  flags="$(team_roles_flags "$ROLES" "$ROLES_OVERRIDE" "$1")" || die 1 "$flags"
  printf '%s' "$flags"
}

# Same parse as codex-bg.sh; an unresolvable profile refuses the launch before session.json.
codex_home() {
  local f="$CLONE/.claude/codex-profile" want real=""
  if [ ! -e "$f" ] && [ ! -L "$f" ]; then f="$root/.claude/codex-profile"; fi
  want="$(sed -n '/^[[:space:]]*$/d; /^#/d; p; q' "$f" 2>/dev/null || true)"
  case "$want" in "~/"*) want="$HOME/${want#\~/}" ;; esac
  [ -z "$want" ] || real="$(cd "$want" 2>/dev/null && pwd -P || true)"
  if [ -z "$real" ]; then
    echo "error: Codex profile ${want:-<none>} from .claude/codex-profile does not resolve" \
      "— no session launched"
    return 1
  fi
  printf '%s' "$real"
}

launch() {
  local role="$1" attempt="$2" name pf sid ch ck extra=""
  team_cancelled && cancel_exit
  name="$(sess_name "$role")"; pf="$TD/runs/$RUN/$role-$attempt.prompt.md"
  [ -n "$(input_rev_for "$role")" ] || die 4 "no input revision for $role — previous stage not accepted"
  # Before session.json: a rejected config must not record an attempt (dead_attempt stops at 2).
  extra="$(role_flags "$role")"
  ch="$(codex_home)" || die 1 "$ch"
  mkdir -p "$TD/runs/$RUN"
  # A known session id makes token-usage bindings explicit (TT-821); transcripts are lower-case.
  sid="$(uuidgen | tr 'A-Z' 'a-z')"
  [[ "$sid" =~ ^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$ ]] || die 1 "error: uuidgen gave no UUID"
  # A team.json written before 2b has no cost_key; jq's `//` would keep the empty string.
  ck="$(team_json cost_key)"; [ -n "$ck" ] || ck="$(team_json ticket)"
  jq -n --arg team "$TEAM" --arg role "$role" --arg run "$RUN" --argjson attempt "$attempt" \
    --arg ticket "$(team_json ticket)" --arg input_rev "$(input_rev_for "$role")" \
    --arg launched_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg mode "$MODE" \
    --arg session_id "$sid" --arg cost_key "$ck" \
    '{team: $team, role: $role, run: $run, attempt: $attempt, ticket: $ticket, mode: $mode,
      cost_key: $cost_key,
      input_rev: $input_rev, launched_at: $launched_at, session_id: $session_id}' \
    > "$TD/session.json"
  printf '%s\n' "$sid" > "$TD/runs/$RUN/$role-$attempt.session"
  render_prompt "$role" "$attempt" "$pf"
  attended "$role" || extra="$extra--disallowedTools AskUserQuestion "
  # `--` is required: --disallowedTools is variadic and would swallow the prompt as a tool name.
  # CODEX_HOME per session, never `-g`: that would move other projects onto this licence (TT-912).
  tmux new-session -d -s "$name" -c "$CLONE" -e "TT_TEAM=$TEAM" -e "TT_TEAM_ROLE=$role" \
    -e "TT_TEAM_RUN=$RUN" -e "TT_TEAM_ATTEMPT=$attempt" -e "CODEX_HOME=$ch" \
    "claude --session-id $sid -n $name ${extra}-- \"\$(cat '$pf')\""
  # Main checkout: a clone on an older base has no helper; a missing one only warns.
  bash "$root/.claude/lib/costs/runtime-mark.sh" session --provider claude --session "$sid" \
    --source team-run --name "$name" --ticket "$ck" --team "$TEAM" \
    --role "$role" --run "$RUN" --attempt "$attempt" --cwd "$CLONE" 2>/dev/null \
    || echo "warn: token-usage registration skipped"
  echo "launched: $role attempt $attempt"
  ! attended "$role" || echo "attach: tmux attach -t $name"
  if [ "$ATTACH" = all ] || attended "$role"; then
    # Main checkout: an in-flight clone's attach predates the self-closing window (TT-790).
    bash "$root/.claude/lib/team-attach.sh" "$TEAM" "$role" >/dev/null 2>&1 \
      || echo "warn: no preview window for $name"
  fi
}

dead_attempt() {
  local role="$1" attempt="$2" input tip
  input="$(session_json input_rev)"
  tip="$(git ls-remote origin "refs/heads/$BRANCH" | cut -f1)"
  if [ "$(git rev-parse HEAD)" = "$input" ] && [ -z "$(git status --porcelain)" ] \
    && { [ -z "$tip" ] || [ "$tip" = "$input" ]; } && [ "$attempt" -lt 2 ]; then
    echo "dead attempt $attempt of $role left no trace — retrying"
    launch "$role" $((attempt + 1))
    return 0
  fi
  die 5 "dead attempt $attempt of $role: partial work or retry limit — supervisor"
}

wait_loop() {
  local role="$1" attempt name r start limit seen=0 n
  attempt="$(session_json attempt)"; name="$(sess_name "$role")"; start="$(date +%s)"
  case "$role" in coder|cli) limit=14400 ;; qa) limit=10800 ;; *) limit=0 ;; esac
  while :; do
    team_cancelled && cancel_exit
    r="$(new_record "$role" "$attempt")"
    if [ -n "$r" ]; then handle_record "$r"; return 0; fi
    n=0; [ ! -f "$TD/runs/$RUN/attention" ] || n="$(wc -l < "$TD/runs/$RUN/attention" | tr -d ' ')"
    if [ "$n" -gt "$seen" ]; then
      seen="$n"; echo "needs attention: tmux attach -t $name"
      notify "needs attention" "$role waits for you: bash .claude/lib/team-attach.sh $TEAM $role"
    fi
    if ! team_tmux_alive "$name"; then
      r="$(new_record "$role" "$attempt")"
      if [ -n "$r" ]; then handle_record "$r"; return 0; fi
      dead_attempt "$role" "$attempt"
      attempt="$(session_json attempt)"; start="$(date +%s)"; continue
    fi
    if [ "$limit" -gt 0 ] && [ $(( $(date +%s) - start )) -ge "$limit" ]; then
      die 3 "stalled — attach: tmux attach -t $name"
    fi
    sleep "$POLL"
  done
}

# Recovery: a session.json means its role is the current stage, whatever else is accepted.
resume_stage() {
  local role attempt r
  role="$(session_json role)"; attempt="$(session_json attempt)"; ROLE="$role"
  [ "$(session_json run)" = "$RUN" ] || die 1 "error: session.json run differs from $TD/run"
  if ls "$TD/runs/$RUN/$role-$attempt-"*.json.accepted >/dev/null 2>&1; then
    end_session "$role"; rm -f "$TD/session.json"; return 0
  fi
  if ! team_tmux_alive "$(sess_name "$role")"; then
    r="$(new_record "$role" "$attempt")"
    if [ -n "$r" ]; then handle_record "$r"; return 0; fi
    dead_attempt "$role" "$attempt"
  fi
  wait_loop "$role"
}

next_stage() {
  local role
  for role in $(team_mode_roles "$MODE"); do
    [ -n "$(accepted_record "$role")" ] || { echo "$role"; return 0; }
  done
}

check_orphans() {
  local role
  for role in $(team_mode_roles "$MODE"); do
    [ "$role" = "${1:-}" ] && continue
    ! team_tmux_alive "$(sess_name "$role")" || die 7 "orphan session $(sess_name "$role") — attach or stop"
  done
}

cmd_advance() {
  local stage
  mkdir "$TD/lock" 2>/dev/null || die 1 "runner lock held by pid $(cat "$TD/lock/pid" 2>/dev/null) — check: bash .claude/lib/team-run.sh $TEAM status"
  OWN_LOCK=1; echo $$ > "$TD/lock/pid"
  rm -f "$TD/cancel"
  ! command -v caffeinate >/dev/null 2>&1 || caffeinate -i -w $$ >/dev/null 2>&1 &
  [ -s "$TD/run" ] || echo "$TEAM-$(date -u +%Y%m%d-%H%M%S)" > "$TD/run"
  RUN="$(cat "$TD/run")"
  while :; do
    if [ -f "$TD/session.json" ]; then
      check_orphans "$(session_json role)"; resume_stage; continue
    fi
    check_orphans
    stage="$(next_stage)"
    if [ -z "$stage" ]; then
      echo "ready: bash .claude/lib/team-merge-check.sh $TEAM"
      notify "ready" "PR published — ask the supervisor to merge $TEAM"; exit 0
    fi
    ROLE="$stage"; launch "$stage" 1; wait_loop "$stage"
  done
}

# Per-ticket override, merged over roles.json at each launch; team-next.sh archives it.
cmd_roles() {
  if [ "$MODE" = cli ] && [ "${1:-}" != --clear ]; then
    echo 'error: roles overrides are not supported in mode cli (fixed opus[1m]/medium);' \
      'use roles --clear to remove a stale override' >&2
    exit 1
  fi
  team_roles_write "$TEAM" "$ROLES_OVERRIDE" "$@" || exit "$?"
}

cmd_status() {
  local role r pid
  jq -c '{team, ticket, branch, line, base_sha}' "$TD/team.json"
  echo "mode: $MODE"
  # Durable non-fatal failures (team-warn.sh) — e.g. /start-team 4b `set-status started`.
  jq -r '(.warnings // [])[] | "warn: " + .text + " (" + .at + ")"' "$TD/team.json"
  RUN="$(cat "$TD/run" 2>/dev/null || true)"; echo "run: ${RUN:-none}"
  [ ! -f "$TD/session.json" ] || echo "session:$(jq -c '{role, attempt, input_rev}' "$TD/session.json")"
  [ ! -f "$ROLES_OVERRIDE" ] || echo "roles override: $(team_roles_status "$ROLES_OVERRIDE")"
  for role in $(team_mode_roles "$MODE"); do
    r="$(ls -1t "$TD/runs/${RUN:-none}/$role"-*.json 2>/dev/null | head -n 1)" || true
    [ -z "$r" ] || echo "$role: $(basename "$r") $(rec "$r" verdict)$([ -e "$r.accepted" ] && echo ' accepted')"
    ! team_tmux_alive "$(sess_name "$role")" || echo "tmux: $(sess_name "$role") alive"
  done
  if [ -d "$TD/lock" ]; then
    pid="$(cat "$TD/lock/pid" 2>/dev/null || true)"
    kill -0 "$pid" 2>/dev/null && echo "lock: runner $pid alive" || echo "lock: stale (pid $pid dead) — bash .claude/lib/team-run.sh $TEAM unlock"
  fi
  [ ! -f "$TD/runs/${RUN:-none}/attention" ] || echo "attention: $(tail -n 1 "$TD/runs/$RUN/attention")"
}

cmd_stop() {
  local pid waited=0 role
  touch "$TD/cancel"
  pid="$(cat "$TD/lock/pid" 2>/dev/null || true)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt "$STOP_WAIT" ]; do sleep 1; waited=$((waited + 1)); done
    ! kill -0 "$pid" 2>/dev/null || die 1 "runner $pid did not stop — check: tmux attach -t $TEAM-runner"
  fi
  # cli too: a stop also ends a cli session left behind by a mode mix-up.
  for role in $TEAM_ROLES cli; do end_session "$role"; done
  rm -rf "$TD/lock"
  echo "stopped; session.json kept for the next run"
}

# Read-only sources for /monitor's post-run summary: clone files are outside the supervisor's dirs.
cmd_summary() {
  local r f trk tf title="" url=""
  RUN="$(cat "$TD/run" 2>/dev/null || true)"
  trk="$(team_json tracker)"; [ -n "$trk" ] || trk=jira
  # /monitor never reads clone files, so the ticket title and link travel through here. `jira` has no
  # ticket.json — it keeps reading them over MCP, and both values stay empty.
  tf="$TD/ticket.json"
  if [ -f "$tf" ]; then
    title="$(jq -r '.title // ""' "$tf" 2>/dev/null || true)"
    url="$(jq -r '.url // ""' "$tf" 2>/dev/null || true)"
  fi
  echo "ticket: $(team_json ticket)"; echo "tracker: $trk"
  echo "title: $title"; echo "url: $url"
  echo "mode: $MODE"; echo "branch: $BRANCH"
  echo "run: ${RUN:-none}"
  r="$(accepted_record "$([ "$MODE" = cli ] && echo cli || echo coder)")"
  echo "pr: $([ -z "$r" ] || rec "$r" pr_id)"
  if [ "$MODE" = cli ]; then
    summary_file cli "$(accepted_summary_file cli cli)"
    return 0
  fi
  f="$(accepted_summary_file qa qa-report)"
  echo "--- qa"
  if [ -f "$f" ]; then grep -E '^(Verdict|Warnings|Rethink signals):' "$f" || true
  else echo "missing: qa-report-<n>.md"; fi
  summary_file wrapup "$(accepted_summary_file wrapup wrapup)"
}

accepted_summary_file() {  # <role> <filename stem>
  local r
  r="$(accepted_record "$1")"
  [ -z "$r" ] || echo "$TD/runs/${RUN:-none}/$2-$(rec "$r" attempt).md"
}

summary_file() {  # summary_file <label> <file> — the body without the machine target_rev line
  echo "--- $1"
  if [ -f "$2" ]; then grep -v '^target_rev: ' "$2" || true; else echo "missing: $1-<n>.md"; fi
}

# Deliberate, supervisor-run removal of a dead runner's lock; never automatic, it would race a start.
cmd_unlock() {
  local pid age
  refuse() { echo "$1" >&2; exit 1; }
  [ -d "$TD/lock" ] || refuse "no lock to remove"
  pid="$(cat "$TD/lock/pid" 2>/dev/null || true)"
  [[ "$pid" =~ ^[0-9]+$ ]] || refuse "lock is not stale — no pid recorded (a runner may be starting)"
  ! kill -0 "$pid" 2>/dev/null || refuse "lock is not stale — runner $pid is alive"
  age=$(( $(date +%s) - $(stat -f %m "$TD/lock") ))
  [ "$age" -gt 10 ] || refuse "lock is not stale — created ${age}s ago"
  rm -rf "$TD/lock"
  echo "removed stale lock (pid $pid dead)"
}

# Only the runner whose pid is in the lock removes it — never a replacement lock of another runner.
trap '[ "$OWN_LOCK" = 1 ] && [ "$(cat "$TD/lock/pid" 2>/dev/null)" = "$$" ] && rm -rf "$TD/lock"' EXIT

case "$CMD" in
  advance) [ $# -le 1 ] || die 2 "error: unknown arguments"; cmd_advance ;;
  roles) shift 2; cmd_roles "$@" ;;
  status) cmd_status ;;
  summary) cmd_summary ;;
  stop) cmd_stop ;;
  unlock) cmd_unlock ;;
  check)
    [ $# -eq 3 ] || die 2 "usage: team-run.sh <team> check <record>"
    r="$3"; case "$r" in /*) ;; *) r="$ORIG_PWD/$r" ;; esac
    RUN="$(rec "$r" run)"; ROLE="$(rec "$r" role)"
    validate_record "$r" && echo "valid: $(basename "$r")" || exit 4 ;;
  *) die 2 "error: unknown command $CMD" ;;
esac
