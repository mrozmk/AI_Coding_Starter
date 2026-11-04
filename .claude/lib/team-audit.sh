#!/usr/bin/env bash
# Process audit of a team run: material for later review, never a gate.
#
# Usage: bash .claude/lib/team-audit.sh <team> [--runner-exit N] [--final ready|archived]
#   writes <main>/.agents/team/audit/<YYYYMMDD>-<team>-<ticket>-<run>.{md,json} + index.jsonl,
#   and launches a detached report-only retro (tmux retro-<run>) when the run turns final flagged
#   or sampled (.claude/team/audit.json)
#   internal: bash .claude/lib/team-audit.sh retro-run <team> <run>   (inside retro-<run>)
#   e.g. bash .claude/lib/team-audit.sh alfa --final archived
#
# Env: TEAM_AUDIT_PR_SECS (5) — time box of the PR title lookup.
# Exit: 0 written (or no run) · 1 error — callers print one warning and keep their own outcome.
set -euo pipefail

# The script's own location, not git: the runner's EXIT trap runs with cwd = the clone.
root="$(cd "$(dirname "$0")/../.." && pwd)"
AUDITOR="$root/.claude/lib/team_audit.py"
OUT="$root/.agents/team/audit"
CONFIG="$root/.claude/team/audit.json"
. "$root/.claude/lib/team-lib.sh"
. "$root/.claude/lib/team-modes.sh"

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }
mark_retro() { python3 -I "$AUDITOR" mark-retro --out "$OUT" --run "$RUN" --value "$1" >/dev/null; }

clone_paths() {
  CLONE="$(team_clone_dir "$TEAM" "$root")"
  TD="$CLONE/.agents/team"
  [ -f "$TD/team.json" ] || { echo "error: no team clone at $CLONE" >&2; exit 1; }
}

