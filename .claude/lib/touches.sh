#!/usr/bin/env bash
# Operator touch log — one JSON line per human intervention, per project and machine, in
# <main checkout>/.agents/touches/<yyyy-mm>.jsonl (git-ignored). Contract:
# .agents/reference/operator-touches.md
#
# Usage: bash .claude/lib/touches.sh add --kind K --what W --reason R [--answer A] [--wait-s N]
#            [--where W] [--main DIR] [--relayed-by ROLE --relayed-session ID]
#        bash .claude/lib/touches.sh report [--since D|<n>d] [--who U] [--reason R] [--main DIR]
#        bash .claude/lib/touches.sh report --brief --team T --ticket K --run RUN [--main DIR]
#        bash .claude/lib/touches.sh block --source HOOK --what TEXT [--main DIR]   (a hook refused)
#        bash .claude/lib/touches.sh hook [--global]      (Notification hook; stdin = the payload)
#   kinds:   question permission plan text decision restart other   (block: written only by block)
#   reasons: human-only no-rule lead-unsure channel-failed guard direct   (hook: only by block)
#   e.g. bash .claude/lib/touches.sh add --kind restart --reason direct --what "restarted the runner"
#
# Exit: add 0 written · 1 main checkout unknown / unsafe target · 2 usage;
#       report 0 (skipped lines named on stderr) · 1 main checkout unknown · 2 usage;
#       block and hook always 0 and silent.
set -u

LIB="$(cd "$(dirname "$0")" && pwd)"
usage() { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
[ $# -gt 0 ] || usage
case "$1" in -h|--help) usage ;; esac
# block: a refusing hook's fire-and-forget record — never an exit code or output of its own.
if [ "$1" = block ]; then python3 -I "$LIB/touches.py" "$@" >/dev/null 2>&1; exit 0; fi
command -v python3 >/dev/null 2>&1 || { echo "error: python3 not found" >&2; exit 2; }
exec python3 -I "$LIB/touches.py" "$@"
