#!/usr/bin/env bash
# scan-sca.sh — SCA class via trivy (preferred: one stable offline surface) or osv-scanner. Both run
# offline against a pre-downloaded DB in --cache; downloading the DB is a separate human step
# (methodology.md → Phase 3). A missing DB surfaces as ERROR tool-exit-N, never as a clean scan.
TOOL=sca
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/scan-common.sh"

parse_args "--repo --out --cache --timeout" "$@"
resolve_repo
prepare_out
# Both tools read their config from the current directory (trivy.yaml; osv-scanner.toml is per
# scanned dir and overridden below): run from the audit dir so the audited repo's copy is never read.
cd "$OUT" || fail out-dir-unwritable "cannot enter --out '$OUT'"

if command -v trivy >/dev/null 2>&1; then
  TOOL=trivy
  require_tool trivy --version
  RULESET=db-offline
  ART="$OUT/sca.trivy.json"
  # Repo-side suppression: --ignorefile /dev/null replaces the repo's .trivyignore(.yaml); trivy.yaml
  # is looked up in the cwd, which is the audit dir. Nothing else applies to a vuln scan.
  HARDENED=trivyignore,trivy-yaml
  RESIDUAL=none
  # --list-all-pkgs: without it a lockfile with zero vulnerabilities has no Results entry, so the
  # analyzed count would read 0 for a clean repo. --skip-java-db-update: a .jar in the tree would
  # otherwise trigger a Java DB download mid-analysis (pkg/javadb/client.go) — --skip-db-update does
  # not cover it; the Java DB is the same human pre-step as the vuln DB (methodology.md → Phase 3).
  run_with_timeout "$TIMEOUT" trivy --cache-dir "$CACHE" fs --scanners vuln --skip-db-update --skip-java-db-update --offline-scan \
    --ignorefile /dev/null --list-all-pkgs --format json --output "$ART" --exit-code 2 --quiet "$REPO" >"$OUT/$TOOL.log" 2>&1
  finish "$RC" 2 "$ART" '(d) => ({ paths: (d.Results || []).map((r) => r.Target), reason: "" })'
elif command -v osv-scanner >/dev/null 2>&1; then
  TOOL=osv-scanner
  require_tool osv-scanner --version
  RULESET=db-offline
  ART="$OUT/sca.osv.json"
  # v2 surface: `scan source`, --output-file, and the local DB via OSV_SCANNER_LOCAL_DB_CACHE_DIRECTORY
  # (--local-db-path is gone). Exit 1 = vulnerabilities, 127 = general error, 128 = no packages found
  # (fail-closed ERROR tool-exit-128 — a scan that parsed nothing is not clean).
  export OSV_SCANNER_LOCAL_DB_CACHE_DIRECTORY="$CACHE"
  # Repo-side suppression: --no-ignore stops .gitignore from hiding manifests; an empty --config
  # overrides every osv-scanner.toml in the tree (IgnoredVulns / PackageOverrides).
  : >"$OUT/osv-none.toml"
  HARDENED=gitignore,osv-scanner-toml
  RESIDUAL=none
  # --all-packages: same reason as trivy's --list-all-pkgs — a clean source must still be listed.
  run_with_timeout "$TIMEOUT" osv-scanner scan source --offline --all-packages --no-ignore --config "$OUT/osv-none.toml" \
    --format json --output-file "$ART" -r "$REPO" >"$OUT/$TOOL.log" 2>&1
  finish "$RC" 1 "$ART" '(d) => ({ paths: (d.results || []).map((r) => (r.source || {}).path), reason: "" })'
else
  TOOL=trivy
  emit UNAVAILABLE binary-missing
fi
