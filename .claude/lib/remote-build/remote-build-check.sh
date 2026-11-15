#!/usr/bin/env bash
# Remote build check (opt-in kit) — wire it as teams.build_check. Logic and limits: remote_build.py;
# contract: .agents/reference/remote-build.md. Off unless workflow.remote_build is true and
# .claude/remote-build.json reached origin/<Trunk>. Never runs the command locally.
exec python3 -I -B "$(dirname "${BASH_SOURCE[0]}")/remote_build.py" "$@"
