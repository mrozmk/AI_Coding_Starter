#!/usr/bin/env bash
# The ONE integration lock per target branch, shared by team-integrate.sh and the solo worker flow
# (AGENTS.md: `merge --ff-only` + `worker-next.sh release`). Whoever publishes onto a branch takes
# it first, so two writers can never interleave a validate → push window on the same base.
#
# Usage: bash .claude/lib/team-integrate-lock.sh <op> …
#   acquire <base> --owner <label> [--pid <pid>]
#   release <base> --owner <label>
#   status  <base>                      → `free` | `<owner> <pid> <at>`
#
# The lock is `<main root>/.agents/team/integrate/locks/<base with / → -->.lock`, a DIRECTORY:
# `mkdir` is the atomic test-and-set. `owner`/`pid`/`at` are written to a tmp file and moved in
# afterwards, so a reader either sees a complete field or none.
#
# A stale lock is NEVER taken over automatically — two recovering integrators would both "break"
# the same lock and race the push. A dead owner only earns a hint (the `team-run.sh unlock`
# pattern); removing it stays a deliberate `release`.
#
# Sourcable: `til_acquire <main root> <base> <owner> <pid>`, `til_release <main root> <base>
# <owner>`, `til_status <main root> <base>` take the main root EXPLICITLY — team-integrate.sh
# resolves it before it `cd`s into the team clone, where `--show-toplevel` would answer the clone.
# Only the CLI derives the root from cwd, and refuses to run inside a team clone.
#
# Exit: 0 ok · 2 usage / run from a team clone · 3 held by somebody else / not ours to release
# Bash 3.2 compatible (macOS /bin/bash).

til_lock_path() {  # til_lock_path <main root> <base> → the lock directory path
  local slug
  # One `/` becomes `--`, so `release/1.2` and `release-1.2` cannot collide on one slug.
  slug="$(printf '%s' "$2" | sed 's|/|--|g')"
  printf '%s\n' "$1/.agents/team/integrate/locks/$slug.lock"
}

til_field() {  # til_field <lock dir> <name> → the field, or empty
  cat "$1/$2" 2>/dev/null || true
}

# A per-acquire nonce, written INTO the lock: it is what lets a release prove the lock in front of
# it is the one it took, and not a later owner's lock with the same label.
til_token() { printf '%s-%s-%s\n' "$(date -u +%s)" "$$" "$RANDOM$RANDOM"; }

# The guard mutex. Both acquire and release hold `<lock>.guard` for their WHOLE read-check-modify
# sequence, so the lock directory is only ever inspected and changed by one process at a time.
#
# Why a second mutex at all: `mkdir` alone makes acquire atomic, but release is inherently
# read-then-modify (read the owner, then remove). Any gap there — however it is closed, including
# renaming the directory away and checking afterwards — leaves a window in which the lock can be
# released and re-taken, and the releaser then acts on somebody else's lock while the base looks
# free. The guard removes the window instead of trying to detect it: while it is held there is no
# moment at which the base reads as free to another writer, and the lock directory itself is never
# renamed or nested.
#
# A stale guard is NEVER taken over automatically (the same rule as the lock itself): the spin is
# bounded and then refuses with the path to remove by hand.
til_guard_take() {  # til_guard_take <lock dir> <base>
  local g="$1.guard" tries=0 max="${TIL_GUARD_TRIES:-50}" p
  mkdir -p "$(dirname "$g")" 2>/dev/null || {
    echo "error: cannot create $(dirname "$g")" >&2; return 1; }
  until mkdir "$g" 2>/dev/null; do
    tries=$((tries + 1))
    if [ "$tries" -ge "$max" ]; then
      p="$(cat "$g/pid" 2>/dev/null || echo unknown)"
      echo "error: lock guard busy for $2 (pid $p) — if no integrator is running, remove $g by hand" >&2
      return 3
    fi
    sleep 0.1
  done
  # From here on the guard is OURS, so every exit path below has to drop it — including a signal.
  til_guard_arm "$1"
  echo $$ > "$g/pid" || { til_guard_release "$1"; echo "error: cannot write $g/pid" >&2; return 1; }
}

