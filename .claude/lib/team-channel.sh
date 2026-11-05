#!/usr/bin/env bash
# The team channel config: the ONE read of the agent-mail channel between the supervision roles,
# for every script, hook and kit file that talks to it. Two halves, never mixed:
#   committed  .claude/project-profile.json → teams.channel   names and policy (the whole team)
#   local      .agents/team/channel.local.json                 machine paths (/setup:teams → channel)
# The local half is a cache of the machine registry entry ($HOME/.agent-mail/projects.json): a
# box, tool or suffix that no longer matches the entry is refused as stale, never guessed.
#
# Sourced:  . .claude/lib/team-channel.sh; team_channel_load [root]
#   root defaults to the checkout's toplevel. Returns 3 with one `error:` line on stderr when the
#   channel is not configured or does not validate (under `set -e` the caller exits 3). Values are
#   read with `jq -r` only; neither file is ever `eval`ed.
# Executed: bash .claude/lib/team-channel.sh <sub> [args]   (from inside the checkout)
#   show                    every exported variable, one NAME=value per line
#   get <field>             one value: project_code mail_suffix tmux_prefix advisor notifier key box
#                           tool tool_sha decisions_dir codex_home kit_dir
#   name <ROLE>             the recipient name: ROLE + mail_suffix
#   turn <FROM> <TO> [args] a wake-up (`--kind turn --awaiting <TO>`) from one role to another
#                           through team-mail.sh; args go to `send` (--body/--body-file, --thread…)
#   render [--dry-run]      .agents/team/{watch,escalation}.local.json from .claude/team/*.tmpl
# Exports (team_channel_load):
#   TEAM_CHANNEL_ROOT        the checkout the config was read from
#   TEAM_CHANNEL_CODE        teams.channel.project_code (required)
#   TEAM_CHANNEL_SUFFIX      teams.channel.mail_suffix (default "")
#   TEAM_CHANNEL_TMUX_PREFIX teams.channel.tmux_prefix (default: the repo dir slug)
#   TEAM_CHANNEL_ADVISOR     pair | solo (default: pair when the profile's codex is true, else solo)
#   TEAM_CHANNEL_NOTIFIER    osascript | notify-send | none (default none)
#   TEAM_CHANNEL_KEY TEAM_CHANNEL_BOX TEAM_CHANNEL_TOOL TEAM_CHANNEL_TOOL_SHA
#   TEAM_CHANNEL_DECISIONS TEAM_CHANNEL_CODEX_HOME TEAM_CHANNEL_KIT   the local half (sha and
#                            codex_home may be empty)
#   TEAM_CHANNEL_SUPERVISOR TEAM_CHANNEL_TEAMLEAD TEAM_CHANNEL_ADVISOR_NAME TEAM_CHANNEL_REVIEWER
#                            the four recipient names (role + suffix); a mail filter uses these,
#                            never a literal name
# Exit (executed): 0 ok · 2 usage · 3 channel not configured / invalid · else the forwarded code.
# Bash 3.2 compatible (macOS /bin/bash).

TEAM_CHANNEL_REL=".agents/team/channel.local.json"
TEAM_CHANNEL_IDENT='^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$'

team_channel_err() { echo "error: team channel: $*" >&2; return 3; }

