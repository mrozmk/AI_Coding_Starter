#!/usr/bin/env bash
# Registry-driven agent-mail client: every call resolves the project's box and tool from the
# machine registry `$HOME/.agent-mail/projects.json` and ALWAYS passes `--box`, so two projects
# with the same role names on one machine never read each other's mail.
#
# Usage: bash .claude/lib/team-mail.sh <KEY|--here> <subcommand> [args...]
#        bash .claude/lib/team-mail.sh check            validate the whole registry
#   show                 the entry as JSON
#   name <ROLE>          the recipient name: ROLE + the entry's suffix
#   ps                   agent-mail processes bound to THIS box (matched on the box path only)
#   pattern [deliver|wait <RECIPIENT>]   the pgrep -f regex for this box (or one of its loops)
#   deliver <RECIPIENT>  the push loop for a codex recipient (foreground; exports codex_home)
#   check                schema of the whole registry + this entry's tool, box dir, one tool per box;
#                        a `tool behind checkout` line (a warning, exit stays 0) when the entry's
#                        ~/.agent-mail/tools/agent_mail-<sha> copy is older than its repo's vendored tool
#   <agent_mail.py cmd>  forwarded with --box (send/state also get --project <project_label>)
# --here resolves the key from .agents/team/channel.local.json (field `key`), else from the one
# registry entry whose `repo` is this checkout. Schema: .agents/reference/agent-mail.md.
#
# Exit: 0 ok · 1 error / check failed · 2 usage · otherwise the forwarded command's code.
# Bash 3.2 compatible (macOS /bin/bash).
set -euo pipefail

usage() { sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
die() { echo "team-mail: $1" >&2; exit "${2:-1}"; }
command -v jq >/dev/null 2>&1 || die "jq is required"

REG="$HOME/.agent-mail/projects.json"
# The tool runs from shared copies (~/.agent-mail/tools/agent_mail-<sha>, other clients' dirs):
# a __pycache__ written there would make a byte-identical copy look different. `-I` ignores
# PYTHON* variables, so every call also passes `-B`; the export covers the tool's children.
export PYTHONDONTWRITEBYTECODE=1
IDENT='^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$'

# Every schema rule in one jq program, shared by `check` and the entry loader. Prints one
# `problem` line per violation; empty output = valid.
SCHEMA_JQ='
def str: type == "string";
def abs: str and startswith("/");
def ident: str and test($id);
def roles: type == "array" and all(.[]; ident);
if type != "object" then "registry: top level must be a JSON object"
else to_entries[] | .key as $k | .value as $e
  | if ($k | test($id) | not) then "\($k): key is not an identifier"
    elif ($e | type) != "object" then "\($k): entry must be a JSON object"
    else
      (["box","tool","project_label","suffix","repo","decisions_dir","claude_roles","codex_roles"][]
        | select($e[.] == null) | "\($k): missing \(.)"),
      (select($e.box != null and ($e.box | abs and endswith(".sqlite") | not))
        | "\($k): box must be an absolute path to a .sqlite file"),
      (["tool","repo","decisions_dir"][] as $f | select($e[$f] != null and ($e[$f] | abs | not))
        | "\($k): \($f) must be an absolute path"),
      (select($e.project_label != null and ($e.project_label | ident | not))
        | "\($k): project_label is not an identifier"),
      (select($e.suffix != null and ($e.suffix | str and (. == "" or test($id)) | not))
        | "\($k): suffix must be \"\" or an identifier"),
      (["claude_roles","codex_roles"][] as $f | select($e[$f] != null and ($e[$f] | roles | not))
        | "\($k): \($f) must be a list of identifiers"),
      (["rules","codex_home"][] as $f | select($e[$f] != null and ($e[$f] | abs | not))
        | "\($k): \($f) must be null or an absolute path")
    end
end,
( [to_entries[]? | select(.value | type == "object") | {box: .value.box, tool: .value.tool, k: .key}]
  | group_by(.box)[] | select(([.[].tool] | unique | length) > 1)
  | "box \(.[0].box): one tool per box — entries \([.[].k] | join(", ")) name different tools" )
'

schema_problems() { jq -r --arg id "$IDENT" "$SCHEMA_JQ" "$REG"; }

load_registry() {
  [ -f "$REG" ] || die "no registry at $REG (run /setup:teams → channel)"
  jq -e . "$REG" >/dev/null 2>&1 || die "$REG is not valid JSON"
}

resolve_here() {
  local top ch k
  top="$(git rev-parse --show-toplevel 2>/dev/null)" || die "--here: not inside a git checkout"
  top="$(cd "$top" && pwd -P)"
  ch="$top/.agents/team/channel.local.json"
  if [ -f "$ch" ]; then
    k="$(jq -r '.key // empty' "$ch" 2>/dev/null || true)"
    [ -z "$k" ] || { printf '%s' "$k"; return; }
  fi
  # Compare physical paths: the registry may spell the repo through a symlink.
  k="$(jq -r 'to_entries[] | "\(.key)\t\(.value.repo // "")"' "$REG" \
    | while IFS="$(printf '\t')" read -r key repo; do
    [ -n "$repo" ] && [ -d "$repo" ] && [ "$(cd "$repo" && pwd -P)" = "$top" ] && echo "$key"
  done)"
  case "$(printf '%s' "$k" | grep -c . || true)" in
    1) printf '%s' "$k" ;;
    0) die "--here: no registry entry has repo=$top" ;;
    *) die "--here: several entries have repo=$top ($(echo $k)); pass the key" ;;
  esac
}

