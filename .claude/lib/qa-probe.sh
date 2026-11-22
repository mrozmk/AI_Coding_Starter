#!/bin/bash
# QA environment preflight — the single probe runner behind /prime-qa Phase 3.
#
# WHY A SCRIPT AND NOT INLINE PROBES:
# The probes must run at command LOAD (`!`-injection), before the model reasons about
# the environment — every defect this preflight exists to catch is of the form "the
# model did not run the check at the right moment". An injected probe removes the
# discretion. But injecting raw `curl` lines forces a permission rule broad enough to
# reach ANY host (`Bash(curl -s -o /dev/null *)`; permission globs are trailing-only,
# so the host cannot be constrained), which then needs a deny list to stop that same
# rule from covering `-d @.env` / `-F file=@…` exfiltration. One exact allow rule for
# an in-repo, argument-free script is narrower AND survives `/maintain:sync-from-starter`,
# because the per-project values live in .claude/qa-env.json rather than in the command.
#
# CONTRACT: emit `key: value` lines on stdout, exit 0 ALWAYS. Print nothing secret —
# .env is stat-ed (size + mtime), never read. Every network call carries an explicit
# timeout: a command whose job is detecting a blocked environment must never itself block.
# The browser section runs `node` locally (module resolution only, no network).
# The probe reports the deployed build SHA; it does not decide which build is acceptable
# for a ticket — /qa-verify makes that per-ticket decision.

ROOT="$CLAUDE_PROJECT_DIR"
[ -z "$ROOT" ] && ROOT="$PWD"
CONFIG="$ROOT/.claude/qa-env.json"

emit() { printf '%s\n' "$*"; }

if ! command -v jq >/dev/null 2>&1; then
  emit "qa-config: UNREADABLE — jq not on PATH (see check-deps.sh)"
  exit 0
fi
if [ ! -f "$CONFIG" ]; then
  emit "qa-config: MISSING — .claude/qa-env.json not found; no environment facts available"
  exit 0
fi
# Distinguish "no curl on this machine" from "host unreachable" — reporting a
# missing tool as an unreachable host sends the tester hunting a network problem.
HAVE_CURL=1
command -v curl >/dev/null 2>&1 || HAVE_CURL=0

cfg() { jq -r --arg k "$1" '.[$k] // ""' "$CONFIG" 2>/dev/null; }

BASE_URL_CFG=$(cfg base_url)
LOCAL_URL=$(cfg local_url)
SERVE=$(cfg local_serve_command)
SERVE_ALT=$(cfg local_serve_command_alt_port)
BUILD_SHA_URL=$(cfg build_sha_url)
ARTIFACTS=$(cfg artifacts_dir)
ENVFILE=$(cfg env_file)
PGREP_PAT=$(cfg browser_mcp_process_pattern)
MCPFILE=$(cfg mcp_config_file)
SAFEFLAG=$(cfg parallel_safe_flag)
DEVICE_MCP=$(cfg device_mcp_server)
BP_PREFIX=$(cfg breakpoint_token_prefix)

emit "qa-config: present"

# --- Deployed host -------------------------------------------------------------
DEPLOYED_OK=1
FAIL_REASON=""

if [ "$HAVE_CURL" -eq 0 ]; then
  DEPLOYED_OK=0
  FAIL_REASON="curl is not on PATH — no host could be probed (this is a tooling gap, not a host outage)"
  emit "deployed-host: NOT PROBED — curl missing from PATH"
elif [ -z "$BASE_URL_CFG" ]; then
  DEPLOYED_OK=0
  FAIL_REASON="no deployed host configured (qa-env.json -> base_url is empty)"
  emit "deployed-host: not configured"
