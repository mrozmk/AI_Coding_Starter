#!/usr/bin/env bash
# Clone-state checks for worker-next.sh, split out by the 500-line cap (TT-871, TT-876).
# Sourced, never executed; expects DIR and W_PROBLEMS from the caller, which sets
# `set -euo pipefail`.
# Contract: .agents/reference/worker-clone.md

# The caller's whole ancestor chain is skipped by pid, not argv: a wrapper shell or a codex
# prompt may quote this script.
w_non_ancestors() {
  { ps -axww -o pid=,ppid=,command= || true; } | awk -v self="$$" '
    { ppid[$1] = $2; line[$1] = $0 }
    END {
      p = self
      while ((p in ppid) && !(p in anc) && p > 1) { anc[p] = 1; p = ppid[p] }
      for (k in line) if (!(k in anc)) print line[k]
    }'
}

w_probe() {
  local pid cmd cwd hit="" re="dotnet (build|test)|test-gate\.sh|codex exec"
  while read -r pid _ cmd; do
    [[ "$cmd" =~ $re ]] || continue
    # cwd too: a relative build started inside the clone has no clone path in its argv.
    cwd="$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' || true)"
    if [[ "$cmd" =~ "$DIR"(/|[[:space:]]|$) || "$cwd" == "$DIR" || "$cwd" == "$DIR"/* ]]; then
      hit="$cmd"; break
    fi
  done < <(w_non_ancestors)
  [ -z "$hit" ] || W_PROBLEMS+=("a build, gate or review is running against $DIR: $hit")
}

w_tree_clean() {  # w_tree_clean <dirty-message>
  local out
  if ! out="$(git -C "$DIR" status --porcelain)"; then W_PROBLEMS+=("git status failed in $DIR")
  elif [ -n "$out" ]; then W_PROBLEMS+=("$1"); fi
}

# The live remote, never the cached origin/<branch>: a push from elsewhere must be seen.
w_live_ref() {
  local out rc
  set +e
  out="$(git -C "$DIR" ls-remote --exit-code origin "refs/heads/$1" 2>/dev/null)"; rc=$?
  set -e
  case "$rc" in
    0) echo "${out%%[[:space:]]*}" ;;
    2) echo absent ;;
    *) return 1 ;;
  esac
}

w_head_branch() { git -C "$DIR" symbolic-ref --short -q HEAD || true; }
