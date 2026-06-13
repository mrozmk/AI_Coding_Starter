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
#       B1 credential FILES by name (.env, *.pem/*.key, id_rsa, .npmrc, *.tfstate, ...)
#     A5 high-entropy / 150+ rules: delegated to gitleaks IF present (optional boost).
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

CMD=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // ""' 2>/dev/null)
CWD=$(printf '%s' "$PAYLOAD" | jq -r '.cwd // ""' 2>/dev/null)
[ -z "$CMD" ] && exit 0

# Only act on `git push`. Leave every other command untouched.
printf '%s' "$CMD" | grep -Eq '(^|[;&|[:space:]])git[[:space:]]+push([[:space:]]|$)' || exit 0

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

# --- resolve the range about to be published -------------------------------------
DIR="$CWD"
[ -z "$DIR" ] && DIR="$CLAUDE_PROJECT_DIR"
[ -z "$DIR" ] && DIR="$PWD"

BRANCH=$(git -C "$DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)
if [ -z "$BRANCH" ] || [ "$BRANCH" = "HEAD" ]; then
  RANGE="HEAD --not --remotes"                       # detached: commits not on any remote
elif git -C "$DIR" rev-parse --verify --quiet "origin/$BRANCH" >/dev/null 2>&1; then
  RANGE="origin/$BRANCH..HEAD"                        # tracked branch: only the delta
else
  RANGE="HEAD --not --remotes"                        # new branch: bound to un-pushed commits
fi

# --- collect ADDED, non-allowlisted lines (path<TAB>content) ----------------------
# awk tracks the current file via the `+++ b/path` header and:
#   - skips allowlisted paths (examples, lockfiles, docs, this repo's pattern-bearing
#     files, fixture dirs) so the gate is USABLE and doesn't self-trigger;
#   - emits only added content lines (single leading '+', not the '+++' header),
#     stripping the '+'.
# Binary diffs are emitted by `git log -p` as "Binary files differ" (no content),
# so regexes never waste time on binaries; credential binaries are caught by B1.
STREAM=$(git -C "$DIR" log -p --no-color $RANGE 2>/dev/null | awk '
  /^\+\+\+ / {
    p=$2; sub(/^b\//,"",p);
    skip = (p=="/dev/null") ||
      (p ~ /\.(example|sample|template|lock|md|snap|map)$/) ||
      (p ~ /(^|\/)\.agents\/reference\//) ||
      (p ~ /(^|\/)\.claude\/(settings\.json|memory-domains\.json)$/) ||
      (p ~ /(^|\/)\.claude\/hooks\/guard-push\.sh$/) ||
      (p ~ /(^|\/)(fixtures|__fixtures__|__mocks__|testdata)\//) ||
      (p ~ /(package-lock\.json|yarn\.lock|pnpm-lock\.yaml|composer\.lock|Cargo\.lock|poetry\.lock|go\.sum)$/);
    next
  }
  /^--- / { next }
  /^\+/ { if (!skip) print p "\t" substr($0,2) }
')

# Inline allow-markers drop the matching line from every class.
ALLOW_MARK='guard-push:allow|pragma: ?allowlist secret|gitleaks:allow'

# --- A1+A2+A3: known-format secrets (zero-FP → hard block) -------------------------
HIGH_RE='-----BEGIN[A-Z ]*PRIVATE KEY-----'
HIGH_RE="$HIGH_RE"'|AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}'
HIGH_RE="$HIGH_RE"'|gh[pousr]_[0-9A-Za-z]{36}'
HIGH_RE="$HIGH_RE"'|github_pat_[0-9A-Za-z_]{82}'
HIGH_RE="$HIGH_RE"'|xox[baprs]-[0-9A-Za-z-]{10,}|xapp-[0-9A-Za-z-]{10,}'
HIGH_RE="$HIGH_RE"'|glpat-[0-9A-Za-z_-]{20}'
HIGH_RE="$HIGH_RE"'|AIza[0-9A-Za-z_-]{35}'
HIGH_RE="$HIGH_RE"'|sk-ant-[0-9A-Za-z_-]{20,}|sk-proj-[0-9A-Za-z_-]{20,}'
HIGH_RE="$HIGH_RE"'|(sk|rk)_live_[0-9A-Za-z]{20,}'
HIGH_RE="$HIGH_RE"'|shp(at|ss)_[0-9a-fA-F]{32}'
HIGH_RE="$HIGH_RE"'|SG\.[0-9A-Za-z_-]{22}\.[0-9A-Za-z_-]{43}'
HIGH_RE="$HIGH_RE"'|ATATT[0-9A-Za-z_=.-]{20,}'
HIGH_RE="$HIGH_RE"'|npm_[0-9A-Za-z]{36}'
HIGH_RE="$HIGH_RE"'|eyJ[0-9A-Za-z_-]{8,}\.eyJ[0-9A-Za-z_-]{8,}\.[0-9A-Za-z_-]{8,}'
HIGH_RE="$HIGH_RE"'|(postgres(ql)?|mysql|mongodb(\+srv)?|redis|amqps?|ftp)://[^:@/[:space:]]+:[^@/[:space:]]+@'
HIGH_RE="$HIGH_RE"'|SK[0-9a-f]{32}'

HITS_HIGH=$(printf '%s\n' "$STREAM" | grep -E -- "$HIGH_RE" | grep -viE -- "$ALLOW_MARK")

# --- A4: generic credential assignments (conservative → placeholder-filtered) ------
A4_RE="(password|passwd|pwd|secret|api[_-]?key|apikey|access[_-]?key|secret[_-]?key|access[_-]?token|auth[_-]?token|client[_-]?secret|private[_-]?key)[\"']?[[:space:]]*[:=][[:space:]]*[\"'][^\"']{8,}[\"']"
# Drop anything that looks like an env reference, template var, or obvious placeholder.
A4_PLACEHOLDER='process\.env|os\.environ|getenv|System\.getenv|ENV\[|secrets\.|vault|\$\{|\$\(|<[A-Za-z0-9_]+>|x{3,}|changeme|change-me|your[_-]|example|placeholder|dummy|sample|redacted|fake|mock|null|none|undefined|\*{3,}|\.\.\.|%s|\{\{|0{6,}|123456'

HITS_A4=$(printf '%s\n' "$STREAM" | grep -iE -- "$A4_RE" | grep -viE -- "$A4_PLACEHOLDER" | grep -viE -- "$ALLOW_MARK")

# --- B1: credential files by name (zero-FP, allowlisting *.example etc.) -----------
NAMES=$(git -C "$DIR" log --name-only --pretty=format: $RANGE 2>/dev/null | sort -u)
FILE_RE='(^|/)\.env($|\.)|(^|/)id_(rsa|dsa|ecdsa|ed25519)$|\.(pem|key|p12|pfx|keystore|jks|ppk)$|(^|/)\.(npmrc|pypirc|netrc|htpasswd)$|(^|/)\.aws/credentials$|(^|/)kubeconfig$|\.(tfstate|tfvars)$|service[_-]?account.*\.json$'
HITS_FILE=$(printf '%s\n' "$NAMES" | grep -E -- "$FILE_RE" | grep -vE -- '\.(example|sample|template)$|\.dist$')

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
if [ -z "$HITS_HIGH" ] && [ -z "$HITS_A4" ] && [ -z "$HITS_FILE" ] && [ -z "$HITS_GL" ]; then
  exit 0
fi

# Report PATHS and classes only — never echo the secret values (stderr is fed back to
# Claude and the audit log; re-printing the secret would re-leak it).
{
  echo "BLOCKED: guard-push detected likely secrets/credentials in the commits about to be pushed ($RANGE)."
  echo "Push is the publication boundary — fix this BEFORE it leaves the machine."
  echo ""
  [ -n "$HITS_HIGH" ] && { echo "• Known-format secret/token or private key in:";   printf '%s\n' "$HITS_HIGH" | cut -f1 | sort -u | sed 's/^/    - /'; }
  [ -n "$HITS_A4" ]   && { echo "• Hardcoded credential assignment in:";              printf '%s\n' "$HITS_A4"   | cut -f1 | sort -u | sed 's/^/    - /'; }
  [ -n "$HITS_FILE" ] && { echo "• Credential file staged for push:";                 printf '%s\n' "$HITS_FILE"               | sed 's/^/    - /'; }
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
