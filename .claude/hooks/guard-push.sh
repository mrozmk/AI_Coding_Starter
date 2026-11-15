#!/bin/bash
# PreToolUse(Bash) guard for `git push` — pre-publication secret/credential scan.
#
# Push is the publication boundary: once commits leave for the remote, removing a
# leaked secret needs a history rewrite (denied in settings.json). So this is the
# LAST deterministic gate before content goes public. It scans the diff about to be
# published for secrets and credential files, and BLOCKS (exit 2) on a hit.
#
# Design (decided via /analysis — see .agents/memory/decisions.md):
#   - Scope: only `git push`. Every other command exits 0 immediately.
#   - Unit of scan: ADDED lines across the per-commit patches of the range about to
#     be published (`git log -p`, NOT net `git diff`) — a secret added then removed
#     within the unpushed range still ships in history, so per-commit is mandatory.
#   - Classes (P0 zero-FP block / P1 conservative block):
#       A1 known-format tokens (GitHub, AWS, Google, Stripe, Slack, GitLab, Atlassian,
#          npm, SendGrid, Shopify, JWT, Anthropic/OpenAI)
#       A2 private keys (-----BEGIN ... PRIVATE KEY-----)
#       A3 connection strings with embedded credentials (proto://user:pass@host)
#       A4 generic assignments (password/secret/api_key = "...") — conservative,
#          placeholder-filtered, "rather pass than false-block"
#       A6 connection-string credential fields (Password=/AccountKey=/... with a real value)
#       B1 credential FILES by name (.env, local.env, *.pem/*.key, id_rsa, .npmrc, *.tfstate, ...)
#     A5 high-entropy / 150+ rules: delegated to gitleaks IF present (optional boost).
#     Patterns live in hooks/lib/leak-patterns.sh (shared with guard-commit.sh).
#   - Asymmetry: missing infra (no jq) → fail-OPEN-but-LOUD + exit 0 (matches house
#     style; check-deps already screams about jq). Detected secret → fail-CLOSED exit 2.
#   - Escape hatches: inline `guard-push:allow` / `pragma: allowlist secret` on the
#     line; whole-push override `GUARD_PUSH_SKIP=1 git push ...` (loud + audited).
#   - Self-trigger guard: this repo documents token FORMATS (settings.json, .md docs,
#     .agents/reference/). Those paths are allowlisted or scanning would self-block.
#
# Mechanics mirror guard-commit.sh: stdin = PreToolUse JSON; exit 2 blocks + feeds
# stderr to Claude; exit 0 allows. MUST be a SYNCHRONOUS hook (no "async": true).

PAYLOAD=$(cat)

# Byte-wise processing: diffs carry arbitrary bytes (minified blobs, non-UTF8 source).
# Without this, awk/grep abort with "multibyte conversion failure" on a UTF-8 locale.
export LC_ALL=C LANG=C

# --- extract the command (needs jq, like guard-commit) ----------------------------
if ! command -v jq >/dev/null 2>&1; then
  # Fail-open-but-LOUD: without jq we cannot parse the command to scan it. Allow the
  # push (consistent with the other hooks' jq policy) but make the gap visible.
  echo "guard-push: jq not found — secret scan SKIPPED for this push. Install jq to re-enable the gate." >&2
  exit 0
fi

HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [ ! -r "$HOOK_DIR/lib/leak-patterns.sh" ]; then
  # Never run the scan with empty regexes: an empty ERE matches every line.
  echo "guard-push: hooks/lib/leak-patterns.sh missing — secret scan SKIPPED. Sync it from the starter with the hooks." >&2
  exit 0
fi
. "$HOOK_DIR/lib/leak-patterns.sh"

CMD=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // ""' 2>/dev/null)
CWD=$(printf '%s' "$PAYLOAD" | jq -r '.cwd // ""' 2>/dev/null)
[ -z "$CMD" ] && exit 0

# Only act on `git push`. Leave every other command untouched. Global flags may sit
# between `git` and `push` (`git -C <dir> push`, `git -c k=v push`) — cover them, or
# those forms bypass the scan entirely.
# A push the plain match misses — in `( … )`, `$( … )`, backticks or `<shell> -c '…'` — is found by
# the segmenter (hooks/lib/git-segments.sh) and checked as that segment; quoted text never matches.
ORIG_CMD="$CMD"
GS_OK=""; [ -r "$HOOK_DIR/lib/git-segments.sh" ] && . "$HOOK_DIR/lib/git-segments.sh" && GS_OK=1
if ! printf '%s' "$CMD" | grep -Eq '(^|[;&|[:space:]])git([[:space:]]+-[Cc][[:space:]]+[^[:space:]]+)*[[:space:]]+push([[:space:]]|$)'; then
  [ -n "$GS_OK" ] || exit 0
  CMD=$(git_first "$CMD" push) || exit 0
