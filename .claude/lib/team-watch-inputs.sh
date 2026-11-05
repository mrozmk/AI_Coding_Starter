#!/usr/bin/env bash
# team-watch inputs beyond the snapshot: mail probes per receiver, role-session prompts. Sourced by
# team-watch-lib.sh, never executed; functions only. Runbook: .agents/reference/team-watch.md.
# The probes come from the rendered .agents/team/watch.local.json (team-channel.sh render); this
# layer never reads a box or tool path itself.

tw_mail_cfg() {  # tw_mail_cfg <cfg> → <role>\t<command> per probe; split: .mail, single: mail_unread
  local m
  m="$(tw_routing)"
  if [ "$m" = split ]; then
    jq -r '(.mail // {}) | to_entries[] | select((.value | type) == "string" and .value != "")
      | "\(.key)\t\(.value)"' "$1"
  else
    jq -r --arg r "${m#single }" '(if (.mail_unread | type) == "string" then .mail_unread
      else (.mail // {})[$r] // "" end) as $c | select($c != "") | "\($r)\t\($c)"' "$1"
  fi
}

# tw_mail <work dir> → mail.json {<role>: [lines]} + mail_err.json {<role>: "<error>"}. The probes
# run concurrently: sequential timeouts would outlast the dog's 2 × TW_SECS freshness.
tw_mail() {
  local w="$1" cfg="$root/.agents/team/watch.local.json" secs r c i=0 pids="" name rc f
  echo '{}' > "$w/mail.json"; echo '{}' > "$w/mail_err.json"
  [ -f "$cfg" ] || return 0
  if ! jq empty "$cfg" >/dev/null 2>&1; then
    jq -n --arg r "$(tw_alarm_target)" '{($r): "watch.local.json is not valid JSON"}' \
      > "$w/mail_err.json"
    return 0
  fi
  secs="$(jq -r '.timeout_secs // 10' "$cfg")"
  [[ "$secs" =~ ^[0-9]+$ ]] && [ "$secs" -ge 1 ] && [ "$secs" -le 60 ] || secs=10
  while IFS=$'\t' read -r r c; do
    [ -n "$r" ] || continue
    i=$((i + 1)); echo "$r" > "$w/m.$i.role"
    if ! tw_role_ok "$r"; then echo unknown > "$w/m.$i.rc"; continue; fi
    ( rc=0; tw_timebox "$secs" bash -c "$c" < /dev/null > "$w/m.$i.out" 2> "$w/m.$i.err" || rc=$?
      echo "$rc" > "$w/m.$i.rc" ) &
    pids="$pids $!"
  done <<<"$(tw_mail_cfg "$cfg" 2>/dev/null)"
  [ -z "$pids" ] || wait $pids 2>/dev/null || true
  [ "$(tw_routing)" = split ] && name="mail probe" || name=mail_unread
  for f in "$w"/m.*.role; do
    [ -f "$f" ] || continue
    i="${f%.role}"; r="$(cat "$f")"; rc="$(cat "$i.rc" 2>/dev/null || echo 1)"
    case "$rc" in
      0) jq --arg r "$r" --rawfile m "$i.out" \
           '.[$r] = ($m | split("\n") | map(select(length > 0)))' "$w/mail.json" \
           | tw_put "$w/mail.json"; continue ;;
      unknown) c="unknown role $r" ;;
      124) c="$name timed out after ${secs}s" ;;
      *) c="$name exit $rc: $(tail -n 1 "$i.err" 2>/dev/null | cut -c1-160)" ;;
    esac
    jq --arg r "$r" --arg c "$c" '.[$r] = $c' "$w/mail_err.json" | tw_put "$w/mail_err.json"
  done
}

