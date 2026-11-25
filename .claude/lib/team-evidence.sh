#!/usr/bin/env bash
# Operator evidence in a supervised session's transcript. Sourced, never executed. Bash 3.2 + jq.
#   team_evidence_match <transcript> <text> <since> <id> <used uuids> [exact]
#     → the uuid of the newest typed user message at or after <since> that contains <text> (with
#       `exact`: equals it, both trimmed — an ask-bound decision's whole reply) and is no machine
#       line (TEAM_EVIDENCE_MACHINE_RE: a doorbell, runner, legacy team-watch (retired), hc or [peer] line); a uuid
#       already used by another answer (space-separated list) counts only when that message names
#       <id>. Nothing when no match.
#   team_evidence_latest <transcript> <team> <d-n> <since>
#     → "<uuid>\t<trimmed message>" of the newest typed, non-machine user message at or after
#       <since> addressed to that decision (`<team> <d-n>` first); nothing when none. A multi-line
#       newest message prints an empty text: it still wins, so no older one-line reply matches.
#   team_evidence_machine_line <text> → 0 when the text is a machine line.
#   team_evidence_dialog_extract <transcript> <since> → the AskUserQuestion calls and answer entries
#     at or after <since>, one compact JSON line each (a half-written last line is dropped)
#   team_evidence_dialog_norm <dialog json> <d-n> → the call's <d-n> questions in full and in order,
#     or nothing when the input is not exactly {"questions": […]} (e.g. the hook-supplied `answers`)
#   team_evidence_dialog_find <transcript> <d-n> <since> <dialog json> → the uuid of the newest
#     answer entry of a dialog equal to the stored one; nothing when dialogs naming <d-n> differ
#   team_evidence_dialog_read <transcript> <uuid> <d-n> <since> <dialog json> → {reply, map} of that
#     entry under the same checks: one question → reply "<d-n> <answer>"; several → map keyed by the
#     stage question texts, reply a display string only
#   team_evidence_dialog_raised <transcript> <since> → the d-<n> ids any AskUserQuestion call named
#   team_evidence_ask_hooks <main> <clone> <config dir> → "clean <digest>" (rc 0) or
#     "unclean <cause>" (rc 1): the effective AskUserQuestion hook registrations of a lead session,
#     with the hooks of every enabled plugin (team_evidence_plugins) in the digest
#   team_evidence_fix <cause> → one line naming what makes that cause go away
#   team_evidence_snapshot <ask hooks line> → {clean, digest, cause}: that line as a launch snapshot
#   team_evidence_anchor <main> <clone> → the main checkout's anchor of that clone (by physical path)
#   team_evidence_provenance <main> <clone> <run> <session id> → "<config dir>" (rc 0) when that
#     session's launch snapshot is clean and the registrations still match it, else the cause (rc 1)
# Callers: team-lead-decision.sh d_evidence (the TeamLead window), the dialog and decision relay
# (the Supervisor window), team-lineage.sh consent (the Supervisor window), team-ask-hook.sh
# (re-verification), the runner (snapshot, reminder), session-host-lib.sh sh_send / sh_type (the
# [peer] marker). It raises the bar; it is not proof (team-lead.md §7).
# Its own file: team-lib.sh has no room, and the callers run from the clone and the main checkout.

# Every line a script or a peer session puts into a supervised window starts with one of these.
TEAM_EVIDENCE_MACHINE_RE='^(stop |gate |prompt |ask |attention |unasked |inbox:|relaunched: |human-only |rejected |continue granted |round |close refused: |relayed: |\[peer\] |\[team-run\]|\[team-watch |<hc from=)'

team_evidence_machine_line() { [[ "$1" =~ $TEAM_EVIDENCE_MACHINE_RE ]]; }

