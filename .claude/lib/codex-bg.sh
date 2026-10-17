#!/usr/bin/env bash
#
# codex-bg.sh — canonical entry point for spawning `codex exec` as a background
# review from a slash command (/plan-feature, /brainstorm, /codex-review).
#
# WHY THIS WRAPPER EXISTS (do not inline `codex exec` in commands again):
# The recurring "codex exit 0 ≠ codex finished" defect came from spawns that
# drifted between three command files and silently dropped load-bearing flags.
# This wrapper bakes the non-negotiable flags into ONE place so they cannot be
# forgotten when a long session compacts the instructions away.
#
# The two mechanical failure modes it forecloses:
#   1. stdin-hang — `codex exec` reads instructions from stdin when stdin is
#      piped. Backgrounded by the harness, stdin is not a TTY, so without
#      `< /dev/null` codex can block forever waiting for input → looks hung →
#      gets killed before it even starts thinking. `< /dev/null` is universal.
#   2. wrong cwd — codex hangs in a non-trusted dir; always run with `-C <repo>`
#      and `--skip-git-repo-check`.
#
# WHAT IT DOES AND DOES NOT DO:
#   - It REQUIRES CODEX_EFFORT and pins it on the command line — never inherited
#     from $CODEX_HOME/config.toml. Per-caller levels and the rationale:
#     .agents/reference/codex-spawn.md → Effort matrix.
#   - It does NOT poll, heartbeat, or kill. Lifecycle (ScheduleWakeup cadence,
#     HARD_KILL backstop, TaskStop) stays in the command instructions — the
#     wrapper only guarantees a correct spawn. Launch it with the harness'
#     `run_in_background: true`; never append a shell `&`.
#
# CONTRACT (env vars):
#   PROMPT   (required) — the full review prompt string
#   OUT      (required) — path for --output-last-message (the clean result;
#                         non-empty == codex finished. Empty at exit == FAILED)
#   LOG      (required) — path for the noisy run log (grows while codex thinks;
#                         this growth is the liveness signal for heartbeats)
#   REPO     (optional) — repo root for -C; defaults to PWD
#   SCHEMA   (optional) — path to --output-schema JSON (structured reviews:
#                         /plan-feature, /brainstorm). Omit for prose
#                         (/codex-review).
#   SANDBOX  (optional) — sandbox mode; defaults to read-only. NOTE: do NOT
#                         combine read-only with SCHEMA — that combination has
#                         hung in testing. When SCHEMA is set, leave SANDBOX
#                         unset (the prompt enforces read-only instead).
#                         workspace-write is the executor/fixer mode
#                         (/execute codex, /check-implementation codex);
#                         reviewers never set it.
#   CODEX_EFFORT (required) — model_reasoning_effort (low|medium|high|xhigh).
#                         Pinned per caller; see codex-spawn.md → Effort matrix.
#   IMAGES   (optional) — newline-separated image paths attached with `-i`
#                         (visual reviews: /design-ui). `-i` is variadic in
#                         codex-cli, so the wrapper closes the list with `--`;
#                         without it the prompt is swallowed as one more image
#                         path and codex exits "No prompt provided via stdin".
#   CODEX_HOME (required when .claude/codex-profile has a value) — must resolve to the directory declared in
#                         .claude/codex-profile; otherwise exit 2 with OUT empty.
#                         LOG's first line names the profile used (TT-912).
#
# Stdout of codex is empty by design (result goes to OUT); $OUT.stdout captures
# it only so nothing leaks to the terminal.
#
# It also registers the codex thread id (TT-821 token usage) as soon as the log
# header names it; registration never affects the exit code.

set -euo pipefail

: "${OUT:?codex-bg.sh: OUT is required}"

# Truncate OUT before validation and spawning. Every caller treats "OUT non-empty" as the done
# signal (exit 0 alone is not trustworthy — see the header), and codex writes it
# only at the very end. A second run reusing the same OUT path would otherwise
# read the PREVIOUS run's review as this run's result and proceed without one.
: > "$OUT"

