#!/usr/bin/env bash
# Offline team smoke suite. Select one independent part with TEAM_SMOKE_PART=1, 2, 3, 4 or mail.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
case "${TEAM_SMOKE_PART:-all}" in
  all) parts=(1 2 3 4 mail) ;;
  1|2|3|4|mail) parts=("$TEAM_SMOKE_PART") ;;
  *) echo "team-smoke: TEAM_SMOKE_PART must be all, 1, 2, 3, 4 or mail" >&2; exit 2 ;;
esac
for part in "${parts[@]}"; do bash "$HERE/team-smoke-$part.sh"; done
echo "team-smoke: OK"
