#!/bin/bash
# Batch gate signal — says when the project's batch gate (its whole Validation suite on the merged
# line, CLAUDE.md → Validation) is due, records each run and keeps the Operator's hold. The rule and
# the line shapes are the Supervisor contract's (.agents/reference/roles/supervisor.md → Regression
# cadence); this script computes them from git, the record, the day plan and the hold.
#
#   batch-gate.sh [-C <dir>] due [--format line|prime|json] [--merged <gate>=<sha>[@<branch>]]…
#                                [--release <checkout>=<sha>]
#   batch-gate.sh [-C <dir>] run <gate> [--expect-head <sha>]
#   batch-gate.sh [-C <dir>] hold|lift --text "<the Operator's words>"
#
# Profile: `teams.batch_gate` in .claude/project-profile.json (`_batch_gate_doc` in the .example);
# absent = no gate. Per machine, in <checkout>/.agents/team/: batch-gate.json (the record, written
# only by `run`, atomically, never over an unreadable one), batch-hold.md (hold/lift), day-plan.md
# (read only: regression points, merge marks, the interim `## Batch runs` baseline).
# `due` is silent (no output, exit 0) outside git, without jq, without a profile or a block, and in
# a team clone (.agents/team/team.json or session.json). `run`, `hold` and `lift` refuse those
# (exit 2), and refuse a caller inside a team clone whatever -C names. `due --release` is silent only
# for a confirmed absent block; anything it cannot evaluate blocks.
# --merged: the commit a landing just merged; a line that lacks it is `behind` (no count). With
# @<branch>, a merge into a branch other than the gate's line is ignored.
# Exit: 0 ok · 1 a red run, or the record unreadable/unwritable · 2 usage or configuration ·
# 3 refused, nothing run or recorded (`run`), or a release blocked (`due --release`).
# BATCH_GATE_TODAY=YYYY-MM-DD overrides today's local date (test seam).
# Never fetches. `run` is the only subcommand that runs anything: the gate's team suite, under the
# machine gate lock (gate-lock.sh), with a scratch HOME/TMPDIR and no inherited step selection.
set -u
CDPATH=
case "${BASH_SOURCE[0]}" in */*) HERE="${BASH_SOURCE[0]%/*}" ;; *) HERE=. ;; esac
HERE=$(cd "$HERE" && pwd)
SEP=$'\037'

usage() {
  echo "usage: batch-gate.sh [-C <dir>] due [--format line|prime|json] [--merged <gate>=<sha>]… [--release <checkout>=<sha>] | run <gate> [--expect-head <sha>] | hold|lift --text \"<words>\"" >&2
  exit 2
}

DIR=""
if [ "${1:-}" = -C ]; then
  [ $# -ge 2 ] && [ -n "$2" ] || usage
  DIR="$2"; shift 2
fi
CMD="${1:-}"; [ $# -gt 0 ] && shift
FORMAT=line RELEASE="" GATE="" EXPECT_HEAD="" TEXT="" HAS_TEXT=0
MERGED=()
case "$CMD" in
  due)
    while [ $# -gt 0 ]; do
      case "$1" in
        --format) [ $# -ge 2 ] || usage; FORMAT="$2"; shift 2 ;;
        --merged) [ $# -ge 2 ] || usage; case "$2" in ?*=?*) ;; *) usage ;; esac; MERGED+=("$2"); shift 2 ;;
        --release) [ $# -ge 2 ] && [ -z "$RELEASE" ] || usage; case "$2" in ?*=?*) ;; *) usage ;; esac
          RELEASE="$2"; shift 2 ;;
        *) usage ;;
      esac
    done
    case "$FORMAT" in line | prime | json) ;; *) usage ;; esac ;;
  run)
    GATE="${1:-}"; [ $# -gt 0 ] && shift
    case "$GATE" in "" | -*) usage ;; esac
    while [ $# -gt 0 ]; do
      case "$1" in
        --expect-head) [ $# -ge 2 ] || usage; case "$2" in "" | -*) usage ;; esac; EXPECT_HEAD="$2"; shift 2 ;;
        *) usage ;;
      esac
    done ;;
  hold | lift)
    while [ $# -gt 0 ]; do
      case "$1" in
        --text) [ $# -ge 2 ] || usage; TEXT="$2"; HAS_TEXT=1; shift 2 ;;
        *) usage ;;
      esac
    done
    [ "$HAS_TEXT" = 1 ] || usage
    case "$TEXT" in *$'\n'* | *$'\r'*) echo "batch-gate: --text is one line — join the Operator's lines" >&2; exit 2 ;; esac
    [ -n "${TEXT//[[:space:]]/}" ] || { echo "batch-gate: --text must not be blank" >&2; exit 2; } ;;
  *) usage ;;
esac

# The writers are the Supervisor's: refuse a caller that sits in a team clone, before -C moves us.
in_clone() {  # <dir> — its checkout (or the dir itself) carries a team marker
  local t
  t=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || t="$1"
  [ -e "$t/.agents/team/team.json" ] || [ -e "$t/.agents/team/session.json" ]
}
NOT_CLONE="run, hold and lift are the Supervisor's — not from a team clone"
if [ "$CMD" != due ]; then
  if in_clone "$PWD" || { [ -n "${CLAUDE_PROJECT_DIR:-}" ] && in_clone "$CLAUDE_PROJECT_DIR"; }; then
    echo "batch-gate: $NOT_CLONE" >&2; exit 2
  fi
fi
if [ -n "$DIR" ]; then cd -- "$DIR" 2>/dev/null || { echo "batch-gate: cannot enter $DIR" >&2; exit 2; }; fi

RELMODE=0 QUIET=0
if [ "$CMD" = due ]; then if [ -n "$RELEASE" ]; then RELMODE=1; else QUIET=1; fi; fi
stop_or_silent() {  # <reason> — due: silent; due --release: blocked (3); run/hold/lift: refused (2)
  [ "$QUIET" = 1 ] && exit 0
  if [ "$RELMODE" = 1 ]; then echo "release blocked: $1"; exit 3; fi
  echo "batch-gate: $1" >&2; exit 2
}

# jq first, before any other tool: the no-jq case runs with a PATH that holds nothing else.
command -v jq >/dev/null 2>&1 || stop_or_silent "jq not on PATH"
[ "$QUIET" = 1 ] && exec 2>/dev/null
TODAY="${BATCH_GATE_TODAY:-}"
if [ -n "$TODAY" ]; then
  case "$TODAY" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;; *)
    echo "batch-gate: BATCH_GATE_TODAY must be YYYY-MM-DD" >&2; exit 2 ;; esac
else
  TODAY=$(date +%F)
fi
TOP=$(git rev-parse --show-toplevel 2>/dev/null) || TOP=""
[ -n "$TOP" ] || stop_or_silent "not a git work tree"
TOP=$(cd "$TOP" && pwd -P) || exit 2
PROFILE_FILE="$TOP/.claude/project-profile.json"
TEAMDIR="$TOP/.agents/team"

one_object() {  # <file> — exactly one JSON object (jq empty alone accepts "" and "{}{}")
  jq -s -e 'length == 1 and (.[0] | type == "object")' "$1" >/dev/null 2>&1
}

# ---- profile ---------------------------------------------------------------------------------------
no_block() { [ "$RELMODE" = 1 ] && exit 0; stop_or_silent "no teams.batch_gate block"; }
[ -e "$PROFILE_FILE" ] || [ -L "$PROFILE_FILE" ] || no_block
one_object "$PROFILE_FILE" || stop_or_silent "the profile is not one readable JSON object"
PROF=$(jq -c . "$PROFILE_FILE" 2>/dev/null) || stop_or_silent "the profile is not readable"
printf '%s' "$PROF" | jq -e '(.teams // {}) | type == "object"' >/dev/null 2>&1 \
  || stop_or_silent "teams is not an object in the profile"
printf '%s' "$PROF" | jq -e '(.teams | type == "object") and (.teams | has("batch_gate"))' >/dev/null 2>&1 \
  || no_block
if in_clone "$TOP"; then
  [ "$CMD" = due ] || { echo "batch-gate: $NOT_CLONE" >&2; exit 2; }
  stop_or_silent "a team clone"
fi

CFG_JQ='
def isint($n): type == "number" and . == floor and . >= $n;
def names: type == "array" and all(.[]; type == "string" and test("^[A-Za-z0-9._-]+$"));
def nodoc: with_entries(select(.key | startswith("_") | not));
def word: type == "string" and test("^[A-Za-z0-9._/-]+$");
.teams as $t
| if ($t.batch_gate | type) != "object" then {err: "batch_gate"} else
  ($t.batch_gate | nodoc) as $b
  | (($b | keys) - ["line", "tests_dir", "heavy", "thresholds", "gates"]) as $extra
  | ($b.line // $t.trunk // "main") as $line
  | ($b.tests_dir // ".claude/lib/tests") as $td
  | ($b.heavy // {"hooks": [".claude/hooks/**"], "settings": [".claude/settings*.json"],
                  "session profiles": [".claude/team/sessions/**"],
                  "runner": [".claude/lib/team-run*.sh", ".claude/lib/team-lib.sh"], "guards": ["**/guard-*"]}) as $hv
  | ($b.thresholds // {}) as $th0
  | if ($extra | length) > 0 then {err: $extra[0]}
    elif ($line | word | not) then {err: "line"}
    elif ($td | word | not) then {err: "tests_dir"}
    elif ($hv | type) != "object" or ($hv | length) == 0
      or ([$hv | nodoc | .[] | type == "array" and length > 0
           and all(.[]; type == "string" and length > 0 and (test("[\t\n\u001f]") | not))] | all | not)
      then {err: "heavy"}
    elif ($th0 | type) != "object" then {err: "thresholds"}
    elif ((($th0 | nodoc | keys) - ["merges", "heavy_merges", "days"]) | length) > 0 then {err: "thresholds"}
    else ({merges: 4, heavy_merges: 2, days: 1} + ($th0 | nodoc)) as $th
    | if ($th.merges | isint(1) | not) then {err: "thresholds.merges"}
      elif ($th.heavy_merges | isint(1) | not) then {err: "thresholds.heavy_merges"}
      elif ($th.days | isint(0) | not) then {err: "thresholds.days"}
      elif ($b.gates | type) != "object" or ($b.gates | nodoc | length) == 0 then {err: "gates"}
      else
        [$b.gates | nodoc | to_entries[] | .key as $g | .value as $v0
         | if ($g | test("^[A-Za-z0-9_-]+$") | not) or ($v0 | type) != "object" then {err: "gates.\($g)"}
           else ($v0 | nodoc) as $v
           | (($v | keys) - ["repo", "command", "only", "skip"]) as $vx
           | if ($vx | length) > 0 then {err: "gates.\($g).\($vx[0])"}
             elif ($v.repo | type) != "string" or ($v.repo | length) == 0 or ($v.repo | test("[\t\n\u001f]"))
               then {err: "gates.\($g).repo"}
             elif ($v | has("command")) and ($v.command | type) != "string" then {err: "gates.\($g).command"}
             elif ($v | has("only")) and ($v.only | names | not) then {err: "gates.\($g).only"}
             elif ($v | has("skip")) and ($v.skip | names | not) then {err: "gates.\($g).skip"}
             else {name: $g, repo: $v.repo, command: ($v.command // "bash \($td)/team-suite.sh"),
                   only: ($v.only // []), skip: ($v.skip // [])} end end] as $gs
        | ([$gs[] | select(.err)] | .[0]) as $e
        | if $e then $e
          else {line: $line, tests_dir: $td, thresholds: $th,
                heavy: [$hv | nodoc | to_entries[] | .key as $a | .value[] | [$a, .] | join("\u001f")],
                gates: [$gs[] | [.name, .repo, .command, (.only | join(" ")), (.skip | join(" ")),
                                 ({repo, command, only, skip} | tojson)] | join("\u001f")]} end
      end
    end
  end'
CFG=$(printf '%s' "$PROF" | jq -c "$CFG_JQ" 2>/dev/null) || CFG='{"err":"batch_gate"}'
CFG_ERR=$(printf '%s' "$CFG" | jq -r '.err // empty')
if [ -n "$CFG_ERR" ]; then
  [ "$QUIET" = 1 ] || stop_or_silent "invalid $CFG_ERR in teams.batch_gate"
  case "$FORMAT" in
    line) echo "batch gate: invalid $CFG_ERR" ;;
    prime) printf 'BATCH_DUE\t-\tunknown\t-\tbatch gate: invalid %s\n' "$CFG_ERR" ;;
    json) jq -n --arg k "$CFG_ERR" '{schema: 1, invalid: $k, gates: []}' ;;
  esac
  exit 0
fi
LINE=$(printf '%s' "$CFG" | jq -r .line)
TD=$(printf '%s' "$CFG" | jq -r .tests_dir)
TH_M=$(printf '%s' "$CFG" | jq -r .thresholds.merges)
TH_H=$(printf '%s' "$CFG" | jq -r .thresholds.heavy_merges)
TH_D=$(printf '%s' "$CFG" | jq -r .thresholds.days)
HV_AREA=() HV_GLOB=()
while IFS="$SEP" read -r a g; do [ -n "$a" ] && HV_AREA+=("$a") && HV_GLOB+=("$g"); done \
  < <(printf '%s' "$CFG" | jq -r '.heavy[]')

if command -v shasum >/dev/null 2>&1; then SHA1=(shasum -a 1); else SHA1=(sha1sum); fi
relpath() {  # <target> <base>, both absolute and physical → target relative to base
  local t="$1" b="$2" up="" rest r
  while :; do
    [ "$b" = / ] && break
    case "$t/" in "$b/"*) break ;; esac
    b=${b%/*}; [ -n "$b" ] || b=/
    up="../$up"
  done
  if [ "$b" = / ]; then rest=${t#/}; else rest=${t#"$b"}; rest=${rest#/}; fi
  r="$up$rest"; r=${r%/}; [ -n "$r" ] || r=.
  printf '%s' "$r"
}
SUITE_RE='^bash ([A-Za-z0-9._/-]+)( --keep-going)?$'
G_NAME=() G_ONLY=() G_SKIP=() G_CFG=() G_DIR=() G_DISP=() G_ERR=() G_SUITE=() G_KEEP=()
while IFS="$SEP" read -r n repo cmd only skip cj; do
  [ -n "$n" ] || continue
  i=${#G_NAME[@]}
  G_NAME[i]="$n" G_ONLY[i]="$only" G_SKIP[i]="$skip" G_ERR[i]="" G_SUITE[i]="" G_KEEP[i]=""
  G_CFG[i]=$(printf '%s' "$cj" | jq -cS . | "${SHA1[@]}" | cut -c1-40)
  d=$(cd "$TOP" && cd -- "$repo" 2>/dev/null && pwd -P) || d=""
  top=""; [ -z "$d" ] || top=$(git -C "$d" rev-parse --show-toplevel 2>/dev/null) || top=""
  [ -z "$top" ] || top=$(cd "$top" && pwd -P) || top=""
  G_DIR[i]="$top"
  if [ -z "$top" ]; then G_ERR[i]="$repo not found"; G_DISP[i]="$repo"; continue; fi
  if [ "$top" = "$TOP" ]; then G_DISP[i]="this checkout"
  else case "$repo" in /*) G_DISP[i]="$top" ;; *) G_DISP[i]=$(relpath "$top" "$TOP") ;; esac; fi
  # The command is data, never a shell line: `bash <team-suite.sh in the gate repo> [--keep-going]`.
  bad="invalid gates.$n.command"
  if [[ "$cmd" =~ $SUITE_RE ]]; then
    p="${BASH_REMATCH[1]}"; G_KEEP[i]="${BASH_REMATCH[2]# }"
    case "$p" in /*) ;; *) p="$top/$p" ;; esac
    if [ "${p##*/}" = team-suite.sh ] && [ -f "$p" ] && pd=$(cd "${p%/*}" 2>/dev/null && pwd -P); then
      case "$pd/" in "$top/"*) G_SUITE[i]="$pd/team-suite.sh"; bad="" ;; esac
    fi
  fi
  G_ERR[i]="$bad"
done < <(printf '%s' "$CFG" | jq -r '.gates[]')
NG=${#G_NAME[@]}

# ---- the record, the hold, the day plan, the lock ------------------------------------------------
REC_FILE="$TEAMDIR/batch-gate.json"
read_rec() {  # → REC, REC_ERR
  REC='{}' REC_ERR=0
  if [ -e "$REC_FILE" ] || [ -L "$REC_FILE" ]; then
    if one_object "$REC_FILE"; then REC=$(jq -c . "$REC_FILE"); else REC_ERR=1; fi
  fi
}
read_rec

read_hold() {  # → HOLD none|held|lifted|bad, HOLD_SINCE, HOLD_WORDS — the writer's constraints apply
  local f="$TEAMDIR/batch-hold.md" l st="" si="" by="" wo="" ns=0 nsi=0 nb=0 nw=0 other=0
  HOLD=none HOLD_SINCE="" HOLD_WORDS=""
  [ -e "$f" ] || [ -L "$f" ] || return 0
  HOLD=bad
  [ -f "$f" ] && [ -r "$f" ] || return 0
  while IFS= read -r l || [ -n "$l" ]; do
    case "$l" in
      "") ;;
      "state: "*) ns=$((ns + 1)); st="${l#state: }" ;;
      "since: "*) nsi=$((nsi + 1)); si="${l#since: }" ;;
      "by: "*) nb=$((nb + 1)); by="${l#by: }" ;;
      "words: "*) nw=$((nw + 1)); wo="${l#words: }" ;;
      *) other=1 ;;
    esac
  done < "$f" || return 0
  [ "$other$ns$nsi$nb$nw" = 01111 ] || return 0
  case "$st" in held | lifted) ;; *) return 0 ;; esac
  [ "$by" = Operator ] && [ -n "${wo//[[:space:]]/}" ] || return 0
  [[ "$si" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}(:[0-9]{2})?Z$ ]] || return 0
  jq -en --arg s "$si" '($s | sub("Z$"; "") | (if length == 16 then . + ":00" else . end) + "Z") as $n
    | ($n | fromdateiso8601 | todate) == $n' >/dev/null 2>&1 || return 0
  HOLD="$st" HOLD_SINCE="$si" HOLD_WORDS="$wo"
}
hold_stands() { [ "$HOLD" = held ] || [ "$HOLD" = bad ]; }
hold_text() {  # the line's hold tail, without the leading " — "
  if [ "$HOLD" = bad ]; then printf 'held (hold file unreadable)'
  else printf 'held by the Operator since %s: "%s"' "${HOLD_SINCE:0:10}" "$HOLD_WORDS"; fi
}
read_hold

PLAN_JQ='
def fields: .[2:] | split(" · ") | map(sub("^ +"; "") | sub(" +$"; ""));
def marks($p): [.[] | select(startswith($p)) | .[($p | length):] | split(" ") | map(select(. != ""))
                | select(length == 2) | {gate: .[0], sha: .[1]}];
def words($p): [.[] | select(startswith($p)) | .[($p | length):] | split(" ")[] | select(. != "")];
reduce (split("\n")[] | sub("\r$"; "")) as $l ({sec: "", date: null, tickets: {}, points: [], runs: {}};
  if ($l | test("^date: ")) then .date = ($l | sub("^date: *"; "") | sub(" +$"; ""))
  elif ($l | startswith("## ")) then .sec = ($l[3:] | sub(" +$"; ""))
  elif ($l | startswith("- ")) then
    ($l | fields) as $f
    | if .sec == "Tickets" then
        .tickets[$f[0]] = {lands: (if any($f[]; startswith("lands ")) then ($f | words("lands ")) else null end),
                           merged: ($f | marks("merged "))}
      elif .sec == "Regression points" and ($f[0] | startswith("after ")) then
        .points += [{tickets: ($f[0][6:] | split(" ") | map(select(. != ""))), gates: ($f | words("gate ")),
                     done: ($f | marks("done "))}]
      elif .sec == "Batch runs" then .runs[$f[0]] = $f[1:]
      else . end
  else . end)'
PLAN='{}'
if [ -f "$TEAMDIR/day-plan.md" ] && [ -r "$TEAMDIR/day-plan.md" ]; then
  PLAN=$(jq -R -s -c "$PLAN_JQ" "$TEAMDIR/day-plan.md" 2>/dev/null) || PLAN='{}'
fi

LOCK=unread LOCK_WHAT="" LOCK_DESC=""
read_lock() {  # → LOCK free|held|error, LOCK_WHAT, LOCK_DESC (the machine gate lock's holder)
  local out rc=0
  [ "$LOCK" = unread ] || return 0
  if [ -f "$HERE/gate-lock.sh" ]; then
    # shellcheck source=/dev/null
    . "$HERE/gate-lock.sh"
    out=$(gate_lock_holder 2>/dev/null) || rc=$?
  else rc=2; fi
  case "$rc" in
    0) LOCK=held; IFS=$'\t' read -r _ LOCK_WHAT LOCK_DESC <<<"$out" ;;
    1) LOCK=free ;;
    *) LOCK=error ;;
  esac
}

ldate() { date -r "$1" +%F 2>/dev/null || date -d "@$1" +%F 2>/dev/null; }
days_between() {  # <YYYY-MM-DD> <YYYY-MM-DD> → whole days from the first to the second
  jq -rn --arg a "$1" --arg b "$2" \
    '((($b + "T00:00:00Z") | fromdateiso8601) - (($a + "T00:00:00Z") | fromdateiso8601)) / 86400 | floor' \
    2>/dev/null || echo 0
}
mins() { echo $(( ($1 + 59) / 60 )); }
commit_of() { git -C "$1" rev-parse --verify -q "$2^{commit}" 2>/dev/null; }
is_hex() { case "$1" in "" | *[!0-9a-f]*) return 1 ;; esac; [ "${#1}" -ge 7 ] && [ "${#1}" -le 40 ]; }

# One gate's entry → ENTRY (the record's, else imported once from the day plan's `## Batch runs`).
IMPORT_JQ='
.runs[$g] as $r
| if ($r | type) != "array" then null else
  ([$r[] | select(startswith("last green "))] | .[0]) as $lg
  | ([$r[] | select(startswith("last run "))] | .[0]) as $lr
  | {last_green: (if $lg == null or $lg == "last green none" then null
                  else ($lg[11:] | split(" ") | {commit: .[0], at: .[1], imported: true}
                        + (if (.[2] | tonumber? // null) != null then {secs: ((.[2] | tonumber) * 60)} else {} end)) end),
     last_run: (if $lr == null then null
                else ($lr[9:] | split(" ") | {commit: .[0], at: .[1], result: .[2],
                      failed_steps: [.[3:][] | split(",")[] | select(. != "")], missing_steps: [], imported: true}) end)}
  | if .last_green == null and .last_run == null then null else . end
  end'
gate_entry() {  # <i> → ENTRY (json or null), IMPORTED 0|1
  local i="$1" g="${G_NAME[$1]}" e c f
  IMPORTED=0 ENTRY=null
  [ "$REC_ERR" = 0 ] || return 0
  e=$(printf '%s' "$REC" | jq -c --arg g "$g" \
    '(.gates | if type == "object" then .[$g] else null end) | if type == "object" then . else null end')
  if [ "$e" = null ]; then
    e=$(printf '%s' "$PLAN" | jq -c --arg g "$g" "$IMPORT_JQ" 2>/dev/null) || e=null
    [ -n "$e" ] || e=null
    if [ "$e" != null ]; then
      IMPORTED=1
      for f in last_green last_run; do
        c=$(printf '%s' "$e" | jq -r --arg f "$f" '.[$f].commit // empty')
        if [ -n "$c" ] && is_hex "$c" && c=$(commit_of "${G_DIR[$i]}" "$c"); then
          e=$(printf '%s' "$e" | jq -c --arg f "$f" --arg c "$c" '.[$f].commit = $c')
        fi
      done
      e=$(printf '%s' "$e" | jq -c --arg cfg "${G_CFG[$i]}" \
        'with_entries(if .value == null then . else .value.config = $cfg end)')
    fi
  fi
  ENTRY="$e"
}
ent_fields() {  # ENTRY → LR_* LG_* (empty when absent)
  local line
  line=$(printf '%s' "$ENTRY" | jq -r '
    def s: if . == null then "" else tostring end;
    (.last_run // {}) as $r | (.last_green // {}) as $g
    | [($r.commit | s), ($r.at | s), ($r.secs | s), ($r.result | s),
       ((($r.failed_steps // []) + ($r.missing_steps // [])) | map(tostring) | join(" ")), ($r.config | s),
       ($g.commit | s), ($g.at | s), ($g.secs | s), ($g.config | s)] | join("\u001f")' 2>/dev/null) || line=""
  IFS="$SEP" read -r LR_COMMIT LR_AT LR_SECS LR_RESULT LR_STEPS LR_CFG LG_COMMIT LG_AT LG_SECS LG_CFG <<<"$line"
}

# Running teams (runner lock pid alive) → RUNNING lines "<team><SEP><ticket>"; computed once.
RT_DONE="" RUNNING=""
running_teams() {
  local glob d pid team ticket
  [ -z "$RT_DONE" ] || return 0
  RT_DONE=1
  [ -f "$HERE/team-profile.sh" ] || return 0
  # shellcheck source=/dev/null
  glob=$( . "$HERE/team-profile.sh" && team_clone_glob "$TOP" ) 2>/dev/null || return 0
  [ -n "$glob" ] || return 0
  for d in "$glob"*/; do
    [ -f "$d.agents/team/lock/pid" ] || continue
    pid=$(cat "$d.agents/team/lock/pid" 2>/dev/null)
    case "$pid" in "" | *[!0-9]*) continue ;; esac
    kill -0 "$pid" 2>/dev/null || continue
    team=$(jq -r '.team // empty' "$d.agents/team/team.json" 2>/dev/null)
    ticket=$(jq -r '.ticket // empty | tostring' "$d.agents/team/team.json" 2>/dev/null)
    [ -n "$team" ] && [ -n "$ticket" ] && RUNNING="$RUNNING$team$SEP$ticket"$'\n'
  done
}

POINTS_JQ='
(.date == $today) as $now | (.tickets // {}) as $T
| (.points // [])[] | select(.gates | index($g)) | . as $p
| ([$p.tickets[] | ($T[.] // {lands: null, merged: []}) as $tk | ($tk.lands // $p.gates)
     | all(.[]; . as $h | any($tk.merged[]; .gate == $h))] | all) as $reached
| select($reached or $now)
| [($reached | tostring), (any($p.done[]; .gate == $g) | tostring), ($p.tickets | join(" ")),
   ([$p.tickets[] | ($T[.] // {merged: []}).merged[] | select(.gate == $g) | .sha] | join(" "))]
| join("\u001f")'

# ---- due: one gate ---------------------------------------------------------------------------------
ITEMS="" OUTL="" ROWS=""
emit() {  # the current gate's E_* → line, prime row, json item
  local hcol=- hj="$HOLD"
  hold_stands && hcol=held
  [ "$HOLD" = bad ] && hj=unreadable
  if [ -n "$E_LINE" ]; then
    OUTL="$OUTL$E_LINE"$'\n'
    ROWS="$ROWS$(printf 'BATCH_DUE\t%s\t%s\t%s\t%s' "$E_GATE" "$E_STATE" "$hcol" "$E_LINE")"$'\n'
  fi
  ITEMS="$ITEMS$(jq -cn --arg gate "$E_GATE" --arg state "$E_STATE" --arg reasons "$E_REASONS" \
    --argjson counted "${E_C:-0}" --argjson heavy "${E_H:-0}" --arg areas "$E_AREAS" --arg since "$E_SINCE" \
    --arg head "$E_HEAD" --arg base "$E_BASE" --arg hold "$hj" --arg lock "$LOCK" --arg lwhat "$LOCK_WHAT" \
    --arg rec "$E_REC" --arg est "$E_EST" --arg line "$E_LINE" '
    def n: if . == "" then null else . end;
    {gate: $gate, state: $state, due: ($state == "due" or $state == "held" or $state == "red"),
     reasons: ($reasons | split("\u001f") | map(select(. != ""))),
     numbers: {counted: $counted, heavy: $heavy, heavy_areas: ($areas | split(", ") | map(select(. != ""))),
               since: ($since | n), head: ($head | n)},
     baseline: ($base | n), hold: $hold, lock: {state: $lock, what: ($lwhat | n)},
     recommendation: ($rec | n), estimate_min: ($est | n | if . == null then null else tonumber end),
     line: ($line | n)}')"$'\n'
}
tail_of() {  # <gate> <next-point tickets> → E_REC and TAIL, the line's end (hold, or recommendation + estimate)
  local g="$1" next="$2" team ticket
  if hold_stands; then TAIL=" — $(hold_text)"; return 0; fi
  read_lock
  if [ "$LOCK" = error ]; then E_REC="machine busy (lock state unreadable)"
  elif [ "$LOCK" = held ]; then E_REC="machine busy ($LOCK_DESC)"
  else
    E_REC="machine free — run now"
    if [ -n "$next" ]; then
      running_teams
      while IFS="$SEP" read -r team ticket; do
        [ -n "$team" ] || continue
        case " $next " in *" $ticket "*) E_REC="$team running $ticket, planned before this point — run after its merge"; break ;; esac
      done <<<"$RUNNING"
    fi
  fi
  TAIL=" · $E_REC"
  [ -z "$E_EST" ] || TAIL="$TAIL · ~$E_EST min"
}
on_line() {  # <repo> <sha> <head> → FULL; non-zero when the line lacks the commit
  is_hex "$2" && FULL=$(commit_of "$1" "$2") && git -C "$1" merge-base --is-ancestor "$FULL" "$3" 2>/dev/null
}
set_behind() {  # <i> <sha> → the gate's `behind` E_* values
  E_STATE=behind E_REASONS="behind"
  E_LINE="batch gate (${G_NAME[$1]}): line behind ${2:0:7} — update ${G_DISP[$1]}'s $LINE first"
}
# Weighting: first-parent commits since the green; each with its files against its first parent.
weigh_commit() {  # <repo> "<sha> <ct>" <file>… → adds to W_COUNTED W_HEAVY W_AREAS W_OLDEST
  local R="$1" cur="$2" hit=0 isheavy=0 f k x pat=()
  shift 2
  for f in "$@"; do
    for ((k = 0; k < ${#HV_AREA[@]}; k++)); do
      # shellcheck disable=SC2053
      if [[ "$f" == ${HV_GLOB[k]} ]]; then
        isheavy=1
        case ", $W_AREAS, " in *", ${HV_AREA[k]}, "*) ;; *) W_AREAS="$W_AREAS${W_AREAS:+, }${HV_AREA[k]}" ;; esac
      fi
    done
  done
  if [ "$isheavy" = 1 ]; then hit=1; else
    for f in "$@"; do
      case "$f" in "$TD"/*) hit=1; break ;; esac
      case "$f" in *.md) pat+=(-e "$f") ;; *) pat+=(-e "${f##*/}") ;; esac
    done
    # One grep per commit, every pattern at once: "a test names one of its files".
    if [ "$hit" = 0 ] && [ "${#pat[@]}" -gt 0 ] \
      && git -C "$R" grep -q -F "${pat[@]}" "${cur%% *}" -- "$TD" 2>/dev/null; then hit=1; fi
  fi
  [ "$hit" = 1 ] || return 0
  W_COUNTED=$((W_COUNTED + 1)); [ "$isheavy" = 0 ] || W_HEAVY=$((W_HEAVY + 1))
  x="${cur#* }"; if [ -z "$W_OLDEST" ] || [ "$x" -lt "$W_OLDEST" ]; then W_OLDEST="$x"; fi
}
weigh() {  # <repo> <from> <to> → W_COUNTED W_HEAVY W_AREAS W_OLDEST
  local R="$1" l cur="" files=()
  W_COUNTED=0 W_HEAVY=0 W_AREAS="" W_OLDEST=""
  while IFS= read -r l; do
    case "$l" in
      $'\001'*) [ -z "$cur" ] || weigh_commit "$R" "$cur" ${files[@]+"${files[@]}"}; cur="${l#?}"; files=() ;;
      "") ;;
      *) files+=("$l") ;;
    esac
  done < <(git -C "$R" log --no-renames --first-parent --diff-merges=first-parent --name-only \
             --format='%x01%H %ct' "$2..$3" 2>/dev/null)
  [ -z "$cur" ] || weigh_commit "$R" "$cur" ${files[@]+"${files[@]}"}
}
eval_gate() {  # <i> → the gate's E_* values
  local i="$1" g="${G_NAME[$1]}" R="${G_DIR[$1]}" m name rest sha br reasons="" next=""
  local n line reached dn tks shas s unsat pts=""
  E_GATE="$g" E_STATE=ok E_LINE="" E_REASONS="" E_C=0 E_H=0 E_AREAS="" E_SINCE="" E_HEAD="" E_BASE=""
  E_REC="" E_EST=""
  if [ -n "${G_ERR[$i]}" ]; then
    E_STATE=unknown
    case "${G_ERR[$i]}" in invalid*) E_LINE="batch gate: ${G_ERR[$i]}" ;; *) E_LINE="batch gate ($g): ${G_ERR[$i]}" ;; esac
    return 0
  fi
  E_HEAD=$(commit_of "$R" "refs/heads/$LINE") || E_HEAD=""
  if [ -z "$E_HEAD" ]; then
    E_STATE=unknown E_LINE="batch gate ($g): ${G_DISP[$i]} has no branch $LINE"; return 0
  fi
  read_lock
  if [ "$LOCK" = held ] && [ "$LOCK_WHAT" = "batch-gate $g" ]; then E_STATE=running; return 0; fi
  for m in ${MERGED[@]+"${MERGED[@]}"}; do
    name="${m%%=*}" rest="${m#*=}"; sha="${rest%%@*}" br=""
    case "$rest" in *@*) br="${rest#*@}" ;; esac
    [ "$name" = "$g" ] || continue
    [ -z "$br" ] || [ "$br" = "$LINE" ] || continue
    on_line "$R" "$sha" "$E_HEAD" || { set_behind "$i" "$sha"; return 0; }
  done
  gate_entry "$i"; ent_fields
  [ -z "$LG_SECS" ] || [ "$LG_CFG" != "${G_CFG[$i]}" ] || E_EST=$(mins "${LG_SECS%.*}")
  if [ "$LR_RESULT" = red ] && [ "$LR_CFG" = "${G_CFG[$i]}" ]; then
    E_STATE=red E_REASONS=red
    E_LINE="batch red ($g) at ${LR_COMMIT:0:7}: ${LR_STEPS:-the suite exited non-zero} — fix and rerun"
    hold_stands && E_LINE="$E_LINE — $(hold_text)"
    return 0
  fi
  # Points of the day plan for this gate: the next unreached one names the teams to wait for.
  while IFS="$SEP" read -r reached dn tks shas; do
    [ -n "$reached" ] || continue
    if [ "$reached" = false ]; then [ -n "$next" ] || next="$tks"; continue; fi
    [ "$dn" = true ] && continue
    unsat=""
    for s in $shas; do
      on_line "$R" "$s" "$E_HEAD" || { set_behind "$i" "$s"; return 0; }
      if [ -z "$LG_COMMIT" ] || ! git -C "$R" merge-base --is-ancestor "$FULL" "$LG_COMMIT" 2>/dev/null; then unsat=1; fi
    done
    [ -z "$unsat" ] || pts="$pts${pts:+, }after $tks"
  done < <(printf '%s' "$PLAN" | jq -r --arg g "$g" --arg today "$TODAY" "$POINTS_JQ" 2>/dev/null)
  # No usable baseline: due without walking the history (the bootstrap hook has a 5 s budget).
  line=""
  if [ -z "$LG_COMMIT" ]; then line="no green baseline"
  elif [ "$LG_CFG" != "${G_CFG[$i]}" ]; then line="gate settings changed since the last green"
  elif ! git -C "$R" merge-base --is-ancestor "$LG_COMMIT" "$E_HEAD" 2>/dev/null; then line="no green baseline"
  fi
  if [ -n "$line" ]; then
    E_STATE=due E_REASONS="$line"
    [ "$REC_ERR" = 0 ] || E_REASONS="record unreadable"
    E_LINE="batch due ($g): $line at ${E_HEAD:0:7}"
    hold_stands && E_STATE=held
    tail_of "$g" "$next"; E_LINE="$E_LINE$TAIL"
    return 0
  fi
  E_BASE="$LG_COMMIT"
  E_SINCE="${LG_AT:0:10} ${LG_AT:11:5}Z"; [ -n "$LG_AT" ] || E_SINCE="${LG_COMMIT:0:7}"
  weigh "$R" "$LG_COMMIT" "$E_HEAD"
  E_C=$W_COUNTED E_H=$W_HEAVY E_AREAS="$W_AREAS"
  [ "$W_COUNTED" -lt "$TH_M" ] || reasons="$reasons${SEP}merges"
  [ "$W_HEAVY" -lt "$TH_H" ] || reasons="$reasons${SEP}heavy"
  if [ -n "$W_OLDEST" ] && [ "$(days_between "$(ldate "$W_OLDEST")" "$TODAY")" -ge "$TH_D" ]; then
    reasons="$reasons${SEP}days"
  fi
  [ -z "$pts" ] || reasons="$reasons${SEP}point"
  [ -n "$reasons" ] || return 0
  E_STATE=due E_REASONS="${reasons#"$SEP"}"
  n="$W_COUNTED merges"; [ "$W_COUNTED" != 1 ] || n="1 merge"
  E_LINE="batch due ($g): $n since $E_SINCE at ${E_HEAD:0:7}"
  [ "$W_HEAVY" = 0 ] || E_LINE="$E_LINE ($W_HEAVY heavy: $W_AREAS)"
  [ -z "$pts" ] || E_LINE="$E_LINE · point $pts reached"
  hold_stands && E_STATE=held
  tail_of "$g" "$next"; E_LINE="$E_LINE$TAIL"
}

# ---- due --release ---------------------------------------------------------------------------------
release_check() {
  local ck="${RELEASE%%=*}" cs="${RELEASE#*=}" ckt i match="" nm=0 target reason any=0 g
  ckt=$(git -C "$ck" rev-parse --show-toplevel 2>/dev/null) && ckt=$(cd "$ckt" && pwd -P) || ckt=""
  for ((i = 0; i < NG; i++)); do
    [ -n "$ckt" ] && [ "${G_DIR[i]}" = "$ckt" ] && { match=$i; nm=$((nm + 1)); }
  done
  if [ "$nm" != 1 ]; then echo "release blocked ($ck): no gate for this checkout"; exit 3; fi
  # The lock first, then a fresh record and hold: a run that ended before the lock read is in them.
  read_lock; read_rec; read_hold
  for ((i = 0; i < NG; i++)); do
    g="${G_NAME[i]}" reason="" target=""
    if [ -n "${G_ERR[i]}" ]; then reason="${G_ERR[i]}"
    elif [ "$i" = "$match" ]; then
      case "$cs" in *[!0-9a-f]*) ;; *) [ "${#cs}" = 40 ] && [ "$(commit_of "${G_DIR[i]}" "$cs")" = "$cs" ] && target="$cs" ;; esac
      [ -n "$target" ] || reason="$cs is not a full commit sha of ${G_DISP[i]}"
    else
      target=$(commit_of "${G_DIR[i]}" "refs/heads/$LINE") || { target=""; reason="${G_DISP[i]} has no branch $LINE"; }
    fi
    if [ -z "$reason" ]; then
      if hold_stands; then reason=$(hold_text)
      elif [ "$LOCK" = error ]; then reason="lock state unreadable"
      elif [ "$LOCK" = held ] && [ "$LOCK_WHAT" = "?" ]; then reason="machine gate lock holder unreadable"
      elif [ "$LOCK" = held ] && [ "$LOCK_WHAT" = "batch-gate $g" ]; then reason="batch run in progress"
      elif [ "$REC_ERR" = 1 ]; then reason="record unreadable"
      fi
    fi
    if [ -z "$reason" ]; then
      gate_entry "$i"; ent_fields
      if [ -z "$LG_COMMIT" ]; then reason="no green record"
      elif [ "$LG_CFG" != "${G_CFG[i]}" ]; then reason="gate settings changed since the last green"
      elif [ "$LR_RESULT" = red ]; then reason="last run red at ${LR_COMMIT:0:7}"
      elif [ "$LG_COMMIT" != "$target" ]; then reason="last green at ${LG_COMMIT:0:7}, not ${target:0:7}"
      elif [ "$LR_COMMIT" != "$target" ] || [ "$LR_RESULT" != green ] || [ "$LR_CFG" != "${G_CFG[i]}" ]; then
        reason="last run at ${LR_COMMIT:0:7}, not a green at ${target:0:7}"
      fi
    fi
    if [ -n "$reason" ]; then echo "release blocked ($g): $reason"; any=1
    else echo "release ok ($g): green at ${target:0:7}"; fi
  done
  [ "$any" = 0 ] || exit 3
  exit 0
}

