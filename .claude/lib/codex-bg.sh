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
# WHAT IT DELIBERATELY DOES NOT DO:
#   - It does NOT force a reasoning effort. With no CODEX_EFFORT set, codex
#     inherits the user's ~/.codex/config.toml default (xhigh) — by design:
#     a review wants full model power. The killer was never xhigh; it was a
#     too-low HARD_KILL ceiling murdering a slow-but-alive process. That ceiling
#     lives in the command's polling loop, NOT here. Set CODEX_EFFORT only to
#     override for a specific run.
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
#   CODEX_EFFORT (optional) — model_reasoning_effort override (low|medium|high|
#                         xhigh). Unset == inherit config default (xhigh).
#
# Stdout of codex is empty by design (result goes to OUT); $OUT.stdout captures
# it only so nothing leaks to the terminal.

set -euo pipefail

: "${PROMPT:?codex-bg.sh: PROMPT is required}"
: "${OUT:?codex-bg.sh: OUT is required}"
: "${LOG:?codex-bg.sh: LOG is required}"

REPO="${REPO:-$PWD}"

if ! command -v codex >/dev/null 2>&1; then
  echo "codex-bg.sh: codex not on PATH — cannot run review" >&2
  exit 127
fi

args=(exec --skip-git-repo-check -C "$REPO")

# Reasoning: inherit config default (xhigh) unless explicitly overridden.
if [ -n "${CODEX_EFFORT:-}" ]; then
  args+=(-c "model_reasoning_effort=${CODEX_EFFORT}")
fi

# Sandbox vs schema are mutually exclusive in practice (see contract note).
if [ -n "${SCHEMA:-}" ]; then
  args+=(--output-schema "$SCHEMA")
else
  args+=(--sandbox "${SANDBOX:-read-only}")
fi

args+=(--output-last-message "$OUT")

# `< /dev/null` is the load-bearing stdin guard — never remove it.
codex "${args[@]}" "$PROMPT" < /dev/null > "${OUT}.stdout" 2> "$LOG"
