#!/bin/bash
# Upkeep reminders — says when /maintain:refresh-brief, /maintain:cleanup-workflow or
# /architecture-review is due, from git facts and the record the three commands write at their end.
# One script computes, a command prints: /prime injects `due --format prime` as a probe and turns
# each row into a Warnings line; /tasks-status lists the same rows. Nothing runs by itself.
#
#   upkeep.sh due [--format prime|json]          prime (default): UPKEEP_DUE<TAB><command><TAB><reason>
#   upkeep.sh record <id> [--only-if-home] [--expect-head <sha>] [--expect-prd-blob <blob>]
#   upkeep.sh decline <id>
#
# Ids: refresh-brief, cleanup-workflow, architecture-review. Thresholds: the `upkeep` block of
# .claude/project-profile.json (absent = defaults, false = off). Record: <home>/.agents/upkeep.json,
# where <home> is this checkout or the one an item's `repo` names; written atomically, never
# overwritten when it is not exactly one JSON object.
# --only-if-home records only when the item's home is this checkout. --expect-head / --expect-prd-blob
# record what the calling command read at its start; a moved HEAD or PRD records nothing (exit 0).
#
# Exit: 0 ok, also every silent case and no-op · 1 the record could not be read or written ·
# 2 usage. `due` is silent (no stdout, no stderr, exit 0) outside a git work tree, without jq,
# without a profile, with "upkeep": false, and in a team clone (.agents/team/session.json).
# UPKEEP_TODAY=YYYY-MM-DD overrides today's UTC date (test seam; any other value exits 2).
# Never fetches, never runs a command; reads git and writes only the record.
set -u
CDPATH=

usage() {
  echo "usage: upkeep.sh due [--format prime|json] | record <id> [--only-if-home] [--expect-head <sha>] [--expect-prd-blob <blob>] | decline <id>" >&2
  exit 2
}
valid_date() { case "$1" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) return 0 ;; esac; return 1; }
valid_sha() { case "$1" in "" | *[!0-9a-f]*) return 1 ;; esac; [ "${#1}" -ge 7 ]; }

CMD="${1:-}"; [ $# -gt 0 ] && shift
FORMAT=prime ID="" ONLY_HOME=0 EXPECT_HEAD="" EXPECT_BLOB=""
case "$CMD" in
  due)
    while [ $# -gt 0 ]; do
      case "$1" in
        --format) [ $# -ge 2 ] || usage; FORMAT="$2"; shift 2 ;;
        *) usage ;;
      esac
    done
    case "$FORMAT" in prime | json) ;; *) usage ;; esac ;;
  record | decline)
    ID="${1:-}"; [ $# -gt 0 ] && shift
    case "$ID" in refresh-brief | cleanup-workflow | architecture-review) ;; *) usage ;; esac
    while [ $# -gt 0 ]; do
      [ "$CMD" = record ] || usage
      case "$1" in
        --only-if-home) ONLY_HOME=1; shift ;;
        --expect-head)
          [ $# -ge 2 ] || usage; case "$2" in "" | -*) usage ;; esac
          EXPECT_HEAD="$2"; shift 2 ;;
        --expect-prd-blob)
          [ "$ID" = refresh-brief ] && [ $# -ge 2 ] || usage; case "$2" in "" | -*) usage ;; esac
          EXPECT_BLOB="$2"; shift 2 ;;
        *) usage ;;
      esac
    done ;;
  *) usage ;;
esac

# jq first, before any git call: the no-jq case runs with a PATH that holds nothing else.
if ! command -v jq >/dev/null 2>&1; then
  [ "$CMD" = due ] && exit 0
  echo "upkeep: jq not on PATH" >&2; exit 1
fi
[ "$CMD" = due ] && exec 2>/dev/null
TODAY="${UPKEEP_TODAY:-}"
if [ -n "$TODAY" ]; then
  valid_date "$TODAY" || { echo "upkeep: UPKEEP_TODAY must be YYYY-MM-DD" >&2; exit 2; }
else
  TODAY=$(date -u +%F)
fi
TOP=$(git rev-parse --show-toplevel 2>/dev/null) || TOP=""
if [ -z "$TOP" ]; then
  [ "$CMD" = due ] && exit 0
  echo "upkeep: not a git work tree" >&2; exit 1
fi
TOP=$(cd "$TOP" && pwd -P) || exit 1
PROFILE_FILE="$TOP/.claude/project-profile.json"
SEP=$'\037'

# ---- profile ---------------------------------------------------------------------------------
PROF='{}'
if [ -f "$PROFILE_FILE" ] \
  && jq -s -e 'length == 1 and (.[0] | type == "object")' "$PROFILE_FILE" >/dev/null 2>&1; then
  PROF=$(jq -c . "$PROFILE_FILE")
