#!/usr/bin/env bash
# The `/setup:teams` channel step: binds this checkout to an agent-mail box through the machine
# registry `$HOME/.agent-mail/projects.json` and writes `.agents/team/channel.local.json`.
#
# Usage: bash .claude/lib/team-mail-setup.sh <repo-root> [--dry-run] [--key K] [--slug S]
#          [--suffix X] [--label L] [--tool DIR] [--codex-home DIR] [--add-roles] [--resync-tool]
#   reuse   an entry whose `repo` is this checkout (or --key K names an existing entry): its box
#           and its `tool` are used as they are — one tool per box, `tool` is never rewritten;
#           missing role recipients are registered; --add-roles appends the canonical role names
#           to the entry's claude_roles/codex_roles (otherwise only offered); --resync-tool
#           (Operator action) repoints an entry whose tool is an agent_mail-<sha> copy to a copy
#           of the current vendored tool — never a foreign tool
#   extend  registry present, no entry: creates ~/.agent-mail/<slug>/{mail.sqlite,decisions/},
#           copies the vendored tool (runtime files, named by their content hash) to
#           ~/.agent-mail/tools/agent_mail-<sha> (an identical copy is reused, a different one
#           refused) and adds an entry whose tool is that copy
#   fresh   no registry: creates it in the same schema, then extends
#   --tool DIR: the vendored tool to copy (default <repo-root>/tools/agent_mail).
#   --dry-run prints the plan and writes nothing (no box is opened, so none is created).
# Defaults: key = teams.channel.project_code, else the slug; slug = the repo dir name, lowercased;
#   suffix = teams.channel.mail_suffix, else ""; label = project_code, else the key;
#   codex_home = the value line of .claude/codex-profile, else null.
# Output: one `<action>\t<what>\t<detail>` line per step (the last ones render the generated
#   .agents/team/{watch,escalation}.local.json through team-channel.sh), then the Reviewer
#   instructions.
# Exit: 0 done · 1 refused (nothing written) · 2 usage. Bash 3.2 compatible (macOS /bin/bash).
set -euo pipefail

usage() { sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
die() { echo "team-mail-setup: $1" >&2; exit "${2:-1}"; }
command -v jq >/dev/null 2>&1 || die "jq is required"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO=""; DRY=""; KEY=""; SLUG=""; SUFFIX=""; LABEL=""; TOOL=""; CODEX_HOME_V=""; ADD_ROLES=""
SUFFIX_SET=""; RESYNC=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --add-roles) ADD_ROLES=1 ;;
    --resync-tool) RESYNC=1 ;;
    --key|--slug|--suffix|--label|--tool|--codex-home)
      [ $# -ge 2 ] || usage
      case "$1" in
        --key) KEY="$2" ;; --slug) SLUG="$2" ;; --suffix) SUFFIX="$2"; SUFFIX_SET=1 ;;
        --label) LABEL="$2" ;; --tool) TOOL="$2" ;; --codex-home) CODEX_HOME_V="$2" ;;
      esac
      shift ;;
    -*) usage ;;
    *) [ -z "$REPO" ] || usage; REPO="$1" ;;
  esac
  shift
done
[ -n "$REPO" ] || usage
[ -d "$REPO" ] || die "$REPO does not exist" 2
REPO="$(cd "$REPO" && pwd -P)"
top="$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$top" ] && [ "$(cd "$top" && pwd -P)" = "$REPO" ] || die "$REPO is not a git repo root" 2

IDENT='^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$'
CLAUDE_ROLES="Supervisor TeamLead Advisor"
CODEX_ROLES="Reviewer"
AM="$HOME/.agent-mail"
REG="$AM/projects.json"
PROFILE="$REPO/.claude/project-profile.json"
. "$HERE/team-channel.sh"   # TEAM_CHANNEL_REL; the render step below runs it
CHANNEL_REL="$TEAM_CHANNEL_REL"
TOOLS_DIR="$AM/tools"
RUNTIME="$TEAM_TOOL_RUNTIME"
# Copies are compared byte for byte; a __pycache__ written into one would break that (`-I`
# ignores PYTHON* variables, hence also `-B` on every call).
export PYTHONDONTWRITEBYTECODE=1

