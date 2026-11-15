#!/usr/bin/env bash
# Guarded deployment-script run (opt-in kit) — the settings `ask` rule matches this path. Logic and limits:
# guarded_write.py; contract: .agents/reference/guarded-writes.md.
exec python3 -I -B "$(dirname "$0")/guarded_write.py" ops "$@"