# team_channel_load [root] — parse + validate both halves once per process.
team_channel_load() {
  [ -z "${TEAM_CHANNEL_LOADED:-}" ] || return 0
  local root p ch reg v e codex dc
  root="${1:-$(git rev-parse --show-toplevel 2>/dev/null || true)}"
  [ -n "$root" ] || { team_channel_err "not inside a git checkout"; return 3; }
  p="$root/.claude/project-profile.json"; ch="$root/$TEAM_CHANNEL_REL"
  reg="$HOME/.agent-mail/projects.json"

  jq -e '.teams.channel | type == "object"' "$p" >/dev/null 2>&1 || {
    team_channel_err "not configured — no teams.channel in .claude/project-profile.json" \
      "(run /setup:teams → channel)"; return 3; }
  _tc_pc() { jq -r --arg f "$1" '.teams.channel[$f] // empty | tostring' "$p" 2>/dev/null || true; }
  TEAM_CHANNEL_CODE="$(_tc_pc project_code)"
  [[ "$TEAM_CHANNEL_CODE" =~ $TEAM_CHANNEL_IDENT ]] || {
    team_channel_err "teams.channel.project_code=${TEAM_CHANNEL_CODE:-<missing>} is not an identifier"
    return 3; }
  TEAM_CHANNEL_SUFFIX="$(_tc_pc mail_suffix)"
  [ -z "$TEAM_CHANNEL_SUFFIX" ] || [[ "$TEAM_CHANNEL_SUFFIX" =~ $TEAM_CHANNEL_IDENT ]] || {
    team_channel_err "teams.channel.mail_suffix=$TEAM_CHANNEL_SUFFIX is not an identifier"; return 3; }
  TEAM_CHANNEL_TMUX_PREFIX="$(_tc_pc tmux_prefix)"
  if [ -z "$TEAM_CHANNEL_TMUX_PREFIX" ]; then
    TEAM_CHANNEL_TMUX_PREFIX="$(basename "$root" | tr '[:upper:]' '[:lower:]' \
      | sed 's/[^a-z0-9_-]/-/g; s/^[^a-z0-9]*//')"
  fi
  # tmux treats `.` and `:` in a target as window/pane separators.
  [[ "$TEAM_CHANNEL_TMUX_PREFIX" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$ ]] || {
    team_channel_err "teams.channel.tmux_prefix=$TEAM_CHANNEL_TMUX_PREFIX must match [A-Za-z0-9][A-Za-z0-9_-]{0,31}"
    return 3; }
  TEAM_CHANNEL_ADVISOR="$(_tc_pc advisor)"
  if [ -z "$TEAM_CHANNEL_ADVISOR" ]; then
    codex="$(jq -r '.codex // false | tostring' "$p" 2>/dev/null || true)"
    if [ "$codex" = true ]; then TEAM_CHANNEL_ADVISOR=pair; else TEAM_CHANNEL_ADVISOR=solo; fi
  fi
  case "$TEAM_CHANNEL_ADVISOR" in pair|solo) ;; *)
    team_channel_err "teams.channel.advisor=$TEAM_CHANNEL_ADVISOR must be pair|solo"; return 3 ;; esac
  TEAM_CHANNEL_NOTIFIER="$(_tc_pc notifier)"; TEAM_CHANNEL_NOTIFIER="${TEAM_CHANNEL_NOTIFIER:-none}"
  case "$TEAM_CHANNEL_NOTIFIER" in osascript|notify-send|none) ;; *)
    team_channel_err "teams.channel.notifier=$TEAM_CHANNEL_NOTIFIER must be osascript|notify-send|none"
    return 3 ;; esac

  [ -f "$ch" ] || { team_channel_err "not configured — no $TEAM_CHANNEL_REL (run /setup:teams → channel)"
    return 3; }
  jq -e 'type == "object"' "$ch" >/dev/null 2>&1 || {
    team_channel_err "$TEAM_CHANNEL_REL is not a JSON object"; return 3; }
  _tc_lc() { jq -r --arg f "$1" '.[$f] // empty | strings' "$ch" 2>/dev/null || true; }
  TEAM_CHANNEL_KEY="$(_tc_lc key)"
  [[ "$TEAM_CHANNEL_KEY" =~ $TEAM_CHANNEL_IDENT ]] || {
    team_channel_err "$TEAM_CHANNEL_REL: key=${TEAM_CHANNEL_KEY:-<missing>} is not an identifier"
    return 3; }
  TEAM_CHANNEL_BOX="$(_tc_lc box)"; TEAM_CHANNEL_TOOL="$(_tc_lc tool)"; TEAM_CHANNEL_TOOL_SHA="$(_tc_lc tool_sha)"
  TEAM_CHANNEL_DECISIONS="$(_tc_lc decisions_dir)"; TEAM_CHANNEL_CODEX_HOME="$(_tc_lc codex_home)"
  TEAM_CHANNEL_KIT="$(_tc_lc kit_dir)"
  for v in box:"$TEAM_CHANNEL_BOX" tool:"$TEAM_CHANNEL_TOOL" decisions_dir:"$TEAM_CHANNEL_DECISIONS" \
    kit_dir:"$TEAM_CHANNEL_KIT"; do
    case "${v#*:}" in /*) ;; *)
      team_channel_err "$TEAM_CHANNEL_REL: ${v%%:*} must be an absolute path"; return 3 ;; esac
  done
  case "$TEAM_CHANNEL_CODEX_HOME" in ''|/*) ;; *)
    team_channel_err "$TEAM_CHANNEL_REL: codex_home must be null or an absolute path"; return 3 ;; esac

  # The local half must still be what the registry says: a re-pointed tool or another box behind
  # the same key means /setup:teams → channel has to run again.
  jq -e . "$reg" >/dev/null 2>&1 || {
    team_channel_err "no readable registry at $reg (run /setup:teams → channel)"; return 3; }
  e="$(jq -r --arg k "$TEAM_CHANNEL_KEY" \
    'if has($k) then [.[$k].box, .[$k].tool, .[$k].suffix] | map(. // "") | join("\t") else "" end' \
    "$reg" 2>/dev/null || true)"
  [ -n "$e" ] || { team_channel_err "registry $reg has no entry $TEAM_CHANNEL_KEY (run /setup:teams → channel)"
    return 3; }
  if [ "${e%	*}" != "$TEAM_CHANNEL_BOX	$TEAM_CHANNEL_TOOL" ]; then
    team_channel_err "$TEAM_CHANNEL_REL is stale against registry entry $TEAM_CHANNEL_KEY" \
      "(box or tool differ; rerun /setup:teams → channel)"
    return 3
  fi
  # The decisions directory and the Codex home are read from the local half too (operator-ref
  # checks, the Reviewer's CODEX_HOME): a moved entry must not leave them pointing at the old ones.
  dc="$(jq -r --arg k "$TEAM_CHANNEL_KEY" \
    '[.[$k].decisions_dir, .[$k].codex_home] | map(. // "") | join("\t")' "$reg" 2>/dev/null || true)"
  if [ "$dc" != "$TEAM_CHANNEL_DECISIONS	$TEAM_CHANNEL_CODEX_HOME" ]; then
    team_channel_err "$TEAM_CHANNEL_REL is stale against registry entry $TEAM_CHANNEL_KEY" \
      "(decisions_dir or codex_home differ; rerun /setup:teams → channel)"
    return 3
  fi
  if [ "${e##*	}" != "$TEAM_CHANNEL_SUFFIX" ]; then
    team_channel_err "teams.channel.mail_suffix=$TEAM_CHANNEL_SUFFIX but registry entry" \
      "$TEAM_CHANNEL_KEY has suffix ${e##*	} — the recipient names would not match; align the two"
    return 3
  fi

  TEAM_CHANNEL_ROOT="$root"
  TEAM_CHANNEL_SUPERVISOR="Supervisor$TEAM_CHANNEL_SUFFIX"
  TEAM_CHANNEL_TEAMLEAD="TeamLead$TEAM_CHANNEL_SUFFIX"
  TEAM_CHANNEL_ADVISOR_NAME="Advisor$TEAM_CHANNEL_SUFFIX"
  TEAM_CHANNEL_REVIEWER="Reviewer$TEAM_CHANNEL_SUFFIX"
  export TEAM_CHANNEL_ROOT TEAM_CHANNEL_CODE TEAM_CHANNEL_SUFFIX TEAM_CHANNEL_TMUX_PREFIX \
    TEAM_CHANNEL_ADVISOR TEAM_CHANNEL_NOTIFIER TEAM_CHANNEL_KEY TEAM_CHANNEL_BOX TEAM_CHANNEL_TOOL \
    TEAM_CHANNEL_TOOL_SHA TEAM_CHANNEL_DECISIONS TEAM_CHANNEL_CODEX_HOME TEAM_CHANNEL_KIT \
    TEAM_CHANNEL_SUPERVISOR TEAM_CHANNEL_TEAMLEAD TEAM_CHANNEL_ADVISOR_NAME TEAM_CHANNEL_REVIEWER
  TEAM_CHANNEL_LOADED=1
}

# team_channel_role <ROLE> — refuses anything but the four canonical roles (rc 2).
team_channel_role() {
  case "$1" in Supervisor|TeamLead|Advisor|Reviewer) printf '%s%s' "$1" "$TEAM_CHANNEL_SUFFIX" ;;
    *) echo "error: team channel: role $1 must be Supervisor|TeamLead|Advisor|Reviewer" >&2; return 2 ;;
  esac
}

# The agent-mail runtime files a tool copy holds, and the name of a copy: a 12-hex hash of their
# names and bytes. Content, not a commit: an uncommitted install gets a stable name, and two
# checkouts with the same tool share one copy. Used by team-mail-setup.sh (copy) and team-mail.sh
# (check). Exit 1 when a runtime file is missing.
# ensure_mail_home — the machine's mail home, mode 0700 whether it is created now or was created
# earlier by something with a wider umask: boxes, decisions notes and worker artifacts live under
# it. Every creator calls this (team-mail-setup.sh, worker-next.sh; agent_mail_store.py has the same
# rule in Python). Prints the path.
ensure_mail_home() {
  local d="$HOME/.agent-mail"
  mkdir -p "$d" && chmod 700 "$d" && printf '%s' "$d"
}

TEAM_TOOL_RUNTIME="README.md __init__.py agent_mail.py agent_mail_deliver.py agent_mail_store.py mail_md.py"
team_tool_hash() {  # team_tool_hash <dir> → <12 hex>
  local f
  for f in $TEAM_TOOL_RUNTIME; do [ -f "$1/$f" ] || return 1; done
  (cd "$1" && for f in $TEAM_TOOL_RUNTIME; do printf '%s\0' "$f"; cat "$f"; done) \
    | shasum -a 256 | cut -c1-12
}

# ---- render: the generated local configs ---------------------------------------------------------
# A path spliced into a shell command inside JSON must survive both: the same character set the
# escalation config parser accepts (team-escalate-lib.sh esc_config_ok), minus the quote.
TEAM_CHANNEL_SAFE='^/[A-Za-z0-9_./~@%+=:, -]*$'
TEAM_CHANNEL_MARK="by team-channel.sh render"

team_channel_render_one() {  # <template> <dest rel> <dry> [jq filter applied after the fill]
  local tmpl="$1" rel="$2" dry="$3" post="${4:-.}" dest out cur tmp
  dest="$TEAM_CHANNEL_ROOT/$rel"
  out="$(jq --arg lib "$TEAM_CHANNEL_LIB" --arg key "$TEAM_CHANNEL_KEY" --arg kit "$TEAM_CHANNEL_KIT" \
    --arg sup "$TEAM_CHANNEL_SUPERVISOR" --arg tl "$TEAM_CHANNEL_TEAMLEAD" \
    --arg adv "$TEAM_CHANNEL_ADVISOR_NAME" --arg rev "$TEAM_CHANNEL_REVIEWER" '
    walk(if type == "string" then
      gsub("\\{\\{LIB\\}\\}"; $lib) | gsub("\\{\\{KEY\\}\\}"; $key) | gsub("\\{\\{KIT_DIR\\}\\}"; $kit)
      | gsub("\\{\\{SUPERVISOR\\}\\}"; $sup) | gsub("\\{\\{TEAMLEAD\\}\\}"; $tl)
      | gsub("\\{\\{ADVISOR\\}\\}"; $adv) | gsub("\\{\\{REVIEWER\\}\\}"; $rev)
    else . end) | '"$post" "$tmpl")" || { echo "error: team channel: cannot render $tmpl" >&2; return 3; }
  if printf '%s' "$out" | grep -q '{{'; then
    echo "error: team channel: $tmpl has an unknown placeholder" >&2; return 3
  fi
  if [ -f "$dest" ]; then
    cur="$(jq -S . "$dest" 2>/dev/null || true)"
    if [ "$cur" = "$(printf '%s' "$out" | jq -S .)" ]; then
      printf 'keep\t%s\t%s\n' "$rel" "identical to the template"; return 0
    fi
    # Only a file this renderer wrote is replaced; a hand-written one stays for the Operator.
    case "$(jq -r '._generated // empty | strings' "$dest" 2>/dev/null || true)" in
      "$TEAM_CHANNEL_MARK"*) ;;
      *) printf 'keep\t%s\t%s\n' "$rel" "hand-written — move it away to render it from the template"
         return 0 ;;
    esac
    printf 'rewrite\t%s\t%s\n' "$rel" "from $(basename "$tmpl")"
  else
    printf 'write\t%s\t%s\n' "$rel" "from $(basename "$tmpl")"
  fi
  [ -z "$dry" ] || return 0
  mkdir -p "$(dirname "$dest")"
  tmp="$(mktemp "$(dirname "$dest")/.team-channel.XXXXXX")"
  printf '%s\n' "$out" > "$tmp" && mv "$tmp" "$dest"
}

team_channel_render() {  # team_channel_render [--dry-run] — after team_channel_load
  local dry="" t="$TEAM_CHANNEL_LIB/../team" v
  [ "${1:-}" != --dry-run ] || dry=1
  for v in "$TEAM_CHANNEL_LIB" "$TEAM_CHANNEL_KIT"; do
    [[ "$v" =~ $TEAM_CHANNEL_SAFE ]] || {
      echo "error: team channel: '$v' has characters a generated command cannot carry" >&2; return 3; }
  done
  team_channel_render_one "$t/watch.local.json.tmpl" .agents/team/watch.local.json "$dry" || return
  # The adapter is the operator kit's; a config pointing at a missing adapter would turn every
  # escalation into a failed send, so without it the file is not written (NO-REPLY no config).
  if [ ! -f "$TEAM_CHANNEL_KIT/escalate.sh" ]; then
    printf 'skip\t%s\t%s\n' .agents/team/escalation.local.json \
      "no adapter at $TEAM_CHANNEL_KIT/escalate.sh (operator kit not installed)"
    return 0
  fi
  # advisor solo: no Reviewer, so no opinion op — the no-reply fallback stays off (D4).
  if [ "$TEAM_CHANNEL_ADVISOR" = solo ]; then
    team_channel_render_one "$t/escalation.local.json.tmpl" .agents/team/escalation.local.json \
      "$dry" 'del(.opinion)'
  else
    team_channel_render_one "$t/escalation.local.json.tmpl" .agents/team/escalation.local.json "$dry"
  fi
}

TEAM_CHANNEL_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- executed ------------------------------------------------------------------------------------
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 2; }
  usage() { sed -n '9,20p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
  [ $# -ge 1 ] || usage
  sub="$1"; shift
  case "$sub" in show|get|name|turn|render) ;; *) usage ;; esac
  team_channel_load || exit 3
  case "$sub" in
    show)
      for v in ROOT CODE SUFFIX TMUX_PREFIX ADVISOR NOTIFIER KEY BOX TOOL TOOL_SHA DECISIONS \
        CODEX_HOME KIT SUPERVISOR TEAMLEAD ADVISOR_NAME REVIEWER; do
        n="TEAM_CHANNEL_$v"; printf '%s=%s\n' "$n" "${!n}"
      done ;;
    get)
      [ $# -eq 1 ] || usage
      case "$1" in
        project_code) echo "$TEAM_CHANNEL_CODE" ;; mail_suffix) echo "$TEAM_CHANNEL_SUFFIX" ;;
        tmux_prefix) echo "$TEAM_CHANNEL_TMUX_PREFIX" ;; advisor) echo "$TEAM_CHANNEL_ADVISOR" ;;
        notifier) echo "$TEAM_CHANNEL_NOTIFIER" ;; key) echo "$TEAM_CHANNEL_KEY" ;;
        box) echo "$TEAM_CHANNEL_BOX" ;; tool) echo "$TEAM_CHANNEL_TOOL" ;;
        tool_sha) echo "$TEAM_CHANNEL_TOOL_SHA" ;; decisions_dir) echo "$TEAM_CHANNEL_DECISIONS" ;;
        codex_home) echo "$TEAM_CHANNEL_CODEX_HOME" ;; kit_dir) echo "$TEAM_CHANNEL_KIT" ;;
        *) usage ;;
      esac ;;
    name) [ $# -eq 1 ] || usage; team_channel_role "$1"; echo ;;
    turn)
      [ $# -ge 2 ] || usage
      from="$(team_channel_role "$1")"; to="$(team_channel_role "$2")"; shift 2
      exec bash "$TEAM_CHANNEL_LIB/team-mail.sh" "$TEAM_CHANNEL_KEY" send --from "$from" --to "$to" \
        --kind turn --awaiting "$to" "$@" ;;
    render) [ $# -le 1 ] || usage; team_channel_render "$@" ;;
  esac
fi