if [ "$CMD" = due ]; then
  [ "$RELMODE" = 0 ] || release_check
  if [ "$REC_ERR" = 1 ]; then
    OUTL="batch gate: record unreadable"$'\n'
    ROWS="$(printf 'BATCH_DUE\t-\tunknown\t-\tbatch gate: record unreadable')"$'\n'
  fi
  for ((gi = 0; gi < NG; gi++)); do eval_gate "$gi"; emit; done
  case "$FORMAT" in
    line) printf '%s' "$OUTL" ;;
    prime) printf '%s' "$ROWS" ;;
    json) printf '%s' "$ITEMS" | jq -s --argjson re "$( [ "$REC_ERR" = 1 ] && echo true || echo false)" \
            '{schema: 1, record_error: $re, gates: .}' ;;
  esac
  exit 0
fi

# ---- hold / lift -----------------------------------------------------------------------------------
if [ "$CMD" = hold ] || [ "$CMD" = lift ]; then
  st=held; [ "$CMD" = hold ] || st=lifted
  since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  mkdir -p "$TEAMDIR" 2>/dev/null || { echo "batch-gate: cannot create .agents/team" >&2; exit 1; }
  tmp=$(mktemp "$TEAMDIR/.batch-hold.XXXXXX" 2>/dev/null) || { echo "batch-gate: cannot write the hold file" >&2; exit 1; }
  printf 'state: %s\nsince: %s\nby: Operator\nwords: %s\n' "$st" "$since" "$TEXT" > "$tmp" \
    && mv -f "$tmp" "$TEAMDIR/batch-hold.md" || { rm -f "$tmp"; echo "batch-gate: cannot write the hold file" >&2; exit 1; }
  echo "batch gate: $st since $since"
  exit 0
