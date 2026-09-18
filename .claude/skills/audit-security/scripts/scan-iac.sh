#!/usr/bin/env bash
# scan-iac.sh — IaC class via `trivy config` (preferred) or checkov, both with check/DB updates
# disabled during analysis. Missing checks surface as ERROR tool-exit-N (fail closed).
TOOL=iac
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/scan-common.sh"

parse_args "--repo --out --cache --timeout" "$@"
resolve_repo
prepare_out
# trivy reads trivy.yaml and checkov .checkov.yaml from the cwd: run from the audit dir.
cd "$OUT" || fail out-dir-unwritable "cannot enter --out '$OUT'"

if command -v trivy >/dev/null 2>&1; then
  TOOL=trivy
  require_tool trivy --version
  RULESET=checks-offline
  ART="$OUT/iac.trivy.json"
  # Repo-side suppression: --ignorefile /dev/null replaces .trivyignore(.yaml); trivy.yaml is cwd-
  # relative (audit dir). Inline `trivy:ignore:<id>` comments have no off switch — declared residual.
  HARDENED=trivyignore,trivy-yaml
  RESIDUAL=trivy-ignore-comments
  # --include-non-failures: a fully-passing file still yields a Results entry, so it counts as analyzed.
  run_with_timeout "$TIMEOUT" trivy --cache-dir "$CACHE" config --skip-check-update --ignorefile /dev/null \
    --include-non-failures --format json --output "$ART" --exit-code 2 --quiet "$REPO" >"$OUT/$TOOL.log" 2>&1
  finish "$RC" 2 "$ART" '(d) => ({ paths: (d.Results || []).map((r) => r.Target), reason: "" })'
elif command -v checkov >/dev/null 2>&1; then
  TOOL=checkov
  require_tool checkov --version
  RULESET=builtin-offline
  ART_DIR="$OUT/iac-checkov"
  mkdir -p "$ART_DIR"
  ART="$ART_DIR/results_json.json"
  # Repo-side suppression: checkov opens <-d>/.checkov.y(a)ml, cwd and home defaults IN ADDITION to
  # --config-file (configargparse; keys absent from the explicit file still apply), so the empty
  # --config-file only shadows cwd/home — it is not a claim. Neither the repo's .checkov.y(a)ml nor
  # inline `checkov:skip=` comments have an off switch: both are residual, and a target that ships
  # the file degrades the class (reason=checkov-yaml-present) instead of pretending it was neutralised.
  printf '{}\n' >"$OUT/checkov-none.yaml"
  HARDENED=none
  RESIDUAL=checkov-yaml,checkov-skip-comments
  { [ -e "$REPO/.checkov.yaml" ] || [ -e "$REPO/.checkov.yml" ]; } && CAVEAT=checkov-yaml-present
  # No --quiet: it drops passed checks from the JSON too, so a fully-passing file would count as unanalyzed.
  run_with_timeout "$TIMEOUT" checkov -d "$REPO" -o json --output-file-path "$ART_DIR" \
    --config-file "$OUT/checkov-none.yaml" --skip-download --compact >"$OUT/$TOOL.log" 2>&1
  # results_json.json is one object per framework, or a bare object for a single framework.
  finish "$RC" 1 "$ART" '(d) => { const files = []; let errs = 0; for (const r of Array.isArray(d) ? d : [d]) { const res = (r || {}).results || {}; for (const k of ["passed_checks", "failed_checks", "skipped_checks"]) for (const c of res[k] || []) files.push(c.file_path); errs += (res.parsing_errors || []).length; } return { paths: files, reason: errs ? `parsing-errors:${errs}` : "" }; }'
else
  TOOL=trivy
  emit UNAVAILABLE binary-missing
fi
