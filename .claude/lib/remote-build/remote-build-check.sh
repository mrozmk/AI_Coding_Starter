#!/usr/bin/env bash
# Remote build check (opt-in kit) — wire it as teams.build_check. Logic and limits: remote_build.py;
# contract: .agents/reference/remote-build.md. Off unless workflow.remote_build is true and
# .claude/remote-build.json reached origin/<Trunk>. Never runs the command locally.
# No exec: this process stays, so a worker's probe sees `remote-build-check.sh` while the check runs.
python3 -I -B "$(dirname "${BASH_SOURCE[0]}")/remote_build.py" "$@" &
child=$!
trap 'kill -TERM "$child" 2>/dev/null' TERM INT HUP
while :; do
  wait "$child"; rc=$?
  kill -0 "$child" 2>/dev/null || exit "$rc"
done
