#!/usr/bin/env bash
# Host-agnostic pull-request comment helper for the /pr-comments skill.
#
# The ONLY thing in the skill that touches the network. Detects the host from the `origin`
# remote and speaks its REST dialect, but every subcommand prints the SAME normalised JSON
# regardless of host, so the skill never branches on host.
#
#   github.com          GitHub REST v3        https://api.github.com   (GITHUB_API_URL for GHE)
#   bitbucket.org       Bitbucket Cloud v2    https://api.bitbucket.org/2.0
#   gitlab.*            GitLab v4             https://<host>/api/v4
#
# Credentials — read from the environment first, then the repo-root .env. NEVER echoed;
# they travel only in request headers, never in a URL, so curl's own error text (which
# may repeat the URL) cannot leak them.
#   GitHub     GITHUB_TOKEN                     Bearer  (fine-grained PAT: Pull requests r/w)
#   Bitbucket  BITBUCKET_EMAIL + BITBUCKET_TOKEN Basic  (personal Atlassian API token — a
#              personal token so replies post as YOU, not as a repo bot)
#   GitLab     GITLAB_TOKEN                     PRIVATE-TOKEN (scope: api)
#
# Subcommands (identical contract on every host):
#   resolve-pr <KEY>                 Open PRs whose source branch contains <KEY>- (case-insensitive,
#                                    boundary-safe: ABC-7 never matches ABC-79).
#   whoami                           Token owner: { id, login, name }.
#   list-open-with-comments [--mine] Open PRs with comment_count > 0. --mine = authored by the
#                                    token owner.
#   comments <PR>                    Every non-deleted comment, all pages, resolution NOT filtered.
#   diff <PR>                        Raw unified diff (text, not JSON).
#   reply <PR> <PARENT_ID> <FILE>    POST the file's content as a reply threaded under PARENT_ID.
#
# Normalised output:
#   PR rows       { id, title, branch, author, comment_count, url }
#   comment rows  { id, body, author, path, line, parent_id, resolved (bool|null), created_at }
#   reply         { id, created_at, url }
#
# Exit codes: 2 bad args · 3 no token · 4 HTTP error · 5 --mine could not identify you ·
#             6 no BITBUCKET_EMAIL · 7 unsupported host.
#
# Offline testing — PR_API_FIXTURE_DIR=<dir> makes api_get / api_post read canned responses
# instead of calling curl, so the jq normalisation can be unit-tested without a token:
#   <dir>/<METHOD>_<url after the API base, [/?&=%:] -> _>.json   the response body
#   <dir>/<same name>.next                                    optional: absolute URL of the next page
#   <dir>/last-post.json                                      what the last POST would have sent
# A missing fixture behaves like HTTP 404 (exit 4) and names the file it looked for.
set -euo pipefail

# --- host / owner / repo from origin ----------------------------------------
ORIGIN_URL="$(git remote get-url origin 2>/dev/null || true)"
HOST="$(printf '%s' "$ORIGIN_URL" | sed -E 's#^[a-z+]+://##; s#^[^@]+@##; s#[:/].*$##')"
SLUG="$(printf '%s' "$ORIGIN_URL" | sed -E 's#^[a-z+]+://[^/]+/##; s#^[^@]+@[^:]+:##; s#\.git$##; s#^/##')"
OWNER="${SLUG%%/*}"
REPO="${SLUG#*/}"
if [ -z "$HOST" ] || [ -z "$OWNER" ] || [ -z "$REPO" ] || [ "$OWNER" = "$SLUG" ]; then
  echo "ERROR: could not derive host/owner/repo from origin remote ('$ORIGIN_URL')." >&2
  exit 7
fi

case "$HOST" in
  github.com)  KIND=github; API_BASE="https://api.github.com" ;;
  bitbucket.org) KIND=bitbucket; API_BASE="https://api.bitbucket.org/2.0" ;;
  gitlab.*)    KIND=gitlab; API_BASE="https://${HOST}/api/v4" ;;
  *)
    # A self-hosted GitHub Enterprise host is indistinguishable from "unknown" by name alone.
    if [ -n "${GITHUB_API_URL:-}" ]; then
      KIND=github; API_BASE="${GITHUB_API_URL%/}"
    else
      echo "ERROR: unsupported host '$HOST' (supported: github.com, bitbucket.org, gitlab.*;" >&2
      echo "       GitHub Enterprise: set GITHUB_API_URL=https://<host>/api/v3)." >&2
      exit 7
    fi ;;
