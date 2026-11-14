#!/usr/bin/env bash
# order brief (team-brief.sh): in-flight list from the anchors, validation, no silent rewrite,
# check, archived by team-next. Later steps add the gate cases to this part.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-lib.sh"
smoke_init

smoke_team AB-1400 feature/AB-1400-x
B="bash .claude/lib/team-brief.sh"
ANCH="$MAIN/.agents/team/anchors"
draft() {  # draft <file> [section to drop] — a full brief, optionally without one section
  { echo "## Ticket"; echo "Add the export button."
    [ "${2:-}" = not ] || { echo; echo "## Not ordered"; echo "none stated"; }
    echo; echo "## In-flight work"; echo "- none"; } > "$1"
}

# ---- (a) inflight -------------------------------------------------------------------------------
run "$MAIN" $B inflight alfa; expect 0 "- none" "(a) no other anchors"
jq -n --arg c "$WORK/gone-beta" '{team: "beta", ticket: "AB-1401", branch: "feature/AB-1401-y",
  role: "coder", clone: $c}' > "$ANCH/beta.json"
run "$MAIN" $B inflight alfa
expect 0 "- beta: AB-1401 on feature/AB-1401-y (?, stage coder)" "(a) beta from its anchor"
has "alfa:" "$WORK/out" && fail "(a) the team lists itself"
jq --arg c "$(cd "$CLONE" && pwd -P)" '.team = "gamma" | .clone = $c' "$ANCH/beta.json" \
  > "$ANCH/gamma.json"
run "$MAIN" $B inflight alfa; expect 0 "- gamma: AB-1401 on feature/AB-1401-y (brainstorm, stage coder)" \
  "(a) mode read from the clone"
rm -f "$ANCH/gamma.json"
echo "team-smoke-21: (a) inflight OK"

# ---- (b) write validates ------------------------------------------------------------------------
draft "$WORK/bad.md" not
run "$MAIN" $B write alfa "$WORK/bad.md"; expect 4 "missing heading: ## Not ordered" "(b) missing"
[ ! -e "$TD/order-brief.md" ] || fail "(b) an invalid draft was placed"
printf '## Ticket\nx\n\n## Not ordered\n\n## In-flight work\n- none\n' > "$WORK/empty.md"
run "$MAIN" $B write alfa "$WORK/empty.md"; expect 4 "empty section: ## Not ordered" "(b) empty"
{ cat "$WORK/empty.md"; printf '\n## Ticket\ny\n'; } > "$WORK/twice.md"
run "$MAIN" $B write alfa "$WORK/twice.md"; expect 4 "appears 2 times: ## Ticket" "(b) duplicate"
draft "$WORK/ok.md"
run "$MAIN" $B write alfa "$WORK/ok.md"; expect 0 "order-brief.md" "(b) full draft"
head -n 1 "$TD/order-brief.md" | grep -qx 'ticket: AB-1400' || fail "(b) no ticket header"
has "Add the export button." "$TD/order-brief.md" || fail "(b) ticket text not copied"
run "$CLONE" $B write alfa "$WORK/ok.md"; expect 1 "main checkout" "(b) refused in a clone"
# A ticket pasted verbatim with its own h2 headings stays one section.
printf '## Ticket
## Description
Export.
## Acceptance
- works

## Not ordered
none stated

## In-flight work
- none
' \
  > "$WORK/h2.md"
run "$MAIN" $B write alfa "$WORK/h2.md" --replace; expect 0 "order-brief.md" "(b) ticket with own h2 headings"
printf '## Ticket
## Description

## Not ordered
none

## In-flight work
- none
' > "$WORK/h2e.md"
run "$MAIN" $B write alfa "$WORK/h2e.md" --replace; expect 0 "" "(b) a ticket heading alone is body"
draft "$WORK/ok.md"; run "$MAIN" $B write alfa "$WORK/ok.md" --replace; expect 0 "" "(b) restore"
echo "team-smoke-21: (b) write OK"

# ---- (c) no silent rewrite ----------------------------------------------------------------------
printf 'changed\n' >> "$WORK/ok.md"
run "$MAIN" $B write alfa "$WORK/ok.md"; expect 4 "--replace" "(c) second write refused"
has changed "$TD/order-brief.md" && fail "(c) the refused write changed the brief"
run "$MAIN" $B write alfa "$WORK/ok.md" --replace; expect 0 "" "(c) --replace"
has changed "$TD/order-brief.md" || fail "(c) --replace did not rewrite"
echo "team-smoke-21: (c) replace OK"

# ---- (d) check ----------------------------------------------------------------------------------
run "$MAIN" $B check alfa; expect 0 "order brief ok" "(d) check passes"
sed -i.bak '/^## In-flight work/d' "$TD/order-brief.md"
run "$MAIN" $B check alfa; expect 4 "missing heading: ## In-flight work" "(d) check catches a broken brief"
mv "$TD/order-brief.md.bak" "$TD/order-brief.md"
echo "team-smoke-21: (d) check OK"

# ---- (e) team-next archives the brief -----------------------------------------------------------
run "$MAIN" perl -e 'alarm 30; exec @ARGV' \
  bash .claude/lib/team-next.sh alfa AB-1402 feature/AB-1402-z origin/develop
expect 0 "was AB-1400" "(e) team-next"
[ ! -e "$TD/order-brief.md" ] || fail "(e) the brief stayed with the new ticket"
ls "$TD"/archive/AB-1400-*/order-brief.md >/dev/null 2>&1 || fail "(e) the brief was not archived"
run "$MAIN" $B check alfa; expect 4 "no order brief" "(e) the new ticket has no brief yet"
echo "team-smoke-21: (e) archive OK"

echo "team-smoke-21: OK"
