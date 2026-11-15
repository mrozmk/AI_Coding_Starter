#!/usr/bin/env bash
# local-env-init.sh — the Operator's one-time, no-echo creation of ~/.config/<dir>/local.env, with
# <dir> and the key name from .claude/local-env.json. Run it in your own terminal; agents never see
# the value. Contract: .agents/reference/local-env-runner.md
#
# Exit: 0 written · 1 aborted · 64 no TTY · 65 value outside the allowed charset · 77 symlink/type ·
#       78 the kit is off or its config is not approved on trunk
set -euo pipefail
set +x
[ -t 0 ] || { echo "local-env-init: run this in your own terminal (needs a TTY)" >&2; exit 64; }
umask 077
W="$(dirname "$0")/with-local-env.sh"

INFO=$(bash "$W" --setup-info) || exit $?
NAME=$(printf '%s\n' "$INFO" | sed -n 's/^dir=//p')
KEY=$(printf '%s\n' "$INFO" | sed -n 's/^key=//p')

D="$HOME/.config/$NAME"
# Refused before chmod: the runner refuses a symlinked dir anyway, and chmod would hit its target.
if [ -L "$D" ]; then
  echo "local-env-init: $D is a symlink - refused" >&2
  exit 77
fi
mkdir -p "$D"
chmod 700 "$D"

F="$D/local.env"
if [ -L "$F" ] || { [ -e "$F" ] && [ ! -f "$F" ]; }; then
  echo "local-env-init: $F is not a regular file - refused" >&2
  exit 77
fi
if [ -f "$F" ]; then
  read -r -p "local-env-init: $F exists. Overwrite? [y/N] " ANSWER
  [ "$ANSWER" = y ] || { echo "local-env-init: aborted, nothing changed" >&2; exit 1; }
fi

read -rs -p "Local dev value for $KEY: " PW
echo
# The single validator is the runner's; printf is a builtin, so the value is not in argv.
printf '%s' "$PW" | bash "$W" --validate-stdin || exit 65

T=$(mktemp "$D/.local.env.XXXXXX")
printf '# local dev only - never prod/stage, never commit\n%s=%s\n' "$KEY" "$PW" > "$T"
unset PW
chmod 600 "$T"
mv -f "$T" "$F"
echo "local-env-init: wrote $F (mode 600)"