# tw_esc_mail <work dir> → esc_mail.json {lines, error}: unread Advisor replies on esc-* threads
# for the TeamLead. Kept out of mail.json, so an escalation reply never becomes a MAIL signal.
tw_esc_mail() {
  local w="$1" cfg="$root/.agents/team/watch.local.json" secs c rc=0 e
  echo '{"lines": [], "error": null}' > "$w/esc_mail.json"
  [ -f "$cfg" ] && jq empty "$cfg" >/dev/null 2>&1 || return 0
  c="$(jq -r '.esc_mail.TeamLead // empty | strings' "$cfg")"
  [ -n "$c" ] || return 0
  secs="$(jq -r '.timeout_secs // 10' "$cfg")"
  [[ "$secs" =~ ^[0-9]+$ ]] && [ "$secs" -ge 1 ] && [ "$secs" -le 60 ] || secs=10
  tw_timebox "$secs" bash -c "$c" < /dev/null > "$w/em.out" 2> "$w/em.err" || rc=$?
  case "$rc" in
    0) jq -n --rawfile m "$w/em.out" '{lines: ($m | split("\n") | map(select(length > 0))),
         error: null}' > "$w/esc_mail.json"; return 0 ;;
    124) e="esc_mail probe timed out after ${secs}s" ;;
    *) e="esc_mail probe exit $rc: $(tail -n 1 "$w/em.err" 2>/dev/null | cut -c1-160)" ;;
  esac
  jq -n --arg e "$e" '{lines: [], error: $e}' > "$w/esc_mail.json"
}

# tw_role_block <role> → TW_RB_SUB (menu|permission) and TW_RB_BLOCK (raw) for the open prompt in
# the role's own tmux window; rc 1 when none. Raw text stays in memory: only its fp and the
# redacted lines leave this file.
tw_role_block() {
  local s
  s="$(tw_tmux_name "$1")"; TW_RB_SUB=""; TW_RB_BLOCK=""
  team_tmux_alive "$s" || return 1
  # Only the bottom lines, where the prompt UI sits: received ATTENTION heads and team menu
  # screens above them carry the same phrases.
  if team_pane "$s" 6 | grep -qF 'Enter to select'; then
    TW_RB_SUB=menu; TW_RB_BLOCK="$(team_pane "$s" 40)"
  elif team_pane "$s" 8 \
      | grep -Eq 'Do you want to (proceed|make this edit|create|allow)|❯ *1\. Yes'; then
    TW_RB_SUB=permission
    TW_RB_BLOCK="$(team_pane_history "$s" 200 \
      | python3 -I "$root/.claude/lib/team_prompt_check.py" --block 2>/dev/null)" \
      || TW_RB_BLOCK="$(team_pane "$s" 15)"
  else
    return 1
  fi
}

tw_rb_fp() { printf '%s' "$TW_RB_BLOCK" | shasum -a 1 | cut -c1-12; }
tw_rb_anchor() {
  local a
  a="$(sed -E '/^[[:space:]]*$/d; s/^[[:space:]]+//; s/[[:space:]]+$//' <<<"$TW_RB_BLOCK" \
    | head -n 1 | team_redact)"
  printf '%s' "${a:0:160}"
}

# tw_role_prompt <role> → "<sub>\t<fp>\t<anchor>", or nothing. The fp, not the anchor, identifies
# a prompt: every permission prompt ends in the same question.
tw_role_prompt() {
  tw_role_block "$1" || return 0
  printf '%s\t%s\t%s\n' "$TW_RB_SUB" "$(tw_rb_fp)" "$(tw_rb_anchor)"
}

# tw_role_panes <work dir> → <work dir>/roles.json {<role>: {sub, fp, anchor, screen}} for the role
# sessions with an open prompt or menu — prompts nobody else would see.
tw_role_panes() {
  local r out='{}'
  for r in $TW_PANE_ROLES; do
    tw_role_block "$r" || continue
    out="$(jq -c --arg r "$r" --arg sub "$TW_RB_SUB" --arg fp "$(tw_rb_fp)" \
      --arg a "$(tw_rb_anchor)" --arg scr "$(team_redact <<<"$TW_RB_BLOCK" | head -n 40)" \
      '.[$r] = {sub: $sub, fp: $fp, anchor: $a,
                screen: ($scr | split("\n") | map(select(test("\\S"))))}' <<<"$out")"
  done
  echo "$out" > "$1/roles.json"
}