esac

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- credentials: env first, then repo-root .env; never echoed --------------
ENV_FILE="$(git rev-parse --show-toplevel 2>/dev/null || echo .)/.env"

# The trailing `|| true` is load-bearing: under `set -euo pipefail` a grep that matches
# nothing fails the whole pipeline, and the caller's assignment is the last command of an
# `&&` list — so a missing key would kill the script with a bare exit 1 before any of the
# handlers below could name the real cause.
#
# LAST occurrence wins, matching every mainstream dotenv parser: appending a corrected
# value at the bottom of .env is the universal reflex, and first-wins silently ignores it
# while the API answers 401 — indistinguishable from an expired token. Duplicates are
# still reported, because a file with two values for one key is a mistake either way.
read_env_var() {
  [ -f "$ENV_FILE" ] || return 0
  local n
  n="$(grep -cE "^$1=" "$ENV_FILE" 2>/dev/null || true)"
  if [ "${n:-0}" -gt 1 ]; then
    echo "WARNING: $1 is defined $n times in .env — using the LAST one." >&2
    echo "         Run: grep -n '^$1=' .env   and leave exactly one." >&2
  fi
  grep -E "^$1=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"'\''' || true
}

need_token() {  # $1 var name, $2 setup hint
  local v="${!1:-}"
  [ -z "$v" ] && v="$(read_env_var "$1")"
  if [ -z "$v" ]; then
    echo "ERROR: $1 not found (checked \$$1 and repo .env)." >&2
    echo "       $2" >&2
    echo "       See .env.example and .agents/reference/pr-host-api.md." >&2
    exit 3
  fi
  printf '%s' "$v"
}

case "$KIND" in
  github)
    TOKEN="$(need_token GITHUB_TOKEN "Create a fine-grained PAT (Pull requests: Read and write) and add GITHUB_TOKEN=... to .env.")"
    AUTH=(-H "Authorization: Bearer ${TOKEN}" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28")
    ;;
  bitbucket)
    TOKEN="$(need_token BITBUCKET_TOKEN "Create an Atlassian API token with scopes (app Bitbucket: read:pullrequest:bitbucket + read:user:bitbucket) and add BITBUCKET_TOKEN=... to .env.")"
    EMAIL="${BITBUCKET_EMAIL:-}"
    [ -z "$EMAIL" ] && EMAIL="$(read_env_var BITBUCKET_EMAIL)"
    # Basic auth with an empty username returns 401 — byte-identical to an expired token, and
    # the two have completely different fixes. Catch it here so the message names the cause.
    if [ -z "$EMAIL" ]; then
      echo "ERROR: BITBUCKET_EMAIL not found (checked \$BITBUCKET_EMAIL and repo .env)." >&2
      echo "       Basic auth needs your Atlassian ACCOUNT EMAIL as the username. Without it every" >&2
      echo "       call returns 401, which looks exactly like an expired token." >&2
      echo "       Add BITBUCKET_EMAIL=<your-atlassian-account-email> to .env — see .env.example." >&2
      exit 6
    fi
    AUTH=(-u "${EMAIL}:${TOKEN}" -H "Accept: application/json")
    ;;
  gitlab)
    TOKEN="$(need_token GITLAB_TOKEN "Create a personal access token (scope: api) and add GITLAB_TOKEN=... to .env.")"
    AUTH=(-H "PRIVATE-TOKEN: ${TOKEN}" -H "Accept: application/json")
    ;;
esac

# --- repo API prefix ----------------------------------------------------------
case "$KIND" in
  github)    API="${API_BASE}/repos/${OWNER}/${REPO}" ;;
  bitbucket) API="${API_BASE}/repositories/${OWNER}/${REPO}" ;;
  gitlab)
    # Nested groups are legal, so the whole path is one URL-encoded project id.
    PROJECT_ENC="$(printf '%s' "$SLUG" | jq -sRr @uri)"
    API="${API_BASE}/projects/${PROJECT_ENC}" ;;