fi

# --- resolve the repo the push publishes from -------------------------------------
# Mirrors guard-commit.sh: a directory named IN the command is where the push actually
# runs, so it beats the caller's cwd. Without this, `cd <worktree> && git push` or
# `git -C <repo> push` is scanned against the caller's repo/branch — the wrong commits.
DIR=$(printf '%s' "$CMD" | sed -nE "s/.*git[[:space:]]+-C[[:space:]]+(\"([^\"]+)\"|'([^']+)'|([^[:space:]]+)).*/\2\3\4/p" | head -1)
if [ -z "$DIR" ]; then
  DIR=$(printf '%s' "$CMD" | sed -nE "s/^[[:space:]]*cd[[:space:]]+(\"([^\"]+)\"|'([^']+)'|([^[:space:]&;|]+)).*/\2\3\4/p" | head -1)
fi
[ -z "$DIR" ] && DIR="$CWD"
[ -z "$DIR" ] && DIR="$CLAUDE_PROJECT_DIR"
[ -z "$DIR" ] && DIR="$PWD"
case "$DIR" in
  /*) ;;
  *)  DIR="${CWD:-$PWD}/$DIR" ;;
esac
git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1 || DIR="${CWD:-${CLAUDE_PROJECT_DIR:-$PWD}}"

# --- protected branches change only through a PR (Branch model `**Protected push:** pr-only`) -------
# Reads the Branch model of the repo being pushed (DIR's top level), through the core reader. Any
# doubt about the MODE — no reader, no block, an unknown value — keeps today's behaviour: no block.
# A destination the guard cannot know (remote.<r>.push, push.default=matching) is refused under
# pr-only, with a request to name it. Scripts' own pushes (team-integrate.sh) are not seen here.
protected_check() {  # protected_check <one git push segment> <its repo dir>
  local seg="$1" top bm fields prot mode args remote="" a dst cur up del="" amb="" hits="" nref=0 all="" skip=""
  printf '%s' "$seg" | grep -Eq -- '--dry-run' && return 0
  top=$(git -C "$2" rev-parse --show-toplevel 2>/dev/null) || return 0
  bm="$HOOK_DIR/../lib/branch-model.sh"
  [ -r "$bm" ] || return 0
  fields=$(cd "$top" && bash "$bm" fields 2>/dev/null) || return 0
  mode=$(printf '%s\n' "$fields" | sed -n 's/^protected_push=//p')
  prot=$(printf '%s\n' "$fields" | sed -n 's/^protected=//p')
  [ "$mode" = pr-only ] && [ -n "$prot" ] || return 0
  args=$(printf '%s' "$seg" | sed -nE 's/.*git[[:space:]]+(-[Cc][[:space:]]+[^[:space:]]+[[:space:]]+)*push([[:space:]]+([^;&|]*))?.*/\3/p' | head -1)
  cur=$(git -C "$top" symbolic-ref --quiet --short HEAD 2>/dev/null)
  set -f
  for a in $args; do
    a="${a#[\"\']}"; a="${a%[\"\']}"
    [ -z "$skip" ] || { skip=""; continue; }   # the value of an option given as its own word
    case "$a" in
      -o|--push-option|--repo|--receive-pack|--exec) skip=1; continue ;;
      --all|--mirror) all=1; continue ;;
      --delete|-d) del=1; continue ;;
      -*) continue ;;
    esac
    if [ -z "$remote" ]; then remote="$a"; continue; fi
    nref=$((nref + 1)); a="${a#+}"
    case "$a" in
      *:*) dst="${a#*:}" ;;
      *)   dst="$a"   # <src> alone goes where remote.<r>.push maps it, when that is set
           [ -n "$del" ] || [ -z "$(git -C "$top" config --get-all "remote.$remote.push" 2>/dev/null)" ] || amb=1 ;;
    esac
    [ "$dst" = HEAD ] && dst="$cur"
    dst="${dst#refs/heads/}"
    case "$dst" in refs/*) continue ;; esac
    hits="$hits $dst"
  done
  set +f
  [ -z "$all" ] || hits="$prot"
  if [ -z "$all" ] && [ "$nref" = 0 ]; then
    # No refspec: what git pushes depends on remote.<r>.push and push.default.
    if [ -n "$(git -C "$top" config --get-all "remote.${remote:-origin}.push" 2>/dev/null)" ] \
       || [ "$(git -C "$top" config --get push.default 2>/dev/null)" = matching ]; then
      amb=1
    else
      up=$(git -C "$top" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)
      hits="$cur ${up#*/}"
    fi
  fi
  for a in $hits; do
    case " $prot " in *" $a "*)
      { echo "BLOCKED: guard-push — \`$a\` is protected; it changes only through a PR (/pr-create, then merge)."
        echo "Push a working branch instead. To allow direct pushes again, set \`**Protected push:** confirm\`"
        echo "(or remove that line) in CLAUDE.md → Branch model."; } >&2
      exit 2 ;;
    esac
  done
  if [ -n "$amb" ]; then
    { echo "BLOCKED: guard-push — this push's destination comes from remote.<name>.push or push.default=matching,"
      echo "and the Branch model protects $prot (Protected push: pr-only). Name the destination explicitly,"
      echo "e.g. git push origin <branch>:<branch>. To allow direct pushes again, set \`**Protected push:** confirm\`"
      echo "(or remove that line) in CLAUDE.md → Branch model."; } >&2
    exit 2
  fi
  return 0
}