else
  emit "deployed-host: $BASE_URL_CFG"
  NP=$(jq '.probe_paths | length' "$CONFIG" 2>/dev/null)
  printf '%s' "$NP" | grep -Eq '^[0-9]+$' || NP=0
  if [ "$NP" -eq 0 ]; then
    DEPLOYED_OK=0
    FAIL_REASON="no probe_paths configured — an unprobed host is not a verified host"
    emit "probe: SKIPPED — probe_paths is empty"
  fi
  i=0
  while [ "$i" -lt "$NP" ]; do
    P=$(jq -r ".probe_paths[$i] // \"\"" "$CONFIG" 2>/dev/null)
    i=$((i + 1))
    [ -z "$P" ] && continue
    URL="${BASE_URL_CFG%/}$P"
    R=$(curl -s -o /dev/null "$URL" -w '%{http_code} %{time_total}' \
          --connect-timeout 5 --max-time 10 2>/dev/null)
    CODE=$(printf '%s' "$R" | awk '{print $1}')
    TIME=$(printf '%s' "$R" | awk '{print $2}')
    if [ -z "$CODE" ] || [ "$CODE" = "000" ]; then
      emit "probe $P: UNREACHABLE (timeout or connection refused)"
      DEPLOYED_OK=0
      [ -z "$FAIL_REASON" ] && FAIL_REASON="deployed probe $P unreachable"
    else
      emit "probe $P: $CODE in ${TIME}s"
      case "$CODE" in
        2??|3??) : ;;
        *) DEPLOYED_OK=0
           [ -z "$FAIL_REASON" ] && FAIL_REASON="deployed probe $P returned $CODE" ;;
      esac
    fi
  done
fi

# --- Deployed build SHA (reported, never a rejection) --------------------------
# /qa-verify decides ancestry from this SHA, so only an identified build counts: a
# meta tag, a body that is one SHA, or one named JSON field — never a stray hex token
# (an asset hash, a request id). This section never touches DEPLOYED_OK.
HEAD_SHA=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null)
[ -n "$HEAD_SHA" ] && emit "local-HEAD: $HEAD_SHA"

if [ -z "$BASE_URL_CFG" ]; then
  emit "deployed-sha: not applicable — no deployed host configured"
elif [ "$HAVE_CURL" -eq 0 ]; then
  emit "deployed-sha: not verified — curl missing from PATH"
elif [ -z "$BUILD_SHA_URL" ]; then
  emit "deployed-sha: not verified — no build_sha_url configured; the deployed build may lag HEAD"