esac

# --- transport ----------------------------------------------------------------
FIXTURES="${PR_API_FIXTURE_DIR:-}"
HDR="$TMP/hdr.txt"

fixture_name() {  # $1 method, $2 url
  local rel="${2#"$API_BASE"/}"
  printf '%s_%s' "$1" "$(printf '%s' "$rel" | tr '/?&=%:' '______')"
}

print_error_body() {  # $1 file
  jq -r '.message // .error.message // .error // .type // empty' "$1" 2>/dev/null >&2 || true
  # A Bitbucket 403 body names the exact scope that is missing and the ones the token holds.
  # Hiding it turns a one-line fix into scope guesswork.
  jq -r '.error.detail | select(. != null)
         | "  required scopes: \(.required // [] | join(", "))"
         + "\n  granted scopes:  \(.granted // [] | join(", "))"' "$1" 2>/dev/null >&2 || true
}

api_get() {  # $1 url, $2 out file; headers land in $HDR
  local url="$1" out="$2" code
  : > "$HDR"
  if [ -n "$FIXTURES" ]; then
    local f="$FIXTURES/$(fixture_name GET "$url")"
    if [ -f "$f.json" ]; then
      cp "$f.json" "$out"
      [ -f "$f.next" ] && printf 'x-fixture-next: %s\n' "$(cat "$f.next")" > "$HDR"
      return 0
    fi
    echo "ERROR: GET failed (fixture missing: $f.json)" >&2
    return 4
  fi
  code="$(curl -sS -D "$HDR" -o "$out" -w '%{http_code}' "${AUTH[@]}" "$url" || true)"
  if [ "$code" != "200" ]; then
    echo "ERROR: GET failed (HTTP ${code:-000}) for ${url}" >&2
    print_error_body "$out"
    return 4
  fi
}

# Next-page URL for the page just fetched, or "" — each host paginates differently.
next_url() {  # $1 current url, $2 page body
  local n
  n="$(sed -nE 's/^x-fixture-next: (.*)$/\1/p' "$HDR" | tr -d '\r')"
  if [ -n "$FIXTURES" ]; then printf '%s' "$n"; return; fi
  case "$KIND" in
    bitbucket) jq -r '.next // ""' "$2" ;;   # absolute URL in the body — follow, never rebuild
    github)    sed -nE 's/^[Ll]ink:.*<([^>]+)>; *rel="next".*$/\1/p' "$HDR" | tr -d '\r' ;;
    gitlab)
      n="$(sed -nE 's/^[Xx]-[Nn]ext-[Pp]age: *([0-9]+).*$/\1/p' "$HDR" | tr -d '\r')"
      [ -z "$n" ] && { printf ''; return; }
      printf '%s' "$(printf '%s' "$1" | sed -E 's/([?&])page=[0-9]+/\1page='"$n"'/; t; s/$/\&page='"$n"'/')" ;;
  esac
}

# Accumulate every page into one JSON array. $3 = jq path to the item array in one page.
paginate() {  # $1 url, $2 out, $3 items filter (default: whole body is the array)
  local url="$1" out="$2" items="${3:-.}" page="$TMP/page.json"
  echo '[]' > "$out"
  while [ -n "$url" ]; do
    api_get "$url" "$page"
    jq -s --arg items "$items" '.[0] + (.[1] | if $items == "." then . else .values end // [])' \
      "$out" "$page" > "$TMP/acc.json"
    mv "$TMP/acc.json" "$out"
    url="$(next_url "$url" "$page")"
  done
}