fi

# ---- run <gate> ------------------------------------------------------------------------------------
gi=""
for ((i = 0; i < NG; i++)); do [ "${G_NAME[i]}" = "$GATE" ] && gi=$i; done
[ -n "$gi" ] || { echo "batch-gate: no gate $GATE in teams.batch_gate" >&2; exit 2; }
[ -z "${G_ERR[gi]}" ] || { echo "batch-gate: ${G_ERR[gi]}" >&2; exit 2; }
[ "$REC_ERR" = 0 ] || { echo "batch-gate: .agents/team/batch-gate.json is not one JSON object — nothing run, nothing overwritten" >&2; exit 1; }
R="${G_DIR[gi]}"
refuse() { echo "batch-gate: $1 — nothing run" >&2; exit 3; }
checkout_ok() {  # the refusals of a run, before and after the lock wait → RUN_HEAD
  local b want
  read_hold
  hold_stands && refuse "$(hold_text)"
  [ -z "$(git -C "$R" status --porcelain 2>/dev/null)" ] || refuse "${G_DISP[gi]} is not clean"
  b=$(git -C "$R" symbolic-ref -q --short HEAD 2>/dev/null) || b=""
  [ "$b" = "$LINE" ] || refuse "${G_DISP[gi]} is not on $LINE"
  RUN_HEAD=$(commit_of "$R" HEAD) || refuse "${G_DISP[gi]} has no commit"
  if [ -n "$EXPECT_HEAD" ]; then
    want=$(commit_of "$R" "$EXPECT_HEAD") || want=""
    [ "$want" = "$RUN_HEAD" ] || refuse "HEAD is $RUN_HEAD, not $EXPECT_HEAD"
  fi
}
checkout_ok
FIRST_HEAD="$RUN_HEAD"
gate_entry "$gi"; IMP_ENTRY="$ENTRY"; IMP="$IMPORTED"

