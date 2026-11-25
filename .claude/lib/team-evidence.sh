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
#   team_evidence_ask_hooks <main> <clone> <config dir> [lead-profile] → "clean <digest>" (rc 0) or
#     "unclean <cause>" (rc 1): the effective AskUserQuestion hook registrations of a lead session,
#     with the hooks of every enabled plugin (team_evidence_plugins) in the digest; `lead-profile`
#     (team-lead.sh preflight only) takes the plugin directories materialize will write ("")
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

# team_evidence_take <file> → the path of a private copy of it (rc 1 when it cannot be read). Every
# input is captured once, here, and both inspected and hashed from that copy: what was judged is
# what the digest binds. The copies live in TEAM_EVIDENCE_TMP, which team_evidence_ask_hooks owns.
team_evidence_take() {
  local c
  c="$(mktemp "$TEAM_EVIDENCE_TMP/in.XXXXXX")" && cat "$1" > "$c" 2>/dev/null && echo "$c"
}

# team_evidence_tree <who> <dir> → the digest lines of one plugin tree (rc 0), or the cause (rc 1):
# the manifest (.claude-plugin/plugin.json, when present) and its `hooks` (a path, an inline event
# map, or a list of both), every hooks.json of the tree, and the frontmatter of every .md, which
# must carry no `hooks` key.
team_evidence_tree() {
  local who="$1" ip="$2" m refs ref p c k files="" fm out=""
  [ -d "$ip" ] && [ -r "$ip" ] || { echo "$who: path $ip is not a readable directory"; return 1; }
  m="$ip/.claude-plugin/plugin.json"
  if [ -e "$m" ]; then
    k="$(team_evidence_take "$m")" || { echo "$who: plugin.json cannot be read"; return 1; }
    refs="$(jq -r 'if type != "object" then error("shape") else .hooks end
      | if . == null then empty elif type == "array" then .[] else . end
      | if type == "string" then "path " + . elif type == "object" then "inline " + tojson else error("shape") end' "$k" 2>/dev/null)" \
      || { echo "$who: plugin.json or its hooks cannot be read"; return 1; }
    out="manifest $(team_evidence_sha < "$k")"
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
    k="$(team_evidence_take "$p")" || { echo "$who: ${p#"$ip"/} is unreadable"; return 1; }
    c="$(team_evidence_hooksrc file "$k")" || { echo "$who: ${p#"$ip"/} $c"; return 1; }
    out="$out"$'\n'"hooks ${p#"$ip"/} $(team_evidence_sha < "$k")"
  done <<<"$files"
  # A skill's or agent's frontmatter hooks run while it is active: not inventoried, so a cause.
  # One pass captures the frontmatter of every .md (`<file>\t<line number>\t<line>`, CR and BOM
  # dropped); the test and the digest both read that capture, and the line number keeps the order
  # of the lines in the sorted digest input. No YAML parser here: any frontmatter line with a
  # `hooks` key, quoted or nested, counts.
  k="$(mktemp "$TEAM_EVIDENCE_TMP/fm.XXXXXX")" || { echo "$who: no temporary file"; return 1; }
  find -L "$ip" -type f -iname '*.md' -exec awk '{ sub(/\r$/, "") } FNR == 1 { sub(/^\357\273\277/, ""); f = ($0 == "---"); next }
    f && $0 == "---" { f = 0 } f { print FILENAME "\t" FNR "\t" $0 }' {} + > "$k" 2>/dev/null \
    || { echo "$who: $ip cannot be walked"; return 1; }
  fm="$(awk '{ l = $0; sub(/^[^\t]*\t[^\t]*\t/, "", l) } l ~ /hooks["\047]?[ \t]*:/ { sub(/\t.*$/, ""); print; exit }' "$k")"
  [ -z "$fm" ] || { echo "$who: frontmatter hooks in ${fm#"$ip"/}"; return 1; }
  out="$out"$'\n'"frontmatter $(LC_ALL=C sort "$k" | team_evidence_sha)"
  printf '%s\n' "${out#$'\n'}"
}

