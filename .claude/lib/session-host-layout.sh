#!/usr/bin/env bash
# session-host-layout.sh — puts running role and team terminals into the main checkout's Herdr space
# (#35): tab Lead (the main-slot role left, side roles stacked right; any other place.tab the same
# way) and one tab per team, named after the team (its TeamLead left, the stage running now on the
# right: the lead is placed first, at launch, and each stage is adopted as a new column). A team
# whose name is a roles tab (Lead, case-insensitive) is never placed: team-new.sh and the runner
# refuse that name. Sourced after session-host-lib.sh; layout_place_roles also needs roles-lib.sh.
#
# Panes are views: placement never ends a terminal (no terminal.kill, pane.close, tab.close, hc kill,
# hc rm) and never writes a layout file. The only window commands: `herdr-app ls`, `herdr-app status`
# and `herdr-app do` tab.rename · pane.focus · terminal.park · terminal.keep · space.new, plus
# `hc label` (herdr.space, herdr.tab: a labelled terminal is adopted into that space and tab, as a new
# column on the right; the space label alone makes a new tab; the view does not move). The window
# knows only terminals with those labels: terminal.keep refuses any other, so every terminal is
# adopted by label first. Every call is time-boxed. A failure prints `warn: placement <address>: <why>` and the
# address's hint, and returns 0: nothing depends on the window. Under tmux every function is a no-op.
#
# Team tabs: label adoption only — a runner never moves the focus. Lead (/roles up, typed by the
# Operator): the first role and the first one beside the main role by label; every further side role
# is adopted, parked, and kept again under the previous one (park → pane.focus → keep down). The
# focus — moved by pane.focus or by a new space — goes back to the pane focused before. The space lookup and
# creation and the tab lookup, creation and rename run under one lock per main checkout
# (registry/layout.lock): two placements in the same second must not make two tabs (#35, #77).

LY_LS=""; LY_SPACE=""; LY_WHY=""; LY_MOVED=""

# ly_app_bin → the app of the core's family: a Linux hc never pairs with herdr-app.exe, hc.exe never
# with a Linux herdr-app. HERDR_APP_BIN wins.
ly_app_bin() {
  if [ -n "${HERDR_APP_BIN:-}" ]; then echo "$HERDR_APP_BIN"
  elif sh_hc_wsl; then echo herdr-app.exe
  else echo herdr-app; fi
}
ly_app() {  # ly_app <args…> — herdr-app, fixture rule, time-boxed
  local p
  p="$(sh_bin_path "$(ly_app_bin)" herdr-app 2>/dev/null)" || { LY_WHY="herdr-app not found"; return 1; }
  sh_timebox "${TEAM_LAYOUT_APP_SECS:-5}" "$p" "$@"
}
ly_do() {  # ly_do <command> [--arg value…]
  ly_app do "$@" >/dev/null 2>&1 || { LY_WHY="herdr-app do $1 failed"; return 1; }
}
ly_ls() {  # refresh LY_LS; rc 1 when the window does not answer
  LY_LS="$(ly_app ls 2>/dev/null)" && jq -e '.spaces | type == "array"' <<<"$LY_LS" >/dev/null 2>&1 \
    || { LY_LS=""; LY_WHY="Herdr window not open or not answering"; return 1; }
}
ly_label() {  # ly_label <handle> <k=v…>
  local p; p="$(sh_hc_path 2>/dev/null)" || { LY_WHY="hc not found"; return 1; }
  sh_timebox "${TEAM_LAYOUT_APP_SECS:-5}" "$p" label "$@" >/dev/null 2>&1 || { LY_WHY="hc label failed"; return 1; }
}
ly_tab_of() {  # ly_tab_of <handle> → the id of the tab listing it (LY_LS), empty when none
  jq -r --arg t "$1" '[.spaces[]?.tabs[]? | select(any(.terminals[]?; .terminal == $t))][0].id // empty' \
    <<<"$LY_LS" 2>/dev/null
}
ly_tab_name() {  # ly_tab_name <handle> → the name of its tab
  jq -r --arg t "$1" '[.spaces[]?.tabs[]? | select(any(.terminals[]?; .terminal == $t))][0].name // empty' \
    <<<"$LY_LS" 2>/dev/null
}
ly_tab_named() {  # ly_tab_named <name> → the id of that tab in LY_SPACE
  jq -r --arg s "$LY_SPACE" --arg n "$1" \
    '[.spaces[]? | select(.id == $s) | .tabs[]? | select(.name == $n)][0].id // empty' <<<"$LY_LS" 2>/dev/null
}
ly_wait_listed() {  # ly_wait_listed <handle> → its tab id once the window lists it (5 tries)
  local i t
  for i in 1 2 3 4 5; do
    ly_ls || return 1
    t="$(ly_tab_of "$1")"; [ -z "$t" ] || { echo "$t"; return 0; }
    sleep "${TEAM_LAYOUT_POLL:-1}"
  done
  LY_WHY="the window does not list $1"; return 1
}