# The guarded section must survive a catchable signal without leaving the guard behind (the next
# acquire AND release would both refuse until somebody removes it by hand). The caller's own
# INT/TERM/HUP traps are saved and put back by `til_guard_release`, so a sourcing script keeps its
# handlers outside the guarded window.
TIL_SAVED_TRAPS=""
til_guard_arm() {  # til_guard_arm <lock dir>
  TIL_SAVED_TRAPS="$(trap -p INT TERM HUP)"
  trap 'til_guard_free "'"$1"'"; exit 130' INT
  trap 'til_guard_free "'"$1"'"; exit 143' TERM
  trap 'til_guard_free "'"$1"'"; exit 129' HUP
}

# Drops the guard, THEN restores whatever the caller had armed for those signals: the guard must
# stay protected until it is actually gone — a signal arriving after `trap -` and before the `rm`
# would run the caller's handler (or the default) and leave the guard behind.
til_guard_release() {  # til_guard_release <lock dir> → non-zero when the guard is still there
  local rc=0
  til_guard_free "$1" || rc=1
  trap - INT TERM HUP
  [ -z "$TIL_SAVED_TRAPS" ] || eval "$TIL_SAVED_TRAPS"
  TIL_SAVED_TRAPS=""
  return "$rc"
}

# Reports failure instead of swallowing it: this is called in `||` chains, where a trailing `echo`
# would hand back rc 0 with the guard still on disk, and the next acquire AND release would refuse.
til_guard_free() {  # til_guard_free <lock dir>
  rm -rf "$1.guard" 2>/dev/null || true
  [ ! -e "$1.guard" ] || {
    echo "error: cannot remove the lock guard $1.guard — remove it by hand" >&2
    return 1; }
}

# `TIL_TOKEN` carries the nonce of the lock this process took, so its own release can prove it is
# removing that lock and not a later one. A release WITHOUT a token (the CLI, a supervisor clearing
# a dead owner's lock) still works on the owner label alone.
TIL_TOKEN=""
til_acquire() {  # til_acquire <main root> <base> <owner> <pid>
  local d="" o p a hint="" tmp created=0 base="$2"
  d="$(til_lock_path "$1" "$2")"
  [ -n "$3" ] || { echo "error: acquire needs --owner <label>" >&2; return 2; }
  til_guard_take "$d" "$2" || return 3
  if [ -d "$d" ]; then
    o="$(til_field "$d" owner)"; p="$(til_field "$d" pid)"; a="$(til_field "$d" at)"
    # A half-written lock (no owner, no pid) counts as HELD: the writer is mid-acquire.
    case "$o" in
      team-integrate:*)
        if [ -n "$p" ] && [ "$p" != none ] && ! kill -0 "$p" 2>/dev/null; then
          hint=" — stale: team-integrate-lock.sh release $2 --owner $o"
        fi ;;
    esac
    til_guard_release "$d"
    echo "error: integration lock for $2 held by ${o:-unknown} (pid ${p:-unknown}) since ${a:-unknown}$hint" >&2
    return 3
  fi
  # Every step is checked: this function is called as `til_acquire … || exit 3`, which DISABLES
  # errexit inside it, so an unchecked failure here would fall through to a successful
  # `til_guard_release` and report a lock that does not exist.
  tmp="$d.fields.$$"
  acq_fail() {  # acq_fail <what> — clean up ONLY our own partial state, never a foreign file
    rm -rf "$tmp"
    [ "$created" = 0 ] || rm -rf "$d"
    til_guard_release "$d"
    # `$2` here would be acq_fail's own argument, not the base — hence the captured $base.
    echo "error: cannot take the integration lock for $base ($1)" >&2
  }
  rm -rf "$tmp"
  mkdir "$tmp" 2>/dev/null || { acq_fail "mkdir $tmp"; return 1; }
  mkdir "$d" 2>/dev/null || { acq_fail "mkdir $d"; return 1; }
  created=1
  # TEST SEAM (fixtures only): a write failure in the middle of the sequence, to prove the partial
  # state is cleaned up and the failure is reported instead of swallowed.
  [ "${TIL_FAIL_AFTER_MKDIR:-0}" != 1 ] || { acq_fail "injected write failure"; return 1; }
  printf '%s\n' "$3" > "$tmp/owner" || { acq_fail "write owner"; return 1; }
  printf '%s\n' "${4:-none}" > "$tmp/pid" || { acq_fail "write pid"; return 1; }
  til_token > "$tmp/token" || { acq_fail "write token"; return 1; }
  date -u +%Y-%m-%dT%H:%M:%SZ > "$tmp/at" || { acq_fail "write at"; return 1; }
  TIL_TOKEN="$(cat "$tmp/token")" || { acq_fail "read token"; return 1; }
  mv "$tmp/owner" "$tmp/pid" "$tmp/token" "$tmp/at" "$d/" || { acq_fail "mv fields"; return 1; }
  rmdir "$tmp" 2>/dev/null || true
  [ -f "$d/owner" ] && [ -f "$d/token" ] || { acq_fail "fields missing after mv"; return 1; }
  til_guard_release "$d"
}

