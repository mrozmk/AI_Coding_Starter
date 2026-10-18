#!/usr/bin/env bash
# PR merge state for the dashboard snapshot (TT-823): asks Azure DevOps, time-boxed and cached.
# Sourced by team-snapshot.sh: relies on its err/age helpers and $W scratch dir, and on
# team_ado_coords from team-lib.sh. Bash 3.2 compatible. pr_state runs in $(…), so the
# "ADO timed out" flag that spans teams is the file $W/ado-timeout, not a variable.
# Env: TEAM_DASH_CACHE (dir reused between snapshots, set by serve.sh), TEAM_DASH_PR_SECS (4).

# Stock macOS has no `timeout`; the child gets its own process group so az and its children die too.
pr_timebox() {  # pr_timebox <secs> <cmd...> → exit 124 on timeout
  perl -e '$t = shift; $p = fork // exit 1;
    if (!$p) { setpgrp(0, 0); exec @ARGV or exit 127 }
    $SIG{ALRM} = sub { kill "KILL", -$p; waitpid $p, 0; exit 124 };
    alarm $t; waitpid $p, 0; exit($? >> 8)' "$@"
}

# pr_state <clone dir> <team> <pr> → completed | abandoned | active | unknown
pr_state() {
  local dir="$1" team="$2" pr="$3" c="" s="" org secs="${TEAM_DASH_PR_SECS:-4}"
  [[ "$secs" =~ ^[1-9][0-9]*$ ]] || secs=4
  if [ -n "${TEAM_DASH_CACHE:-}" ] && [ -d "$TEAM_DASH_CACHE" ]; then
    c="$TEAM_DASH_CACHE/pr-$team-$pr"
    [ ! -f "$c" ] || s="$(cat "$c")"
    # Only a completed PR never changes back (ADO can reactivate an abandoned one); the rest is
    # retried at most once a minute.
    case "$s" in
      completed) ;;
      abandoned|active|unknown) [ "$(age "$c")" -lt 60 ] || s="" ;;
      *) s="" ;;
    esac
  fi
  if [ -z "$s" ] && [ -f "$W/ado-timeout" ]; then
    # One hung ADO must not stall the snapshot once per finished team; no cache write either.
    err "$team: PR $pr skipped — ADO timed out earlier in this snapshot"
    echo unknown
    return 0
  fi
  if [ -z "$s" ]; then
    # `root` is a team-snapshot.sh global and is NOT set when pr_state runs standalone from a test,
    # so `$dir` is the fallback for both the profile read and the adapter path (`set -u`).
    local prov r="${root:-$dir}"
    prov="${TEAM_DASH_PR_PROVIDER:-}"
    [ -n "$prov" ] || prov="$(jq -r '.teams.pr_provider // "azure-devops"' \
      "$r/.claude/project-profile.json" 2>/dev/null || echo azure-devops)"
    if [ "$prov" = github ]; then
      # The adapter already normalises the status; the timeout flag keeps its ADO-era file name.
      if (cd "$dir" && pr_timebox "$secs" bash "$r/.claude/lib/team-pr.sh" state "$pr") \
        > "$W/pr-$team.json" 2>/dev/null; then
        s="$(jq -r '.status // empty' "$W/pr-$team.json" 2>/dev/null)" || s=""
      elif [ $? = 124 ]; then
        touch "$W/ado-timeout"
      fi
    else
      org="$(cd "$dir" && team_ado_coords >/dev/null 2>&1 && echo "$ADO_ORG_URL")" || org=""
      # team_pr_json inlined: perl execs, so it cannot run a bash function. Output to a file, not a
      # pipe: a killed az must not keep the caller waiting on its stdout.
      if [ -n "$org" ]; then
        if pr_timebox "$secs" az repos pr show --org "$org" --id "$pr" -o json \
          > "$W/pr-$team.json" 2>/dev/null; then
          s="$(jq -r '.status // empty' "$W/pr-$team.json" 2>/dev/null)" || s=""
        elif [ $? = 124 ]; then
          touch "$W/ado-timeout"
        fi
      fi
    fi
    case "$s" in completed|abandoned|active) ;; *) s=unknown ;; esac
    [ -z "$c" ] || printf '%s\n' "$s" > "$c"
  fi
  [ "$s" != unknown ] || err "$team: PR $pr status unknown"
  echo "$s"
}
