#!/usr/bin/env bash
# Offline team smoke suite. Select one independent part with TEAM_SMOKE_PART=1 … 19, mail, channel,
# kit or purity. Parts run one after another by default; TEAM_SMOKE_PARALLEL=1 runs them concurrently,
# except the parts whose header carries the line `# team-smoke: serial` (timing assertions that
# assume an idle machine): those run afterwards, alone, so load never shows up as their failure.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
case "${TEAM_SMOKE_PART:-all}" in
  all) parts=(purity 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 mail channel kit) ;;
  [1-9]|1[0-9]|mail|channel|kit) parts=("$TEAM_SMOKE_PART") ;;
  purity) parts=(purity) ;;
  *) echo "team-smoke: TEAM_SMOKE_PART must be all, purity, mail, channel, kit or 1 … 19" >&2; exit 2 ;;
esac
run_part() {
  if [ "$1" = purity ]; then bash "$HERE/team-purity.sh"; else bash "$HERE/team-smoke-$1.sh"; fi
}
serial() { grep -qx '# team-smoke: serial' "$HERE/team-smoke-$1.sh" 2>/dev/null; }

if [ -z "${TEAM_SMOKE_PARALLEL:-}" ] || [ ${#parts[@]} -eq 1 ]; then
  for part in "${parts[@]}"; do run_part "$part"; done
else
  LOGS=$(mktemp -d); trap 'rm -rf "$LOGS"' EXIT
  pids=(); names=(); rc=0
  for part in "${parts[@]}"; do
    ! serial "$part" || continue
    run_part "$part" > "$LOGS/$part" 2>&1 & pids+=($!); names+=("$part")
  done
  i=0
  for p in ${pids[@]+"${pids[@]}"}; do
    if wait "$p"; then tail -n 1 "$LOGS/${names[$i]}"
    else echo "team-smoke: part ${names[$i]} failed"; sed 's/^/  | /' "$LOGS/${names[$i]}"; rc=1; fi
    i=$((i + 1))
  done
  for part in "${parts[@]}"; do
    serial "$part" || continue
    run_part "$part" || rc=1
  done
  [ "$rc" = 0 ] || exit 1
fi
echo "team-smoke: OK"