else
  # One call: body, then the status on the last line; curl's own exit kept apart.
  R=$(curl -q -s "$BUILD_SHA_URL" -w '\n%{http_code}' --connect-timeout 5 --max-time 10 2>/dev/null)
  RC=$?
  CODE=$(printf '%s\n' "$R" | tail -n 1)
  BODY=$(printf '%s\n' "$R" | sed '$d')
  SHA_REASON=""
  DEP_SHA=""
  if [ "$RC" -ne 0 ]; then
    case "$CODE" in
      000|"") SHA_REASON="build_sha_url unreachable (timeout or connection refused)" ;;
      *) SHA_REASON="build_sha_url transfer incomplete (curl exit $RC)" ;;
    esac
  else
    case "$CODE" in 2??) : ;; *) SHA_REASON="build_sha_url returned $CODE" ;; esac
  fi
  if [ -z "$SHA_REASON" ]; then
    # 1. <meta name="build-sha" content="…">, whole attributes only
    M=$(printf '%s' "$BODY" | tr '\n\r\t' '   ' | grep -Eo '<meta[[:space:]][^>]*>' \
        | grep -E '[[:space:]]name="build-sha"' \
        | grep -Eo '[[:space:]]content="[0-9a-f]{7,40}"' | cut -d'"' -f2 | sort -u)
    case "$(printf '%s' "$M" | grep -c .)" in
      0) DEP_SHA="" ;;
      1) DEP_SHA="$M" ;;
      *) SHA_REASON="conflicting build-sha meta tags" ;;
    esac
  fi
  if [ -z "$SHA_REASON" ] && [ -z "$DEP_SHA" ]; then
    # 2. the body is one SHA
    DEP_SHA=$(printf '%s' "$BODY" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | tr -d '\n')
    if [ "$(printf '%s\n' "$BODY" | grep -c '[^[:space:]]')" -gt 1 ] \
       || ! printf '%s' "$DEP_SHA" | grep -Eqx '[0-9a-f]{7,40}'; then
      DEP_SHA=""
    fi
  fi
  if [ -z "$SHA_REASON" ] && [ -z "$DEP_SHA" ]; then
    # 3. one JSON document, one named field; a parser failure yields nothing
    DEP_SHA=$(printf '%s' "$BODY" | jq -rs 'if length == 1 and (.[0] | type) == "object" then .[0]
        | [.sha, .commit, .commit_sha, .git_sha, .build_sha, .revision]
        | map(select(type == "string" and test("\\A[0-9a-f]{7,40}\\z"))) | unique
        | if length == 1 then .[0] else empty end else empty end' 2>/dev/null) || DEP_SHA=""
  fi
  printf '%s' "$DEP_SHA" | grep -Eqx '[0-9a-f]{7,40}' || DEP_SHA=""
  if [ -n "$SHA_REASON" ]; then
    emit "deployed-sha: not verified — $SHA_REASON"
  elif [ -z "$DEP_SHA" ]; then
    emit "deployed-sha: not verified — build_sha_url returned no recognisable SHA"
  elif [ -z "$HEAD_SHA" ]; then
    emit "deployed-sha: not verified — no local HEAD to compare (deployed $DEP_SHA)"
  elif [ "${DEP_SHA#"$HEAD_SHA"}" != "$DEP_SHA" ] || [ "${HEAD_SHA#"$DEP_SHA"}" != "$HEAD_SHA" ]; then
    emit "deployed-sha: $DEP_SHA (equal)"
  else
    emit "deployed-sha: $DEP_SHA (differs)"
  fi
fi

# --- Local fallback ------------------------------------------------------------
if [ -n "$LOCAL_URL" ] && [ "$HAVE_CURL" -eq 1 ]; then
  R=$(curl -s -o /dev/null "$LOCAL_URL" -w '%{http_code}' \
        --connect-timeout 2 --max-time 5 2>/dev/null)
  [ -z "$R" ] && R="000"
  if [ "$R" = "000" ]; then
    emit "local-host: $LOCAL_URL — down (not serving)"
  else
    emit "local-host: $LOCAL_URL — $R"
  fi
elif [ -n "$LOCAL_URL" ]; then
  emit "local-host: $LOCAL_URL — NOT PROBED (curl missing from PATH)"
else
  emit "local-host: not configured"
fi
[ -n "$SERVE" ] && emit "local-serve-command: $SERVE"
[ -n "$SERVE_ALT" ] && emit "local-serve-command-2nd-session: $SERVE_ALT"

# --- BASE_URL resolution (deterministic — the model transcribes, does not derive)
if [ "$DEPLOYED_OK" -eq 1 ]; then
  emit "RESOLVED-BASE_URL: $BASE_URL_CFG"
  emit "RESOLVED-REASON: deployed host reachable on every probe path — build vs ticket decided per ticket by /qa-verify"
elif [ -n "$LOCAL_URL" ]; then
  emit "RESOLVED-BASE_URL: $LOCAL_URL"
  emit "RESOLVED-REASON: $FAIL_REASON"
else
  emit "RESOLVED-BASE_URL: (none)"
  emit "RESOLVED-REASON: $FAIL_REASON, and no local_url configured — QA cannot observe runtime behaviour"
fi

# --- Readiness checks (information, never a gate) ------------------------------
# Every entry is validated inside jq on the complete value: a shell check after $(…)
# would see trailing newlines stripped. The URL is never printed (it may carry a token).
NR=$(jq 'if has("readiness_checks") then (.readiness_checks | if type == "array" then length else -1 end) else 0 end' "$CONFIG" 2>/dev/null)
printf '%s' "$NR" | grep -Eq '^-?[0-9]+$' || NR=-1
if [ "$NR" -lt 0 ]; then
  emit "readiness-checks: MALFORMED — not an array"
elif [ "$NR" -eq 0 ]; then
  emit "readiness-checks: none configured"
elif [ "$HAVE_CURL" -eq 0 ]; then
  emit "readiness-checks: NOT PROBED — curl missing from PATH"
else
  RMAX=$NR
  [ "$RMAX" -gt 10 ] && RMAX=10
  i=0
  while [ "$i" -lt "$RMAX" ]; do
    E=$(jq -r --argjson i "$i" '.readiness_checks[$i] as $e
      | if ($e | type) != "object" then "bad entry must be an object"
        elif ($e.name | type) != "string" or ($e.name | test("\\A[A-Za-z0-9._-]{1,40}\\z") | not) then "bad name must match [A-Za-z0-9._-]{1,40}"
        elif ($e.url | type) != "string" or ($e.url | test("\\Ahttps?://[^/?#@\\s]+([/?#]\\S*)?\\z") | not) then "bad url must be http(s) without userinfo"
        elif ($e | has("expect_status")) and (($e.expect_status | type) != "number" or $e.expect_status != ($e.expect_status | floor) or $e.expect_status < 100 or $e.expect_status > 599) then "bad expect_status must be an integer 100-599"
        else "ok \($e.name) \($e.url) \(if $e | has("expect_status") then $e.expect_status | tostring else "-" end)" end' "$CONFIG" 2>/dev/null)
    i=$((i + 1))
    case "$E" in
      ok\ *) : ;;
      bad\ *) emit "readiness #$i: MALFORMED — ${E#bad }"; continue ;;
      *) emit "readiness #$i: MALFORMED — entry unreadable"; continue ;;
    esac
    # A valid name and URL hold no whitespace; read (not an unquoted expansion) keeps a
    # `[1-3]` in the URL from being globbed against the filesystem.
    read -r _ RN U EXP <<< "$E"
    RC_CODE=$(curl -q -s -o /dev/null --globoff --proto =http,https -w '%{http_code}' \
                --connect-timeout 5 --max-time 10 "$U" 2>/dev/null)
    if [ -z "$RC_CODE" ] || [ "$RC_CODE" = "000" ]; then
      emit "readiness $RN: UNREACHABLE — timeout or connection refused"
    elif [ "$EXP" != "-" ]; then
      if [ "$RC_CODE" = "$EXP" ]; then
        emit "readiness $RN: ok — $RC_CODE"
      else
        emit "readiness $RN: FAILED — got $RC_CODE, expected $EXP"
      fi
    else
      case "$RC_CODE" in
        2??|3??) emit "readiness $RN: ok — $RC_CODE" ;;
        *) emit "readiness $RN: FAILED — got $RC_CODE, expected 2xx/3xx" ;;
      esac
    fi
  done
  [ "$NR" -gt 10 ] && emit "readiness-checks: $((NR - 10)) more not run (limit 10)"
