#!/usr/bin/env bash
# Prompt replay — a frozen corpus of past prompts and a harness that replays it through a guard +
# tier implementation (measures only; never changes a decision). Contract: the #321 spec.
#
# Usage: bash .claude/lib/prompt-replay.sh build --sources <sources.json> --out <new dir>
#        bash .claude/lib/prompt-replay.sh verify --corpus <dir> [--require-complete]
#        bash .claude/lib/prompt-replay.sh sheet --corpus <dir>        (rewrites labelling-sheet.csv)
#        bash .claude/lib/prompt-replay.sh run --corpus <dir> --impl <root> [--impl <root2>]
#            [--labels <intervention,label csv>] [--layer touched|replay|all] [--ctx <ctx>]
#            [--changes-out <file>]
#   build reads every source read-only, once, masks every input through touches.py and writes
#   touched.jsonl, replay.jsonl.gz, policy.json, labelling-sheet.csv and manifest.json.
#   run verifies the hashes first; with two roots it lists decision and outcome changes.
#
# Exit: 0 ok · 1 runtime (a worker failed) · 2 usage · 3 refused (hash or coverage).
set -u

LIB="$(cd "$(dirname "$0")" && pwd)"
usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
[ $# -gt 0 ] || usage
case "$1" in -h|--help) usage ;; esac
command -v python3 >/dev/null 2>&1 || { echo "error: python3 not found" >&2; exit 2; }
exec python3 -I "$LIB/prompt_replay.py" "$@"
