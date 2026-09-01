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

# --- Build skew ----------------------------------------------------------------
HEAD_SHA=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null)
[ -n "$HEAD_SHA" ] && emit "local-HEAD: $HEAD_SHA"

SKEW="not-applicable"
if [ "$DEPLOYED_OK" -eq 1 ]; then
  if [ -z "$BUILD_SHA_URL" ]; then
    SKEW="NOT-VERIFIED — no build_sha_url configured; the deployed build may lag HEAD"
  else
    DEP_SHA=$(curl -s "$BUILD_SHA_URL" --connect-timeout 5 --max-time 10 2>/dev/null \
              | grep -Eo '[0-9a-f]{7,40}' | head -1)
    if [ -z "$DEP_SHA" ]; then
      SKEW="NOT-VERIFIED — build_sha_url returned no recognisable SHA"
    elif [ -n "$HEAD_SHA" ] && [ "${DEP_SHA#"$HEAD_SHA"}" != "$DEP_SHA" ]; then
      SKEW="matched ($DEP_SHA)"
    elif [ -n "$HEAD_SHA" ] && [ "${HEAD_SHA#"$DEP_SHA"}" != "$HEAD_SHA" ]; then
      SKEW="matched ($DEP_SHA)"
    else
      SKEW="MISMATCH — deployed $DEP_SHA != local $HEAD_SHA"
      DEPLOYED_OK=0
      FAIL_REASON="deployed build SHA $DEP_SHA does not match local HEAD $HEAD_SHA"
    fi
  fi
fi
emit "build-skew: $SKEW"

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
  emit "RESOLVED-REASON: deployed host reachable on every probe path"
elif [ -n "$LOCAL_URL" ]; then
  emit "RESOLVED-BASE_URL: $LOCAL_URL"
  emit "RESOLVED-REASON: $FAIL_REASON"
else
  emit "RESOLVED-BASE_URL: (none)"
  emit "RESOLVED-REASON: $FAIL_REASON, and no local_url configured — QA cannot observe runtime behaviour"
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
