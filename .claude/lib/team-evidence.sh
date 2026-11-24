#!/usr/bin/env bash
# Operator evidence in a supervised session's transcript. Sourced, never executed. Bash 3.2 + jq.
#   team_evidence_match <transcript> <text> <since> <id> <used uuids> [exact]
#     → the uuid of the newest typed user message at or after <since> that contains <text> (with
#       `exact`: equals it, both trimmed — an ask-bound decision's whole reply) and is
#       no doorbell (stop, gate, prompt, ask, attention, unasked, …), runner, legacy team-watch (retired) or hc message line; a uuid already used by another answer
#       (space-separated list) counts only when that message names <id>. Nothing when no match.
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
#     "unclean <cause>" (rc 1): the effective AskUserQuestion hook registrations of a lead session
#   team_evidence_snapshot <ask hooks line> → {clean, digest, cause}: that line as a launch snapshot
#   team_evidence_anchor <main> <clone> → the main checkout's anchor of that clone (by physical path)
#   team_evidence_provenance <main> <clone> <run> <session id> → "<config dir>" (rc 0) when that
#     session's launch snapshot is clean and the registrations still match it, else the cause (rc 1)
# Callers: team-lead-decision.sh (the TeamLead window, the dialog), team-lineage.sh consent (the
# Supervisor window), team-ask-hook.sh (re-verification), the runner (snapshot, reminder). It raises
# the bar; it is not proof (team-lead.md §7).
# Its own file: team-lib.sh has no room, and the callers run from the clone and the main checkout.

team_evidence_match() {
  jq -r --arg x "$2" --arg since "$3" --arg id "$4" \
    --arg used "$5" --arg mode "${6:-}" '
    def trim: sub("^\\s+"; "") | sub("\\s+$"; "");
    ($used | split(" ") | map(select(. != ""))) as $u
    | select(.type == "user" and ((.isMeta // false) | not) and ((.timestamp // "") >= $since))
    | (.uuid // "?") as $uid
    | (.message.content | if type == "string" then .
        elif type == "array" then (map(select(.type == "text") | .text) | join(" ")) else "" end) as $m
    | select($m != "" and (if $mode == "exact" then ($m | trim) == ($x | trim) else ($m | contains($x)) end)
        and ($m | test("^(stop |gate |prompt |ask |attention |unasked |inbox:|relaunched: |human-only |\\[team-run\\]|\\[team-watch |<hc from=)") | not))
    | select((($u | index($uid)) == null) or ($m | test("(^|[^A-Za-z0-9-])" + $id + "([^0-9]|$)")))
    | $uid' "$1" 2>/dev/null | tail -n 1
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

# The only AskUserQuestion hook a lead session may carry: the project's inert guard, the same bytes
# as the main checkout's. Anything else could answer the dialog with no menu shown.
TEAM_EVIDENCE_GUARD='bash "$CLAUDE_PROJECT_DIR/.claude/hooks/guard-team-question.sh"'
team_evidence_ask_hooks() {
  local main="$1" clone="$2" cfg="${3:-}" src f name ents="" e plugins m g="" list="" d h
  [ -n "$cfg" ] || cfg="$HOME/.claude"
  for src in "user settings.json|$cfg/settings.json" "project settings.json|$clone/.claude/settings.json" \
      "project settings.local.json|$clone/.claude/settings.local.json" \
      "teamlead.settings.json|$clone/.agents/team/teamlead.settings.json"; do
    name="${src%%|*}"; f="${src#*|}"
    [ -f "$f" ] || continue
    jq empty "$f" >/dev/null 2>&1 || { echo "unclean $name: unparseable"; return 1; }
    # A plugin brings hooks from its own manifest, which cannot be inventoried here: fail closed.
    plugins="$(jq -r '(.enabledPlugins // {}) | if type == "object" then to_entries[] | select(.value == true) | .key else empty end' "$f" 2>/dev/null)"
    [ -z "$plugins" ] || { echo "unclean $name: enabled plugin $(head -n 1 <<<"$plugins")"; return 1; }
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