team_evidence_match() {
  jq -r --arg x "$2" --arg since "$3" --arg id "$4" \
    --arg used "$5" --arg mode "${6:-}" --arg re "$TEAM_EVIDENCE_MACHINE_RE" '
    def trim: sub("^\\s+"; "") | sub("\\s+$"; "");
    ($used | split(" ") | map(select(. != ""))) as $u
    | select(.type == "user" and ((.isMeta // false) | not) and ((.timestamp // "") >= $since))
    | (.uuid // "?") as $uid
    | (.message.content | if type == "string" then .
        elif type == "array" then (map(select(.type == "text") | .text) | join(" ")) else "" end) as $m
    | select($m != "" and (if $mode == "exact" then ($m | trim) == ($x | trim) else ($m | contains($x)) end)
        and ($m | test($re) | not))
    | select((($u | index($uid)) == null) or ($m | test("(^|[^A-Za-z0-9-])" + $id + "([^0-9]|$)")))
    | $uid' "$1" 2>/dev/null | tail -n 1
}

team_evidence_latest() {
  jq -r --arg team "$2" --arg id "$3" --arg since "$4" --arg re "$TEAM_EVIDENCE_MACHINE_RE" '
    select(.type == "user" and ((.isMeta // false) | not) and ((.timestamp // "") >= $since))
    | (.uuid // "?") as $uid
    | (.message.content | if type == "string" then .
        elif type == "array" then (map(select(.type == "text") | .text) | join(" ")) else "" end) as $m
    | select($m != "" and ($m | test($re) | not))
    | ($m | sub("^\\s+"; "") | sub("\\s+$"; "")) as $t
    | select($t | test("^" + $team + "[[:space:]]+" + $id + "([[:space:]]|$)"))
    | "\($uid)\t\(if ($t | contains("\n")) then "" else $t end)"' "$1" 2>/dev/null | tail -n 1
}

# The normalised <d-n> questions of a call input: exactly {"questions": [...]}, every field the
# Operator saw (question, header, multiSelect, each option's label and description), in order.
TEAM_EVIDENCE_NORM='def tenorm($d): if type == "object" and keys == ["questions"] and (.questions | type) == "array"
  then [.questions[] | select(type == "object" and ((.question // "") | type) == "string"
      and ((.question // "") | startswith($d)))
    | {question: .question, header: (.header // null), multiSelect: (.multiSelect // false),
       options: [(.options // [])[] | {label: .label, description: (.description // "")}]}]
  else null end;
def tenamed($d): (if type == "object" then (.questions // []) else [] end)
  | if type == "array" then any(.[]; type == "object" and ((.question // "") | tostring | startswith($d))) else false end;'

# The streaming pass: a live transcript can be tens of MB and its last line half-written; jq emits
# every complete record before the bad line, and the comparisons run on this small extract.
team_evidence_dialog_extract() {
  [ -f "$1" ] || return 0
  jq -c --arg since "$2" '
    select(type == "object") | . as $e | select(($e.timestamp // "") >= $since)
    | if $e.type == "assistant" then
        ($e.message.content // [] | if type == "array" then .[] else empty end
          | select(type == "object" and .type == "tool_use" and .name == "AskUserQuestion")
          | {k: "ask", uuid: ($e.uuid // ""), id: (.id // ""), input: .input})
      elif $e.type == "user" and (($e.toolUseResult // null) | type) == "object" then
        ($e.message.content // [] | if type == "array" then .[] else empty end
          | select(type == "object" and .type == "tool_result")
          | {k: "ans", uuid: ($e.uuid // ""), tid: (.tool_use_id // ""), answers: ($e.toolUseResult.answers // null)})
      else empty end' "$1" 2>/dev/null || true
}

team_evidence_dialog_norm() {
  jq -c --arg d "$2 " "$TEAM_EVIDENCE_NORM"' tenorm($d) | select(. != null)' <<<"$1" 2>/dev/null
}

# The answer entries that count as evidence for <d-n>: every call naming <d-n> carries the stored
# dialog exactly (so editing ## Dialog can never pick between differing dialogs), and the entry
# answers one of those calls with a value for each <d-n> question. Printed oldest first.
team_evidence_dialog_valid() {  # <transcript> <d-n> <since> <dialog json>
  local s
  s="$(team_evidence_dialog_norm "$4" "$2")"
  [ -n "$s" ] && [ "$s" != "[]" ] || return 0
  team_evidence_dialog_extract "$1" "$3" | jq -c -s --arg d "$2 " --argjson s "$s" "$TEAM_EVIDENCE_NORM"'
    [.[] | select(.k == "ask") | {id, n: (.input | tenorm($d)), named: (.input | tenamed($d))}
      | select(.named or ((.n // []) | length) > 0)] as $named
    | if ($named | length) == 0 or any($named[]; .n == null)
        or (($named | map(.n | tojson) | unique) != [$s | tojson]) then empty
      else ($named | map(.id)) as $ids
        | .[] | select(.k == "ans" and (.tid as $t | any($ids[]; . == $t)) and (.answers | type) == "object")
        | . as $a | select(all($s[]; ($a.answers[.question] // "") | (type == "string" and length > 0)))
      end' 2>/dev/null
}

team_evidence_dialog_find() {
  team_evidence_dialog_valid "$1" "$2" "$3" "$4" | tail -n 1 | jq -r '.uuid // empty' 2>/dev/null
}

team_evidence_dialog_read() {
  local s
  s="$(team_evidence_dialog_norm "$5" "$3")"
  [ -n "$s" ] && [ "$s" != "[]" ] || return 1
  team_evidence_dialog_valid "$1" "$3" "$4" "$5" \
    | jq -c --arg u "$2" --arg d "$3" --argjson s "$s" 'select(.uuid == $u) | .answers as $a
      | if ($s | length) == 1 then {reply: "\($d) \($a[$s[0].question])", map: null}
        else {map: ([$s[] | {key: (.question | ltrimstr("\($d) ")), value: $a[.question]}] | from_entries),
              reply: ("\($d) " + ([$s[] | "\(.header // (.question | ltrimstr("\($d) "))): \($a[.question])"] | join("; ")))}
        end' 2>/dev/null | tail -n 1
}

team_evidence_dialog_raised() {
  team_evidence_dialog_extract "$1" "$2" | jq -r 'select(.k == "ask")
    | (if (.input | type) == "object" then (.input.questions // []) else [] end)
    | if type == "array" then .[] else empty end
    | (if type == "object" then (.question // "") else "" end) | tostring
    | select(test("^d-[0-9]+ ")) | capture("^(?<d>d-[0-9]+) ").d' 2>/dev/null | sort -u
}

team_evidence_sha() {  # stdin → its sha256 hex; rc 1 without a tool
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 | cut -d' ' -f1
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
  else return 1; fi
}

# One hook source of a plugin (a hooks file, or an inline `hooks` value): prints the first reason it
# is not clean. A file is an object without `modules` (hooks registered in code); the document and
# its `hooks` member are both read as event maps, so a file with or without the wrapper is covered;
# an event map with a guarded event is not clean, whatever its matcher.
TEAM_EVIDENCE_PLUGIN='def g: ["PreToolUse", "PermissionRequest", "PostToolUse", "UserPromptSubmit"];
  def chk: if type != "object" then "is not an event map"
    else ([keys[] | select(. as $k | g | index($k))] | if length > 0 then "has a \(.[0]) hook" else empty end) end;
  if $kind == "file" and type != "object" then "is not an object"
  elif $kind == "file" and has("modules") then "registers hooks in code (modules)"
  else (chk, (if type == "object" and has("hooks") then (.hooks | chk) else empty end)) end'

team_evidence_hooksrc() {  # <file|inline> <path | json> → nothing (rc 0), or the reason (rc 1)
  local c
  if [ "$1" = file ]; then c="$(jq -r --arg kind file "$TEAM_EVIDENCE_PLUGIN" "$2" 2>/dev/null)" || c="is unreadable"
  else c="$(jq -r --arg kind inline "$TEAM_EVIDENCE_PLUGIN" <<<"$2" 2>/dev/null)" || c="is unreadable"; fi
  [ -z "$c" ] || { head -n 1 <<<"$c"; return 1; }
}

# team_evidence_tree <who> <dir> → the digest lines of one plugin tree (rc 0), or the cause (rc 1):
# the manifest (.claude-plugin/plugin.json, when present) and its `hooks` (a path, an inline event
# map, or a list of both), every hooks.json of the tree, and no `hooks` frontmatter in any .md.
team_evidence_tree() {
  local who="$1" ip="$2" m refs ref p c files="" fm out=""
  [ -d "$ip" ] && [ -r "$ip" ] || { echo "$who: path $ip is not a readable directory"; return 1; }
  m="$ip/.claude-plugin/plugin.json"
  if [ -e "$m" ]; then
    refs="$(jq -r 'if type != "object" then error("shape") else .hooks end
      | if . == null then empty elif type == "array" then .[] else . end
      | if type == "string" then "path " + . elif type == "object" then "inline " + tojson else error("shape") end' "$m" 2>/dev/null)" \
      || { echo "$who: plugin.json or its hooks cannot be read"; return 1; }
    out="manifest $(team_evidence_sha < "$m")"
    while IFS= read -r ref; do
      case "$ref" in
        path\ *) p="${ref#path }"
          case "$p" in /*|*..*) echo "$who: hooks path $p leaves the plugin"; return 1 ;; esac
          p="$ip/${p#./}"
          [ -f "$p" ] || { echo "$who: hooks file ${p#"$ip"/} is missing"; return 1; }
          files="$files$p"$'\n' ;;
        inline\ *) c="$(team_evidence_hooksrc inline "${ref#inline }")" \
          || { echo "$who: plugin.json hooks $c"; return 1; } ;;
      esac
    done <<<"$refs"
  fi
  # The default file by its path (a case-insensitive volume opens it under any spelling), and
  # every hooks.json of the tree under any spelling: more than the host loads, never less.
  [ ! -e "$ip/hooks/hooks.json" ] || files="$files$ip/hooks/hooks.json"$'\n'
  p="$(find -L "$ip" -iname hooks.json 2>/dev/null)" || { echo "$who: $ip cannot be walked"; return 1; }
  files="$(printf '%s%s\n' "$files" "$p" | LC_ALL=C sort -u)"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    c="$(team_evidence_hooksrc file "$p")" || { echo "$who: ${p#"$ip"/} $c"; return 1; }
    out="$out"$'\n'"hooks ${p#"$ip"/} $(team_evidence_sha < "$p")"
  done <<<"$files"
  # A skill's or agent's frontmatter hooks run while it is active: not inventoried, so a cause.
  # No YAML parser here: any frontmatter line with a `hooks` key, quoted or nested, counts.
  fm="$(find -L "$ip" -type f -name '*.md' -exec awk '{ sub(/\r$/, "") } FNR == 1 { sub(/^\357\273\277/, ""); f = ($0 == "---"); next }
    f && $0 == "---" { f = 0 } f && /hooks["\047]?[ \t]*:/ { print FILENAME; f = 0 }' {} + 2>/dev/null)" \
    || { echo "$who: $ip cannot be walked"; return 1; }
  [ -z "$fm" ] || { echo "$who: frontmatter hooks in $(head -n 1 <<<"$fm" | sed "s|^$ip/||")"; return 1; }
  printf '%s\n' "${out#$'\n'}"
}

# team_evidence_plugins <config dir> <enabled ids, one per line> → the digest lines of the enabled
# plugins' hooks as the host loads them (rc 0), or the cause (rc 1). Per install record of an id
# (<config dir>/plugins/installed_plugins.json): the manifest (.claude-plugin/plugin.json, when
# present) and its `hooks` (a path, an inline event map, or a list of both), every hooks.json in
# the install tree (hooks/hooks.json and a skill's own), the marketplace entry's inline `hooks`,
# and no `hooks:` frontmatter in any .md. Anything that cannot be read or resolved is a cause.
team_evidence_plugins() {
  local cfg="$1" key name mkt P ins km ips ip loc entry m refs ref p c files fm out=""
  [ -z "${CLAUDE_CODE_PLUGIN_CACHE_DIR:-}" ] \
    || { echo "enabled plugins: CLAUDE_CODE_PLUGIN_CACHE_DIR is set, the plugin root cannot be established"; return 1; }
  P="$cfg/plugins"; ins="$P/installed_plugins.json"; km="$P/known_marketplaces.json"
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    name="${key%@*}"; mkt="${key##*@}"
    [ "$name" != "$key" ] && [ -n "$name" ] && [ -n "$mkt" ] \
      || { echo "enabled plugin $key: not a <name>@<marketplace> id"; return 1; }
    ips="$(jq -r --arg k "$key" '.plugins[$k] | if type == "array" and length > 0 then .[] else error("none") end
      | .installPath | if type == "string" and . != "" then . else error("no path") end' "$ins" 2>/dev/null)" && [ -n "$ips" ] \
      || { echo "enabled plugin $key: no usable install record in $ins"; return 1; }
    loc="$(jq -r --arg m "$mkt" '.[$m].installLocation // empty' "$km" 2>/dev/null)" || loc=""
    entry="$([ -n "$loc" ] && jq -cS --arg n "$name" '[.plugins[]? | select(.name == $n)]
      | if length == 1 then .[0] | {hooks: .hooks, strict: .strict} else error("entry") end' \
      "$loc/.claude-plugin/marketplace.json" 2>/dev/null)" && [ -n "$entry" ] \
      || { echo "enabled plugin $key: no single entry in the marketplace manifest of $mkt"; return 1; }
    if [ "$(jq -r '.hooks | type' <<<"$entry")" != null ]; then
      c="$(team_evidence_hooksrc inline "$(jq -c .hooks <<<"$entry")")" \
        || { echo "enabled plugin $key: the marketplace entry's hooks $c"; return 1; }
    fi
    while IFS= read -r ip; do
      c="$(team_evidence_tree "enabled plugin $key" "$ip")" || { echo "$c"; return 1; }
      out="$out"$'\n'"plugin $key $ip entry $entry"$'\n'"$c"
    done <<<"$(LC_ALL=C sort -u <<<"$ips")"
  done <<<"$2"
  printf '%s\n' "${out#$'\n'}"
}

# team_evidence_terminal <team> <decision file> <d-n> → the terminal command that answers that
# decision, a line for the Operator to copy. An unbound decision takes its outcome from --outcome
# on this route (only a dialog answer derives it from the label).
team_evidence_terminal() {
  local o=""
  grep -q '^bind_ask: ' "$2" 2>/dev/null || o=' --outcome <the answer, when it is continue|close|more-revise|approve>'
  printf 'bash .claude/lib/team-lead.sh decision answer %s %s --text "%s <answer>"%s\n' "$1" "$3" "$3" "$o"
}

# team_evidence_fix <cause> → one line: what the Operator changes to make the registrations clean.
team_evidence_fix() {
  case "$1" in
    "plugin directory "*) echo "unset CLAUDE_CODE_PLUGIN_DIRS for the runner and the lead (or drop that directory from it), or remove the hook from that plugin" ;;
    *"enabled plugins: CLAUDE_CODE_PLUGIN_CACHE_DIR"*) echo "unset that variable for the runner and the lead" ;;
    "account-synced plugin content"*) echo "switch the synced plugin off for this profile, or run the lead on a profile without it" ;;
    "registrations changed since launch"|"no launch snapshot"*|"no anchor"*) echo "undo the change, or end and relaunch the lead (a launch takes a new snapshot)" ;;
    *"enabled plugin"*) echo "disable that plugin for the lead's profile (/plugin, or enabledPlugins → false in the settings file that enables it), or remove its hook" ;;
    "user mod "*|"clone mod "*) echo "remove that mod's hooks directory (a clone mod: make it equal to the main checkout's)" ;;
    *guard-team-question*) echo "restore .claude/hooks/guard-team-question.sh from the main checkout" ;;
    *) echo "remove that hook registration from the named settings file" ;;
  esac
}

# The only AskUserQuestion hook a lead session may carry: the project's inert guard, the same bytes
# as the main checkout's. Anything else could answer the dialog with no menu shown.
TEAM_EVIDENCE_GUARD='bash "$CLAUDE_PROJECT_DIR/.claude/hooks/guard-team-question.sh"'
team_evidence_ask_hooks() {
  local main="$1" clone="$2" cfg="${3:-}" src f name ents="" e plugins m g="" list="" d h plist="" pd=""
  [ -n "$cfg" ] || cfg="$HOME/.claude"
  # The managed settings file (macOS path) is one more source of hooks and enabledPlugins; no
  # override knob, so nothing a session sets can hide it.
  for src in "managed settings|/Library/Application Support/ClaudeCode/managed-settings.json" \
      "user settings.json|$cfg/settings.json" "project settings.json|$clone/.claude/settings.json" \
      "project settings.local.json|$clone/.claude/settings.local.json" \
      "teamlead.settings.json|$clone/.agents/team/teamlead.settings.json"; do
    name="${src%%|*}"; f="${src#*|}"
    [ -f "$f" ] || continue
    jq empty "$f" >/dev/null 2>&1 || { echo "unclean $name: unparseable"; return 1; }
    # A plugin brings its own hooks: every id any source enables (anything but `false`: a version
    # constraint enables too) is inventoried below, whichever source would win the merge.
    plugins="$(jq -r '(.enabledPlugins // {}) | if type == "object" then to_entries[] | select(.value != false and .value != null) | .key
      else error("shape") end' "$f" 2>/dev/null)" || { echo "unclean $name: unreadable enabledPlugins"; return 1; }
    [ -z "$plugins" ] || plist="$plist$plugins"$'\n'
    # PreToolUse and PermissionRequest hooks can both answer the dialog (updatedInput). A matcher
    # matches as a name list (comma or pipe) or unanchored, as Claude Code matches; an invalid regex
    # counts as matching (fails closed).
    e="$(jq -c --arg src "$name" '
      def hits($m): $m == "" or $m == "*"
        or any($m | split(",")[] | split("|")[] | gsub("^\\s+|\\s+$"; ""); . == "AskUserQuestion")
        or (try ("AskUserQuestion" | test($m)) catch true);
      ((.hooks.PreToolUse // []) | if type == "array" then .[] else empty end | {ev: "PreToolUse", h: .}),
      ((.hooks.PermissionRequest // []) | if type == "array" then .[] else empty end | {ev: "PermissionRequest", h: .})
      | .ev as $ev | .h | select(type == "object") | (.matcher // "") as $m
      | select(hits($m))
      | {src: $src, event: $ev, matcher: $m, cmds: [(.hooks // []) | if type == "array" then .[] else empty end
          | if (.type // "command") == "command" then (.command // "") else "<\(.type)>" end]}' "$f" 2>/dev/null)" \
      || { echo "unclean $name: unreadable hooks"; return 1; }
    [ -z "$e" ] || ents="$ents$e"$'\n'
  done
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    if jq -e --arg c "$TEAM_EVIDENCE_GUARD" '.src == "project settings.json" and .event == "PreToolUse" and .cmds == [$c]' <<<"$e" >/dev/null 2>&1; then
      g=1; continue
    fi
    echo "unclean $(jq -r '"\(.src): \(.event) \(if .matcher == "" then "(no matcher)" else .matcher end) \(.cmds | join(" ; "))"' <<<"$e")"
    return 1
  done <<<"$ents"
  # Plugins the host loads with no enabledPlugins entry: each plugin directory named in the
  # environment (colon-separated) is inventoried as a plugin tree; plugin content synced from the
  # account cannot be.
  if [ -n "${CLAUDE_CODE_PLUGIN_DIRS:-}" ]; then
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      case "$d" in "~/"*) d="$HOME/${d#\~/}" ;; esac
      [ -f "$d/.claude-plugin/plugin.json" ] \
        || { echo "unclean plugin directory $d (CLAUDE_CODE_PLUGIN_DIRS): no .claude-plugin/plugin.json, what loads from it cannot be established"; return 1; }
      e="$(team_evidence_tree "plugin directory $d (CLAUDE_CODE_PLUGIN_DIRS)" "$d")" || { echo "unclean $e"; return 1; }
      pd="$pd"$'\n'"plugindir $d"$'\n'"$e"
    done <<<"$(printf '%s\n' "$CLAUDE_CODE_PLUGIN_DIRS" | tr ':' '\n')"
  fi
  if [ -e "$cfg/plugins/synced" ]; then
    d="$(find -L "$cfg/plugins/synced" \( -iname hooks.json -o -iname plugin.json -o -iname '*.md' \) 2>/dev/null)" \
      || { echo "unclean account-synced plugin content cannot be inventoried: $cfg/plugins/synced cannot be walked"; return 1; }
    [ -z "$d" ] || { echo "unclean account-synced plugin content cannot be inventoried: $(sed -n 1p <<<"$d")"; return 1; }
  fi
  if [ -n "$plist" ]; then
    e="$(team_evidence_plugins "$cfg" "$(LC_ALL=C sort -u <<<"$plist")")" || { echo "unclean $e"; return 1; }
    pd="$pd"$'\n'"$e"
  fi
  m="$main/.claude/hooks/guard-team-question.sh"
  if [ -n "$g" ]; then
    [ -f "$m" ] && cmp -s "$m" "$clone/.claude/hooks/guard-team-question.sh" \
      || { echo "unclean project settings.json: guard-team-question.sh differs from the main checkout's"; return 1; }
    [ "$(grep -v '^[[:space:]]*#' "$m" | grep -v '^[[:space:]]*$')" = "exit 0" ] \
      || { echo "unclean project settings.json: main's guard-team-question.sh is not inert"; return 1; }
  fi
  # Mods (.claude/skills/<name>/hooks/) load in a trusted project and may register hooks in code: a
  # clone mod must be main's tree byte for byte; a user-level mod cannot be inventoried at all.
  for d in "$cfg"/skills/*/hooks; do
    [ -d "$d" ] || continue
    d="${d%/hooks}"; echo "unclean user mod ${d##*/}"; return 1
  done
  for d in "$clone"/.claude/skills/*/hooks; do
    [ -d "$d" ] || continue
    d="${d%/hooks}"; d="${d##*/}"
    [ -d "$main/.claude/skills/$d" ] && diff -r -q "$main/.claude/skills/$d" "$clone/.claude/skills/$d" >/dev/null 2>&1 \
      || { echo "unclean clone mod $d"; return 1; }
    list="$list $d"
  done
  h="$( { printf '%s' "$ents" | jq -cS -s 'sort_by(.src, .matcher)'
    [ -z "$g" ] || cat "$m"
    [ -z "$pd" ] || printf '%s\n' "$pd"
    for d in $list; do
      ( cd "$main/.claude/skills/$d" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do
          printf '%s %s\n' "$d/$f" "$(team_evidence_sha < "$f")"; done )
    done; } | team_evidence_sha)" && [ -n "$h" ] || { echo "unclean no sha256 tool"; return 1; }
  echo "clean $h"
}

team_evidence_snapshot() {
  jq -nc --arg h "$1" 'if ($h | startswith("clean ")) then {clean: true, digest: ($h | ltrimstr("clean ")), cause: ""}
    else {clean: false, digest: "", cause: (if $h == "" then "no registration check" else ($h | ltrimstr("unclean ")) end)} end'
}

team_evidence_anchor() {
  local phys x anc=""
  phys="$(cd "$2" 2>/dev/null && pwd -P)" || return 1
  for x in "$1"/.agents/team/anchors/*.json; do
    [ -f "$x" ] && [ "$(jq -r '.clone // ""' "$x" 2>/dev/null)" = "$phys" ] || continue
    [ -z "$anc" ] || return 1; anc="$x"
  done
  [ -n "$anc" ] && echo "$anc"
}

team_evidence_provenance() {
  local anc snap cfg now
  anc="$(team_evidence_anchor "$1" "$2")" || { echo "no anchor for this clone"; return 1; }
  snap="$(jq -c --arg s "$4" --arg r "$3" '.lead_ask_hooks[$s] // empty | select(.run == $r)' "$anc" 2>/dev/null)"
  [ -n "$snap" ] || { echo "no launch snapshot for this session"; return 1; }
  [ "$(jq -r '.clean' <<<"$snap")" = true ] \
    || { echo "launch snapshot unclean: $(jq -r '.cause // "unknown"' <<<"$snap")"; return 1; }
  cfg="$(jq -r '.config_dir // ""' <<<"$snap")"
  now="$(team_evidence_ask_hooks "$1" "$2" "$cfg")" || { echo "${now#unclean }"; return 1; }
  [ "$now" = "clean $(jq -r '.digest // ""' <<<"$snap")" ] \
    || { echo "registrations changed since launch"; return 1; }
  echo "$cfg"
}