# ly_space <main> <yes|no> → LY_SPACE: the space whose folder is the main checkout (physical path);
# yes: create it when missing (only /roles up — the Operator asked; a runner never creates one).
ly_space() {
  local main n i fd
  main="$(cd "$1" && pwd -P)"
  # Herdr for Windows keeps a WSL folder as its UNC path (\\wsl.localhost\<distro>\…).
  fd="$main"; ! sh_hc_wsl || fd="$(wslpath -w "$main" 2>/dev/null)" || fd="$main"
  n="$(jq -r --arg f "$fd" '[.spaces[]? | select(.folder == $f)] | length' <<<"$LY_LS" 2>/dev/null)"
  LY_SPACE="$(jq -r --arg f "$fd" '[.spaces[]? | select(.folder == $f)][0].id // empty' <<<"$LY_LS" 2>/dev/null)"
  [ "${n:-0}" -le 1 ] || echo "warn: $n Herdr spaces hold $main — using the first ($LY_SPACE)"
  [ -z "$LY_SPACE" ] || return 0
  [ "$2" = yes ] || { LY_WHY="open the project as a Herdr space (or run /roles)"; return 1; }
  # space.new shows the new space (the focus moves) and answers {space, tab, terminal}; its first tab
  # holds a shell, which is never closed here.
  LY_MOVED=1
  LY_SPACE="$(ly_app do space.new --name "$(sh_prefix "$1")" --folder "$fd" 2>/dev/null \
    | jq -r '.space // empty | strings' 2>/dev/null)" || LY_SPACE=""
  if [ -n "$LY_SPACE" ]; then
    echo "created: Herdr space $(sh_prefix "$1") for $main"
    ly_ls || return 1
    return 0
  fi
  for i in 1 2 3 4 5; do
    ly_ls || return 1
    LY_SPACE="$(jq -r --arg f "$fd" '[.spaces[]? | select(.folder == $f)][0].id // empty' <<<"$LY_LS" 2>/dev/null)"
    [ -z "$LY_SPACE" ] || { echo "created: Herdr space $(sh_prefix "$1") for $main"; return 0; }
    sleep "${TEAM_LAYOUT_POLL:-1}"
  done
  LY_WHY="space.new gave no space for $main"; return 1
}

# ly_adopt <handle> <tab name> — into the named tab of LY_SPACE by label; a missing tab is made by
# the space label alone (Herdr opens a new tab), then found by the terminal and renamed.
ly_adopt() {
  local h="$1" name="$2" tab
  tab="$(ly_tab_named "$name")"
  if [ -n "$tab" ]; then
    ly_label "$h" "herdr.space=$LY_SPACE" "herdr.tab=$tab" || return 1
    ly_wait_listed "$h" >/dev/null || return 1
    return 0
  fi
  ly_label "$h" "herdr.space=$LY_SPACE" || return 1
  tab="$(ly_wait_listed "$h")" || return 1
  ly_do tab.rename --id "$tab" --name "$name" || return 1
  ly_ls || true   # the next placement must find the tab by its new name
}