cfg() {
  jq -r --arg k "$KEY" --arg f "$1" \
    '.[$k][$f] // empty | if type == "array" then join(" ") else . end' "$REG"
}

# The box path as an ERE literal: pgrep -f takes a regex and box paths carry dots and spaces.
box_re() { printf '%s' "$BOX" | sed 's/[][\.*^$+?(){}|]/\\&/g'; }

check_entry() {  # check_entry → prints problems for the selected entry's filesystem side
  [ -f "$TOOL/agent_mail.py" ] || echo "$KEY: tool $TOOL has no agent_mail.py"
  [ -f "$TOOL/agent_mail_deliver.py" ] || echo "$KEY: tool $TOOL has no agent_mail_deliver.py"
  [ -d "$(dirname "$BOX")" ] || echo "$KEY: box directory $(dirname "$BOX") does not exist"
  local dd; dd="$(cfg decisions_dir)"
  [ -d "$dd" ] || echo "$KEY: decisions_dir $dd does not exist"
}

# A copy made by team-mail-setup.sh is named after the vendored tool's commit; when the entry's
# repo has moved on, say so — swapping the tool under a live box is the Operator's call.
tool_behind() {  # tool_behind <key> → the warning line, or nothing
  local k="$1" tool repo old new
  tool="$(jq -r --arg k "$k" '.[$k].tool // empty' "$REG")"
  repo="$(jq -r --arg k "$k" '.[$k].repo // empty' "$REG")"
  [ "$(dirname "$tool")" = "$HOME/.agent-mail/tools" ] || return 0
  old="$(basename "$tool")"; old="${old#agent_mail-}"
  printf '%s' "$old" | grep -Eq '^[0-9a-f]{4,40}$' || return 0
  [ -d "$repo/tools/agent_mail" ] || return 0
  new="$(git -C "$repo" log -1 --format=%h -- tools/agent_mail 2>/dev/null || true)"
  [ -n "$new" ] || return 0
  # Abbreviations grow with the repo: equal when one is a prefix of the other.
  case "$new" in "$old"*) return 0 ;; esac
  case "$old" in "$new"*) return 0 ;; esac
  echo "tool behind checkout ($old → $new) — re-sync is an Operator action:" \
    "bash \"$repo/.claude/lib/team-mail-setup.sh\" \"$repo\" --key $k --resync-tool"
}

