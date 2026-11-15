#!/bin/bash
# roles-lib.sh — sourced: the one reader and validator of teams.sessions (the project's role
# sessions) and the roles.lock that serialises `/roles`. No side effects on source; bash 3.2.
#
#   roles_validate            every rule at once; prints `error: teams.sessions.<Role>…` lines and
#                             returns 2 when any failed, a legacy-key warning on stderr; 0 = valid
#   roles_list [--standing]   enabled roles in declaration order (--standing: those /roles starts)
#   roles_cfg <role> <field>  the value or its code default; fields: cli model effort settings
#                             contract standing enabled place.tab place.slot (rc 2: bad value/field)
#   roles_is_declared <name>  rc 0 when <name> is a declared role (enabled or not, standing or not)
#   roles_lock <registry dir> [wait secs]  /  roles_unlock <registry dir>
#
# A role is any key of teams.sessions: a project adds one (its own contract, settings profile and
# place) by editing the profile, never the code. The four shipped names carry code defaults for
# the fields they omit, so a profile in the old two-field shape ({model, effort}) still reads; the
# legacy key Advisor is read as Fable. Without teams.sessions the shipped default list applies.
# The profile is <ROLES_ROOT, default $PWD>/.claude/project-profile.json.

ROLES_MODEL_RE='^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}(\[[0-9a-z]+\])?$'   # = team-profile.sh's TeamLead model check
ROLES_NAME_RE='^[A-Z][A-Za-z0-9]{1,23}$'   # checked in jq (Oniguruma): ASCII, not locale collation
ROLES_SHIPPED='{
  "Supervisor": {"cli": "claude", "model": "opus", "effort": "medium", "settings": "Supervisor",
                 "contract": ".agents/reference/roles/supervisor.md", "place": {"tab": "Lead", "slot": "main"}},
  "Fable": {"cli": "claude", "model": "fable", "effort": "high", "settings": "Advisor",
            "contract": ".agents/reference/roles/advisor.md", "place": {"tab": "Lead", "slot": "side"}},
  "Astra": {"cli": "codex", "model": "astra", "effort": "high",
            "contract": ".agents/reference/roles/advisor.md", "place": {"tab": "Lead", "slot": "side"}},
  "TeamLead": {"standing": false, "cli": "claude", "model": "fable", "effort": "high"}}'
ROLES_GENERIC='{"cli": "claude", "model": "opus", "effort": "high", "standing": true, "enabled": true}'
# Per-name defaults for the fields a declaration leaves out (the old shape had only model/effort).
ROLES_DEFAULTS='{
  "Supervisor": {"effort": "medium", "settings": "Supervisor",
                 "contract": ".agents/reference/roles/supervisor.md", "place": {"tab": "Lead", "slot": "main"}},
  "Fable": {"settings": "Advisor", "contract": ".agents/reference/roles/advisor.md",
            "place": {"tab": "Lead", "slot": "side"}},
  "Astra": {"cli": "codex", "contract": ".agents/reference/roles/advisor.md",
            "place": {"tab": "Lead", "slot": "side"}},
  "TeamLead": {"standing": false}}'
