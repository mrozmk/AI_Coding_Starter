#!/usr/bin/env bash
# Seeding a team clone: copy the profile's seed files in, and refuse a seed that would overwrite a
# tracked file. Sourced by team-lib.sh (team_profile_load, TEAM_PROBLEMS); never executed.
# Bash 3.2 compatible.

# Copies, not symlinks: each team gets its own writable credential and permission files.
team_seed_files() {
  local root="$1" dir="$2" f
  team_profile_load "$root"
  # Per-clone excludes (Claude runtime state, handoffs) would otherwise dirty the clone's tree.
  [ ! -f "$root/.git/info/exclude" ] || cp "$root/.git/info/exclude" "$dir/.git/info/exclude"
  for f in ${TEAM_SEED_FILES[@]+"${TEAM_SEED_FILES[@]}"}; do
    if [ -e "$root/$f" ]; then
      mkdir -p "$dir/$(dirname "$f")"
      cp "$root/$f" "$dir/$f"
    fi
    # A seeded credential file stays private to the clone.
    [ "$f" != .env ] || [ ! -f "$dir/.env" ] || chmod 600 "$dir/.env"
  done
}

# Usage: team_seed_checks <root> <base> — refuse a seed that would overwrite a TRACKED file.
# The seed copy lands on top of a fresh checkout of <base>, so seeding a file that <base> tracks
# with different content leaves the clone dirty from its first second: every `git status` gate,
# the merge-check and the integration then read a change nobody made. Untracked or ignored files
# (credentials, settings.local.json) are exactly what seeding is for and never a problem.
team_seed_checks() {
  local root="$1" base="$2" f
  team_profile_load "$root"
  for f in ${TEAM_SEED_FILES[@]+"${TEAM_SEED_FILES[@]}"}; do
    git -C "$root" cat-file -e "$base:$f" 2>/dev/null || continue
    [ -e "$root/$f" ] || continue
    # `if`, not `&& continue`: under `set -e` a failing trailing AND-list would end the caller.
    if git -C "$root" show "$base:$f" 2>/dev/null | cmp -s - "$root/$f"; then continue; fi
    TEAM_PROBLEMS+=("seed file $f is tracked on $base with different content \
— drop it from teams.seed_files")
  done
}