# team_evidence_plugins <config dir> <enabled ids, one per line> → the digest lines of the enabled
# plugins' hooks as the host loads them (rc 0), or the cause (rc 1). Per install record of an id
# (<config dir>/plugins/installed_plugins.json): its tree (team_evidence_tree) and the marketplace
# entry's inline `hooks`. Anything that cannot be read or resolved is a cause.
team_evidence_plugins() {
  local cfg="$1" key name mkt P ins km ips ip loc entry c out=""
  P="$cfg/plugins"
  ins="$(team_evidence_take "$P/installed_plugins.json")" || ins=/dev/null
  km="$(team_evidence_take "$P/known_marketplaces.json")" || km=/dev/null
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    name="${key%@*}"; mkt="${key##*@}"
    [ "$name" != "$key" ] && [ -n "$name" ] && [ -n "$mkt" ] \
      || { echo "enabled plugin $key: not a <name>@<marketplace> id"; return 1; }
    ips="$(jq -r --arg k "$key" '.plugins[$k] | if type == "array" and length > 0 then .[] else error("none") end
      | .installPath | if type == "string" and . != "" then . else error("no path") end' "$ins" 2>/dev/null)" && [ -n "$ips" ] \
      || { echo "enabled plugin $key: no usable install record in $P/installed_plugins.json"; return 1; }
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
    "plugin directory "*) echo "drop that directory from CLAUDE_CODE_PLUGIN_DIRS in the source the cause names (the environment of the runner and the lead, or the env key of that settings file), or remove the hook from that plugin" ;;
    *CLAUDE_CODE_PLUGIN_CACHE_DIR*) echo "unset that variable in the source the cause names (the environment of the runner and the lead, or the env key of that settings file)" ;;
    "account-synced plugin content"*) echo "switch the synced plugin off for this profile, or run the lead on a profile without it" ;;
    "registrations changed since launch"|"no launch snapshot"*|"no anchor"*) echo "undo the change, or end and relaunch the lead (a launch takes a new snapshot)" ;;
    *"enabled plugin"*) echo "disable that plugin for the lead's profile (/plugin, or enabledPlugins → false in the settings file that enables it), or remove its hook" ;;
    "user mod "*|"clone mod "*) echo "remove that mod's hooks directory (a clone mod: make it equal to the main checkout's)" ;;
    *guard-team-question*) echo "restore .claude/hooks/guard-team-question.sh from the main checkout" ;;
    *team-status.sh*) echo "restore .claude/hooks/team-status.sh and its settings entry from the main checkout" ;;
    *) echo "remove that hook registration from the named settings file" ;;
  esac
}

# The only hooks on AskUserQuestion a lead session may carry are the project's own two, each pinned
# to the main checkout's bytes: the inert question guard (PreToolUse) and the session-state hook
# (matcher-less PostToolUse, one command, nothing but type/command/timeout). Anything else could
# answer the dialog with no menu shown, or replace the result the answer is read from.
TEAM_EVIDENCE_GUARD='bash "$CLAUDE_PROJECT_DIR/.claude/hooks/guard-team-question.sh"'
TEAM_EVIDENCE_STATUS='bash "$CLAUDE_PROJECT_DIR/.claude/hooks/team-status.sh"'
team_evidence_ask_hooks() {
  local rc=0
  TEAM_EVIDENCE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/team-evidence.XXXXXX")" || { echo "unclean no temporary directory"; return 1; }
  team_evidence_ask_hooks_in "$@" || rc=$?
  rm -rf "$TEAM_EVIDENCE_TMP"; TEAM_EVIDENCE_TMP=""
  return "$rc"
}

# team_evidence_inv <dir> → the inventory of a tree, one line per file, sorted: `<path> <sha256>`.
# rc 1 when the tree or a file cannot be read, or the tree holds a link: a link's text can be equal
# in two checkouts while it points at different bytes, so a tree with one has no inventory.
team_evidence_inv() {
  local f s l out=""
  l="$(cd "$1" 2>/dev/null && find . \( -type f -o -type l \) 2>/dev/null)" || return 1
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ ! -L "$1/$f" ] || return 1
    s="$(team_evidence_sha < "$1/$f")" && [ -n "$s" ] || return 1
    out="$out$f $s"$'\n'
  done <<<"$(LC_ALL=C sort <<<"$l")"
  printf '%s' "$out"
}