transcript_args() {
  local f name sid phys
  phys="$(cd "$CLONE" && pwd -P)"
  shopt -s nullglob
  for f in "$TD/runs/$RUN"/*.session; do
    name="$(basename "$f" .session)"; sid="$(head -n 1 "$f")"
    TRANSCRIPTS+=(--transcript "$name=$(team_role_transcript "$phys" "$sid")")
  done
  shopt -u nullglob
}

auditor() {  # auditor [--title T] → the auditor's stdout
  python3 -I "$AUDITOR" audit --team-dir "$TD" --clone "$CLONE" --run "$RUN" --out "$OUT" \
    --config "$CONFIG" --roles "$ROLES" ${EXTRA[@]+"${EXTRA[@]}"} \
    ${TRANSCRIPTS[@]+"${TRANSCRIPTS[@]}"} "$@"
}

# Off the critical path: the audit is already written; a hung az only costs the time box.
pr_title() {  # pr_title <pr> → title or nothing
  local tmp t=""
  tmp="$(mktemp)"
  if (cd "$CLONE" && team_ado_coords >/dev/null 2>&1 \
      && pr_timebox "${TEAM_AUDIT_PR_SECS:-5}" az repos pr show --org "$ADO_ORG_URL" --id "$1" \
        --query title -o tsv) > "$tmp" 2>/dev/null; then
    t="$(head -n 1 "$tmp")"
  fi
  rm -f "$tmp"
  printf '%s' "$t"
}

launch_retro() {
  local s="retro-$RUN"
  if team_tmux_alive "$s"; then mark_retro "skipped: running"; return 0; fi
  # Marked before the launch, so a fast retro's own `done` is never overwritten.
  mark_retro "launched $(utc)"
  tmux new-session -d -s "$s" -c "$root" \
    "bash '$root/.claude/lib/team-audit.sh' retro-run '$TEAM' '$RUN'" 2>/dev/null \
    || { mark_retro "failed: tmux"; echo "warn: retro not launched" >&2; }
}

cmd_audit() {
  local first pr title
  clone_paths
  [ -s "$TD/run" ] || { echo "audit: no run"; exit 0; }
  RUN="$(cat "$TD/run")"
  ROLES="$(team_mode_roles "$(team_mode "$TD/team.json")")"
  mkdir -p "$OUT"
  transcript_args
  first="$(auditor)"
  pr="$(sed -n 's/^pr: //p' <<<"$first")"
  if [ -n "$pr" ] && [ "$pr" != - ]; then
    title="$(pr_title "$pr")"
    [ -z "$title" ] || auditor --title "$title" >/dev/null
  fi
  grep '^audit: ' <<<"$first"
  case "$(sed -n 's/^retro: //p' <<<"$first")" in due*) launch_retro ;; esac
}

# Tools are removed, not just left unlisted: dontAsk still honours the main checkout's settings
# allow list (bare Write, Bash(sed *), …), so only --disallowedTools keeps the retro read-only.
run_claude() {  # run_claude <prompt> — the one claude call; the test stubs claude on PATH
  pr_timebox "$((MAX_MIN * 60))" claude -p --model "$MODEL" --effort "$EFFORT" \
    --permission-mode dontAsk --allowedTools Read Grep Glob \
    --disallowedTools Write Edit NotebookEdit Bash Agent "mcp__*" \
    -- "$1"
}

# /retro Step 2's extractor, run here so the retro session needs no Write or Bash.
retro_metrics() {  # retro_metrics <dir> <doc> → one "- <role> attempt <n>: …" line per transcript
  local x="$1/retro-extract.py" role att path rc
  awk '/^### Step 2/ {s = 1} s && /^```python/ {p = 1; next} p && /^```/ {exit} p' \
    "$root/.claude/commands/retro.md" > "$x"
  [ -s "$x" ] || { echo "error: no Step 2 extractor in retro.md" >&2; return 1; }
  while IFS=$'\t' read -r role att path; do
    if [ ! -f "$path" ]; then
      echo "- $role attempt $att: $path — metrics: none (transcript missing)"; continue
    fi
    rc=0; python3 -I "$x" "$path" > "$1/$role-$att.json" 2>/dev/null || rc=$?
    if [ "$rc" = 0 ]; then echo "- $role attempt $att: $path — metrics: $1/$role-$att.json"
    else echo "- $role attempt $att: $path — metrics: none (extractor rc $rc)"; fi
  done < <(jq -r '.transcripts[] | [.role, .attempt, .path] | @tsv' "$2")
}

cmd_retro_run() {
  local md doc base p list rc=0
  md="$(jq -r --arg r "$RUN" 'select(.run == $r) | .audit' "$OUT/index.jsonl" | tail -n 1)"
  [ -n "$md" ] || { echo "error: run $RUN not in $OUT/index.jsonl" >&2; exit 1; }
  base="${md%.md}"; doc="$base.json"
  MODEL="$(jq -r '.retro_cfg.model' "$doc")"; EFFORT="$(jq -r '.retro_cfg.effort' "$doc")"
  MAX_MIN="$(jq -r '.retro_cfg.max_minutes' "$doc")"
  [[ "$MAX_MIN" =~ ^[1-9][0-9]*$ ]] \
    || { mark_retro "failed: max_minutes $MAX_MIN"; echo "error: retro max_minutes" >&2; exit 1; }
  TMPD="$(mktemp -d "${TMPDIR:-/tmp}/retro-$RUN.XXXXXX")"
  trap 'rm -rf "$TMPD"' EXIT
  list="$(retro_metrics "$TMPD" "$doc")" || { mark_retro "failed: extractor"; exit 1; }
  p="$(cat "$root/.claude/team/prompts/retro-run.md")"
  put() { local k="{{$1}}"; p="${p//"$k"/$2}"; }
  put RUN "$RUN"; put TICKET "$(jq -r '.header.ticket' "$doc")"; put AUDIT "$md"
  put TRANSCRIPTS "$list"
  run_claude "$p" > "$base.retro.md" 2> "$base.retro.log" || rc=$?
  if [ "$rc" = 0 ]; then mark_retro "done $(utc)"; else mark_retro "failed: rc $rc"; fi
}

[ $# -ge 1 ] || usage
if [ "$1" = retro-run ]; then
  [ $# -eq 3 ] || usage
  TEAM="$2"; RUN="$3"; cmd_retro_run; exit 0
fi
TEAM="$1"; shift
EXTRA=(); TRANSCRIPTS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --runner-exit) [[ "${2:-}" =~ ^[0-9]+$ ]] || usage; EXTRA+=(--runner-exit "$2"); shift 2 ;;
    --final) case "${2:-}" in ready|archived) ;; *) usage ;; esac; EXTRA+=(--final "$2"); shift 2 ;;
    *) usage ;;
  esac
done
cmd_audit
