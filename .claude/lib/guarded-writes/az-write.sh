#!/usr/bin/env bash
# Guarded az write (opt-in kit) — the settings `ask` rule matches this path. Logic and limits:
# guarded_write.py; contract: .agents/reference/guarded-writes.md. Off unless workflow.guarded_writes
# is true and the config reached origin/<Trunk>.
exec python3 -I -B "$(dirname "$0")/guarded_write.py" az "$@"
