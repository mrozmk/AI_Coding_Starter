#!/usr/bin/env bash
# The per-run TeamLead's identity and permission profile.
# Usage: bash .claude/lib/team-lead.sh materialize <team>   (from the main checkout)
#        bash .claude/lib/team-lead.sh whoami                (exit 0 when the caller is the lead)
#        bash .claude/lib/team-lead.sh pending <team>        (main checkout or the team's clone)
#        bash .claude/lib/team-lead.sh end <team> | finalize <team> merged | relaunch <team>
#        bash .claude/lib/team-lead.sh digest-check <team> <plan path>
#        bash .claude/lib/team-lead.sh diff <team>   (acceptance-diff.patch + .stat in the round's dir)
#        bash .claude/lib/team-lead.sh decision open|answer|withdraw|list <team> …  (team-lead-decision.sh)
#        bash .claude/lib/team-lead.sh decision relay <team> d-<n> --text "<team> d-<n> <reply>"
#          (the Supervisor, main checkout)
#        bash .claude/lib/team-lead.sh notes-init <team> | log-append <team> merged|closed | owns <team>
#   pending lists the lead's open items — pending decisions first, then mode (team.json mode
#   `lead` with no mode verdict yet), then relayed (an answer the Supervisor relayed, not applied
#   yet), then ask (runs/<run>/asks/, not class-tier, not bound to a pending decision), stop (no
#   ask, no .answered), rejected, gate,
#   attention (not idle_prompt, not a permission prompt an ask covers), inbox (this run's or
#   run-less messages), oldest first:
#   `<kind> <ref> — <summary>`. end stops the lead session (0 when none runs); finalize ends it
#   once per run, resolves its notifications and marks runs/<run>/finalized; relaunch asks the live runner to relaunch a dead
#   lead. notes-init creates runs/<run>/teamlead-notes.md (six headings) when absent; log-append
#   appends the notes once per run (runs/<run>/log-appended) to <main>/.agents/team/teamlead-log.md;
#   owns exits 0 when the team's current run has its own TeamLead (teamlead.json run). digest-check exits 0 when runs/<run>/digest.md has a `scope:` header, or in quick mode
#   when no path the plan names maps to a routed domain (.claude/memory-domains.json); else 1.
#   materialize writes <clone>/.agents/team/teamlead.settings.json (mode 600): the role profile
#   .claude/team/sessions/TeamLead.settings.json unioned with the project and local deny/ask
#   rules, the PR host's update verbs denied for teams.pr_provider, guard-teamlead-write.sh
#   registered for Edit|Write|NotebookEdit and guard-teamlead-bash.sh for Bash.
#   It refuses a profile that is not the per-run one (env role TeamLead, deny git commit and
#   team-record.sh) — the retired global TeamLead.settings.json a partial sync left behind.
#   e.g. bash .claude/lib/team-lead.sh materialize alfa
# Contract: .agents/reference/team-lead.md
set -euo pipefail