# Every `git push` segment of the command (separators, subshells, substitutions, `<shell> -c`) is
# checked, each against its own repo: its `-C <dir>`, else the last `cd <dir>` segment before it,
# else the session's. Without the segmenter: a plain split on && || ; | and newlines.
protected_scan() {
  local segs seg d cdir="" base="${CWD:-${CLAUDE_PROJECT_DIR:-$PWD}}"
  if [ -n "$GS_OK" ]; then segs=$(git_segments "$ORIG_CMD")
  else segs="${ORIG_CMD//&&/$'\n'}"; segs="${segs//||/$'\n'}"; segs="${segs//;/$'\n'}"; segs="${segs//|/$'\n'}"; fi
  while IFS= read -r seg; do
    d=$(printf '%s' "$seg" | sed -nE "s/^[[:space:]]*cd[[:space:]]+(\"([^\"]+)\"|'([^']+)'|([^[:space:]]+)).*/\2\3\4/p")
    if [ -n "$d" ]; then cdir="$d"; continue; fi
    if [ -n "$GS_OK" ]; then git_seg_is "$seg" push || continue
    else printf '%s' "$seg" | grep -Eq '(^|[[:space:]])git([[:space:]]+-[Cc][[:space:]]+[^[:space:]]+)*[[:space:]]+push([[:space:]]|$)' || continue; fi
    d=$(printf '%s' "$seg" | sed -nE "s/.*git[[:space:]]+-C[[:space:]]+(\"([^\"]+)\"|'([^']+)'|([^[:space:]]+)).*/\2\3\4/p")
    [ -n "$d" ] || d="${cdir:-$base}"
    case "$d" in /*) ;; *) d="$base/$d" ;; esac
    git -C "$d" rev-parse --git-dir >/dev/null 2>&1 || d="$base"
    protected_check "$seg" "$d"
  done <<EOF_SEGS
$segs
EOF_SEGS
}
protected_scan


# Forms with nothing to scan → allow.
#   --dry-run            : not publishing
#   --delete / `:branch` : deleting a remote ref, no content
printf '%s' "$CMD" | grep -Eq -- '--dry-run' && exit 0
printf '%s' "$CMD" | grep -Eq -- '--delete([[:space:]]|=)|[[:space:]]:[^[:space:]]' && exit 0

# --- whole-push override (explicit, loud, audited) --------------------------------
if printf '%s' "$CMD" | grep -Eq 'GUARD_PUSH_SKIP=(1|true|yes)'; then
  echo "guard-push: OVERRIDE — GUARD_PUSH_SKIP set, secret scan bypassed for this push." >&2
  if [ -n "$CLAUDE_PROJECT_DIR" ] && [ -d "$CLAUDE_PROJECT_DIR/.claude" ]; then
    TS=$(date '+%Y-%m-%d %H:%M:%S')
    printf '[%s] GUARD-PUSH OVERRIDE: %s\n' "$TS" "$CMD" >> "$CLAUDE_PROJECT_DIR/.claude/audit.log" 2>/dev/null
  fi
  exit 0
fi

# --- resolve the tip about to be published ----------------------------------------
# `git push origin <ref>` publishes <ref>, not the checked-out branch. Take the first
# refspec's source side when it resolves to a local ref; otherwise fall back to HEAD
# (fail toward scanning something rather than skipping the scan).
PUSHARGS=$(printf '%s' "$CMD" | sed -nE 's/.*git[[:space:]]+(-[Cc][[:space:]]+[^[:space:]]+[[:space:]]+)*push[[:space:]]+([^;&|]*).*/\2/p' | head -1)
TIP="HEAD"; SRC=""; REMOTE_SEEN=""
set -f
for a in $PUSHARGS; do
  case "$a" in
    -*) continue ;;                                              # flags carry no refs
    *)  if [ -z "$REMOTE_SEEN" ]; then REMOTE_SEEN=1; continue; fi  # first bare arg = remote
        SRC="${a%%:*}"                                           # refspec source side
        break ;;
  esac