ly_warn() {  # ly_warn <main> <address> — the failure line and the hint
  echo "warn: placement $2: ${LY_WHY:-failed}"
  echo "  $2: $(sh_hint "$2" --main "$1" 2>/dev/null || echo "bash .claude/lib/roles.sh status")"
}
ly_lock() { sh_lock "$1" layout "" "layout pid=$$ $2" "${TEAM_LAYOUT_LOCK_WAIT:-30}"; }
ly_unlock() { sh_unlock "$1" layout ""; }

# ly_roles_tab <name> → 0 when <name> equals a roles tab (Lead, or a role's place.tab), case-insensitive.
ly_roles_tab() {
  local t n; n="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  for t in Lead $(roles_list --standing 2>/dev/null | while read -r r; do roles_cfg "$r" place.tab 2>/dev/null; done); do
    [ "$n" != "$(printf '%s' "$t" | tr '[:upper:]' '[:lower:]')" ] || return 0
  done
  return 1
}

# layout_place_team <main> <address> — a team session (its TeamLead or a stage) into its team's tab
# (the team name: the address without its last -<role>), by label adoption only. Never creates the
# space (warns instead). rc 0 always.
layout_place_team() {
  local m="$1" a="$2" h held t="${2%-*}"
  [ "$(sh_record_get "$m" "$a" backend)" = herdr ] || { echo "$a: $(sh_hint "$a" --main "$m" 2>/dev/null)"; return 0; }
  if ly_roles_tab "$t"; then LY_WHY="team $t has the name of a roles tab — not placed"; ly_warn "$m" "$a"; return 0; fi
  h="$(sh_target "$m" "$a" 2>/dev/null)" || { LY_WHY="$a: no live terminal of ours (replaced or gone)"; ly_warn "$m" "$a"; return 0; }
  ly_ls || { ly_warn "$m" "$a"; return 0; }
  if [ -n "$(ly_tab_of "$h")" ]; then echo "already placed: $a in $(ly_tab_name "$h")"; return 0; fi
  if ! held="$(ly_lock "$m" "$a")"; then LY_WHY="layout lock held by $held"; ly_warn "$m" "$a"; return 0; fi
  if ly_ls && ly_space "$m" no; then
    if [ -n "$(ly_tab_of "$h")" ]; then echo "already placed: $a in $(ly_tab_name "$h")"
    elif ly_adopt "$h" "$t"; then echo "placed: $a in $t"
    else ly_warn "$m" "$a"; fi
  else
    ly_warn "$m" "$a"
  fi
  ly_unlock "$m"
  return 0
}

# ly_focused → the terminal of the focused pane (`herdr-app status` .focused_pane, mapped through
# LY_LS), empty when unknown. (.agent is not the focus.)
ly_focused() {
  local p
  p="$(ly_app status 2>/dev/null | jq -r '.focused_pane // empty | tostring' 2>/dev/null)"
  [ -n "$p" ] || return 0
  jq -r --arg p "$p" '[.spaces[]?.tabs[]?.terminals[]? | select((.pane | tostring) == $p) | .terminal][0] // empty' \
    <<<"$LY_LS" 2>/dev/null
}

ly_refocus() {  # ly_refocus <terminal> — the focus back, when placement moved it
  [ -z "$LY_MOVED" ] || [ -z "$1" ] || ly_do pane.focus --terminal "$1" \
    || echo "warn: placement: the focus could not be given back to $1"
}

# ly_below <handle> <previous> — an adopted terminal moved under the previous one: park (its pane
# goes, it keeps running), focus the previous, keep down. A failed step adopts it back by label, so
# it is never left without a pane.
ly_below() {
  local h="$1" prev="$2" tab="$3"
  ly_do terminal.park --terminal "$h" || return 1
  LY_MOVED=1
  if ly_do pane.focus --terminal "$prev" && ly_do terminal.keep --terminal "$h" --place down \
    && ly_wait_listed "$h" >/dev/null; then
    return 0
  fi
  local why="$LY_WHY"
  ly_adopt "$h" "$tab" >/dev/null 2>&1 || true
  LY_WHY="$why (adopted back by label)"; return 1
}

