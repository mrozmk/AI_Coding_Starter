# Tracker comments at the per-run TeamLead's gates (.agents/reference/tracker-comments.md §5–§6,
# team-lead.md §11). Sourced by team-verdict.sh for `plan approve` and `acceptance
# accept`; uses its globals (TD RD RRD RUN MAIN MODE TICKET GATE last LIB, rec, bad).
# Opt-in: nothing runs unless workflow.tracker_comments is true in the main checkout's profile and
# the run's tracker is not none (trk_on). Every refusal exits 10.
# Bash 3.2 compatible.

TRACKER_LINE=""   # the comparator's line, stored in the verdict as `tracker`
TRK_TMP="$(mktemp -d)"; trap 'rm -rf "$TRK_TMP"' EXIT
trk_fail() { echo "error: tracker comments: $1" >&2; exit 10; }

trk_on() {
  local p="$MAIN/.claude/project-profile.json" t
  [ -f "$p" ] && [ "$(jq -r '.workflow.tracker_comments // false' "$p" 2>/dev/null)" = true ] || return 1
  t="$(jq -r '.tracker // empty' "$TD/team.json")"
  [ "${t:-jira}" != none ]
}

# trk_ledger <rev> <artifact> → the snapshot path the artifact's `## From tracker comments` ledger
# names on its `Read:` line at <rev>; empty when there is no such ledger.
trk_ledger() {
  git show "$1:$2" 2>/dev/null | awk '/^## From tracker comments$/ { f = 1; next } /^## / { f = 0 }
    f && /^Read: / && match($0, /snapshot [^ ]+/) { print substr($0, RSTART + 9, RLENGTH - 9); exit }'
}

# trk_baseline <planner record> <plan> → BASE (a local copy of the baseline snapshot) and
# BASE_FROM (<artifact>@<rev>). The plan gate and acceptance read the plan's own ledger, else its
# source spec's (contract §5.3).
BASE=""; BASE_FROM=""
trk_baseline() {
  local r="$1" rev plan spec art snap key
  rev="$(rec "$r" output_rev)"
  spec="$(jq -r '[.artifacts[] | select(startswith(".agents/specs/"))][0] // empty' "$r")"
  plan="$(jq -r '[.artifacts[] | select(startswith(".agents/plans/"))][0] // empty' "$r")"
  art=""; snap=""
  if [ "$2" = plan ] && [ -n "$plan" ]; then
    art="$plan"; snap="$(trk_ledger "$rev" "$plan")"
    if [ -z "$snap" ] && [ -z "$spec" ]; then
      spec="$(git show "$rev:$plan" 2>/dev/null | sed -n 's/^\*\*Source spec:\*\* *//p' | head -n 1 | tr -d '`')"
    fi
  fi
  if [ -z "$snap" ] && [ -n "$spec" ] && [ "$MODE" != quick ]; then
    art="$spec"; snap="$(trk_ledger "$rev" "$spec")"
  fi
  [ -n "$art" ] || trk_fail "$(basename "$r") names no ${2} to read the ledger from"
  [ -n "$snap" ] || trk_fail "$art at $(basename "$r")'s output_rev has no '## From tracker comments' ledger with a 'Read: … snapshot <path>' line — the planner reads the ticket at entry (tracker-comments.md §3–§4)"
  git show "$rev:$snap" > "$TRK_TMP/base.json" 2>/dev/null \
    || trk_fail "the ledger's snapshot $snap is not committed at $(basename "$r")'s output_rev"
  key="$(jq -r '.key // empty' "$TRK_TMP/base.json" 2>/dev/null || true)"
  [ "$key" = "${TICKET#\#}" ] || trk_fail "the snapshot $snap is for '${key}', the run's ticket is ${TICKET}"
  BASE="$TRK_TMP/base.json"; BASE_FROM="$art@${rev:0:12}"
}

