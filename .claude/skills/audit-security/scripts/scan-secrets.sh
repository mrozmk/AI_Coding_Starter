#!/usr/bin/env bash
# scan-secrets.sh — secrets class via gitleaks 8.x: `gitleaks git` (history) plus `gitleaks dir`
# (working tree — untracked and gitignored files such as .env never appear in the history scan),
# merged into one artifact; a non-git target gets the dir scan only. Contract and manifest line:
# scan-common.sh. gitleaks makes no network calls.
#
# Repo-side suppression (methodology.md → Repo-side suppression):
#   --config <skill config>   neutralised: the audited repo's .gitleaks.toml is precedence #4, --config is #1
#   --ignore-gitleaks-allow   neutralised: inline `gitleaks:allow` comments are ignored
#   -i <empty dir>            NOT a claim: it only shadows the cwd default. gitleaks 8.30 ALWAYS also
#                             loads <source>/.gitleaksignore (cmd/root.go, independent of -i) — no off
#                             switch, so it is residual; a target that ships the file degrades the class
#                             (reason=gitleaksignore-present) instead of being reported as hardened.
TOOL=gitleaks
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/scan-common.sh"

parse_args "--repo --out --cache --timeout" "$@"
resolve_repo
prepare_out
require_tool gitleaks version
RULESET=default
count_units

CONFIG="$(cd "$SCAN_DIR/.." && pwd -P)/config/gitleaks.toml"
[ -f "$CONFIG" ] || fail config-missing "pinned config $CONFIG is missing; refusing to fall back to the target's .gitleaks.toml"
IGNORE_NONE="$OUT/gitleaks-ignore-none"
mkdir -p "$IGNORE_NONE" 2>/dev/null || fail out-dir-unwritable "cannot create $IGNORE_NONE"
HARDENED=config,allow-comments
RESIDUAL=gitleaksignore
CAVEAT=""
[ -e "$REPO/.gitleaksignore" ] && CAVEAT=gitleaksignore-present

ART="$OUT/secrets.gitleaks.json"
HIST="$OUT/secrets.gitleaks.history.json"
TREE="$OUT/secrets.gitleaks.worktree.json"
rm -f "$ART" "$HIST" "$TREE"

# `gitleaks git` on a non-git directory exits 0 with "0 commits scanned" — it must never be the only
# scan. rev-parse (not `[ -d .git ]`) also recognises a linked worktree.
IS_GIT=0
[ "$(git -C "$REPO" rev-parse --is-inside-work-tree 2>/dev/null)" = "true" ] && IS_GIT=1

# One deadline for both invocations; a scan that starts after it is a TIMEOUT, not skipped.
SECONDS=0
scan() {  # $1 subcommand, $2 report path
  local left=$((TIMEOUT - SECONDS))
  [ "$left" -gt 0 ] || { RC=124; return; }
  # --exit-code 0: findings are read from the merged report, so the exit code means tool failure only.
  run_with_timeout "$left" gitleaks "$1" -c "$CONFIG" -i "$IGNORE_NONE" --ignore-gitleaks-allow --no-banner --redact \
    --report-format json --report-path "$2" --exit-code 0 "$REPO" >>"$OUT/$TOOL.log" 2>&1
}

if [ "$IS_GIT" -eq 1 ]; then
  scan git "$HIST"
  case "$RC" in 124) emit TIMEOUT ;; 0) ;; *) fail "tool-exit-$RC" "gitleaks git exited $RC (see $OUT/$TOOL.log)" ;; esac
fi
scan dir "$TREE"
case "$RC" in 124) emit TIMEOUT ;; 0) ;; *) fail "tool-exit-$RC" "gitleaks dir exited $RC (see $OUT/$TOOL.log)" ;; esac

# Merge: every finding tagged with its scope; dir-scan paths (File and the Fingerprint built from it)
# come back absolute and are made repo-relative so both scopes name files the same way and no host
# path enters the artifact. An unreadable report is ERROR, not clean.
COUNT=$(node -e '
  const fs = require("fs");
  const [hist, tree, out, repo] = process.argv.slice(1);
  const rel = (p) => (typeof p === "string" && p.startsWith(repo + "/") ? p.slice(repo.length + 1) : p);
  const load = (file, scope) => {
    if (!file) return [];
    let d; try { d = JSON.parse(fs.readFileSync(file, "utf8")); } catch { process.exit(3); }
    if (!Array.isArray(d)) process.exit(3);
    return d.map((x) => ({ ...x, File: rel(x.File), Fingerprint: rel(x.Fingerprint), Scope: scope }));
  };
  const all = [...load(hist, "history"), ...load(tree, "worktree")];
  fs.writeFileSync(out, JSON.stringify(all, null, 2) + "\n");
  process.stdout.write(String(all.length));
' "$([ "$IS_GIT" -eq 1 ] && printf '%s' "$HIST")" "$TREE" "$ART" "$REPO" 2>>"$OUT/$TOOL.log") || fail artifact-unreadable "cannot merge gitleaks reports (see $OUT/$TOOL.log)"

redact_artifact "$ART"
[ "$IS_GIT" -eq 1 ] && redact_artifact "$HIST"
redact_artifact "$TREE"
if [ "$COUNT" -gt 0 ]; then emit OK_FINDINGS "$CAVEAT"; else emit OK_CLEAN "$CAVEAT"; fi