elif [ "$CMD" = due ]; then
  exit 0
fi
if [ "$CMD" = due ]; then
  [ -e "$TOP/.agents/team/session.json" ] && exit 0
  printf '%s' "$PROF" | jq -e '.upkeep == false' >/dev/null && exit 0
fi

# One item's settings → enabled, invalid key, commits, feat_commits, min_days, repo, thresholds json.
CFG_JQ='
def isint($n): if type == "number" then (. == floor and . >= $n) else false end;
def defaults: {refresh_brief: true,
  cleanup_workflow: {commits: 200, min_days: 14, repo: ""},
  architecture_review: {feat_commits: 40, min_days: 14, repo: ""}};
(.upkeep) as $u
| (if $u == false then false
   elif ($u | type) == "object" then (if ($u | has($k)) then $u[$k] else true end)
   else true end) as $v
| if $v == false then ["0", "", "", "", "", "", "{}"]
  elif $k == "refresh_brief" then
    ["1", (if $v == true then "" else "refresh_brief" end), "", "", "", "", "{}"]
  else
    (if $v == true or $v == null then (defaults | .[$k])
     elif ($v | type) == "object" then (defaults | .[$k]) + ($v | with_entries(select(.key | startswith("_") | not)))
     else null end) as $c
    | if $c == null then ["1", $k, "", "", "", "", "{}"]
      else
        (if $k == "cleanup_workflow" then "commits" else "feat_commits" end) as $ck
        | ["1",
           (if ($c[$ck] | isint(1)) | not then $ck
            elif ($c.min_days | isint(0)) | not then "min_days"
            elif ($c.repo | type) != "string" then "repo"
            else "" end),
           ($c.commits // "" | tostring), ($c.feat_commits // "" | tostring),
           ($c.min_days | tostring), ($c.repo | if type == "string" then . else "" end),
           ({($ck): $c[$ck], min_days: $c.min_days} | tojson)]
      end
  end
| join("\u001f")'

item_cfg() {  # <id> → C_ENABLED C_INVALID C_COMMITS C_FEAT C_DAYS C_REPO C_THRESH
  local key line
  case "$1" in
    refresh-brief) key=refresh_brief ;;
    cleanup-workflow) key=cleanup_workflow ;;
    architecture-review) key=architecture_review ;;
  esac
  line=$(printf '%s' "$PROF" | jq -r --arg k "$key" "$CFG_JQ" 2>/dev/null) || line=""
  IFS="$SEP" read -r C_ENABLED C_INVALID C_COMMITS C_FEAT C_DAYS C_REPO C_THRESH <<<"$line"
  [ -n "$C_THRESH" ] || C_THRESH='{}'
}