# trk_fresh <dir> <gated record> → FRESH: the lead's newest tracker-<gate>-<n>.json in <dir>, for
# the run's ticket, read no earlier than the gated record was written.
FRESH=""
trk_fresh() {
  local n f ra wa key
  n="$(ls "$1" 2>/dev/null | grep -E "^tracker-$GATE-[0-9]+\.json\$" | sort -t- -k3,3n | tail -n 1 || true)"
  f="$1/$n"; [ -n "$n" ] && [ -s "$f" ] \
    || trk_fail "no fresh read: snapshot the ticket into ${1#"$TD"/}/tracker-$GATE-<n>.json first (tracker-comments.md §2–§3)"
  key="$(jq -r '.key // empty' "$f" 2>/dev/null || true)"
  [ "$key" = "${TICKET#\#}" ] || trk_fail "$n is for '${key}', the run's ticket is ${TICKET}"
  ra="$(jq -r '.read_at // empty' "$f")"; wa="$(rec "$2" written_at)"
  [ -n "$ra" ] && ! [[ "${ra:0:19}" < "${wa:0:19}" ]] \
    || trk_fail "$n was read at ${ra:-?}, before $(basename "$2") was written (${wa}) — read the ticket again"
  FRESH="$f"
}

# trk_compare [--reconciled <list>] → TRK_RC (0 · 3 · 4) and TRACKER_LINE; the result JSON in
# $TRK_TMP/cmp.json.
TRK_RC=0
trk_compare() {
  [ -f "$LIB/tracker-snapshot.mjs" ] || trk_fail "no .claude/lib/tracker-snapshot.mjs in this clone"
  TRK_RC=0
  TRACKER_LINE="$(node "$LIB/tracker-snapshot.mjs" compare "$BASE" "$FRESH" "$@" --out "$TRK_TMP/cmp.json")" \
    || TRK_RC=$?
  case "$TRK_RC" in 0|3|4) ;; *) trk_fail "the comparator failed (exit $TRK_RC): ${TRACKER_LINE}" ;; esac
}

trk_gate() {
  local pr ids id sect missing="" recon=""
  if [ "$GATE" = acceptance ]; then
    pr=""
    for f in $(GATE=plan verdicts); do [ "$(rec "$RD/$f" verdict)" != approve ] || pr="$RD/$(rec "$RD/$f" for)"; done
    [ -n "$pr" ] && [ -f "$pr" ] || trk_fail "no plan approve in run $RUN — nothing to take the baseline from"
    trk_baseline "$pr" plan
    trk_fresh "$RRD" "$last"
    [ ! -f "$RD/answers.md" ] \
      || recon="$(grep -oE '[A-Za-z0-9_-]+@[0-9a-f]{64}' "$RD/answers.md" | sort -u | paste -sd, - || true)"
    if [ -n "$recon" ]; then trk_compare --reconciled "$recon"; else trk_compare; fi
    case "$TRK_RC" in
      0) ;;
      4) trk_fail "${TRACKER_LINE} — the read is not complete: open a decision, never accept on it" ;;
      3) sect="$(awk '/^## Ordered vs delivered$/ { f = 1; next } /^## / { f = 0 } f' "$RRD/acceptance-brief.md")"
         ids="$(jq -r '(.new + .edited + .removed)[]' "$TRK_TMP/cmp.json")"
         [ "$(jq -r .description_changed "$TRK_TMP/cmp.json")" != true ] || ids="$ids description"
         for id in $ids; do printf '%s\n' "$sect" | grep -qwF -- "$id" || missing="$missing $id"; done
         [ -z "$missing" ] || trk_fail "${TRACKER_LINE} — name${missing} under '## Ordered vs delivered' in acceptance-brief.md, or order a rework / open a decision" ;;
    esac
  else
    trk_baseline "$last" "$GATE"
    trk_fresh "$RD" "$last"
    trk_compare
    case "$TRK_RC" in
      3) trk_fail "${TRACKER_LINE} — revise with the list as findings (the planner reconciles, new snapshot)" ;;
      4) trk_fail "${TRACKER_LINE} — escalate with a decision" ;;
    esac
  fi
  TRACKER_LINE="$TRACKER_LINE · baseline $BASE_FROM"
}