fi

# --- Credentials file: presence only, never contents ---------------------------
# Never use `rg`/`grep --files` to test for .env — ripgrep honours .gitignore and
# .env is gitignored, so it reports a false absence.
if [ -n "$ENVFILE" ] && [ -f "$ROOT/$ENVFILE" ]; then
  SZ=$(wc -c < "$ROOT/$ENVFILE" 2>/dev/null | tr -d '[:space:]')
  MT=$(date -r "$ROOT/$ENVFILE" '+%Y-%m-%d %H:%M' 2>/dev/null)
  emit "credentials-file $ENVFILE: present, ${SZ} bytes, modified ${MT} (contents never read)"
elif [ -n "$ENVFILE" ]; then
  emit "credentials-file $ENVFILE: MISSING — tracker-driven QA will soft-fail"
fi

# --- Concurrency + parallel safety ---------------------------------------------
if [ -n "$PGREP_PAT" ]; then
  N=$(pgrep -f "$PGREP_PAT" 2>/dev/null | wc -l | tr -d '[:space:]')
  emit "browser-mcp-servers-running: ${N:-0} (information, not a gate)"
fi

if [ -n "$MCPFILE" ] && [ -f "$ROOT/$MCPFILE" ]; then
  # Only judge the parallel-safe flag when a browser MCP is actually declared —
  # otherwise the warning fires on every project that does no browser QA at all,
  # and a preflight that always warns is read as noise and then ignored.
  if [ -z "$PGREP_PAT" ] || ! grep -q -- "$PGREP_PAT" "$ROOT/$MCPFILE" 2>/dev/null; then
    emit "mcp-config $MCPFILE: present, no browser MCP declared (parallel-safety not applicable)"
  elif [ -n "$SAFEFLAG" ] && grep -q -- "$SAFEFLAG" "$ROOT/$MCPFILE" 2>/dev/null; then
    emit "mcp-config $MCPFILE: present, parallel-safe flag \"$SAFEFLAG\": yes"
  elif [ -n "$SAFEFLAG" ]; then
    emit "mcp-config $MCPFILE: present, parallel-safe flag \"$SAFEFLAG\": NO — a second concurrent session will collide"
  else
    emit "mcp-config $MCPFILE: present"
  fi
elif [ -n "$MCPFILE" ]; then
  emit "mcp-config $MCPFILE: MISSING"
fi