: "${PROMPT:?codex-bg.sh: PROMPT is required}"
: "${LOG:?codex-bg.sh: LOG is required}"
: "${CODEX_EFFORT:?codex-bg.sh: CODEX_EFFORT is required (low|medium|high|xhigh) — see .agents/reference/codex-spawn.md → Effort matrix}"
case "$CODEX_EFFORT" in
  low|medium|high|xhigh) ;;
  # A typo would reach the API, fail with an empty OUT and be misread as "codex returned nothing".
  *) echo "codex-bg.sh: CODEX_EFFORT='$CODEX_EFFORT' is not one of low|medium|high|xhigh" >&2; exit 2 ;;
esac

REPO="${REPO:-$PWD}"

if ! command -v codex >/dev/null 2>&1; then
  echo "codex-bg.sh: codex not on PATH — cannot run review" >&2
  exit 127
fi

args=(exec --skip-git-repo-check -C "$REPO" -c "model_reasoning_effort=${CODEX_EFFORT}")

# Sandbox vs schema are mutually exclusive in practice (see contract note).
if [ -n "${SCHEMA:-}" ]; then
  args+=(--output-schema "$SCHEMA")
else
  args+=(--sandbox "${SANDBOX:-read-only}")
fi

args+=(--output-last-message "$OUT")

if [ -n "${IMAGES:-}" ]; then
  while IFS= read -r img; do
    [ -n "$img" ] && args+=(-i "$img")
  done <<< "$IMAGES"
  args+=(--)
fi

# Links the thread to its parent Claude session; a no-op unless $AGENT_COSTS_HOME exists.
register_thread() {
  local tid="" alive
  # Liveness before the read: a codex that exits mid-iteration still gets its log read once more.
  while :; do
    alive=1
    kill -0 "$1" 2>/dev/null || alive=0
    tid="$(sed -n '/^session id: /{s///p;q;}' "$LOG" 2>/dev/null || true)"
    [ -n "$tid" ] && break
    [ "$alive" = 1 ] || break
    sleep 1
  done
  [ -n "$tid" ] || return 0
  bash "$(dirname "$0")/costs/runtime-mark.sh" session --provider codex --session "$tid" \
    --source codex-bg --parent "${CLAUDE_CODE_SESSION_ID:-}" --cwd "$REPO" \
    --team-json "$REPO/.agents/team/session.json" 2>/dev/null || true
}

refuse() {
  printf 'codex-bg.sh: %s\n' "$1" | tee "$LOG" >&2
  exit 2
}

# An inherited environment ran reviews on the private ~/.codex profile (TT-912).
# Located from the wrapper itself: /audit-security passes a REPO outside the checkout.
profile_file="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/codex-profile"
[ -f "$profile_file" ] || refuse "cannot read the Codex profile from $profile_file"
want="$(sed -n '/^[[:space:]]*$/d; /^#/d; p; q' "$profile_file" 2>/dev/null || true)"
# A template profile (comments only — a project without teams) keeps the plain starter behaviour.
if [ -n "$want" ]; then
  case "$want" in "~/"*) want="$HOME/${want#\~/}" ;; esac
  want_real="$(cd "$want" 2>/dev/null && pwd -P || true)"
  [ -n "$want_real" ] || refuse "declared Codex profile $want does not exist"
  [ -n "${CODEX_HOME:-}" ] \
    || refuse "CODEX_HOME is not set — export CODEX_HOME=$want (declared in .claude/codex-profile)"
  have_real="$(cd "$CODEX_HOME" 2>/dev/null && pwd -P || true)"
  [ -n "$have_real" ] && [ "$have_real" = "$want_real" ] \
    || refuse "CODEX_HOME=$CODEX_HOME is not the project profile $want"
else
  have_real="${CODEX_HOME:-default}"
fi

# Truncated before either process starts: a reused LOG must not expose an old thread header.
printf 'codex-bg.sh: CODEX_HOME=%s\n' "$have_real" > "$LOG"
# `< /dev/null` is the load-bearing stdin guard — never remove it.
codex "${args[@]}" "$PROMPT" < /dev/null > "${OUT}.stdout" 2>> "$LOG" &
pid=$!
# Killing the wrapper (HARD_KILL → TaskStop) must not orphan codex.
trap 'kill "$pid" 2>/dev/null' TERM INT
register_thread "$pid" >/dev/null 2>&1 &
rc=0; wait "$pid" || rc=$?
exit "$rc"
