# scan-common.sh — sourced by every scan-<class>.sh. Contract: methodology.md → Phase 3.
#
# The wrappers are the security boundary: the host allow-lists them, never the raw binaries.
# Every wrapper prints exactly one manifest line as its LAST stdout line:
#   STATUS <tool> <version> <ruleset> <units> basis=<analyzed|in-scope> [reason=<slug>]
#          [artifact=<path relative to --out>] [hardened=<a,b>] [residual=<a,b|none>]
#   STATUS ∈ OK_FINDINGS | OK_CLEAN | ERROR | TIMEOUT | UNAVAILABLE
# `basis=analyzed` means <units> was read back from the tool's own output (what it really analyzed);
# `basis=in-scope` means the wrapper could only count the files in scope (the tool exposes no scanned
# list). The runner treats only `analyzed` as evidence of analysis; a reason on an OK_* line is a caveat
# (parse errors, timeouts) that turns the class into a gap. `artifact` names the file the runner
# ingests findings from; `hardened` / `residual` declare which repo-side suppression mechanisms the
# wrapper neutralised and which it could not (methodology.md → Repo-side suppression).
# Exit code: 0 for OK_* / UNAVAILABLE, 1 for ERROR / TIMEOUT. The runner reads the line, not the code.
set -uo pipefail

SCAN_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
RUNNER="$SCAN_DIR/audit-runner.mjs"
CLASS=$(basename "$0" .sh); CLASS=${CLASS#scan-}
REPO="" OUT="" CACHE="" RULES="" TIMEOUT=600
VERSION="-" RULESET="-" UNITS=0 BASIS=in-scope REASON="" ART="" HARDENED="" RESIDUAL=""
# A caveat the wrapper knows before the tool runs (e.g. the target ships a suppression file the tool
# honours with no off switch). `finish` prepends it to the derive_units reason so the class degrades
# to partial:<slug> — the wrapper declares the hole and fails closed instead of claiming hardening.
CAVEAT=""

# Same skip-lists as audit-runner.mjs SKIP_DIRS / SKIP_PATHS — both sides must count the same units.
SKIP_DIRS=(.git node_modules vendor dist build .venv venv __pycache__ .next .turbo target coverage .cache)
SKIP_PATHS=(.agents/audits)

emit() {  # $1 status, $2 reason (optional) → prints manifest, exits
  local status="$1" reason="${2:-}"
  local line="$status $TOOL $VERSION $RULESET $UNITS basis=$BASIS"
  [ -n "$reason" ] && line="$line reason=$reason"
  case "$status" in OK_FINDINGS|OK_CLEAN)
    [ -n "$ART" ] && line="$line artifact=${ART#$OUT/}"
    [ -n "$HARDENED" ] && line="$line hardened=$HARDENED"
    [ -n "$RESIDUAL" ] && line="$line residual=$RESIDUAL" ;;
  esac
  echo "$line"
  case "$status" in OK_FINDINGS|OK_CLEAN|UNAVAILABLE) exit 0 ;; *) exit 1 ;; esac
}

fail() { echo "$TOOL: $2" >&2; emit ERROR "$1"; }  # $1 slug, $2 human message

parse_args() {  # $1 = space-separated allow-list of flags; rest = argv
  local allowed=" $1 "; shift
  while [ $# -gt 0 ]; do
    case "$allowed" in *" $1 "*) ;; *) fail bad-flag "unknown flag '$1' (allowed:$allowed)" ;; esac
    [ $# -ge 2 ] || fail bad-flag "flag '$1' needs a value"
    case "$1" in
      --repo) REPO="$2" ;;
      --out) OUT="$2" ;;
      --cache) CACHE="$2" ;;
      --rules) RULES="$2" ;;
      --timeout) TIMEOUT="$2" ;;
    esac
    shift 2
  done
  [ -n "$REPO" ] || fail bad-flag "--repo is required"
  [ -n "$OUT" ] || fail bad-flag "--out is required"
  case "$TIMEOUT" in ''|*[!0-9]*) fail bad-flag "--timeout must be an integer" ;; esac
}

resolve_repo() {
  [ -d "$REPO" ] || fail target-not-dir "target '$REPO' is not a directory"
  REPO=$(cd "$REPO" && pwd -P)
  [ "$REPO" != "/" ] || fail target-refused "refusing to scan /"
  # Inside .git there is no worktree, so the toplevel check below cannot fire — refuse it explicitly.
  [ "$(git -C "$REPO" rev-parse --is-inside-git-dir 2>/dev/null)" != "true" ] || fail target-refused "refusing to scan a .git directory as the target"
  local top
  if top=$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null); then
    [ "$top" = "$REPO" ] || fail target-not-repo-root "target must be the worktree toplevel ($top), got $REPO"
  fi
}

