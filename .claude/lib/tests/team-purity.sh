#!/usr/bin/env bash
# Purity test for the team layer: no project-specific identity in what every downstream inherits.
# The team harness was ported from a private project; its names, ticket keys and machine paths
# must not leak into the public template. A hit prints <file>:<line>: <text> and exits 1.
#
# Usage: bash .claude/lib/tests/team-purity.sh [root]     (root defaults to the starter checkout)
# Scope: .claude/lib .claude/team .claude/hooks .claude/commands .agents/reference tools/ docs/teams
#        .claude/dashboard
# Role names in code are Supervisor / TeamLead / Advisor / Reviewer; project names enter only
# through configuration (teams.channel.mail_suffix), never as literals.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT="${1:-$(cd "$HERE/../../.." && pwd)}"

scan() {  # scan <root> — the deny-list over the scope; prints hits, rc 1 on any
python3 -I - "$1" "$HERE/team-purity.sh" <<'PY'
import os
import re
import sys

root, self_path = sys.argv[1], os.path.realpath(sys.argv[2])
DENY = re.compile(r"(?i:takeTask)|FableTT|AstraTT|OpusTeam|OpusSupervisor|OpusMonitoring"
                  r"|OpusTT|TT_SESSION_ROLE|/Users/mrozo|\bTT-[0-9]+"
                  r"|SolTT|develop-netcore7|mail-tt|TT_TEAM")
PIN = re.compile(r"# source: taketask [0-9a-f]{7,40}")
SCOPE = (".claude/lib", ".claude/team", ".claude/hooks", ".claude/commands", ".agents/reference",
         "tools", "docs/teams", ".claude/dashboard")
hits = 0
for top in SCOPE:
    base = os.path.join(root, top)
    for d, dirs, files in os.walk(base):
        dirs[:] = sorted(x for x in dirs if x not in ("__pycache__", ".pytest_cache"))
        for name in sorted(files):
            path = os.path.join(d, name)
            if os.path.realpath(path) == self_path:
                continue
            try:
                with open(path, encoding="utf-8") as fh:
                    lines = fh.read().splitlines()
            except (UnicodeDecodeError, OSError):
                continue
            manifest = os.path.relpath(path, root) == ".claude/team/manifest.txt"
            for n, line in enumerate(lines, 1):
                # The one provenance pin: the manifest names the upstream it was re-synced from.
                if manifest and PIN.fullmatch(line):
                    continue
                if DENY.search(line):
                    hits += 1
                    print("%s:%d: %s" % (os.path.relpath(path, root), n, line.strip()[:160]))
if hits:
    print("team-purity: FAIL — %d line(s) carry project identity" % hits)
    sys.exit(1)
print("team-purity: OK")
PY
}

# The test of the test: a planted leak in a scratch root must fail, the pin line must not.
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/.claude/lib" "$T/.claude/team"
printf '# source: taketask ea141a197\n' > "$T/.claude/team/manifest.txt"
scan "$T" > "$T/out" || { cat "$T/out"; echo "team-purity: FAIL — the pin line was flagged"; exit 1; }
printf 'role=OpusTeam\n' > "$T/.claude/lib/x.sh"
! scan "$T" > "$T/out" || { echo "team-purity: FAIL — a planted leak passed"; exit 1; }
printf 'ticket AB-1 TT-12\n' > "$T/.claude/lib/x.sh"
! scan "$T" > "$T/out" || { echo "team-purity: FAIL — a ticket key passed"; exit 1; }
for leak in 'worker SolTT' 'git switch develop-netcore7' '/mail-tt' 'TT_TEAM_ROLE=coder'; do
  printf '%s\n' "$leak" > "$T/.claude/lib/x.sh"
  ! scan "$T" > "$T/out" || { echo "team-purity: FAIL — '$leak' passed"; exit 1; }
done
rm -f "$T/.claude/lib/x.sh"; mkdir -p "$T/docs/teams"
printf 'the Advisor was FableTT\n' > "$T/docs/teams/x.md"
! scan "$T" > "$T/out" || { echo "team-purity: FAIL — a leak in docs/teams passed"; exit 1; }
rm -f "$T/docs/teams/x.md"; mkdir -p "$T/.claude/dashboard"
printf '<h1>TAKETASK AGENT TREE</h1>\n' > "$T/.claude/dashboard/index.html"
! scan "$T" > "$T/out" || { echo "team-purity: FAIL — an upper-case leak in the dashboard passed"; exit 1; }

scan "$ROOT"
