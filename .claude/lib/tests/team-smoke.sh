#!/usr/bin/env bash
# Offline team smoke suite. Select one independent part with TEAM_SMOKE_PART=1 … 26, mail, channel,
# kit, policy, sessions, host, host-wsl, notify, roles, dialog, stop or purity (parts 4, 8, 11 and 13 were removed). Parts run one after another by default; TEAM_SMOKE_PARALLEL=1 runs them concurrently,
# except the parts whose header carries the line `# team-smoke: serial` (timing assertions that
# assume an idle machine): those run afterwards, alone, so load never shows up as their failure.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# A fixture must never reach the calling Claude session's messaging socket (team-suite.sh says why).
unset CLAUDE_CODE_MESSAGING_SOCKET CLAUDE_CODE_MESSAGING_TOKEN
case "${TEAM_SMOKE_PART:-all}" in
  all) parts=(purity 1 2 3 5 6 7 9 10 12 14 15 16 17 18 19 20 21 22 23 24 25 26 mail channel kit policy sessions host host-wsl notify roles dialog stop) ;;
  4|8|11|13) echo "team-smoke: part $TEAM_SMOKE_PART was removed" >&2; exit 2 ;;
  [1-9]|1[0-9]|2[0-9]|mail|channel|kit|policy|sessions|host|host-wsl|notify|roles|dialog|stop) parts=("$TEAM_SMOKE_PART") ;;
  purity) parts=(purity) ;;
  *) echo "team-smoke: TEAM_SMOKE_PART must be all, purity, mail, channel, kit, policy, sessions, host, host-wsl, notify, roles, dialog, stop or 1 … 26" >&2; exit 2 ;;
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