pf() { [ -f "$PROFILE" ] && jq -r --arg f "$1" '.teams.channel[$f] // empty' "$PROFILE" 2>/dev/null || true; }
step() { printf '%s\t%s\t%s\n' "$1" "$2" "${3:-}"; }
apply() { [ -n "$DRY" ] || "$@"; }
is_ident() { printf '%s' "$1" | grep -Eq "$IDENT"; }

TMPF=""; TMPD=""
trap '[ -z "$TMPF" ] || rm -f "$TMPF"; [ -z "$TMPD" ] || rm -rf "$TMPD"' EXIT
write_json() {  # write_json <dest> <json> — atomic, next to the destination
  TMPF="$(mktemp "$(dirname "$1")/.team-mail-setup.XXXXXX")"
  printf '%s\n' "$2" > "$TMPF"
  mv "$TMPF" "$1"; TMPF=""
}

# ---- the tool copy: ~/.agent-mail/tools/agent_mail-<hash>, runtime files only ------------------
src_sha() {  # src_sha <vendored dir> → the content hash its copy is named after (team_tool_hash)
  local f; for f in $RUNTIME; do [ -f "$1/$f" ] || die "$1 lacks $f"; done
  team_tool_hash "$1"
}
copy_state() {  # copy_state <src> <dst> → absent | same | differs (__pycache__ ignored)
  [ -e "$2" ] || { echo absent; return; }
  [ -d "$2" ] && [ ! -L "$2" ] || { echo differs; return; }
  local have want f
  have="$(cd "$2" && ls -A | grep -vx __pycache__ | LC_ALL=C sort | tr '\n' ' ' || true)"
  want="$(printf '%s\n' $RUNTIME | LC_ALL=C sort | tr '\n' ' ')"
  [ "$have" = "$want" ] || { echo differs; return; }
  for f in $RUNTIME; do cmp -s "$1/$f" "$2/$f" || { echo differs; return; }; done
  echo same
}
plan_copy() {  # plan_copy <src> → sets NEW_SHA, NEW_TOOL, COPY_STATE; refuses a different copy
  NEW_SHA="$(src_sha "$1")"
  NEW_TOOL="$TOOLS_DIR/agent_mail-$NEW_SHA"
  COPY_STATE="$(copy_state "$1" "$NEW_TOOL")"
  [ "$COPY_STATE" != differs ] \
    || die "$NEW_TOOL exists with different content; it is not the tool named $NEW_SHA — move it away first"
}
apply_copy() {  # apply_copy <src> — after plan_copy; atomic (temp dir + mv)
  if [ "$COPY_STATE" = same ]; then step keep tool-copy "$NEW_TOOL (identical, sha $NEW_SHA)"; return; fi
  step create tool-copy "$NEW_TOOL (sha $NEW_SHA)"
  [ -z "$DRY" ] || return 0
  mkdir -p "$TOOLS_DIR"
  TMPD="$(mktemp -d "$TOOLS_DIR/.agent_mail.XXXXXX")"
  local f; for f in $RUNTIME; do cp -p "$1/$f" "$TMPD/$f"; done
  chmod 755 "$TMPD"; mv "$TMPD" "$NEW_TOOL"; TMPD=""
}
managed_sha() {  # managed_sha <tool path> → <sha> when it is one of our copies, else nothing
  case "$1" in "$TOOLS_DIR"/agent_mail-*) ;; *) return 0 ;; esac
  local s="${1#"$TOOLS_DIR"/agent_mail-}"
  printf '%s' "$s" | grep -Eq '^[0-9a-f]{4,40}$' && printf '%s' "$s" || true
}

# ---- the plan: which mode, which key ------------------------------------------------------------
CODE="$(pf project_code)"
[ -n "$SUFFIX_SET" ] || SUFFIX="$(pf mail_suffix)"
[ -n "$SLUG" ] || SLUG="$(basename "$REPO" | tr '[:upper:]' '[:lower:]' \
  | sed 's/[^a-z0-9._-]/-/g; s/^[^a-z0-9]*//')"
is_ident "$SLUG" || die "slug '$SLUG' is not an identifier; pass --slug" 2
[ -z "$SUFFIX" ] || is_ident "$SUFFIX" || die "suffix '$SUFFIX' is not an identifier" 2
[ -n "$TOOL" ] || TOOL="$REPO/tools/agent_mail"
TOOL_SRC="$TOOL"

MODE=""
if [ ! -e "$REG" ]; then
  MODE=fresh
