# Shared guard for the attended acceptance scripts (sourced, never run by an agent).
# Refuses unless: the cwd is the top of a scratch checkout that carries the marker `.p9-scratch`
# (whose single line is that same path), HOME is not the account's real home, and
# CLAUDE_CONFIG_DIR is set (the launched roles keep the Operator's login while HOME is the fixture).
# Every tmux name these scripts touch starts with the team name, which starts with `p9`.
p9_die() { printf 'p9: refused: %s\n' "$*" >&2; exit 2; }
P9_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || p9_die "not inside a git checkout"
[ "$(pwd -P)" = "$(cd "$P9_ROOT" && pwd -P)" ] || p9_die "run from the checkout's top: $P9_ROOT"
[ -f "$P9_ROOT/.p9-scratch" ] && [ "$(cat "$P9_ROOT/.p9-scratch")" = "$P9_ROOT" ] \
  || p9_die "no .p9-scratch marker naming this checkout — this is not the scratch clone"
p9_real_home() {
  if [ "$(uname)" = Darwin ]; then dscl . -read "/Users/$(id -un)" NFSHomeDirectory | awk '{print $2}'
  else getent passwd "$(id -un)" | cut -d: -f6; fi
}
[ "$HOME" != "$(p9_real_home)" ] || p9_die "HOME is the real home; source the scratch env first"
[ -n "${CLAUDE_CONFIG_DIR:-}" ] || p9_die "CLAUDE_CONFIG_DIR is not set"
P9_SHA="$(git -C "$P9_ROOT" rev-parse --short HEAD)"
P9_CLONE_OF() { printf '%s/../%s-%s\n' "$P9_ROOT" "$(basename "$P9_ROOT")" "$1"; }

# p9_provision <team> <prompt text> — a quick-mode clone whose planner prompt is the fixed text.
p9_provision() {
  local team="$1" text="$2" clone base="${P9_BASE:-HEAD}"
  case "$team" in p9*) ;; *) p9_die "team name must start with p9" ;; esac
  clone="$(P9_CLONE_OF "$team")"
  [ -d "$clone" ] || bash .claude/lib/team-new.sh "$team" "P9-1" "docs/$team" "$base" quick \
    || p9_die "team-new.sh failed for $team"
  printf '%s\n' "$text" > "$clone/.claude/team/prompts/planner-quick.md"
  printf '%s\n' "$clone"
}

# p9_start <team> — the stage runner in its own tmux session, with the scratch env forwarded.
p9_start() {
  tmux new-session -d -s "$1-runner" -c "$P9_ROOT" -e "HOME=$HOME" \
    -e "CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR" "bash .claude/lib/team-run.sh $1; read"
}

# p9_cleanup <team> — stop the runner, then kill only this team's tmux sessions.
p9_cleanup() {
  local s
  bash .claude/lib/team-run.sh "$1" stop >/dev/null 2>&1 || true
  for s in $(tmux ls -F '#{session_name}' 2>/dev/null | grep "^$1-"); do
    tmux kill-session -t "=$s" 2>/dev/null || true
  done
}

# p9_field <team> <q> <key> — the last "<key>: …" line of the q file, via show.
p9_field() { bash .claude/lib/team-question.sh "$1" show "$2" | sed -n "s/^$3: //p" | tail -n 1; }
p9_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }
