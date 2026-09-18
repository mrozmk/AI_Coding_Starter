#!/usr/bin/env bash
# scan-sast.sh — SAST class via semgrep. Needs a LOCAL ruleset (--rules <dir>): the registry is
# fetched at analysis time, which the no-network-during-analysis control forbids, so no ruleset is
# fail-closed ERROR, not `--config auto`.
TOOL=semgrep
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/scan-common.sh"

parse_args "--repo --out --cache --rules --timeout" "$@"
resolve_repo
prepare_out
require_tool semgrep --version
[ -n "$RULES" ] && [ -e "$RULES" ] || fail no-local-ruleset "--rules <local dir|file> is required; semgrep may not fetch rules during analysis"
# A ruleset with zero rules would scan nothing and report OK_CLEAN — a control not established.
grep -rqE '^[[:space:]]*-?[[:space:]]*id:' "$RULES" 2>/dev/null || fail no-local-ruleset "ruleset '$RULES' contains no rule (no 'id:' entry)"
RULES=$(cd "$(dirname "$RULES")" && pwd -P)/$(basename "$RULES")
RULESET=$(basename "$RULES")

ART="$OUT/sast.semgrep.json"
export SEMGREP_SEND_METRICS=off
# Repo-side suppression: --disable-nosem ignores `nosemgrep` comments, --no-git-ignore stops the
# repo's .gitignore from hiding files the inventory counts. `.semgrepignore` has no public off switch
# (only the [INTERNAL] --x-ignore-semgrepignore-files), so it stays a declared residual.
HARDENED=nosemgrep-comments,gitignore
RESIDUAL=semgrepignore
# --error makes findings exit 1 so they are distinguishable from a clean 0; tool errors exit 2+.
run_with_timeout "$TIMEOUT" semgrep scan --config "$RULES" --metrics=off --disable-version-check \
  --disable-nosem --no-git-ignore \
  --json --output "$ART" --error --quiet "$REPO" >"$OUT/$TOOL.log" 2>&1
# Units = files semgrep says it scanned (a ruleset whose languages match nothing scans zero files and
# still exits 0). Parse errors / per-file timeouts exit 0 without --strict, so they become a caveat.
finish "$RC" 1 "$ART" '(d) => ({ paths: (d.paths || {}).scanned || [], reason: (d.errors || []).length ? `scan-errors:${d.errors.length}` : "" })'