else
  # Never write into a registry that does not pass the schema — it is shared with other clients.
  if ! out="$(bash "$HERE/team-mail.sh" check 2>&1)"; then
    printf '%s\n' "$out" | sed 's/^/  /' >&2
    die "the registry $REG fails the schema check; fix it first"
  fi
  if [ -n "$KEY" ] && jq -e --arg k "$KEY" 'has($k)' "$REG" >/dev/null; then
    MODE=reuse
  elif [ -z "$KEY" ]; then
    matches="$(jq -r 'to_entries[] | "\(.key)\t\(.value.repo)"' "$REG" \
      | while IFS="$(printf '\t')" read -r k r; do
      [ -d "$r" ] && [ "$(cd "$r" && pwd -P)" = "$REPO" ] && echo "$k"; done || true)"
    n="$(printf '%s' "$matches" | grep -c . || true)"
    if [ "$n" = 1 ]; then MODE=reuse; KEY="$matches"
    elif [ "$n" -gt 1 ]; then die "several registry entries have repo=$REPO ($(echo $matches)); pass --key"
    else MODE=extend; fi
  else
    MODE=extend
  fi
fi
[ -n "$KEY" ] || KEY="${CODE:-$SLUG}"
is_ident "$KEY" || die "key '$KEY' is not an identifier; pass --key" 2
if [ "$MODE" != reuse ] && [ -e "$REG" ] && jq -e --arg k "$KEY" 'has($k)' "$REG" >/dev/null; then
  other="$(jq -r --arg k "$KEY" '.[$k].repo' "$REG")"
  die "key $KEY already names the entry of $other; pass --key $KEY to reuse it, or another --key"
fi
[ -n "$DRY" ] && echo "dry-run: nothing is written" || true
step mode "$MODE" "key $KEY"

# ---- fresh / extend: registry, box dir, entry ---------------------------------------------------
if [ "$MODE" != reuse ]; then
  [ -f "$TOOL/agent_mail.py" ] || die "no agent-mail tool at $TOOL (agent_mail.py missing); pass --tool"
  SRC="$(cd "$TOOL" && pwd -P)"
  plan_copy "$SRC"
  TOOL="$NEW_TOOL"
  if [ -z "$CODEX_HOME_V" ] && [ -f "$REPO/.claude/codex-profile" ]; then
    CODEX_HOME_V="$(grep -v '^[[:space:]]*#' "$REPO/.claude/codex-profile" | grep -m1 . || true)"
    # Strip the literal "~/" by length: an unquoted ~ in ${V#~/} is itself tilde-expanded.
    case "$CODEX_HOME_V" in "~/"*) CODEX_HOME_V="$HOME/${CODEX_HOME_V:2}" ;; esac
  fi
  DIR="$AM/$SLUG"; BOX="$DIR/mail.sqlite"; DEC="$DIR/decisions"
  # A box nobody registered belongs to someone (another client, an old setup): never adopt it.
  [ ! -e "$BOX" ] || die "$BOX exists but no registry entry names it; register it by hand or pass --slug"
  if [ -e "$REG" ] && jq -e --arg b "$BOX" 'any(.[]; .box == $b)' "$REG" >/dev/null; then
    die "$BOX is already registered under another key"
  fi
  if [ "$MODE" = fresh ]; then
    step create registry "$REG"
    apply ensure_mail_home >/dev/null
    [ -n "$DRY" ] || write_json "$REG" '{}'
  fi
  apply_copy "$SRC"
  step create box-dir "$DIR (+ decisions/)"
  apply ensure_mail_home >/dev/null
  apply mkdir -p "$DEC"
  ENTRY="$(jq -n --arg box "$BOX" --arg tool "$TOOL" --arg label "${LABEL:-${CODE:-$KEY}}" \
    --arg suffix "$SUFFIX" --arg repo "$REPO" --arg dec "$DEC" --arg ch "$CODEX_HOME_V" \
    --arg cr "$CLAUDE_ROLES" --arg xr "$CODEX_ROLES" \
    '{box: $box, tool: $tool, project_label: $label, suffix: $suffix, repo: $repo,
      decisions_dir: $dec, claude_roles: ($cr | split(" ")), codex_roles: ($xr | split(" ")),
      rules: null, codex_home: (if $ch == "" then null else $ch end)}')"
  step add entry "$KEY (tool $TOOL)"
  [ -n "$DRY" ] || write_json "$REG" "$(jq --arg k "$KEY" --argjson e "$ENTRY" '. + {($k): $e}' "$REG")"
  step create box "$BOX"
  [ -n "$DRY" ] || python3 -I -B "$TOOL/agent_mail.py" --box "$BOX" recipients >/dev/null