done
set +f
if [ -n "$SRC" ] && git -C "$DIR" rev-parse --verify --quiet "$SRC" >/dev/null 2>&1; then
  TIP="$SRC"
fi

BRANCH="$TIP"
[ "$TIP" = "HEAD" ] && BRANCH=$(git -C "$DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)
if [ -z "$BRANCH" ] || [ "$BRANCH" = "HEAD" ]; then
  RANGE="$TIP --not --remotes"                       # detached: commits not on any remote
elif git -C "$DIR" rev-parse --verify --quiet "origin/$BRANCH" >/dev/null 2>&1; then
  RANGE="origin/$BRANCH..$TIP"                        # tracked branch: only the delta
else
  RANGE="$TIP --not --remotes"                        # new branch: bound to un-pushed commits
fi

# --- collect ADDED, non-allowlisted lines (path<TAB>content) ----------------------
# Per-commit patches, not the net diff: a secret added then removed in the range still
# ships in history. Allowlisted paths are skipped inside leak_added_lines.
STREAM=$(git -C "$DIR" log -p --no-color $RANGE 2>/dev/null | leak_added_lines)

# --- A1-A4 + A6: content classes ---------------------------------------------------
leak_scan "$STREAM"

# --- B1: credential files by name (zero-FP, allowlisting *.example etc.) -----------
# Deletions excluded per commit: removing a credential file must not block, while a file
# added in one commit and deleted in a later one is still listed by the adding commit.
NAMES=$(git -C "$DIR" log --name-only --diff-filter=d --pretty=format: $RANGE 2>/dev/null | sort -u)
LEAK_HITS_FILE=$(printf '%s\n' "$NAMES" | leak_file_hits)

# --- A5: gitleaks if available (optional breadth/entropy boost) --------------------
HITS_GL=""
if command -v gitleaks >/dev/null 2>&1; then
  if gitleaks detect --source "$DIR" --no-banner --redact --log-opts="$RANGE" >/dev/null 2>&1; then
    : # rc 0 → no leaks
  else
    [ $? -eq 1 ] && HITS_GL="gitleaks reported leaks in the push range (run: gitleaks detect --log-opts=\"$RANGE\")"
  fi
fi

# --- verdict ----------------------------------------------------------------------
if [ -z "$LEAK_HITS_HIGH" ] && [ -z "$LEAK_HITS_A4" ] && [ -z "$LEAK_HITS_A6" ] && [ -z "$LEAK_HITS_FILE" ] && [ -z "$HITS_GL" ]; then
  exit 0
fi

# Report PATHS and classes only — never echo the secret values (stderr is fed back to
# Claude and the audit log; re-printing the secret would re-leak it).
{
  echo "BLOCKED: guard-push detected likely secrets/credentials in the commits about to be pushed ($RANGE)."
  echo "Push is the publication boundary — fix this BEFORE it leaves the machine."
  echo ""
  leak_report "Credential file staged for push"
  [ -n "$HITS_GL" ]   && echo "• $HITS_GL"
  echo ""
  echo "How to resolve:"
  echo "  1. Remove the secret from the file, rotate it if it was real, and amend/rewrite the offending commit(s)."
  echo "     (History rewrite is denied for the AI — ask the human to run it.)"
  echo "  2. False positive? Add an inline marker on the line: '# guard-push:allow' (or 'pragma: allowlist secret'),"
  echo "     or move sample values to a *.example / *.sample file."
  echo "  3. Genuine emergency override (logged to audit.log): re-run as  GUARD_PUSH_SKIP=1 git push ..."
} >&2

exit 2