# The suite's child gets a clean selection environment and its own scratch HOME/TMPDIR; this shell
# keeps its HOME, so the gate lock is released where it was taken (gate_lock.py resolves ~ per call).
SUITE=(bash "${G_SUITE[gi]}"); [ -z "${G_KEEP[gi]}" ] || SUITE+=(--keep-going)
ENVU=(-u TEAM_SUITE_TESTS -u TEAM_SUITE_SELFTEST -u TEAM_SUITE_JOBS -u TEAM_SUITE_CASE_TIMES)
for v in $(compgen -v); do case "$v" in TEAM_SUITE_* | BATCH_GATE_*) ENVU+=(-u "$v") ;; esac; done
SH=$(mktemp -d) && ST=$(mktemp -d) && SCR=$(mktemp -d) || { echo "batch-gate: mktemp failed" >&2; exit 2; }
suite_list() {  # <only> <skip> → the step names, one per line
  (cd "$R" && env "${ENVU[@]}" HOME="$SH" TMPDIR="$ST" TEAM_SUITE_ONLY="$1" TEAM_SUITE_SKIP="$2" \
     "${SUITE[@]}" --list-steps) 2>/dev/null
}
KNOWN=$(suite_list "" "") && [ -n "$KNOWN" ] || { echo "batch-gate: the suite lists no steps" >&2; exit 2; }
for s in ${G_ONLY[gi]} ${G_SKIP[gi]}; do
  printf '%s\n' "$KNOWN" | grep -qxF -- "$s" \
    || { echo "batch-gate: gates.$GATE names a step the suite does not know: $s" >&2; exit 2; }