fi

# From here on the registry entry is the only source of box/tool paths.
if [ "$MODE" = reuse ] || [ -z "$DRY" ]; then
  e() { jq -r --arg k "$KEY" --arg f "$1" '.[$k][$f] // empty' "$REG"; }
  BOX="$(e box)"; TOOL="$(e tool)"; DEC="$(e decisions_dir)"; CODEX_HOME_V="$(e codex_home)"
  # The entry's suffix names its recipients. A project that declares another one would silently
  # take over that box's roles (another project's, under --key), so the mismatch is refused.
  if [ "$MODE" = reuse ] && [ -n "$SUFFIX" ] && [ "$SUFFIX" != "$(e suffix)" ]; then
    die "entry $KEY has mail suffix '$(e suffix)', this project declares '$SUFFIX' — reusing it would take over its recipients; pick this project's own key, or a new box"
  fi
  SUFFIX="$(e suffix)"
  HAVE_CR="$(jq -r --arg k "$KEY" '.[$k].claude_roles | join(" ")' "$REG")"
  HAVE_XR="$(jq -r --arg k "$KEY" '.[$k].codex_roles | join(" ")' "$REG")"
else
  HAVE_CR="$CLAUDE_ROLES"; HAVE_XR="$CODEX_ROLES"
fi
if [ "$MODE" = reuse ]; then
  [ -f "$TOOL/agent_mail.py" ] \
    || die "entry $KEY: tool $TOOL has no agent_mail.py — fix the entry; this step never rewrites tool"
  OLD_SHA="$(managed_sha "$TOOL")"
  if [ -n "$RESYNC" ]; then
    [ -n "$OLD_SHA" ] \
      || die "--resync-tool: $TOOL is not an agent_mail-<sha> copy; a foreign tool is never swapped"
    others="$(jq -r --arg k "$KEY" --arg b "$BOX" \
      'to_entries[] | select(.key != $k and .value.box == $b) | .key' "$REG")"
    [ -z "$others" ] \
      || die "--resync-tool: the box is shared with $(echo $others); repoint them together by hand"
    [ -f "$TOOL_SRC/agent_mail.py" ] || die "no agent-mail tool at $TOOL_SRC; pass --tool"
    SRC="$(cd "$TOOL_SRC" && pwd -P)"
    plan_copy "$SRC"
    case "$NEW_SHA" in "$OLD_SHA"*) NEW_SHA="$OLD_SHA" ;; esac
    case "$OLD_SHA" in "$NEW_SHA"*) NEW_SHA="$OLD_SHA" ;; esac
    if [ "$NEW_SHA" = "$OLD_SHA" ]; then
      step keep tool "$TOOL (already at sha $OLD_SHA)"
    else
      apply_copy "$SRC"
      step repoint tool "$OLD_SHA → $NEW_SHA ($NEW_TOOL; the old copy stays for other boxes)"
      [ -n "$DRY" ] || write_json "$REG" "$(jq --arg k "$KEY" --arg t "$NEW_TOOL" '.[$k].tool = $t' "$REG")"
      TOOL="$NEW_TOOL"; OLD_SHA="$NEW_SHA"
    fi
  else
    step keep tool "$TOOL (one tool per box — the entry's own)"
  fi
  if [ -e "$BOX" ]; then step keep box "$BOX"
  else step keep box "$BOX (absent; the entry's tool creates it on first use)"; fi
  [ -n "$OLD_SHA" ] || step note tool "the vendored $REPO/tools/agent_mail is not used for this box"
  TOOL_SHA="$OLD_SHA"
else
  TOOL_SHA="$NEW_SHA"
fi

# ---- role recipients: register the missing ones, never overwrite one -------------------------
RJ="$(dirname "$BOX")/recipients.json"
for role in $CLAUDE_ROLES; do
  name="$role$SUFFIX"
  if [ -f "$RJ" ] && jq -e --arg n "$name" 'has($n)' "$RJ" >/dev/null 2>&1; then
    step keep recipient "$name ($(jq -r --arg n "$name" '.[$n].adapter' "$RJ"))"
  else
    step register recipient "$name (monitor)"
    [ -n "$DRY" ] \
      || python3 -I -B "$TOOL/agent_mail.py" --box "$BOX" register --as "$name" --adapter monitor >/dev/null
  fi
