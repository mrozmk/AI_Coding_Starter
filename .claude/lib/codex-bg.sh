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
#     from ~/.codex/config.toml. Per-caller levels and the rationale:
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
#
# Stdout of codex is empty by design (result goes to OUT); $OUT.stdout captures
# it only so nothing leaks to the terminal.

set -euo pipefail

: "${PROMPT:?codex-bg.sh: PROMPT is required}"
: "${OUT:?codex-bg.sh: OUT is required}"
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

# Truncate OUT before spawning. Every caller treats "OUT non-empty" as the done
# signal (exit 0 alone is not trustworthy — see the header), and codex writes it
# only at the very end. A second run reusing the same OUT path would otherwise
# read the PREVIOUS run's review as this run's result and proceed without one.
: > "$OUT"

# `< /dev/null` is the load-bearing stdin guard — never remove it.
codex "${args[@]}" "$PROMPT" < /dev/null > "${OUT}.stdout" 2> "$LOG"