done

# shellcheck source=/dev/null
. "$HERE/gate-lock.sh"
trap gate_lock_release EXIT
trap 'gate_lock_cancel; exit 130' INT TERM HUP
gate_lock_acquire "batch-gate $GATE" || { echo "batch-gate: the machine gate lock was not acquired — nothing run" >&2; exit 3; }
checkout_ok
[ "$RUN_HEAD" = "$FIRST_HEAD" ] || refuse "the checkout moved while waiting for the gate lock ($FIRST_HEAD → $RUN_HEAD)"

EXPECTED=$(suite_list "${G_ONLY[gi]}" "${G_SKIP[gi]}") && [ -n "$EXPECTED" ] \
  || { echo "batch-gate: the suite lists no steps for gate $GATE" >&2; exit 2; }
if [ -z "${G_ONLY[gi]}" ] && ! printf '%s\n' "$EXPECTED" | grep -q '^smoke-'; then
  echo "batch-gate: the suite lists no smoke- step — its dispatcher is missing" >&2; exit 2
fi
AT=$(date -u +%Y-%m-%dT%H:%M:%SZ); T0=$(date +%s)
(cd "$R" && env "${ENVU[@]}" HOME="$SH" TMPDIR="$ST" TEAM_SUITE_ONLY="${G_ONLY[gi]}" \
   TEAM_SUITE_SKIP="${G_SKIP[gi]}" "${SUITE[@]}") 2>&1 | tee "$SCR/run.out"