# ---- home of an item ---------------------------------------------------------------------------
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
home_of() {  # <repo> → H_DIR H_DISP H_REC_DISP, or H_ERR and rc 1
  local repo="$1" res top
  H_ERR=""
  if [ -z "$repo" ]; then H_DIR="$TOP" H_DISP=. H_REC_DISP=.agents/upkeep.json; return 0; fi
  res=$(cd "$TOP" && cd -- "$repo" 2>/dev/null && pwd -P) || res=""
  top=""
  if [ -n "$res" ]; then top=$(git -C "$res" rev-parse --show-toplevel 2>/dev/null) || top=""; fi
  if [ -z "$top" ]; then H_ERR="unknown — $repo not found"; return 1; fi
  H_DIR=$(cd "$top" && pwd -P) || { H_ERR="unknown — $repo not found"; return 1; }
  if [ "$H_DIR" = "$TOP" ]; then H_DISP=. H_REC_DISP=.agents/upkeep.json; return 0; fi
  case "$repo" in
    /*) H_DISP="$H_DIR" ;;
    *) H_DISP=$(relpath "$H_DIR" "$TOP") ;;
  esac
  H_REC_DISP="$H_DISP/.agents/upkeep.json"
}

# ---- the record ----------------------------------------------------------------------------------
record_ok() {  # <file> — exactly one JSON object (jq empty alone accepts "" and "{}{}")
  jq -s -e 'length == 1 and (.[0] | type == "object")' "$1" >/dev/null 2>&1
}
read_record() {  # <file> → REC (compact json), REC_ERR true|false
  REC='{}' REC_ERR=false
  [ -e "$1" ] || return 0
  if record_ok "$1"; then REC=$(jq -c . "$1"); else REC_ERR=true; fi
}
rec_fields() {  # <id> → L_HAS L_COMMIT L_DATE L_BLOB D_HAS D_COMMIT D_DATE D_BLOB
  local line
  line=$(printf '%s' "$REC" | jq -r --arg id "$1" '
    def s: if type == "string" then . else "" end;
    def o: if type == "object" then . else null end;
    (if (.items | type) == "object" then (.items[$id] | o) else null end) as $e
    | ($e.last_run | o) as $l | ($e.declined | o) as $d
    | [($l != null | tostring), ($l.commit | s), ($l.date | s), ($l.prd_blob | s),
       ($d != null | tostring), ($d.commit | s), ($d.date | s), ($d.prd_blob | s)]
    | join("\u001f")' 2>/dev/null) || line=""
  IFS="$SEP" read -r L_HAS L_COMMIT L_DATE L_BLOB D_HAS D_COMMIT D_DATE D_BLOB <<<"$line"
  [ "$L_HAS" = true ] || L_HAS=false
  [ "$D_HAS" = true ] || D_HAS=false
}

# ---- counting ------------------------------------------------------------------------------------
days_since() {  # <YYYY-MM-DD> → whole days until today (UTC)
  local n
  n=$(jq -rn --arg a "$1" --arg b "$TODAY" \
    '((($b + "T00:00:00Z") | fromdateiso8601) - (($a + "T00:00:00Z") | fromdateiso8601)) / 86400 | floor' \
    2>/dev/null) || n=0
  printf '%s' "${n:-0}"
}
baseline() {  # <home> <commit> <date> → B_KIND B_VALUE B_DATE RANGE
  local h="$1" c="$2" d="$3"
  valid_date "$d" || d=""
  valid_sha "$c" || c=""
  if [ -n "$c" ] && git -C "$h" merge-base --is-ancestor "$c" HEAD 2>/dev/null; then
    B_KIND=commit B_VALUE="$c" B_DATE="$d"; RANGE=("$c..HEAD")
    if [ -z "$B_DATE" ]; then
      B_DATE=$(git -C "$h" log -1 --format=%ct "$c" | jq -Rr 'tonumber | todate[:10]' 2>/dev/null)
    fi
  elif [ -n "$d" ]; then
    B_KIND=date B_VALUE="$d" B_DATE="$d"; RANGE=("--since=${d}T00:00:00Z" HEAD)
  else
    B_KIND=none B_VALUE=""; RANGE=(HEAD)
    B_DATE=$(git -C "$h" log --max-parents=0 --format=%ct HEAD \
      | jq -Rnr '[inputs | select(length > 0) | tonumber] | min | todate[:10]' 2>/dev/null)
  fi
}
count_range() {  # <home> → NUM_COMMITS NUM_FEAT NUM_DAYS over RANGE
  NUM_COMMITS=$(git -C "$1" rev-list --count "${RANGE[@]}" 2>/dev/null) || NUM_COMMITS=0
  [ -n "$NUM_COMMITS" ] || NUM_COMMITS=0
  NUM_FEAT=$(git -C "$1" log --format=%s "${RANGE[@]}" 2>/dev/null | grep -c '^feat' || true)
  [ -n "$NUM_FEAT" ] || NUM_FEAT=0
  NUM_DAYS=$(days_since "$B_DATE")
}
crossed() {  # <id> — the count rule over the current NUM_* values
  local n thr
  if [ "$1" = cleanup-workflow ]; then n=$NUM_COMMITS thr=$C_COMMITS; else n=$NUM_FEAT thr=$C_FEAT; fi
  [ "$n" -ge "$thr" ] && [ "$NUM_DAYS" -ge "$C_DAYS" ]
}

# ---- due -----------------------------------------------------------------------------------------
ITEMS="" ROWS=""
emit_item() {
  local r
  r=$(printf '%s' "$I_REASON" | tr '\t\n' '  ')
  ITEMS="$ITEMS$(jq -cn --arg id "$I_ID" --arg cmd "$I_CMD" --arg state "$I_STATE" \
    --argjson due "$I_DUE" --argjson ask "$I_ASK" --arg reason "$r" \
    --arg bk "$I_BKIND" --arg bv "$I_BVALUE" --argjson numbers "$I_NUMBERS" --argjson thr "$I_THRESH" \
    --arg home "$I_HOME" --arg rec "$I_REC" --argjson re "$I_RECERR" \
    '{id: $id, command: $cmd, state: $state, due: $due, ask: $ask, reason: $reason,
      baseline: {kind: $bk, value: (if $bv == "" then null else $bv end)},
      numbers: $numbers, thresholds: $thr, home: $home, record: $rec, record_error: $re}')"$'\n'
  if [ "$I_DUE" = true ] && [ "$I_STATE" = ok ]; then
    ROWS="$ROWS$(printf 'UPKEEP_DUE\t%s\t%s' "$I_CMD" "$r")"$'\n'
  fi
}
eval_counted() {  # cleanup-workflow / architecture-review
  local since label n
  baseline "$H_DIR" "$L_COMMIT" "$L_DATE"; count_range "$H_DIR"
  I_BKIND=$B_KIND I_BVALUE=$B_VALUE
  case "$B_KIND" in
    commit) since="since the last run" ;;
    date) since="since $B_VALUE" ;;
    *) since="since the first commit — never recorded" ;;
  esac
  if [ "$I_ID" = cleanup-workflow ]; then
    n=$NUM_COMMITS label=commits
    I_NUMBERS="{\"commits\":$NUM_COMMITS,\"days\":$NUM_DAYS}"
  else
    n=$NUM_FEAT label="feat commits"
    I_NUMBERS="{\"commits\":$NUM_COMMITS,\"feat_commits\":$NUM_FEAT,\"days\":$NUM_DAYS}"
  fi
  I_REASON="$n $label and $NUM_DAYS days $since"
  crossed "$I_ID" || return 0
  I_DUE=true I_ASK=true
  [ "$H_DIR" = "$TOP" ] || I_REASON="$I_REASON in $H_DISP — run it from that checkout"
  if [ "$D_HAS" = true ]; then
    baseline "$H_DIR" "$D_COMMIT" "$D_DATE"; count_range "$H_DIR"
    crossed "$I_ID" || I_ASK=false
  fi
}
eval_brief() {
  local blob prd_c brief_c
  if [ ! -f "$TOP/docs/PRD.md" ] || [ ! -f "$TOP/.agents/memory/project-brief.md" ]; then
    I_REASON="no PRD or no brief"; return 0
  fi
  blob=$(git -C "$TOP" hash-object docs/PRD.md 2>/dev/null) || blob=""
  baseline "$TOP" "$L_COMMIT" "$L_DATE"; I_BKIND=$B_KIND I_BVALUE=$B_VALUE
  I_NUMBERS=$(jq -cn --arg b "$blob" --arg r "$L_BLOB" \
    '{prd_blob: (if $b == "" then null else $b end), recorded_prd_blob: (if $r == "" then null else $r end)}')
  if [ "$L_HAS" = true ]; then
    if [ "$blob" != "$L_BLOB" ]; then
      I_DUE=true I_REASON="docs/PRD.md changed since the last refresh"
    else
      I_REASON="docs/PRD.md unchanged since the last refresh"
    fi
  else
    prd_c=$(git -C "$TOP" log -1 --format=%H -- docs/PRD.md 2>/dev/null)
    brief_c=$(git -C "$TOP" log -1 --format=%H -- .agents/memory/project-brief.md 2>/dev/null)
    if [ -z "$prd_c" ]; then
      I_REASON="never recorded — docs/PRD.md has no commit"
    elif [ -z "$brief_c" ] || ! git -C "$TOP" merge-base --is-ancestor "$prd_c" "$brief_c" 2>/dev/null; then
      I_DUE=true I_REASON="never recorded — docs/PRD.md has commits the brief does not"
    else
      I_REASON="never recorded — the brief's last commit contains every docs/PRD.md commit"
    fi
  fi
  [ "$I_DUE" = true ] || return 0
  I_ASK=true
  [ "$D_HAS" = true ] && [ "$blob" = "$D_BLOB" ] && I_ASK=false
  return 0
}
eval_item() {  # <id> <command>
  I_ID="$1" I_CMD="$2"
  item_cfg "$I_ID"
  [ "$C_ENABLED" = 1 ] || return 0
  I_STATE=ok I_DUE=false I_ASK=false I_REASON="" I_BKIND=none I_BVALUE="" I_NUMBERS='{}'
  I_THRESH="$C_THRESH" I_RECERR=false I_HOME=. I_REC=.agents/upkeep.json
  if [ -n "$C_INVALID" ]; then
    I_STATE=unknown I_REASON="invalid $C_INVALID"; emit_item; return 0
  fi
  if ! home_of "$C_REPO"; then
    I_STATE=unknown I_REASON="$H_ERR" I_HOME="$C_REPO" I_REC="$C_REPO/.agents/upkeep.json"
    emit_item; return 0
  fi
  I_HOME="$H_DISP" I_REC="$H_REC_DISP"
  read_record "$H_DIR/.agents/upkeep.json"; I_RECERR=$REC_ERR
  rec_fields "$I_ID"
  if ! git -C "$H_DIR" rev-parse --verify -q HEAD >/dev/null 2>&1; then
    I_REASON="no commits"; emit_item; return 0
  fi
  if [ "$I_ID" = refresh-brief ]; then eval_brief; else eval_counted; fi
  emit_item
}

if [ "$CMD" = due ]; then
  eval_item refresh-brief /maintain:refresh-brief
  eval_item cleanup-workflow /maintain:cleanup-workflow
  eval_item architecture-review /architecture-review
  if [ "$FORMAT" = json ]; then
    printf '%s' "$ITEMS" | jq -s '{schema: 1, items: .}'
  else
    printf '%s' "$ROWS"
  fi
  exit 0
fi

# ---- record / decline ----------------------------------------------------------------------------
item_cfg "$ID"
if [ "$C_ENABLED" != 1 ]; then echo "upkeep: $ID is off — nothing recorded"; exit 0; fi
if [ "$C_INVALID" = repo ]; then echo "upkeep: $ID has an invalid repo in the profile — nothing recorded" >&2; exit 1; fi
home_of "$C_REPO" || { echo "upkeep: $H_ERR" >&2; exit 1; }
if [ "$ONLY_HOME" = 1 ] && [ "$H_DIR" != "$TOP" ]; then
  echo "upkeep: $ID tracks $C_REPO — this run was not there; nothing recorded"; exit 0
fi
HEAD_SHA=$(git -C "$H_DIR" rev-parse --verify -q 'HEAD^{commit}' 2>/dev/null) || HEAD_SHA=""
[ -n "$HEAD_SHA" ] || { echo "upkeep: $H_DISP has no commit — nothing recorded" >&2; exit 1; }
if [ -n "$EXPECT_HEAD" ]; then
  want=$(git -C "$H_DIR" rev-parse --verify -q "$EXPECT_HEAD^{commit}" 2>/dev/null) || want=""
  if [ "$want" != "$HEAD_SHA" ]; then
    echo "upkeep: $ID reviewed $EXPECT_HEAD, HEAD is now $HEAD_SHA — nothing recorded"; exit 0
  fi
fi
WITH_BLOB=false BLOB=""
if [ "$ID" = refresh-brief ]; then
  WITH_BLOB=true
  [ -f "$H_DIR/docs/PRD.md" ] && BLOB=$(git -C "$H_DIR" hash-object docs/PRD.md 2>/dev/null)
  if [ -n "$EXPECT_BLOB" ] && [ "$EXPECT_BLOB" != "$BLOB" ]; then
    echo "upkeep: refresh-brief read PRD $EXPECT_BLOB, docs/PRD.md is now ${BLOB:-absent} — nothing recorded"
    exit 0
  fi
fi
FILE="$H_DIR/.agents/upkeep.json"
BASE='{}'
if [ -e "$FILE" ]; then
  record_ok "$FILE" || { echo "upkeep: $H_REC_DISP is not one JSON object — nothing recorded" >&2; exit 1; }
  BASE=$(jq -c . "$FILE")
fi
KIND=last_run; [ "$CMD" = decline ] && KIND=declined
fail_write() { rm -f "${tmp:-}"; echo "upkeep: cannot write $H_REC_DISP" >&2; exit 1; }
tmp=""
mkdir -p "$H_DIR/.agents" 2>/dev/null || fail_write
tmp=$(mktemp "$H_DIR/.agents/.upkeep.XXXXXX" 2>/dev/null) || { tmp=""; fail_write; }
printf '%s' "$BASE" | jq --arg id "$ID" --arg kind "$KIND" --arg date "$TODAY" --arg commit "$HEAD_SHA" \
  --arg blob "$BLOB" --argjson withblob "$WITH_BLOB" '
  .schema = 1
  | .items = (if (.items | type) == "object" then .items else {} end)
  | .items[$id] = (if (.items[$id] | type) == "object" then .items[$id] else {} end)
  | .items[$id][$kind] = ({date: $date, commit: $commit}
      + (if $withblob then {prd_blob: (if $blob == "" then null else $blob end)} else {} end))
  | if $kind == "last_run" then del(.items[$id].declined) else . end' > "$tmp" 2>/dev/null || fail_write
record_ok "$tmp" && jq -e --arg id "$ID" --arg kind "$KIND" '.items[$id][$kind].commit' "$tmp" >/dev/null 2>&1 \
  || fail_write
mv -f "$tmp" "$FILE" 2>/dev/null || fail_write
if [ "$CMD" = decline ]; then
  echo "upkeep: declined $ID in $H_REC_DISP"
else
  echo "upkeep: recorded $ID in $H_REC_DISP"
fi
exit 0
