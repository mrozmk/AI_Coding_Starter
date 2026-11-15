#!/usr/bin/env bash
# Local env runner (opt-in kit) — the settings rule matches this path. Logic and limits:
# local_env.py; contract: .agents/reference/local-env-runner.md. Off unless workflow.local_env is true
# and .claude/local-env.json reached origin/<Trunk>.
set +x
set -uo pipefail
if [ -n "${BASH_ENV:-}" ] || [ -n "${ENV:-}" ]; then
  echo "with-local-env: BASH_ENV/ENV is set in the caller — refused" >&2
  exit 64
fi
exec python3 -I -B "$(dirname "${BASH_SOURCE[0]}")/local_env.py" "$@"
