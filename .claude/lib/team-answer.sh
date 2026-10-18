#!/usr/bin/env bash
# Answer a team role from the supervisor: approve or reject its open permission prompt, or type a reply.
#
# Usage: bash .claude/lib/team-answer.sh <team> <role> <action> [<text>|<n>|<n,n>|none]
# Actions: yes|no|say|pick|other|picks
#   e.g. bash .claude/lib/team-answer.sh alfa coder yes
#        bash .claude/lib/team-answer.sh alfa coder say "Use the existing endpoint, no new route."
#        bash .claude/lib/team-answer.sh alfa planner pick 2
#        bash .claude/lib/team-answer.sh alfa planner other "Use the counter."
# picks answers one checkbox question; none sends explicit "none - skip all", not an empty answer.
#
# yes/no act only when the role's screen shows a permission prompt; `no` also sends the reason as text.
# pick/other act only on an open single-question menu (AskUserQuestion); other types into "Type something.".
set -euo pipefail

if [ $# -lt 3 ] || [ $# -gt 4 ]; then
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
fi
case "$3" in pick|other|picks)
  [ $# = 4 ] || { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 2; } ;;
esac
. "$(dirname "$0")/team-lib.sh"
name="$1-$2"; action="$3"; text="${4:-}"
[[ "$name" =~ ^[a-z0-9-]+$ ]] || { echo "error: bad session name $name" >&2; exit 2; }
tmux has-session -t "=$name" 2>/dev/null || { echo "error: tmux session $name not found" >&2; exit 1; }

type_text() { tmux send-keys -t "=$name:" -l -- "$1"; tmux send-keys -t "=$name:" Enter; }

# Refuses before any keystroke: no menu, a multi-question menu, or the cursor away from option 1.
menu_ready() {
  PANE="$(team_pane "$name" 40)"
  grep -qF 'Enter to select' <<<"$PANE" && grep -qF 'Type something.' <<<"$PANE" \
    || { echo "error: no single-question menu in $name — nothing sent" >&2; exit 1; }
  ! grep -Eq 'Submit answers|Review your answers|✔ Submit' <<<"$PANE" \
    || { echo "error: multi-question menu — answer in the window (tier 3)" >&2; exit 1; }
  grep -Eq '❯[[:space:]]*1\.' <<<"$PANE" \
    || { echo "error: menu cursor is not on option 1 in $name — nothing sent" >&2; exit 1; }
}

press_down() {
  local i=1
  while [ "$i" -lt "$1" ]; do tmux send-keys -t "=$name:" Down; i=$((i + 1)); done
}

multi_error() { echo "error: $* — answer in the window (tier 3)" >&2; exit 1; }

# Known renderer only; a completed question tab still counts as a question.
multi_header() {
  local h icons pattern
  h="$(grep -E '^[[:space:]]*←.*✔ Submit.*→[[:space:]]*$' <<<"$PANE")" \
    || multi_error "missing question header"
  icons="$( { grep -oE '[☐☒]' <<<"$h" || true; } | wc -l | tr -d ' ')"
  [ "$icons" = 1 ] || multi_error "not a single-question checkbox menu"
  pattern='^[[:space:]]*←[[:space:]]+[☐☒][[:space:]]+(.+[^[:space:]])'
  pattern+='[[:space:]]+✔[[:space:]]Submit[[:space:]]+→[[:space:]]*$'
  [[ "$h" =~ $pattern ]] || multi_error "unknown question header"
  HEADER="${BASH_REMATCH[1]}"
}

multi_rows() {
  local line n mark label expected=1 body row
  LABELS=(); CHECKED=(); OTHER=0
  row='^[[:space:]]*(❯[[:space:]]*)?([1-9][0-9]?)\.[[:space:]]+\[([ ✔])\][[:space:]]+(.+)$'
  body="$(awk '/^[[:space:]]*❯[[:space:]]*1[.]/{m=1}
    m && /^[[:space:]]*Submit[[:space:]]*$/{exit} m{print}' <<<"$PANE")"
  while IFS= read -r line; do
    if [[ "$line" =~ $row ]]; then
      n="${BASH_REMATCH[2]}"; mark="${BASH_REMATCH[3]}"; label="${BASH_REMATCH[4]}"
      [ "$n" = "$expected" ] && [ "$OTHER" = 0 ] || multi_error "incomplete option list"
      LABELS[$n]="$label"; CHECKED[$n]="$mark"; expected=$((expected + 1))
      if [ "$label" = 'Type something' ]; then
        OTHER="$n"; [ "$mark" = ' ' ] || multi_error "Other is already selected"
      fi
    elif [[ "$line" =~ ^[[:space:]]*(❯[[:space:]]*)?[0-9]+\. ]]; then
      multi_error "unknown option row"
    fi
  done <<<"$body"
  [ "$OTHER" -gt 1 ] || multi_error "missing final Type something option"
}

multi_ready() {
  local n seen=',' requests
  PANE="$(team_pane "$name" 40)"
  multi_header; TITLE="$HEADER"
  grep -qF 'Enter to select · ↑/↓ to navigate · Esc to cancel' <<<"$PANE" \
    && ! grep -qF 'Review your answers' <<<"$PANE" || multi_error "not an option screen"
  grep -Eq '^[[:space:]]*❯[[:space:]]*1\.[[:space:]]+\[' <<<"$PANE" \
    && [ "$(grep -c '❯' <<<"$PANE")" = 1 ] || multi_error "menu cursor is not on option 1"
  [ "$(grep -Ec '^[[:space:]]*Submit[[:space:]]*$' <<<"$PANE")" = 1 ] \
    || multi_error "missing unique Submit row"
  multi_rows
  [ "$text" != none ] || return 0
  IFS=',' read -r -a requests <<<"$text"
  for n in "${requests[@]}"; do
    [ "$n" -lt "$OTHER" ] || multi_error "option $n is not a real option on screen"
    [[ "$seen" != *",$n,"* ]] || multi_error "duplicate option $n"
    seen="$seen$n,"
  done
}

# Capture the actual review before the final Enter; never submit an unanswered question.
multi_review() {
  local i=0
  while [ "$i" -lt 20 ]; do
    PANE="$(team_pane "$name" 40)"
    if grep -qF 'Review your answers' <<<"$PANE"; then
      multi_header
      [ "$HEADER" = "$TITLE" ] \
        && grep -qF 'Ready to submit your answers?' <<<"$PANE" \
        && grep -Eq '^[[:space:]]*❯[[:space:]]*1\. Submit answers[[:space:]]*$' <<<"$PANE" \
        && [ "$(grep -Ec '^[[:space:]]*● ' <<<"$PANE")" = 1 ] \
        && ! grep -qF 'You have not answered all questions' <<<"$PANE" \
        && grep -Fxq "→ $EXPECTED" <<<"$(sed 's/^[[:space:]]*//' <<<"$PANE")" \
        || multi_error "unexpected review or answer; final Enter not sent"
      return 0
    fi
    grep -qF 'Enter to select' <<<"$PANE" || multi_error "review screen unavailable"
    sleep 0.1; i=$((i + 1))
  done
  multi_error "review screen did not appear; final Enter not sent"
}

multi_send() {
  local i=1 want mark
  EXPECTED=''
  while [ "$i" -lt "$OTHER" ]; do
    want=' '; [[ ",$text," != *",$i,"* ]] || want='✔'
    mark="${CHECKED[$i]}"
    [ "$want" = "$mark" ] || tmux send-keys -t "=$name:" Enter
    if [ "$want" = '✔' ]; then EXPECTED="${EXPECTED:+$EXPECTED, }${LABELS[$i]}"; fi
    tmux send-keys -t "=$name:" Down; i=$((i + 1))
  done
  if [ "$text" = none ]; then
    EXPECTED='none - skip all'
    tmux send-keys -t "=$name:" Enter
    tmux send-keys -t "=$name:" -l -- "$EXPECTED"
  fi
  tmux send-keys -t "=$name:" Down
  tmux send-keys -t "=$name:" Enter
  multi_review
  tmux send-keys -t "=$name:" Enter
}

case "$action" in
  yes)
    team_prompt_open "$name" || { echo "error: no pending permission prompt in $name — nothing approved" >&2; exit 1; }
    # Tier 1 only: a prompt that matches an ask/deny rule of the clone, or carries SQL writes, is the
    # Operator's to answer in the window (team-mode.md §10) — the supervisor's Enter is refused.
    root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    # Checked, then proven to exist: a clone the checker cannot read has no ask/deny rules, so an
    # unresolved path would silently turn every prompt into tier 1.
    clone="$(team_clone_dir "$1" "$root")" \
      || { echo "error: cannot resolve the clone of $1 — nothing approved" >&2; exit 1; }
    [ -d "$clone" ] \
      || { echo "error: no clone at $clone — nothing approved" >&2; exit 1; }
    team_pane "$name" 40 | python3 -I "$(dirname "$0")/team_prompt_check.py" "$clone" \
      || { echo "error: ask/deny-tier prompt in $name — Operator answers in the window (tier 3)" >&2; exit 1; }
    tmux send-keys -t "=$name:" Enter ;;
  no)
    team_prompt_open "$name" || { echo "error: no pending permission prompt in $name — nothing rejected" >&2; exit 1; }
    tmux send-keys -t "=$name:" Escape
    sleep 1
    type_text "Rejected by the developer${text:+: $text}. Treat it as a material question (team-mode.md §4): write a blocked record and wait." ;;
  say)
    [ -n "$text" ] || { echo "error: say needs the text to type" >&2; exit 2; }
    # Enter after the text would confirm the focused option of an open menu or prompt.
    ! team_prompt_open "$name" && ! team_pane "$name" 40 | grep -qF 'Enter to select' \
      || { echo "error: a menu or permission prompt is open in $name — nothing sent" >&2; exit 1; }
    type_text "$text" ;;
  pick)
    [[ "$text" =~ ^[1-9][0-9]?$ ]] || { echo "error: pick needs an option number 1-99" >&2; exit 2; }
    menu_ready
    grep -Eq "^[[:space:]]*(❯[[:space:]]*)?$text\.[[:space:]]" <<<"$PANE" \
      || { echo "error: option $text not on screen in $name — nothing sent" >&2; exit 1; }
    press_down "$text"
    tmux send-keys -t "=$name:" Enter ;;
  other)
    [ -n "$text" ] || { echo "error: other needs the text to type" >&2; exit 2; }
    menu_ready
    k="$(sed -nE 's/^[[:space:]]*(❯[[:space:]]*)?([0-9]+)\. Type something\..*/\2/p' <<<"$PANE" \
      | head -n1)"
    [ -n "$k" ] || { echo "error: no numbered 'Type something.' option in $name — nothing sent" >&2; exit 1; }
    press_down "$k"
    type_text "$text" ;;
  picks)
    [[ "$text" = none || "$text" =~ ^[1-9][0-9]?(,[1-9][0-9]?)*$ ]] \
      || { echo "error: picks needs option numbers separated by commas, or none" >&2; exit 2; }
    multi_ready
    multi_send ;;
  *) echo "error: action must be yes, no, say, pick, other or picks" >&2; exit 2 ;;
esac
sleep 2
echo "sent $action to $name; screen now:"
team_pane "$name" 8 | sed 's/^/  | /'
