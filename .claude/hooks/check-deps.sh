#!/bin/bash
# SessionStart hook — environment preflight.
#
# Verifies the system tools the workflow's HOOKS rely on. Prints a warning ONLY
# when something is missing; stays silent (and cheap) on a healthy machine. The
# other hooks (guard-memory, track-memory-read, audit-append) fail OPEN without
# `jq` — i.e. they silently do nothing — so a missing `jq` is otherwise invisible.
# This hook turns that silent no-op into one loud, early signal.
#
# Why NOT check `rg`: Claude Code ships its own ripgrep and exposes `rg` via a
# shell-function wrapper, so `rg` works inside Claude Code even with no system
# `rg` binary on PATH. A `command -v rg` here runs in a non-interactive subshell
# that lacks that function and would FALSE-POSITIVE on most machines. No hook
# uses rg anyway (they use jq/git/grep). So rg is intentionally out of scope.
#
# Mechanics (Claude Code hooks): stdin carries the SessionStart JSON; we don't
# need it. stdout from a SessionStart hook is injected into the session context,
# so Claude sees this warning and relays it to the user.
#
# MUST NOT itself depend on jq — it is one of the tools being checked. Pure
# `command -v`. Always exit 0: a preflight check must never block a session.

cat >/dev/null 2>&1   # drain stdin; the payload is not needed

missing=""
for dep in jq git; do
  command -v "$dep" >/dev/null 2>&1 || missing="$missing $dep"
done

[ -z "$missing" ] && exit 0   # all required tools present → silent, no noise

# Package names match the binary names for both brew and apt (jq → jq, git → git),
# so $missing doubles as the install list.
echo "⚠️  Workflow preflight: missing required tool(s) on PATH:$missing"
echo "   Impact:"
case "$missing" in *jq*)  echo "   - jq: memory-distillation guard, audit log and read telemetry silently no-op (those hooks fail open)." ;; esac
case "$missing" in *git*) echo "   - git: /commit, /push, /pull, /release and every git-based hook are unavailable." ;; esac
echo "   Install — macOS: brew install$missing · Debian/Ubuntu: sudo apt install$missing · then restart the session."
exit 0