# → [{key, name, decl, cfg}] in declaration order. key: the profile key; name: the role (Advisor →
# Fable; dropped when Fable is declared too); cfg: generic * name defaults * declaration (null when
# the declaration is no object). A codex role keeps a default settings only if it declared one.
ROLES_JQ_NORM='
  def clean: if type == "object" then with_entries(select(.value != null)) else . end;
  def merged($n; $d): ($generic * ($defaults[$n] // {}) * ($d | clean))
    | if .cli == "codex" and ($d | has("settings") | not) then del(.settings) else . end;
  (.teams.sessions // $shipped) as $s
  | if ($s | type) != "object" then error("teams.sessions is not an object") else . end
  | [$s | keys_unsorted[] | select(startswith("_") | not)] as $ks
  | [ $ks[] as $k | $s[$k] as $d
      | (if $k == "Advisor" then "Fable" else $k end) as $n
      | select(($k == "Advisor" and ($ks | index("Fable") != null)) | not)
      | {key: $k, name: $n, decl: $d,
         cfg: (if ($d | type) == "object" then merged($n; $d) else null end)} ]'

roles_profile() { echo "${ROLES_ROOT:-$PWD}/.claude/project-profile.json"; }

# roles_jq <program> [jq args…] — runs <program> over the normalised list (as $roles; the profile
# as input). rc 3 + one error line when the profile is unreadable or teams.sessions is no object.
roles_jq() {
  local prog="$1" err cur; shift
  cur="$(cat "$(roles_profile)" 2>/dev/null)" || cur=""
  [ -n "$cur" ] || cur='{}'
  jq -r <<<"$cur" \
    --argjson shipped "$ROLES_SHIPPED" --argjson generic "$ROLES_GENERIC" \
    --argjson defaults "$ROLES_DEFAULTS" "$@" "($ROLES_JQ_NORM) as \$roles | $prog" 2>"${TMPDIR:-/tmp}/roles-jq.$$" \
    && { rm -f "${TMPDIR:-/tmp}/roles-jq.$$"; return 0; }
  err="$(sed -n 's/^jq: error.*): //p' "${TMPDIR:-/tmp}/roles-jq.$$" | head -1)"
  rm -f "${TMPDIR:-/tmp}/roles-jq.$$"
  echo "error: $(roles_profile | sed "s|^${ROLES_ROOT:-$PWD}/||"): ${err:-not valid JSON}" >&2
  return 3
}

roles_list() {  # roles_list [--standing]
  local st=false
  [ "${1:-}" != --standing ] || st=true
  roles_jq '$roles[] | select(.cfg != null and .cfg.enabled == true
    and (($st | not) or .cfg.standing == true)) | .name' --argjson st "$st"
}

roles_is_declared() {  # roles_is_declared <name>
  [ -n "${1:-}" ] || return 1
  [ "$(roles_jq '[$roles[] | select(.name == $n)] | length' --arg n "$1")" != 0 ]
}

roles_cfg() {  # roles_cfg <role> <field> — an undeclared role gets the code defaults
  local r="$1" f="$2" v
  case "$f" in cli|model|effort|settings|contract|standing|enabled|place.tab|place.slot) ;;
    *) echo "error: roles_cfg: unknown field $f" >&2; return 2 ;; esac
  [ "$r" != Advisor ] || r=Fable
  v="$(roles_jq '(first($roles[] | select(.name == $r) | .cfg) // ($generic * ($defaults[$r] // {})))
    | (if $f == "place.slot" and has("place") then .place.slot //= "side" else . end)
    | getpath($f | split(".")) | select(. != null) | tostring' --arg r "$r" --arg f "$f")" || return 2
  case "$f" in
    model) [[ "$v" =~ $ROLES_MODEL_RE ]] \
      || { echo "error: teams.sessions.$1.model=$v is not a model name" >&2; return 2; } ;;
    effort) case "$v" in low|medium|high|xhigh|max) ;;
      *) echo "error: teams.sessions.$1.effort=$v must be low|medium|high|xhigh|max" >&2
         return 2 ;; esac ;;
  esac
  echo "$v"
}

# roles_validate — all errors are collected, then printed; nothing is started by a caller on rc 2.
# Standing, enabled roles get every rule; a standing:false role (the per-run TeamLead) or a disabled
# one only cli/model/effort, since nothing launches it from this list.
roles_validate() {
  local out rc=0 kind a b root="${ROLES_ROOT:-$PWD}"
  out="$(roles_jq '
    def full: .cfg.standing == true and .cfg.enabled == true;
    def e($k; $m): "E\terror: teams.sessions.\($k)\($m)";
    (.teams.sessions | objects | select(has("Advisor"))
      | "W\tteams.sessions.Advisor is deprecated — read as Fable"
        + (if has("Fable") then " (ignored: Fable is declared)" else "" end)),
    ($roles[] | .key as $k | .cfg as $c
      | if ($k | test($name_re)) | not then e($k; ": the role name must match \($name_re)")
        elif $c == null then e($k; " is not an object")
        else
          (if ($c.standing | type) != "boolean" then e($k; ".standing must be true or false") else empty end),
          (if ($c.enabled | type) != "boolean" then e($k; ".enabled must be true or false") else empty end),
          (if ($c.cli | IN("claude", "codex")) | not then e($k; ".cli=\($c.cli) must be claude|codex") else empty end),
          (if ($c.model | type) != "string" or ($c.model | test($model_re) | not)
             then e($k; ".model=\($c.model) is not a model name") else empty end),
          (if ($c.effort | IN("low", "medium", "high", "xhigh", "max")) | not
             then e($k; ".effort=\($c.effort) must be low|medium|high|xhigh|max") else empty end),
          (select(full)
           | (if ($c.contract | type) != "string" or $c.contract == "" then e($k; ".contract is required")
              elif ($c.contract | startswith("/")) or ($c.contract | split("/") | index("..") != null)
                then e($k; ".contract=\($c.contract) must be a path inside the repo")
              else "C\t\($k)\t\($c.contract)" end),
             (if $c | has("settings") | not then empty
              elif $c.cli == "codex" then e($k; ".settings is for claude roles only")
              elif ($c.settings | type) != "string" or ($c.settings | test("^[A-Za-z0-9_-]+$") | not)
                then e($k; ".settings=\($c.settings) is not a profile name")
              else "S\t\($k)\t\($c.settings)" end),
             (if $c | has("place") | not then empty
              elif ($c.place | type) != "object" then e($k; ".place must be an object {tab, slot}")
              else
                (if ($c.place.tab | type) != "string" or $c.place.tab == "" then e($k; ".place.tab is required") else empty end),
                (if ($c.place.slot // "side" | IN("main", "side")) | not
                   then e($k; ".place.slot=\($c.place.slot) must be main|side") else empty end)
              end))
        end),
    ([$roles[] | select(.cfg != null and full and (.cfg.place | type) == "object" and .cfg.place.slot == "main")]
     | group_by(.cfg.place.tab | tostring)[] | select(length > 1)
     | "E\terror: teams.sessions: tab \(.[0].cfg.place.tab) has more than one main slot (\(map(.key) | join(", ")))")
  ' --arg name_re "$ROLES_NAME_RE" --arg model_re "$ROLES_MODEL_RE")" || return 2
  while IFS="$(printf '\t')" read -r kind a b; do
    case "$kind" in
      W) echo "warning: $a" >&2 ;;
      E) echo "$a" >&2; rc=2 ;;
      C) [ -f "$root/$b" ] || { echo "error: teams.sessions.$a.contract=$b: no such file" >&2; rc=2; } ;;
      S) [ -f "$root/.claude/team/sessions/$b.settings.json" ] || {
           echo "error: teams.sessions.$a.settings=$b: no .claude/team/sessions/$b.settings.json" >&2
           rc=2; } ;;
    esac
  done <<EOF