prepare_out() {
  mkdir -p "$OUT" 2>/dev/null || fail out-dir-unwritable "cannot create --out '$OUT'"
  [ -w "$OUT" ] || fail out-dir-unwritable "--out '$OUT' is not writable"
  OUT=$(cd "$OUT" && pwd -P)
  [ "$OUT" != "$REPO" ] && [ "$OUT" != "/" ] || fail out-dir-refused "--out must not be the repo root or /"
  [ -n "$CACHE" ] || CACHE="$OUT/cache"
  mkdir -p "$CACHE" 2>/dev/null || fail out-dir-unwritable "cannot create cache dir '$CACHE'"
  CACHE=$(cd "$CACHE" && pwd -P)
  # Scanners read user-level config from $HOME (~/.semgrep, ~/.trivy.yaml, checkov's home config) and
  # write caches there; an isolated home under the cache dir keeps both inside the audit. git needs no
  # ~/.gitconfig for the read-only commands gitleaks runs.
  mkdir -p "$CACHE/home" 2>/dev/null || fail out-dir-unwritable "cannot create isolated home '$CACHE/home'"
  export HOME="$CACHE/home" XDG_CACHE_HOME="$CACHE" XDG_CONFIG_HOME="$CACHE/home/.config"
}

require_tool() {  # $1 tool; rest: version args. Sets VERSION or emits UNAVAILABLE.
  local tool="$1"; shift
  command -v "$tool" >/dev/null 2>&1 || emit UNAVAILABLE binary-missing
  VERSION=$("$tool" "$@" 2>/dev/null | head -n 1 | tr -s ' \t' '_' | tr -d '\r')
  [ -n "$VERSION" ] || VERSION=unknown
}

# Files in scope (basis=in-scope). This is NOT what the tool analyzed — use derive_units for that.
count_units() {
  local prune=() d
  for d in "${SKIP_DIRS[@]}"; do prune+=(-name "$d" -o); done
  for d in "${SKIP_PATHS[@]}"; do prune+=(-path "$REPO/$d" -o); done
  unset 'prune[${#prune[@]}-1]'
  # -type d on the prune side: a regular file named `build` or `dist` is a unit, not a skipped dir.
  # A root-level `.git` FILE is a linked worktree's gitdir pointer, not a unit (runner: inventory).
  UNITS=$(find "$REPO" \( -type d \( "${prune[@]}" \) \) -prune -o -type f ! -path "$REPO/.git" -print 2>/dev/null | wc -l | tr -d ' ')
  BASIS=in-scope
}

# Units the tool itself reports having analyzed (basis=analyzed). $2 is a JS arrow `(d) => ({ paths,
# reason })` over the parsed artifact; `paths` (the analyzed files, normalised to repo-relative) is
# also written to $OUT/<class>.units.json so the runner can diff them against the inventory — a count
# alone cannot tell "scanned the source" from "scanned two config files". An unparsable artifact is
# ERROR, never a clean scan.
derive_units() {  # $1 artifact, $2 JS expression
  local out
  out=$(node -e '
    const fs = require("fs");
    const [file, expr, repo, unitsFile, cls, tool] = process.argv.slice(1);
    let d; try { d = JSON.parse(fs.readFileSync(file, "utf8")); } catch { process.exit(3); }
    const r = new Function("d", `return (${expr})(d ?? {})`)(d);
    // semgrep/osv print absolute paths, trivy repo-relative, checkov "/rel" — one shape for the runner.
    const rel = (p) => { p = String(p); if (p.startsWith(repo + "/")) return p.slice(repo.length + 1); return p.startsWith("/") ? p.slice(1) : p; };
    const paths = [...new Set((r.paths || []).filter((p) => typeof p === "string" && p).map(rel))].sort();
    fs.writeFileSync(unitsFile, JSON.stringify({ schema_version: 1, class: cls, tool, paths }, null, 2) + "\n");
    process.stdout.write(`${paths.length} ${r.reason ?? ""}`);
  ' "$1" "$2" "$REPO" "$OUT/$CLASS.units.json" "$CLASS" "$TOOL" 2>>"$OUT/$TOOL.log") || fail artifact-unreadable "cannot derive analyzed units from $1"
  UNITS=${out%% *}
  REASON=${out#* }; [ "$REASON" = "$out" ] && REASON=""
  BASIS=analyzed
}

# macOS ships no `timeout`; a background job plus a watchdog is the portable form. Sets RC (124 on timeout).
run_with_timeout() {
  local secs="$1"; shift
  "$@" &
  local pid=$!
  ( sleep "$secs"; kill "$pid" 2>/dev/null ) &
  local watchdog=$!
  wait "$pid"; RC=$?
  kill "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null
  if [ "$RC" -eq 143 ] || [ "$RC" -eq 137 ]; then RC=124; fi
}

# Redaction at ingest, before any model or the runner reads the artifact. Uses the runner's own
# pattern list so bash and node never disagree on what a secret looks like.
redact_artifact() {  # $1 file
  [ -f "$1" ] || fail artifact-missing "scanner reported success but wrote no artifact at $1"
  node "$RUNNER" redact --file "$1" >/dev/null 2>&1 || fail redaction-failed "could not redact $1"
}

finish() {  # $1 RC of the tool, $2 exit code meaning findings, $3 artifact path, $4 derive_units expression (optional)
  local rc="$1" findings_rc="$2" art="$3" expr="${4:-}"
  case "$rc" in
    124) emit TIMEOUT ;;
    0|"$findings_rc")
      redact_artifact "$art"
      [ -z "$expr" ] || derive_units "$art" "$expr"
      [ -z "$CAVEAT" ] || REASON="$CAVEAT${REASON:+,$REASON}"
      if [ "$rc" -eq 0 ]; then emit OK_CLEAN "$REASON"; else emit OK_FINDINGS "$REASON"; fi ;;
    *) fail "tool-exit-$rc" "scanner exited $rc (see $OUT/$TOOL.log)" ;;
  esac
}