til_release() {  # til_release <main root> <base> <owner> [token]
  local d o t rc=0
  d="$(til_lock_path "$1" "$2")"
  [ -n "$3" ] || { echo "error: release needs --owner <label>" >&2; return 2; }
  til_guard_take "$d" "$2" || return 3
  # TEST SEAM (fixtures only, explicit non-empty value): runs INSIDE the guarded section, which is
  # exactly where the old implementation was vulnerable — a concurrent release/acquire staged here
  # must now be refused rather than interleaved.
  # Subshell with errexit OFF: `eval` parses a fresh command list, and errexit DOES apply inside
  # it, so a staged command that refuses (which is the point) would otherwise abort the release
  # mid-guard and leak the guard directory.
  [ -z "${TIL_RACE_HOOK:-}" ] || ( set +e; eval "$TIL_RACE_HOOK" ) || true
  if [ ! -d "$d" ]; then
    echo "error: no integration lock for $2" >&2
    rc=3
  else
    o="$(til_field "$d" owner)"; t="$(til_field "$d" token)"
    if [ "$o" != "$3" ]; then
      echo "error: integration lock for $2 is held by ${o:-unknown}, not $3" >&2
      rc=3
    elif [ -n "${4:-}" ] && [ "$t" != "$4" ]; then
      # Same label, different lock: ours was already released and the base re-taken.
      echo "error: integration lock for $2 is a later lock of $o — not released" >&2
      rc=3
    else
      # `|| true`: under the CLI's errexit a failed `rm` would abort the function right here and
      # the guard would never be released.
      rm -rf "$d" 2>/dev/null || true
      [ ! -e "$d" ] || { echo "error: cannot remove the integration lock $d" >&2; rc=3; }
    fi
  fi
  til_guard_release "$d" || rc=3
  return "$rc"
}

til_status() {  # til_status <main root> <base> → free | <owner> <pid> <at>
  local d
  d="$(til_lock_path "$1" "$2")"
  if [ -d "$d" ]; then
    printf '%s %s %s\n' "$(til_field "$d" owner)" "$(til_field "$d" pid)" "$(til_field "$d" at)"
  else
    echo free
  fi
}

til_main() {
  local op base="" owner="" pid="none" root
  op="${1:-}"; [ $# -eq 0 ] || shift
  case "$op" in acquire|release|status) ;;
    *) sed -n '6,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 2 ;;
  esac
  while [ $# -gt 0 ]; do
    case "$1" in
      --owner) owner="${2:-}"; shift 2 || return 2 ;;
      --pid)   pid="${2:-}"; shift 2 || return 2 ;;
      -*)      echo "error: unknown option '$1'" >&2; return 2 ;;
      *)       [ -z "$base" ] || { echo "error: one <base> only" >&2; return 2; }
               base="$1"; shift ;;
    esac
  done
  [ -n "$base" ] || { echo "error: $op needs <base>" >&2; return 2; }
  root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$root" ] || { echo "error: not a git repository" >&2; return 2; }
  # A clone's lock directory would be invisible to every other writer on that branch.
  [ ! -f "$root/.agents/team/team.json" ] \
    || { echo "error: run from the main checkout, not a team clone" >&2; return 2; }
  case "$op" in
    acquire) til_acquire "$root" "$base" "$owner" "$pid" ;;
    release) til_release "$root" "$base" "$owner" ;;
    status)  til_status "$root" "$base" ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -euo pipefail
  til_main "$@"
fi