rcs=("${PIPESTATUS[@]}")
SECS=$(( $(date +%s) - T0 ))

OKS=" " FAILS="" ALLOWED=" " SUITE_LOG=""
while IFS= read -r l; do
  case "$l" in
    "ok "*) s="${l#ok }"; OKS="$OKS${s%% *} " ;;
    "FAIL "*) s="${l#FAIL }"; s="${s%% *}"; case " $FAILS " in *" $s "*) ;; *) FAILS="$FAILS${FAILS:+ }$s" ;; esac ;;
    "skip "*" (TEAM_SUITE_SKIP)")
      s="${l#skip }"; s="${s%% *}"
      case " ${G_SKIP[gi]} " in *" $s "*) ALLOWED="$ALLOWED$s " ;; esac ;;
    "skip "*" — "*)
      s="${l#skip }"; s="${s%% *}"
      # The approved applicability skips: a fixed list, never the `skip … — <reason>` form itself.
      case "$s:${l#skip "$s" — }" in "wcag-audit-browser-test:engine cache not installed"*) ALLOWED="$ALLOWED$s " ;; esac ;;
    "log: "*) SUITE_LOG="${l#log: }" ;;
  esac
done < "$SCR/run.out"
MISSING=""
while IFS= read -r s; do
  [ -n "$s" ] || continue
  case "$OKS$ALLOWED $FAILS " in *" $s "*) ;; *) MISSING="$MISSING${MISSING:+ }$s" ;; esac