api_post() {  # $1 url, $2 body file, $3 out file; prints nothing, returns 4 on failure
  local url="$1" body="$2" out="$3" code
  if [ -n "$FIXTURES" ]; then
    cp "$body" "$FIXTURES/last-post.json"
    local f="$FIXTURES/$(fixture_name POST "$url")"
    if [ -f "$f.json" ]; then cp "$f.json" "$out"; return 0; fi
    echo "ERROR: POST failed (fixture missing: $f.json)" >&2
    return 4
  fi
  code="$(curl -sS -o "$out" -w '%{http_code}' -X POST "${AUTH[@]}" \
    -H "Content-Type: application/json" -d @"$body" "$url" || true)"
  if [ "$code" = "403" ]; then
    echo "ERROR: POST forbidden (403) for ${url}" >&2
    echo "       Reads work but the write does not — the token lacks a write scope" >&2
    echo "       (GitHub: Pull requests write · Bitbucket: write:pullrequest:bitbucket · GitLab: api)." >&2
    print_error_body "$out"
    return 4
  fi
  if [ "$code" != "201" ] && [ "$code" != "200" ]; then
    echo "ERROR: POST failed (HTTP ${code:-000}) for ${url}" >&2
    print_error_body "$out"
    return 4
  fi
}

# --- per-host normalisation (jq) --------------------------------------------
# One filter per host per shape; every filter yields the SAME keys.
case "$KIND" in
  github)
    PR_ROW='{ id: .number, title, branch: .head.ref, author: .user.login,
              comment_count: ((.comments // 0) + (.review_comments // 0)), url: .html_url }'
    ;;
  bitbucket)
    PR_ROW='{ id, title, branch: .source.branch.name, author: .author.display_name,
              comment_count, url: .links.html.href }'
    ;;
  gitlab)
    PR_ROW='{ id: .iid, title, branch: .source_branch, author: .author.username,
              comment_count: .user_notes_count, url: .web_url }'
    ;;
esac

# Open PRs, normalised. GitHub's list payload carries no comment counts, so each PR is
# re-fetched individually — the counts live only on the single-PR object.
fetch_open_prs() {  # $1 out
  local out="$1"
  case "$KIND" in
    github)
      paginate "$API/pulls?state=open&per_page=100" "$TMP/list.json"
      echo '[]' > "$out"
      for n in $(jq -r '.[].number' "$TMP/list.json"); do
        api_get "$API/pulls/$n" "$TMP/pr.json"
        jq -s '.[0] + [.[1]]' "$out" "$TMP/pr.json" > "$TMP/acc.json"; mv "$TMP/acc.json" "$out"
      done
      ;;
    bitbucket) paginate "$API/pullrequests?state=OPEN&pagelen=50" "$out" values ;;
    gitlab)    paginate "$API/merge_requests?state=opened&per_page=100" "$out" ;;
  esac
  jq "[ .[] | $PR_ROW ]" "$out" > "$TMP/norm.json"; mv "$TMP/norm.json" "$out"
}

# Token owner as { id, login, name } — the `id` is what --mine compares against.
fetch_me() {  # $1 out
  case "$KIND" in
    github)
      api_get "$API_BASE/user" "$1" || return 4
      jq '{ id: .login, login, name: (.name // .login) }' "$1" > "$TMP/me.json" ;;
    bitbucket)
      # GET /user sits behind read:user:bitbucket, not read:pullrequest — a PR-only token
      # 403s here while every PR read works. That is expected, not a broken token.
      api_get "$API_BASE/user" "$1" || return 4
      jq '{ id: .uuid, login: (.nickname // .display_name), name: .display_name }' "$1" > "$TMP/me.json" ;;
    gitlab)
      api_get "$API_BASE/user" "$1" || return 4
      jq '{ id: .username, login: .username, name: .name }' "$1" > "$TMP/me.json" ;;
  esac
  mv "$TMP/me.json" "$1"
}

# The normalised PR row's `author` and whoami's `id` use the same identity per host
# (login / uuid-vs-display_name is the one exception, handled below).
author_key_of_me() {
  case "$KIND" in
    bitbucket) jq -r '.name' "$1" ;;
    *)         jq -r '.id' "$1" ;;
  esac
}

usage() {
  echo "usage: pr-api.sh {resolve-pr <KEY>|whoami|list-open-with-comments [--mine]|comments <PR>|diff <PR>|reply <PR> <PARENT_ID> <FILE>}" >&2
  exit 2
}