# layout_place_roles <main> — every running herdr role with a place.tab into its tab: per tab the
# main-slot role first (label adoption: it makes and names the tab), then the side roles in
# declaration order (focus the previous one, terminal.keep right for the first beside the main role,
# down for the rest). A placed terminal is left where it is. Creates the space when missing. When it
# moved the focus, the focus the window had before goes back at the end (also after a failure).
layout_place_roles() {
  local m="$1" r tab tabs h prev prevslot held foc slot order any=""
  LY_MOVED=""
  for r in $(roles_list --standing 2>/dev/null); do
    [ "$(sh_record_get "$m" "$r" backend)" = herdr ] && [ -n "$(roles_cfg "$r" place.tab 2>/dev/null)" ] && any=1
  done
  [ -n "$any" ] || return 0
  if ! ly_ls; then
    for r in $(roles_list --standing 2>/dev/null); do
      [ "$(sh_record_get "$m" "$r" backend)" = herdr ] || continue
      sh_alive "$r" --main "$m" >/dev/null 2>&1 && ly_warn "$m" "$r"
    done
    return 0
  fi
  foc="$(ly_focused)"
  if ! held="$(ly_lock "$m" "/roles up")"; then LY_WHY="layout lock held by $held"; echo "warn: placement: ${LY_WHY}"; return 0; fi
  if ! ly_ls || ! ly_space "$m" yes; then
    echo "warn: placement: ${LY_WHY:-failed}"; ly_unlock "$m"; ly_refocus "$foc"; return 0
  fi
  # Tabs in declaration order of their first role.
  tabs="$(for r in $(roles_list --standing 2>/dev/null); do roles_cfg "$r" place.tab 2>/dev/null; done | awk 'NF && !s[$0]++')"
  while IFS= read -r tab; do
    [ -n "$tab" ] || continue
    order="$(for slot in main side; do for r in $(roles_list --standing 2>/dev/null); do
        [ "$(roles_cfg "$r" place.tab 2>/dev/null)" = "$tab" ] && [ "$(roles_cfg "$r" place.slot 2>/dev/null)" = "$slot" ] \
          && echo "$r"
      done; done)"
    prev=""; prevslot=""
    for r in $order; do
      [ "$(sh_record_get "$m" "$r" backend)" = herdr ] || continue
      sh_alive "$r" --main "$m" >/dev/null 2>&1 || continue
      slot="$(roles_cfg "$r" place.slot 2>/dev/null)"
      h="$(sh_target "$m" "$r" 2>/dev/null)" || { LY_WHY="no live terminal of ours"; ly_warn "$m" "$r"; continue; }
      if [ -n "$(ly_tab_of "$h")" ]; then prev="$h"; prevslot="$slot"; continue; fi
      # By label: the tab's first terminal, and the first one beside the main role (a new column
      # on the right). Every further one: adopted, then moved under the previous one.
      ly_adopt "$h" "$tab" || { ly_warn "$m" "$r"; continue; }
      if [ -n "$prev" ] && [ "$prevslot" != main ]; then
        ly_below "$h" "$prev" "$tab" || { ly_warn "$m" "$r"; prev="$h"; prevslot="$slot"; continue; }
      fi
      echo "placed: $r in $tab"
      prev="$h"; prevslot="$slot"
    done
  done <<<"$tabs"
  ly_unlock "$m"
  ly_refocus "$foc"
  return 0
}

# layout_panes <main> → "<address>\t<tab name or none>" per herdr record of a standing role (one ls);
# `?` when the window does not answer.
layout_panes() {
  local m="$1" r h t ok=1
  ly_ls || ok=""
  for r in $(roles_list --standing 2>/dev/null); do
    [ "$(sh_record_get "$m" "$r" backend)" = herdr ] || continue
    if [ -z "$ok" ]; then printf '%s\t?\n' "$r"; continue; fi
    h="$(sh_record_get "$m" "$r" handle)"; t="$(ly_tab_name "$h")"
    printf '%s\t%s\n' "$r" "${t:-none}"
  done
}