usage() { sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
[ $# -ge 1 ] || usage
. "$(dirname "$0")/team-lib.sh"
. "$(dirname "$0")/team-lead-lib.sh"
LIB="$(cd "$(dirname "$0")" && pwd)"
. "$LIB/team-lead-decision.sh"
. "$LIB/team-ask.sh"
. "$LIB/team-modes.sh"

# resolve <team> → TD (the clone's team dir) and MAIN (the main checkout), from either side. In the
# clone the main checkout is the one the runner recorded, never `git rev-parse` of the clone.
resolve() {
  local r
  team_check_name "$1" || exit 2
  r="$(team_root)"
  if [ -f "$r/.agents/team/team.json" ]; then
    TD="$r/.agents/team"; MAIN="$(team_lead_json main_root)"
  else
    team_profile_load "$r"; TD="$(team_clone_dir "$1" "$r")/.agents/team"; MAIN="$r"
  fi
  [ -f "$TD/team.json" ] || { echo "error: no team clone for $1" >&2; exit 1; }
  [ "$(jq -r .team "$TD/team.json")" = "$1" ] || { echo "error: this clone is not team $1" >&2; exit 1; }
  RUN="$(cat "$TD/run" 2>/dev/null || true)"
}

gate_decided() {  # gate_decided <record basename> — a non-escalate verdict names it
  local v
  for v in "$TD/runs/$RUN"/teamlead-*-*.json; do
    [ -f "$v" ] || continue
    jq -e --arg r "$1" '.for == $r and .verdict != "escalate"' "$v" >/dev/null && return 0
  done
  return 1
}

pending_decision_for() {  # pending_decision_for <a-n> — a pending (or relayed) decision is bound to that ask
  local f
  for f in "$TD/runs/$RUN"/decisions/d-*.md; do
    [ -f "$f" ] && [ "$(dfm "$f" bind_ask)" = "$1" ] || continue
    [ "$(dfm "$f" status)" = pending ] || relayed_unapplied "$f" && return 0
  done
  return 1
}
# relayed_unapplied <decision file> — the Supervisor relayed its answer and the lead has not applied
# it yet: still answered, and (a plan-gate decision) no plan verdict names its source.
relayed_unapplied() {
  local v
  [ "$(dfm "$1" status)" = answered ] || return 1
  v="$(dfm "$1" answered_via)"; [ "${v%% *}" = supervisor-window ] || return 1
  [ "$(dfm "$1" gate)" != plan ] || ! gate_decided "$(basename "$(dfm "$1" source)")"
}
# ask_covers <role> <utc> — an ask of that stage is waiting, or was filed within 10 s of <utc>.
ask_covers() {
  local a d
  for a in $(ask_ids); do
    [ "$(ask_get "$a" role)" = "$1" ] || continue
    [ "$(ask_get "$a" state)" != waiting ] || return 0
    d=$(( $(team_epoch "$2") - $(team_epoch "$(ask_get "$a" filed_at)") )); d="${d#-}"
    [ "$d" -gt 10 ] || return 0
  done
  return 1
}

# operator_touches — every human action the run needed: the distinct lines of runs/<run>/
# operator-touches (a human-answered decision, a startup dialog first seen) plus an older run's
# operator-window answers in answers.md. team_audit.py counts by the same rule.
operator_touches() {
  local rd="$TD/runs/$RUN" n=0 w=0
  [ ! -f "$rd/operator-touches" ] || n="$(cut -d' ' -f2- "$rd/operator-touches" | sort -u | grep -c . || true)"
  [ ! -f "$rd/answers.md" ] || w="$(grep -c '\[authority operator-window\]' "$rd/answers.md" || true)"
  echo $(( ${n:-0} + ${w:-0} ))
}

# One line per item, sorted by a 14-digit UTC key that is cut off before printing.
pending() {
  local f role attempt last ts since="" stage l gate rr ir a
  resolve "$1"
  {
    if [ -n "$RUN" ]; then
      # Stage records of the current rework round (team-lead.md §9); round 1's stay behind.
      rr="$(team_run_ref "$TD" "$RUN")"
      # Open human decisions sort before everything: the Operator's answers wait on them.
      for f in "$TD/runs/$RUN"/decisions/d-*.md; do
        [ -f "$f" ] && [ "$(dfm "$f" status)" = pending ] || continue
        echo "00000000000000 decision .agents/team/runs/$RUN/decisions/$(basename "$f") — $(sed -n '/^## Question$/{n;p;q;}' "$f")"
      done
      # Mode lead: the choice comes before every stage (team-lead.md §1a); the runner applies it.
      if [ "$(team_mode "$TD/team.json" 2>/dev/null)" = lead ] && [ -z "$(team_mode_verdict "$TD" "$RUN")" ]; then
        echo "00000000000001 mode .agents/team/team.json — choose the run's mode (team-lead.md → Mode choice): team-verdict.sh mode brainstorm|quick|cli --message \"<reason>\""
      fi
      # An answer the Supervisor relayed waits for the lead to apply it (team-lead.md §7).
      for f in "$TD/runs/$RUN"/decisions/d-*.md; do
        [ -f "$f" ] && relayed_unapplied "$f" || continue
        a="$(dfm "$f" bind_ask)"
        echo "00000000000001 relayed .agents/team/runs/$RUN/decisions/$(basename "$f")${a:+ (ask $a)} — apply the stored answer"
      done
      # Open asks of the stages (team-lead.md §6): not answered, not bound to a pending decision; a
      # class ask is answered by the hook itself within the same call.
      ask_init "$TD" 2>/dev/null || true
      for a in $(ask_ids); do
        case "$(ask_get "$a" state)" in waiting|timed-out) ;; *) continue ;; esac
        [ "$(ask_get "$a" tier)" != class ] && [ ! -f "$ASK_D/$a.answer.json" ] || continue
        pending_decision_for "$a" && continue
        echo "$(ask_get "$a" filed_at | tr -dc 0-9) ask .agents/team/runs/$RUN/asks/$a.json — $(ask_get "$a" role) $(ask_get "$a" kind)$([ "$(ask_get "$a" tier)" != operator ] || echo ' operator') — $(ask_one_line "$a")"
      done
      for f in "$TD/runs/$rr"/*-*-*.json; do
        [ -f "$f" ] || continue
        case "$(basename "$f")" in teamlead-*) continue ;; esac  # verdicts, not stage records
        role="$(jq -r .role "$f")"; attempt="$(jq -r .attempt "$f")"
        last="$(ls "$TD/runs/$rr" | grep -E "^$role-$attempt-[0-9]+\.json\$" | sort -t- -k3,3n \
          | tail -n 1)"
        [ "$(basename "$f")" = "$last" ] || continue
        ts="$(jq -r .written_at "$f" | tr -dc 0-9)"
        # A record the runner rejected and handed to the lead (team-run-stop.sh): acked, no answer yet.
        a="${rr#"$RUN"}"; a="${a#/}${a:+/}$(basename "$f")"
        if [ -f "$(dirname "$f")/rejected-$(basename "$f" .json)" ] && [ "$(cat "$TD/acked" 2>/dev/null)" = "$a" ] \
          && [ ! -e "$f.answered" ]; then
          echo "$ts rejected .agents/team/runs/$rr/$(basename "$f") — $(head -n 1 "$(dirname "$f")/rejected-$(basename "$f" .json)")"
          continue
        fi
        case "$role $(jq -r .verdict "$f")" in
          *" blocked"|*" failed")
            # Answered, or listed once as its ask.
            [ ! -e "$f.answered" ] && [ -z "$(ask_open_for_record "$a")" ] || continue
            echo "$ts stop .agents/team/runs/$rr/$(basename "$f") — $(jq -r '.message // ""' "$f")" ;;
          # A gate stays open until a verdict other than escalate names its record.
          "planner done")
            [ ! -e "$f.accepted" ] && ! gate_decided "$(basename "$f")" || continue
            echo "$ts gate .agents/team/runs/$RUN/$(basename "$f") — plan gate" ;;
        esac
      done
      # Attention lines after the active stage's newest record are still unanswered.
      stage="$(jq -r '.role // empty' "$TD/session.json" 2>/dev/null || true)"
      if [ -n "$stage" ]; then
        f="$(ls -1 "$TD/runs/$rr/$stage"-*-*.json 2>/dev/null | tail -n 1 || true)"
        [ -z "$f" ] || since="$(jq -r .written_at "$f" | tr -dc 0-9)"
      fi
      [ ! -f "$TD/runs/$RUN/attention" ] || while IFS= read -r l; do
        ts="$(printf '%s' "${l%% *}" | tr -dc 0-9)"
        [ -n "$ts" ] && [[ "$ts" > "$since" ]] || continue
        # An idle stage is a notice, not a decision owed (the ring still comes, team-lead.md §6).
        [ "$(cut -d' ' -f2 <<<"$l")" != idle_prompt ] || continue
        # A permission prompt the ask channel covers is listed as its ask.
        if [ "$(cut -d' ' -f2 <<<"$l")" = permission_prompt ] && ask_covers "${stage:-}" "${l%% *}"; then
          continue
        fi
        echo "$ts attention .agents/team/runs/$RUN/attention — ${stage:-?}: ${l#* }"
      done < "$TD/runs/$RUN/attention"
    fi
    if [ -n "$MAIN" ]; then
      for f in "$MAIN/.agents/team/inbox/$1/new"/*; do
        [ -f "$f" ] || continue
        # Another run's leftover is not this lead's to act on; a message without a run is.
        ir="$(dfm "$f" run)"
        [ -z "$ir" ] || [ "$ir" = "$RUN" ] || continue
        echo "$(basename "$f" | cut -c1-16 | tr -dc 0-9) inbox $f — $(dfm "$f" event)"
      done
    fi
  } | sort -s -k1,1 | cut -d' ' -f2-
}

# The constraint digest is required at the plan gate in brainstorm (decisions.md alone is input) and
# in quick only when the plan names a path of a routed memory domain.
digest_check() {
  local root t dom
  resolve "$1"
  grep -q '^scope:' "$TD/runs/$RUN/digest.md" 2>/dev/null && return 0
  root="${TD%/.agents/team}"
  if [ "$(jq -r '.mode // "brainstorm"' "$TD/team.json")" = quick ]; then
    . "$(dirname "$0")/../hooks/lib/memory-domain.sh"
    memory_domain_config "$root"
    dom=""
    # Paths are the plan's backticked tokens with a slash, without a :line or #anchor suffix.
    while IFS= read -r t; do
      t="${t#./}"; t="${t%%[:#]*}"
      dom="$(memory_domain_for "$root" "$t")"
      [ -z "$dom" ] || [ "$dom" = "$MEMORY_DOMAIN_FALLBACK" ] || break
      dom=""
    done < <(grep -oE '`[^` ]+/[^` ]*`' "$root/$2" 2>/dev/null | tr -d '`' || true)
    [ -n "$dom" ] || return 0
  fi
  echo "constraint digest missing — see the Digest section of the TeamLead prompt" >&2
  return 1
}

# The acceptance diff: base_sha..the current round's newest qa record's output_rev in the clone,
# without this run's spec and plan (the blind check must not see them). Written into the round's dir
# (runs/<run>/ or runs/<run>/r<n>/), where the blind check and the brief of that round go too.
# Prints the two paths only.
acceptance_diff() {
  local root qa rev base pl a ex=() d
  resolve "$1"
  [ -n "$RUN" ] || { echo "error: no current run" >&2; exit 4; }
  root="${TD%/.agents/team}"; d="$TD/runs/$(team_run_ref "$TD" "$RUN")"
  qa="$(ls "$d" 2>/dev/null | grep -E '^qa-[0-9]+-[0-9]+\.json$' | sort -t- -k2,2n -k3,3n | tail -n 1 || true)"
  [ -n "$qa" ] || { echo "error: no qa record in run $RUN" >&2; exit 4; }
  rev="$(jq -r '.output_rev // empty' "$d/$qa")"; base="$(jq -r '.base_sha // empty' "$TD/team.json")"
  pl="$(ls -1 "$TD/runs/$RUN"/planner-*.json.accepted 2>/dev/null | tail -n 1 || true)"
  if [ -n "$pl" ]; then
    for a in $(jq -r '.artifacts[]? | select(startswith(".agents/specs/") or startswith(".agents/plans/"))' "${pl%.accepted}"); do
      ex+=(":(exclude)$a")
      case "$a" in .agents/plans/active/*) ex+=(":(exclude).agents/plans/done/${a#.agents/plans/active/}") ;; esac
    done
  fi
  git -C "$root" diff "$base..$rev" -- . ${ex[@]+"${ex[@]}"} > "$d/acceptance-diff.patch" \
    || { echo "error: git diff $base..$rev failed in the clone" >&2; exit 1; }
  git -C "$root" diff --stat "$base..$rev" -- . ${ex[@]+"${ex[@]}"} > "$d/acceptance-diff.stat"
  echo "$d/acceptance-diff.patch"; echo "$d/acceptance-diff.stat"
}

end_lead() {
  resolve "$1"
  team_end_session "$TD" "$(team_tmux_name "$1" lead)" lead "${TEAM_EXIT_WAIT_SECS:-60}" \
    || { echo "error: TeamLead session of $1 did not end" >&2; exit 1; }
  rm -f "$MAIN/.agents/team/registry/$(team_tmux_name "$1" lead).reg.json"
  echo "TeamLead ended: $1"
}

finalize() {
  end_lead "$1" >/dev/null
  # The run is over: its inbox messages go to done/ (team-inbox.sh close-run) and its Operator
  # notifications are resolved; never blocks.
  [ -z "$RUN" ] || bash "$LIB/team-inbox.sh" --main "$MAIN" close-run "$1" "$RUN" >/dev/null 2>&1 || true
  [ -z "$RUN" ] || bash "$LIB/notify.sh" resolve --team "$1" --run "$RUN" --all >/dev/null 2>&1 || true
  if [ -n "$RUN" ] && [ -d "$TD/runs/$RUN" ] && [ ! -e "$TD/runs/$RUN/finalized" ]; then
    printf '%s %s\n' "$2" "$(team_utc)" > "$TD/runs/$RUN/finalized"
  fi
  echo "finalized: $1 ${RUN:-none} $2"
}

# The lead's notes (team-lead.md §10): one file per run at the run root, read by every round's wrapup.
NOTES_HEADINGS="## Order ambiguities|## No-rule questions|## Gate misses|## Operator cases|## Wrapup decisions|## Late answers"
notes_init() {
  local f h
  resolve "$1"
  [ -n "$RUN" ] || { echo "error: no current run" >&2; exit 4; }
  f="$TD/runs/$RUN/teamlead-notes.md"; mkdir -p "$(dirname "$f")"
  if [ ! -f "$f" ]; then
    ( IFS='|'; for h in $NOTES_HEADINGS; do printf '%s\n\n' "$h"; done ) > "$f.tmp" && mv "$f.tmp" "$f"
  fi
  echo "$f"
}

# log_append <team> <merged|closed> — the run's notes as one block of the shared log in the main
# checkout, once per run. The block is built aside and appended under a mkdir lock, so blocks of
# clones finishing at once never interleave.
log_append() {
  local outcome="$2" rd log lock tmp waited=0 max f
  resolve "$1"
  case "$outcome" in merged|closed) ;; *) usage ;; esac
  [ -n "$RUN" ] && [ "$(jq -r '.run // empty' "$TD/teamlead.json" 2>/dev/null)" = "$RUN" ] \
    || { echo "no TeamLead in run ${RUN:-none} — nothing to append"; return 0; }
  rd="$TD/runs/$RUN"
  [ ! -e "$rd/log-appended" ] || { echo "teamlead log: already appended for $RUN"; return 0; }
  [ -n "$MAIN" ] && [ -d "$MAIN/.agents" ] && git -C "$MAIN" rev-parse --git-dir >/dev/null 2>&1 \
    || { echo "error: main checkout '${MAIN:-none}' is not a checkout with .agents/" >&2; exit 1; }
  mkdir -p "$MAIN/.agents/team"
  log="$MAIN/.agents/team/teamlead-log.md"; lock="$MAIN/.agents/team/teamlead-log.lock"
  tmp="$rd/.teamlead-log-block.tmp"
  # The run's own notes carry the count first, so the shared log inherits it (team-lead.md §10).
  f="$rd/teamlead-notes.md"; touch "$f"
  { echo "Operator touches: $(operator_touches)"; grep -v '^Operator touches: ' "$f" || true; } > "$f.tmp" \
    && mv "$f.tmp" "$f"
  { echo "### $(team_utc) $1 $(jq -r '.ticket // "-"' "$TD/team.json") $RUN — $outcome"; echo
    if [ -s "$rd/teamlead-notes.md" ]; then cat "$rd/teamlead-notes.md"; else echo "(no notes)"; fi
    echo; } > "$tmp"
  max=$(( ${TEAM_LOG_LOCK_SECS:-30} * 5 ))
  until mkdir "$lock" 2>/dev/null; do
    [ "$waited" -lt "$max" ] || { rm -f "$tmp"; echo "error: $lock held for ${TEAM_LOG_LOCK_SECS:-30}s" >&2; exit 1; }
    sleep 0.2; waited=$((waited + 1))
  done
  cat "$tmp" >> "$log" && team_utc > "$rd/log-appended"
  rmdir "$lock"; rm -f "$tmp"
  echo "teamlead log: appended $RUN ($outcome) to $log"
}

owns() {
  resolve "$1"
  [ -n "$RUN" ] && [ "$(jq -r '.run // empty' "$TD/teamlead.json" 2>/dev/null)" = "$RUN" ]
}

# Same union as supervisor-sessions.sh materialize, written into the clone instead of the main
# checkout's watch/profiles: the lead runs in the clone, the global roles do not.
materialize() {
  local team="$1" root clone out tpl pr='[]' L mq
  team_check_name "$team" || exit 2
  root="$(team_root)"
  [ ! -f "$root/.agents/team/team.json" ] \
    || { echo "error: team clone — run team-lead.sh materialize from the main checkout" >&2; exit 1; }
  team_profile_load "$root"
  clone="$(team_clone_dir "$team" "$root")"
  [ -f "$clone/.agents/team/team.json" ] || { echo "error: $clone is not a team clone" >&2; exit 1; }
  tpl="$root/.claude/team/sessions/TeamLead.settings.json"
  jq -e '.env.TEAM_SESSION_ROLE == "TeamLead"
    and ((.permissions.deny // []) | index("Bash(git commit*)") != null
         and index("Bash(bash .claude/lib/team-record.sh*)") != null)' "$tpl" >/dev/null 2>&1 \
    || { echo "error: $tpl is not the per-run TeamLead profile (the retired global one?) — run /maintain:sync-from-starter" >&2; exit 1; }
  case "$TEAM_PR_PROVIDER" in
    github) pr='["Bash(gh pr merge*)","Bash(gh pr edit*)"]' ;;
    azure-devops) pr='["Bash(az repos pr update*)"]' ;;
  esac
  # The lead runs every team tool and its guards from the main checkout (the copy the runner and the
  # stage hook run): allow rules take the main path, the clone spelling is denied. The deny/ask
  # union also reads the clone's project settings, which the lead loads by launching there.
  L="$(team_lead_lib_prefix "$root")" || { echo "error: main checkout path holds a quote" >&2; exit 1; }
  mq="$(team_lead_shell_word "$root")"
  out="$clone/.agents/team/teamlead.settings.json"
  ( umask 077
    jq -n --argjson pr "$pr" --arg L "$L" --arg H "$root/.claude/hooks" --arg Mq "$mq" --arg team "$team" \
      --slurpfile t "$tpl" --slurpfile m "$root/.claude/settings.json" \
      --slurpfile ml "$(f="$root/.claude/settings.local.json"; [ -f "$f" ] && echo "$f" || echo /dev/null)" \
      --slurpfile c "$(f="$clone/.claude/settings.json"; [ -f "$f" ] && echo "$f" || echo /dev/null)" \
      --slurpfile cl "$(f="$clone/.claude/settings.local.json"; [ -f "$f" ] && echo "$f" || echo /dev/null)" '
      def cloned: test("^Bash\\(\\*?(bash|node) \\.claude/lib/");
      def twin: sub("^Bash\\((?<s>\\*?)(?<c>bash|node) \\.claude/lib/"; "Bash(\(.s)\(.c) " + $L);
      $t[0] as $tp | [$tp, ($m[0] // {}), ($ml[0] // {}), ($c[0] // {}), ($cl[0] // {})] as $all
      | ($tp.permissions.allow // []) as $a0
      | [$all[] | .permissions.deny // [] | .[]] as $d0
      | [$all[] | .permissions.ask // [] | .[]] as $k0
      | {env: $tp.env, _main_lib: $L,
         permissions: {
           allow: ([$a0[] | if cloned then twin
                    elif . == "Bash(*.claude/lib/codex-bg.sh)" then "Bash(*" + $L + "codex-bg.sh)"
                    else . end]
                   + ["Bash(bash " + $L + "team-inbox.sh --main " + $Mq + " done " + $team + " *)"] | unique),
           deny: ($d0 + $pr
                  + [$a0[] | select(cloned) | capture("^Bash\\((?<c>bash|node) \\.claude/lib/(?<s>[^ )*]+)")
                     | "Bash(\(.c) .claude/lib/\(.s)*)"]
                  + ["Bash(*bash .claude/lib/codex-bg.sh*)", "Bash(bash .claude/lib/team-inbox.sh*)"]
                  + [$d0[] | select(cloned) | twin] | unique),
           ask: ($k0 + [$k0[] | select(cloned) | twin] | unique)},
         hooks: {PreToolUse: [{matcher: "Edit|Write|NotebookEdit", hooks: [{type: "command",
           onFailure: "block", command: ("bash \"" + $H + "/guard-teamlead-write.sh\"")}]},
           {matcher: "Bash", hooks: [{type: "command", onFailure: "block",
           command: ("bash \"" + $H + "/guard-teamlead-bash.sh\"")}]}]}}' \
      > "$out.tmp"
    mv "$out.tmp" "$out" )
  jq -r '"profile TeamLead: \(.permissions.deny | length) deny,"
    + " \(.permissions.ask | length) ask, \(.permissions.allow | length) allow"' "$out"
}

case "$1" in
  materialize) [ $# -eq 2 ] || usage; materialize "$2" ;;
  whoami) [ $# -eq 1 ] || usage; team_lead_caller ;;
  pending) [ $# -eq 2 ] || usage; pending "$2" ;;
  digest-check) [ $# -eq 3 ] || usage; digest_check "$2" "$3" ;;
  decision) shift; decision_main "$@" ;;
  diff) [ $# -eq 2 ] || usage; acceptance_diff "$2" ;;
  notes-init) [ $# -eq 2 ] || usage; notes_init "$2" ;;
  log-append) [ $# -eq 3 ] || usage; log_append "$2" "$3" ;;
  owns) [ $# -eq 2 ] || usage; owns "$2" ;;
  end) [ $# -eq 2 ] || usage; end_lead "$2" ;;
  finalize) [ $# -eq 3 ] && [ "$3" = merged ] || usage; finalize "$2" "$3" ;;
  relaunch) [ $# -eq 2 ] || usage; resolve "$2"; touch "$TD/relaunch-lead"
    echo "TeamLead relaunch requested: $2 (the live runner relaunches it at its next poll)" ;;
  *) usage ;;
esac