done <<<"$EXPECTED"
RESULT=red
[ "${rcs[0]}" = 0 ] && [ "${rcs[1]:-0}" = 0 ] && [ -z "$FAILS" ] && [ -z "$MISSING" ] && RESULT=green

b=$(git -C "$R" symbolic-ref -q --short HEAD 2>/dev/null) || b=""
if [ -n "$(git -C "$R" status --porcelain 2>/dev/null)" ] || [ "$b" != "$LINE" ] \
  || [ "$(commit_of "$R" HEAD)" != "$RUN_HEAD" ]; then
  echo "batch-gate: checkout moved during the run — the result proves nothing; nothing recorded" >&2; exit 1
fi

fail_write() { rm -f "${tmp:-}"; echo "batch-gate: cannot write .agents/team/batch-gate.json" >&2; exit 1; }
BASE='{}'
if [ -e "$REC_FILE" ] || [ -L "$REC_FILE" ]; then
  one_object "$REC_FILE" || { echo "batch-gate: .agents/team/batch-gate.json is not one JSON object — nothing recorded" >&2; exit 1; }
  BASE=$(jq -c . "$REC_FILE")
fi
[ "$IMP" = 1 ] || IMP_ENTRY=null
tmp=""
mkdir -p "$TEAMDIR" 2>/dev/null || fail_write
tmp=$(mktemp "$TEAMDIR/.batch-gate.XXXXXX" 2>/dev/null) || { tmp=""; fail_write; }
printf '%s' "$BASE" | jq --arg g "$GATE" --argjson imp "$IMP_ENTRY" --arg commit "$RUN_HEAD" --arg at "$AT" \
  --argjson secs "$SECS" --arg result "$RESULT" --arg failed "$FAILS" --arg missing "$MISSING" \
  --arg log "$SUITE_LOG" --arg cfg "${G_CFG[gi]}" '
  def words: split(" ") | map(select(. != ""));
  .schema = 1
  | .gates = (if (.gates | type) == "object" then .gates else {} end)
  | .gates[$g] = (if (.gates[$g] | type) == "object" then .gates[$g]
                  else ($imp // {} | with_entries(select(.value != null))) end)
  | .gates[$g].last_run = {commit: $commit, at: $at, secs: $secs, result: $result,
      failed_steps: ($failed | words), missing_steps: ($missing | words), log: $log, config: $cfg}
  | if $result == "green" then .gates[$g].last_green = {commit: $commit, at: $at, secs: $secs, config: $cfg}
    else . end' > "$tmp" 2>/dev/null || fail_write
one_object "$tmp" || fail_write
mv -f "$tmp" "$REC_FILE" 2>/dev/null || fail_write
if [ "$RESULT" = green ]; then
  echo "batch green ($GATE) at ${RUN_HEAD:0:7} · $(mins "$SECS") min"
  exit 0
fi
steps="$FAILS${FAILS:+${MISSING:+ }}$MISSING"
echo "batch red ($GATE) at ${RUN_HEAD:0:7}: ${steps:-the suite exited ${rcs[0]}} — fix and rerun"
exit 1