done

# ---- canonical role names in the entry: offered, written only with --add-roles ----------------
miss_cr=""; for r in $CLAUDE_ROLES; do case " $HAVE_CR " in *" $r "*) ;; *) miss_cr="$miss_cr $r" ;; esac; done
miss_xr=""; for r in $CODEX_ROLES; do case " $HAVE_XR " in *" $r "*) ;; *) miss_xr="$miss_xr $r" ;; esac; done
if [ -n "$miss_cr$miss_xr" ]; then
  if [ -n "$ADD_ROLES" ]; then
    step add roles "claude_roles +=${miss_cr:- none}; codex_roles +=${miss_xr:- none}"
    [ -n "$DRY" ] || write_json "$REG" "$(jq --arg k "$KEY" --arg c "${miss_cr# }" --arg x "${miss_xr# }" '
      .[$k].claude_roles += ($c | split(" ") | map(select(. != "")))
      | .[$k].codex_roles += ($x | split(" ") | map(select(. != "")))' "$REG")"
  else
    step offer roles \
      "claude_roles +=${miss_cr:- none}; codex_roles +=${miss_xr:- none} (rerun with --add-roles)"
  fi
fi

# ---- the local channel file --------------------------------------------------------------------
CH="$REPO/$CHANNEL_REL"
git -C "$REPO" check-ignore -q "$CHANNEL_REL" 2>/dev/null \
  || step warn gitignore "$CHANNEL_REL is not ignored — add .agents/team/ to .gitignore"
CJ="$(jq -n --arg key "$KEY" --arg box "$BOX" --arg tool "$TOOL" --arg dec "$DEC" \
  --arg ch "$CODEX_HOME_V" --arg kit "$(dirname "$BOX")/kit" --arg sha "$TOOL_SHA" \
  '{key: $key, box: $box, tool: $tool, tool_sha: (if $sha == "" then null else $sha end),
    decisions_dir: $dec, codex_home: (if $ch == "" then null else $ch end), kit_dir: $kit}')"
if [ -f "$CH" ] && [ "$(jq -S . "$CH" 2>/dev/null)" = "$(printf '%s' "$CJ" | jq -S .)" ]; then
  step keep channel "$CHANNEL_REL"
else
  step write channel "$CHANNEL_REL"
  if [ -z "$DRY" ]; then mkdir -p "$(dirname "$CH")"; write_json "$CH" "$CJ"; fi
fi

# ---- the generated local configs: .agents/team/{watch,escalation}.local.json --------------------
# Rendered from .claude/team/*.tmpl by team-channel.sh, which reads the channel config just written;
# a render problem is reported, never fatal — the channel itself is bound.
if [ -n "$DRY" ]; then
  if ! (cd "$REPO" && bash "$HERE/team-channel.sh" render --dry-run 2>/dev/null); then
    step plan render ".agents/team/watch.local.json + escalation.local.json, after the channel file"
  fi
elif ! jq -e '.teams.channel | type == "object"' "$PROFILE" >/dev/null 2>&1; then
  step skip render "no teams.channel in the profile — the generated configs need its names"
elif out="$(cd "$REPO" && bash "$HERE/team-channel.sh" render 2>&1)"; then
  printf '%s\n' "$out"
else
  step warn render "$(printf '%s' "$out" | tail -n 1)"
fi

# ---- the Reviewer registers itself: it needs its own Codex thread UUID ------------------------
if [ "$(pf advisor)" = solo ]; then
  echo "reviewer: none (teams.channel.advisor = solo)"
else
  cat <<EOF
reviewer: in this project's Codex window (CODEX_HOME=${CODEX_HOME_V:-<unset>}), first thing after start:
  python3 -I -B "$TOOL/agent_mail.py" --box "$BOX" register --as Reviewer$SUFFIX --adapter codex-queue --thread <UUID from /status or \$CODEX_THREAD_ID>
  (its sandbox needs write access to $(dirname "$BOX") and read access to $TOOL)
then, in the Advisor's session, (re)start the push loop as a background task:
  bash .claude/lib/team-mail.sh $KEY deliver Reviewer$SUFFIX
  liveness: pgrep -f "\$(bash .claude/lib/team-mail.sh $KEY pattern deliver Reviewer$SUFFIX)"
EOF
fi
