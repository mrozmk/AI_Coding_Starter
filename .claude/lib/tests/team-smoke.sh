#!/usr/bin/env bash
# Offline team smoke suite. Select one independent part with TEAM_SMOKE_PART=1 … 14, mail or purity.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
case "${TEAM_SMOKE_PART:-all}" in
  all) parts=(purity 1 2 3 4 5 6 7 8 9 10 11 12 13 14 mail) ;;
  [1-9]|1[0-4]|mail) parts=("$TEAM_SMOKE_PART") ;;
  purity) parts=(purity) ;;
  *) echo "team-smoke: TEAM_SMOKE_PART must be all, purity, mail or 1 … 14" >&2; exit 2 ;;
esac
for part in "${parts[@]}"; do
  if [ "$part" = purity ]; then bash "$HERE/team-purity.sh"; else bash "$HERE/team-smoke-$part.sh"; fi
done
echo "team-smoke: OK"