$out
EOF
  return "$rc"
}

# ---- roles.lock: one /roles at a time ----------------------------------------------------------------
# A mkdir lock holding `started` (the holder's `ps -o lstart=`) and then `pid`. A waiter reclaims it
# when the holder is dead, when the pid now belongs to another process (start time differs), or
# when no pid appeared within 2 s; a live holder is waited on. The reclaim is serialised as in
# team-watch-lib.sh (tw_claim / tw_stale / tw_reclaim): two waiters that judged the same dead holder
# would otherwise each rm + mkdir, the second removing the first one's fresh lock.
roles_mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }
roles_lstart() { ps -o lstart= -p "$1" 2>/dev/null | sed 's/^ *//; s/ *$//'; }

roles_lock_stale() {  # roles_lock_stale <lock dir>
  local p s now
  p="$(cat "$1/pid" 2>/dev/null || true)"
  if [ -z "$p" ]; then
    now="$(date +%s)"; [ $(( now - $(roles_mtime "$1") )) -gt 2 ]; return
  fi
  kill -0 "$p" 2>/dev/null || return 0
  s="$(cat "$1/started" 2>/dev/null || true)"
  [ -n "$s" ] && [ "$s" != "$(roles_lstart "$p")" ]
}

roles_lock_reclaim() {  # rc 1: another waiter is reclaiming
  local r="$1.reclaim" now
  if ! mkdir "$r" 2>/dev/null; then
    now="$(date +%s)"; [ $(( now - $(roles_mtime "$r") )) -le 5 ] || rm -rf "$r"
    return 1
  fi
  ! roles_lock_stale "$1" || rm -rf "$1"
  rmdir "$r" 2>/dev/null || true
}

roles_lock() {  # roles_lock <registry dir> [wait secs, default 30] — rc 1: held by a live /roles
  local d="$1/roles.lock" tries=0 max=$(( ${2:-30} * 5 ))
  ( umask 077; mkdir -p "$1" ) 2>/dev/null || return 1
  until mkdir "$d" 2>/dev/null; do
    if roles_lock_stale "$d" && roles_lock_reclaim "$d"; then continue; fi
    if [ "$tries" -ge "$max" ]; then
      echo "another /roles is running (pid $(cat "$d/pid" 2>/dev/null || echo '?'))" >&2
      return 1
    fi
    sleep 0.2; tries=$((tries + 1))
  done
  roles_lstart $$ > "$d/started"
  echo $$ > "$d/pid"
}

roles_unlock() {  # roles_unlock <registry dir> — only the holder removes it
  local d="$1/roles.lock"
  [ "$(cat "$d/pid" 2>/dev/null)" = "$$" ] || return 0
  rm -rf "$d"
}