# --- Cross-device lane (information only, never a gate) -----------------------
# Names and widths the device verifier needs; an empty value is a normal state the
# router already handles by routing the family to NEEDS-HUMAN.
emit "device_mcp_server: ${DEVICE_MCP:-unset}"
for k in touch_sweep_widths pointer_sweep_widths; do
  N=$(jq -r --arg k "$k" '(.[$k] // []) | length' "$CONFIG" 2>/dev/null)
  printf '%s' "$N" | grep -Eq '^[0-9]+$' || N=0
  if [ "$N" -gt 0 ]; then emit "$k: $N widths"; else emit "$k: unset"; fi
done
emit "breakpoint_token_prefix: ${BP_PREFIX:-unset}"

# --- Browser driver (information only, never a gate) ---------------------------
# Who observes browser rows in /qa-verify, and whether the project's own Playwright
# resolves for the default `script` driver. Resolution only: the package manifest is
# read as data, never imported, and only a node_modules inside this checkout counts.
DRIVER=$(cfg browser_driver)
case "$DRIVER" in
  "") emit "browser-driver: script (default)" ;;
  script|mcp|subagent) emit "browser-driver: $DRIVER" ;;
  *) emit "browser-driver: UNKNOWN \"$DRIVER\" — treated as script" ;;
esac

if ! command -v node >/dev/null 2>&1; then
  emit "playwright: NOT CHECKED — node not on PATH"
else
  BOUND=$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null)
  [ -z "$BOUND" ] && BOUND="$ROOT"
  PW=$(node --no-global-search-paths -e 'const fs=require("fs"),path=require("path"),real=q=>{try{return fs.realpathSync(q)}catch(x){return path.resolve(q)}},root=real(process.argv[1]),bound=real(process.argv[2]||root),r=require("module").createRequire(root+"/");let old="";for(const p of ["playwright","@playwright/test"]){const dir=(r.resolve.paths(p)||[]).find(d=>fs.existsSync(path.join(d,p,"package.json")));if(!dir||(dir!==bound&&!dir.startsWith(bound+path.sep)))continue;let e;try{e=r.resolve(p)}catch(x){continue}let m=null;try{m=JSON.parse(fs.readFileSync(path.join(dir,p,"package.json"),"utf8"))}catch(x){continue}if(!m||m.name!==p)continue;const v=String(m.version||"");const n=v.split(".").map(x=>parseInt(x,10));if(n[0]>1||(n[0]===1&&n[1]>=49)){console.log("ok "+p+" "+v);process.exit(0)}if(!old)old=p+" "+v}if(old){console.log("old "+old);process.exit(0)}process.exit(1)' "$ROOT" "$BOUND" 2>/dev/null)
  case "$PW" in
    ok\ *) emit "playwright: resolves from the project (${PW#ok })" ;;
    old\ *) emit "playwright: resolves from the project (${PW#old }) — below 1.49, the script driver needs locator.ariaSnapshot" ;;
    *) emit "playwright: not resolvable from the project" ;;
  esac
fi

LAUNCH=$(jq -r '(.browser_launch // {}) as $b | [ (if (($b.channel // "") | tostring) != "" then "channel=" + ($b.channel | tostring) else empty end), (if (($b.user_agent // "") | tostring) != "" then "user-agent=custom" else empty end), (if $b.ignore_https_errors == true then "ignore-https-errors=yes" else empty end) ] | join(" · ")' "$CONFIG" 2>/dev/null)
emit "browser-launch: ${LAUNCH:-defaults}"

# --- Artifacts destination -----------------------------------------------------
if [ -n "$ARTIFACTS" ]; then
  # Probe both spellings: a directory-only rule (`dir/`) matches the path only when
  # git can tell it IS a directory — which it cannot for a path that does not exist
  # yet. Without the trailing-slash form a correctly-ignored artifacts dir reads as
  # unignored on a fresh clone.
  if git -C "$ROOT" check-ignore -q "$ARTIFACTS" 2>/dev/null \
     || git -C "$ROOT" check-ignore -q "${ARTIFACTS%/}/" 2>/dev/null; then
    emit "artifacts-dir $ARTIFACTS: gitignored (correct — QA evidence is not repo history)"
  else
    emit "artifacts-dir $ARTIFACTS: NOT gitignored — screenshots would be committable"
  fi
fi

exit 0