team_evidence_ask_hooks_in() {
  local main="$1" clone="$2" cfg="${3:-}" proj="${4:-}" src f k name ents="" e x plugins m g="" st="" list="" d h plist="" pd="" dirs="" mods="" mset="" mval="" fset="" fval=""
  [ -n "$cfg" ] || cfg="$HOME/.claude"
  # The process environment first: it reaches the lead through the runner's launch.
  [ -z "${CLAUDE_CODE_PLUGIN_CACHE_DIR:-}" ] \
    || { echo "unclean environment: CLAUDE_CODE_PLUGIN_CACHE_DIR is set, the plugin root cannot be established"; return 1; }
  # A value with a newline or a tab cannot be carried by the line records below: unclean.
  case "${CLAUDE_CODE_PLUGIN_DIRS:-}" in *$'\n'*|*$'\t'*)
    echo "unclean environment: CLAUDE_CODE_PLUGIN_DIRS holds a newline or a tab, its directories cannot be established"; return 1 ;; esac
  [ -z "${CLAUDE_CODE_PLUGIN_DIRS:-}" ] || dirs="environment"$'\t'"$CLAUDE_CODE_PLUGIN_DIRS"$'\n'
  # The managed settings file (macOS path) is one more source of hooks and enabledPlugins; no
  # override knob, so nothing a session sets can hide it.
  for src in "managed settings|/Library/Application Support/ClaudeCode/managed-settings.json" \
      "user settings.json|$cfg/settings.json" "project settings.json|$clone/.claude/settings.json" \
      "project settings.local.json|$clone/.claude/settings.local.json" \
      "teamlead.settings.json|$clone/.agents/team/teamlead.settings.json"; do
    name="${src%%|*}"; f="${src#*|}"
    [ -f "$f" ] || continue
    k="$(team_evidence_take "$f")" && jq empty "$k" >/dev/null 2>&1 || { echo "unclean $name: unparseable"; return 1; }
    # The host applies a settings file's `env` to the session: a plugin root or plugin directory
    # set there counts like the process environment's.
    x="$(jq -r '(.env // {}) | if type != "object" then error("shape") else
      (if (.CLAUDE_CODE_PLUGIN_CACHE_DIR // null) != null then "cache" else empty end),
      (if (.CLAUDE_CODE_PLUGIN_DIRS // null) == null then empty
       elif (.CLAUDE_CODE_PLUGIN_DIRS | type != "string" or test("[\n\t]")) then "baddirs"
       else "dirs " + .CLAUDE_CODE_PLUGIN_DIRS end) end' "$k" 2>/dev/null)" \
      || { echo "unclean $name: unreadable env"; return 1; }
    case $'\n'"$x" in *$'\n'cache*)
      echo "unclean $name: env.CLAUDE_CODE_PLUGIN_CACHE_DIR is set, the plugin root cannot be established"; return 1 ;; esac
    case $'\n'"$x" in *$'\n'baddirs*)
      echo "unclean $name: env.CLAUDE_CODE_PLUGIN_DIRS is no plain one-line string, its directories cannot be established"; return 1 ;; esac
    # One line by construction: no newline in the value, and a `cache` line has returned above.
    case "$x" in "dirs "*)
      dirs="$dirs$name env"$'\t'"${x#dirs }"$'\n'
      case "$name" in
        "managed settings") mset=1; mval="${x#dirs }" ;;
        teamlead.settings.json) fset=1; fval="${x#dirs }" ;;
      esac ;;
    esac
    # A plugin brings its own hooks: every id any source enables (anything but `false`: a version
    # constraint enables too) is inventoried below, whichever source would win the merge.
    plugins="$(jq -r '(.enabledPlugins // {}) | if type == "object" then to_entries[] | select(.value != false and .value != null) | .key
      else error("shape") end' "$k" 2>/dev/null)" || { echo "unclean $name: unreadable enabledPlugins"; return 1; }
    [ -z "$plugins" ] || plist="$plist$plugins"$'\n'
    # PreToolUse and PermissionRequest hooks can both answer the dialog (updatedInput); a
    # PostToolUse hook can replace the tool result the answer is read from. A matcher matches as a
    # name list (comma or pipe) or unanchored, as Claude Code matches; an invalid regex counts as
    # matching (fails closed). `extra` lists hook fields beyond type/command/timeout.
    e="$(jq -c --arg src "$name" '
      def hits($m): $m == "" or $m == "*"
        or any($m | split(",")[] | split("|")[] | gsub("^\\s+|\\s+$"; ""); . == "AskUserQuestion")
        or (try ("AskUserQuestion" | test($m)) catch true);
      ((.hooks.PreToolUse // []) | if type == "array" then .[] else empty end | {ev: "PreToolUse", h: .}),
      ((.hooks.PermissionRequest // []) | if type == "array" then .[] else empty end | {ev: "PermissionRequest", h: .}),
      ((.hooks.PostToolUse // []) | if type == "array" then .[] else empty end | {ev: "PostToolUse", h: .})
      | .ev as $ev | .h | select(type == "object") | (.matcher // "") as $m
      | select(hits($m))
      | {src: $src, event: $ev, matcher: $m, cmds: [(.hooks // []) | if type == "array" then .[] else empty end
          | if (.type // "command") == "command" then (.command // "") else "<\(.type)>" end],
         extra: ([(.hooks // []) | if type == "array" then .[] else empty end
          | if type == "object" then (keys - ["command", "timeout", "type"])[] else "<shape>" end] | unique)}' "$k" 2>/dev/null)" \
      || { echo "unclean $name: unreadable hooks"; return 1; }
    [ -z "$e" ] || ents="$ents$e"$'\n'
  done
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    if jq -e --arg c "$TEAM_EVIDENCE_GUARD" '.src == "project settings.json" and .event == "PreToolUse" and .cmds == [$c]' <<<"$e" >/dev/null 2>&1; then
      g=1; continue
    fi
    if jq -e --arg c "$TEAM_EVIDENCE_STATUS" '.src == "project settings.json" and .event == "PostToolUse" and .matcher == ""
        and .cmds == [$c] and .extra == []' <<<"$e" >/dev/null 2>&1; then
      st=1; continue
    fi
    echo "unclean $(jq -r '"\(.src): \(.event) \(if .matcher == "" then "(no matcher)" else .matcher end) \(.cmds | join(" ; "))"' <<<"$e")"
    return 1
  done <<<"$ents"
  # The value the host applies is the highest source's that sets the key: managed settings, then
  # the lead's --settings file (teamlead.settings.json; it overrides the user/project/local `env`
  # and the inherited process environment — checked on Claude Code 2026-11-25), and only below
  # those the union of everything else (fails closed). materialize writes "" there, so the lead
  # loads none of the Operator's plugin directories. Only the preflight passes `lead-profile` (an
  # argument, never the environment) to take that value before the launch has written the file;
  # the launch and every answer check read the actual file.
  [ "$proj" != lead-profile ] || { fset=1; fval=""; }
  if [ -n "$mset" ]; then dirs="managed settings env"$'\t'"$mval"$'\n'
  elif [ -n "$fset" ]; then dirs="teamlead.settings.json env"$'\t'"$fval"$'\n'; fi
  # Plugins the host loads with no enabledPlugins entry: each plugin directory named by
  # CLAUDE_CODE_PLUGIN_DIRS (colon-separated; the environment or a settings file's env) is
  # inventoried as a plugin tree, its resolved path in the digest; plugin content synced from the
  # account cannot be.
  # The digest takes each resolved directory once, in path order, without its source: the lead's
  # own process sees a settings `env` value in its environment too, and must get the same digest.
  # The source (the first that names the directory) is kept for the cause.
  list=""
  while IFS=$'\t' read -r name x; do
    [ -n "$name" ] || continue
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      case "$d" in "~/"*) d="$HOME/${d#\~/}" ;; esac
      # A relative entry resolves against the working directory of whoever reads it: here the
      # checker's, in the session the lead's (the clone). The same string, two trees: unclean.
      case "$d" in /*) ;; *)
        echo "unclean plugin directory $d (CLAUDE_CODE_PLUGIN_DIRS, $name): not an absolute path, the tree it names depends on the working directory"; return 1 ;; esac
      list="$list$d"$'\t'"$name"$'\n'
    done <<<"$(printf '%s\n' "$x" | tr ':' '\n')"
  done <<<"$dirs"
  x=""
  while IFS=$'\t' read -r d name; do
    [ -n "$d" ] && [ "$d" != "$x" ] || continue
    x="$d"
    [ -f "$d/.claude-plugin/plugin.json" ] \
      || { echo "unclean plugin directory $d (CLAUDE_CODE_PLUGIN_DIRS, $name): no .claude-plugin/plugin.json, what loads from it cannot be established"; return 1; }
    e="$(team_evidence_tree "plugin directory $d (CLAUDE_CODE_PLUGIN_DIRS, $name)" "$d")" || { echo "unclean $e"; return 1; }
    pd="$pd"$'\n'"plugindir $d"$'\n'"$e"
  done <<<"$(printf '%s' "$list" | LC_ALL=C sort -s -t "$(printf '\t')" -k1,1)"
  list=""
  if [ -e "$cfg/plugins/synced" ]; then
    d="$(find -L "$cfg/plugins/synced" \( -iname hooks.json -o -iname plugin.json -o -iname '*.md' \) 2>/dev/null)" \
      || { echo "unclean account-synced plugin content cannot be inventoried: $cfg/plugins/synced cannot be walked"; return 1; }
    [ -z "$d" ] || { echo "unclean account-synced plugin content cannot be inventoried: $(sed -n 1p <<<"$d")"; return 1; }
  fi
  if [ -n "$plist" ]; then
    e="$(team_evidence_plugins "$cfg" "$(LC_ALL=C sort -u <<<"$plist")")" || { echo "unclean $e"; return 1; }
    pd="$pd"$'\n'"$e"
  fi
  # The two pinned scripts: one capture of main's copy each, compared with the clone's and hashed.
  m=""
  if [ -n "$g" ]; then
    m="$(team_evidence_take "$main/.claude/hooks/guard-team-question.sh")" && cmp -s "$m" "$clone/.claude/hooks/guard-team-question.sh" \
      || { echo "unclean project settings.json: guard-team-question.sh differs from the main checkout's"; return 1; }
    [ "$(grep -v '^[[:space:]]*#' "$m" | grep -v '^[[:space:]]*$')" = "exit 0" ] \
      || { echo "unclean project settings.json: main's guard-team-question.sh is not inert"; return 1; }
  fi
  if [ -n "$st" ]; then
    st="$(team_evidence_take "$main/.claude/hooks/team-status.sh")" && cmp -s "$st" "$clone/.claude/hooks/team-status.sh" \
      || { echo "unclean project settings.json: team-status.sh differs from the main checkout's"; return 1; }
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
    # One inventory of each tree (every file read once): the two are compared, and main's same
    # inventory is what the digest takes.
    x="$(team_evidence_inv "$main/.claude/skills/$d")" && e="$(team_evidence_inv "$clone/.claude/skills/$d")" \
      && [ -n "$x" ] && [ "$x" = "$e" ] || { echo "unclean clone mod $d"; return 1; }
    mods="$mods$(awk -v p="$d/" '{ print p $0 }' <<<"$x")"$'\n'
  done
  h="$( { printf '%s' "$ents" | jq -cS -s 'sort_by(.src, .event, .matcher)'
    [ -z "$m" ] || cat "$m"
    [ -z "$st" ] || cat "$st"
    [ -z "$pd" ] || printf '%s\n' "$pd"
    printf '%s' "$mods"; } | team_evidence_sha)" && [ -n "$h" ] || { echo "unclean no sha256 tool"; return 1; }
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