# --- subcommands -------------------------------------------------------------
CMD="${1:-}"
case "$CMD" in
  resolve-pr)
    KEY="${2:-}"
    [ -z "$KEY" ] && usage
    fetch_open_prs "$TMP/prs.json"
    # Boundary-safe, case-insensitive: branch must contain <key>- (trailing hyphen).
    jq --arg key "$KEY" '
      [ .[] | select(((.branch // "") | ascii_downcase)
                     | contains(($key | ascii_downcase) + "-")) ]' "$TMP/prs.json"
    ;;

  whoami)
    fetch_me "$TMP/user.json"
    cat "$TMP/user.json"
    ;;

  list-open-with-comments)
    MINE=0
    [ "${2:-}" = "--mine" ] && MINE=1
    fetch_open_prs "$TMP/prs.json"
    if [ "$MINE" = "1" ]; then
      ME=""
      if fetch_me "$TMP/user.json" 2>/dev/null; then ME="$(author_key_of_me "$TMP/user.json")"; fi
      if [ -z "$ME" ] && [ "$KIND" = "bitbucket" ]; then
        # Reached when the token lacks read:user:bitbucket — load-bearing, not dead code.
        ME="$(git config user.name 2>/dev/null || true)"
      fi
      if [ -z "$ME" ]; then
        echo "ERROR: --mine could not identify you (GET /user failed)." >&2
        exit 5
      fi
      jq --arg me "$ME" '[ .[] | select((.author | ascii_downcase) == ($me | ascii_downcase))
                                | select(.comment_count > 0) ]' "$TMP/prs.json"
    else
      jq '[ .[] | select(.comment_count > 0) ]' "$TMP/prs.json"
    fi
    ;;

  comments)
    PR="${2:-}"
    [ -z "$PR" ] && usage
    case "$KIND" in
      github)
        # Two namespaces: inline review comments (threaded via in_reply_to_id) and general
        # issue comments (flat). REST exposes no thread-resolved flag → resolved: null.
        paginate "$API/pulls/$PR/comments?per_page=100" "$TMP/inline.json"
        paginate "$API/issues/$PR/comments?per_page=100" "$TMP/general.json"
        jq -s '
          (.[0] | map({ id, body, author: .user.login, path,
                        line: (.line // .original_line), parent_id: (.in_reply_to_id // null),
                        resolved: null, created_at }))
          + (.[1] | map({ id, body, author: .user.login, path: null, line: null,
                          parent_id: null, resolved: null, created_at }))' \
          "$TMP/inline.json" "$TMP/general.json"
        ;;
      bitbucket)
        paginate "$API/pullrequests/$PR/comments?pagelen=100" "$TMP/comments.json" values
        jq '[ .[] | select(.deleted != true)
              | { id, body: .content.raw, author: .user.display_name,
                  path: (.inline.path // null), line: (.inline.to // .inline.from // null),
                  parent_id: (.parent.id // null), resolved: (.resolution != null),
                  created_at: .created_on } ]' "$TMP/comments.json"
        ;;
      gitlab)
        # Notes hang off discussions; the discussion id (a sha) is what a reply targets, so
        # parent_id is normalised to the ROOT NOTE id and `reply` maps it back (see below).
        paginate "$API/merge_requests/$PR/discussions?per_page=100" "$TMP/disc.json"
        jq '[ .[] | .notes as $n | ($n[0].id) as $root
              | $n[] | select(.system != true)
              | { id, body, author: .author.username,
                  path: (.position.new_path // .position.old_path // null),
                  line: (.position.new_line // .position.old_line // null),
                  parent_id: (if .id == $root then null else $root end),
                  resolved: (if .resolvable then .resolved else null end),
                  created_at } ]' "$TMP/disc.json"
        ;;
    esac
    ;;

  diff)
    PR="${2:-}"
    [ -z "$PR" ] && usage
    case "$KIND" in
      github)    DIFF_URL="$API/pulls/$PR"; DIFF_ACCEPT="application/vnd.github.v3.diff" ;;
      bitbucket) DIFF_URL="$API/pullrequests/$PR/diff"; DIFF_ACCEPT="text/plain" ;;
      gitlab)    DIFF_URL="$API/merge_requests/$PR/raw_diffs"; DIFF_ACCEPT="text/plain" ;;
    esac
    if [ -n "$FIXTURES" ]; then
      f="$FIXTURES/$(fixture_name GET "$DIFF_URL").diff"
      [ -f "$f" ] || { echo "ERROR: diff fixture missing: $f" >&2; exit 4; }
      cat "$f"; exit 0
    fi
    # Text, not JSON — may 302 to the raw blob (Bitbucket), so follow redirects.
    diff_code="$(curl -sSL -o "$TMP/diff.txt" -w '%{http_code}' "${AUTH[@]}" \
      -H "Accept: $DIFF_ACCEPT" "$DIFF_URL" || true)"
    if [ "$diff_code" != "200" ] && [ "$KIND" = "gitlab" ]; then
      # raw_diffs needs GitLab >= 15.7; older instances still serve /changes as JSON.
      api_get "$API/merge_requests/$PR/changes" "$TMP/changes.json"
      jq -r '.changes[] | "diff --git a/\(.old_path) b/\(.new_path)\n\(.diff)"' "$TMP/changes.json"
      exit 0
    fi
    if [ "$diff_code" != "200" ]; then
      echo "ERROR: diff fetch failed (HTTP ${diff_code:-000}) for PR #$PR" >&2
      exit 4
    fi
    cat "$TMP/diff.txt"
    ;;

  reply)
    PR="${2:-}"; PARENT_ID="${3:-}"; BODY_FILE="${4:-}"
    { [ -z "$PR" ] || [ -z "$PARENT_ID" ] || [ -z "$BODY_FILE" ]; } && usage
    if [ ! -f "$BODY_FILE" ]; then
      echo "ERROR: reply body file not found: $BODY_FILE" >&2
      exit 2
    fi
    # The body is built by jq from the raw file — the comment text is never shell-escaped.
    case "$KIND" in
      github)
        # PARENT_ID may be an inline review comment or a general issue comment; the two live
        # in different namespaces with different reply endpoints, so probe which one it is.
        if api_get "$API/pulls/comments/$PARENT_ID" "$TMP/probe.json" 2>/dev/null; then
          jq -n --rawfile raw "$BODY_FILE" --argjson p "$PARENT_ID" '{ body: $raw, in_reply_to: $p }' > "$TMP/body.json"
          api_post "$API/pulls/$PR/comments" "$TMP/body.json" "$TMP/resp.json"
        else
          jq -n --rawfile raw "$BODY_FILE" '{ body: $raw }' > "$TMP/body.json"
          api_post "$API/issues/$PR/comments" "$TMP/body.json" "$TMP/resp.json"
        fi
        jq '{ id, created_at, url: .html_url }' "$TMP/resp.json"
        ;;
      bitbucket)
        # Threads under parent.id; the inline anchor is inherited from the parent (per API
        # docs — validate live before relying; see pr-host-api.md).
        jq -n --rawfile raw "$BODY_FILE" --argjson p "$PARENT_ID" \
          '{ content: { raw: $raw }, parent: { id: $p } }' > "$TMP/body.json"
        api_post "$API/pullrequests/$PR/comments" "$TMP/body.json" "$TMP/resp.json"
        jq '{ id, created_at: .created_on, url: .links.html.href }' "$TMP/resp.json"
        ;;
      gitlab)
        # PARENT_ID is a normalised note id; the POST target is the discussion that owns it.
        paginate "$API/merge_requests/$PR/discussions?per_page=100" "$TMP/disc.json"
        DISC="$(jq -r --argjson p "$PARENT_ID" '.[] | select(any(.notes[]; .id == $p)) | .id' "$TMP/disc.json" | head -1)"
        if [ -z "$DISC" ]; then
          echo "ERROR: no discussion on MR !$PR contains note $PARENT_ID." >&2
          exit 2
        fi
        jq -n --rawfile raw "$BODY_FILE" '{ body: $raw }' > "$TMP/body.json"
        api_post "$API/merge_requests/$PR/discussions/$DISC/notes" "$TMP/body.json" "$TMP/resp.json"
        jq --arg u "https://${HOST}/${SLUG}/-/merge_requests/${PR}" \
          '{ id, created_at, url: ($u + "#note_" + (.id | tostring)) }' "$TMP/resp.json"
        ;;
    esac
    ;;

  ""|-h|--help|help)
    usage
    ;;
  *)
    echo "ERROR: unknown subcommand '$CMD'" >&2
    usage
    ;;
esac