report_check() {  # report_check <problems> <ok label> <keys to look for a stale tool copy>
  if [ -n "$1" ]; then printf '%s\n' "$1" | sed 's/^/FAIL /'; exit 1; fi
  echo "OK $2"
  local k; for k in $3; do tool_behind "$k"; done
  exit 0
}

[ $# -ge 1 ] || usage
load_registry

if [ "$1" = check ] && [ $# -eq 1 ]; then
  report_check "$(schema_problems)" "registry $REG ($(jq 'length' "$REG") entries)" \
    "$(jq -r 'keys[]' "$REG")"
fi

KEY="$1"; shift
[ $# -ge 1 ] || usage
SUB="$1"; shift
[ "$KEY" != --here ] || KEY="$(resolve_here)"
printf '%s' "$KEY" | grep -Eq "$IDENT" || die "invalid key '$KEY'" 2
jq -e --arg k "$KEY" 'has($k)' "$REG" >/dev/null || die "unknown project key: $KEY"

PROBLEMS="$(schema_problems | awk -v p="$KEY: " 'index($0, p) == 1')"
BOX="$(cfg box)"; TOOL="$(cfg tool)"; LABEL="$(cfg project_label)"; SUFFIX="$(cfg suffix)"
if [ "$SUB" = check ]; then
  ALL="$(schema_problems)"
  report_check "$(printf '%s\n%s' "$ALL" "$( [ -n "$PROBLEMS" ] || check_entry)" | grep . || true)" \
    "$KEY (box $BOX, tool $TOOL)" "$KEY"
fi
[ -z "$PROBLEMS" ] \
  || die "entry $KEY is invalid: $(printf '%s' "$PROBLEMS" | head -1) (team-mail.sh $KEY check)"

# codex keeps one thread store per CODEX_HOME; `codex queue` must look in the recipient's own.
CH="$(cfg codex_home)"
[ -z "$CH" ] || export CODEX_HOME="$CH"

case "$SUB" in
  show) jq --arg k "$KEY" '.[$k]' "$REG" ;;
  name)
    role="${1:-}"; [ -n "$role" ] || die "name needs a ROLE" 2
    printf '%s' "$role" | grep -Eq "$IDENT" || die "invalid role '$role'" 2
    echo "$role$SUFFIX" ;;
  pattern)
    case "${1:-}" in
      '') box_re; echo ;;
      deliver) [ -n "${2:-}" ] || die "pattern deliver needs a RECIPIENT" 2
               echo "$(box_re) --recipient $2( |\$)" ;;
      wait) [ -n "${2:-}" ] || die "pattern wait needs a RECIPIENT" 2
            echo "$(box_re) wait --for $2( |\$)" ;;
      *) die "pattern: deliver|wait <RECIPIENT>" 2 ;;
    esac ;;
  ps) pgrep -fl -- "$(box_re)" || true ;;
  deliver)
    [ -n "${1:-}" ] || die "deliver needs a RECIPIENT" 2
    r="$1"; shift
    exec python3 -I -B -u "$TOOL/agent_mail_deliver.py" --box "$BOX" --recipient "$r" "$@" ;;
  send) exec python3 -I -B "$TOOL/agent_mail.py" --box "$BOX" send --project "$LABEL" "$@" ;;
  state)
    # --project belongs to the get/set sub-parser, so it goes after the verb.
    [ -n "${1:-}" ] || die "state needs get|set" 2
    v="$1"; shift
    exec python3 -I -B "$TOOL/agent_mail.py" --box "$BOX" state "$v" --project "$LABEL" "$@" ;;
  *) exec python3 -I -B "$TOOL/agent_mail.py" --box "$BOX" "$SUB" "$@" ;;
esac
