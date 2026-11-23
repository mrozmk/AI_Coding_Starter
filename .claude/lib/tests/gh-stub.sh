# Shared gh stub for the tracker smokes: every call is logged to $GH_LOG, all state lives in
# $GH_DIR (issues.json, comments.json, items.json, fields.json, issue-<n>.json, subs-<n>.json,
# pool-items.json for `gh api graphql`, timeline-<n>.json for an issue timeline, pr-<n>.json for
# `gh pr view`), 30 items per page, failures by env switch (STUB_GH_PAGE2_FAIL,
# STUB_GH_CREATE_THEN_FAIL, STUB_GH_POST_THEN_FAIL, STUB_GH_EDIT_DENY, STUB_GH_SUB_DENY) and by
# one-shot file: race-claim.txt (a comment POST first stores a foreign comment with that body — a
# competing claim landing before ours), race-reread.txt (the SECOND comment read first stores a
# foreign comment with that body — a takeover landing between a check and its confirm) and
# post-fail-once (the next comment POST fails, nothing stored). Sourced; needs $WORK/bin on PATH.
gh_stub_install() {
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >> "$GH_LOG"
G="$GH_DIR"
pages() {  # pages <array file> — 30 per page, each page its own JSON array (as `gh api` does)
  local n i=0
  n=$(jq 'length' "$1")
  if [ "$n" = 0 ]; then echo '[]'; return 0; fi
  while [ "$i" -lt "$n" ]; do
    if [ "$i" -gt 0 ] && [ "${STUB_GH_PAGE2_FAIL:-0}" = 1 ]; then
      echo "gh: HTTP 502 on page 2" >&2; exit 1
    fi
    jq -c ".[$i:$((i + 30))]" "$1"
    i=$((i + 30))
  done
}
case "${1:-}" in
  issue)
    case "${2:-}" in
      view)
        if [ -f "$G/issue-$3.json" ]; then cat "$G/issue-$3.json"
        elif jq -e --argjson n "$3" 'any(.[]; .number == $n)' "$G/issues.json" >/dev/null 2>&1; then
          jq --argjson n "$3" '.[] | select(.number == $n)
            | . + {url: ("https://github.com/owner/repo/issues/" + (.number | tostring))}' \
            "$G/issues.json"
        else echo "could not resolve to an Issue" >&2; exit 1; fi ;;
      create)
        t=""; bf=""; shift 2
        while [ $# -gt 0 ]; do case "$1" in
          --title) t="$2"; shift 2 ;; --body-file) bf="$2"; shift 2 ;; *) shift ;; esac; done
        n=$(( $(jq 'length' "$G/issues.json") + 100 ))
        jq --argjson n "$n" --arg t "$t" --rawfile b "$bf" \
          '. + [{number: $n, title: $t, body: $b}]' "$G/issues.json" > "$G/t" \
          && mv "$G/t" "$G/issues.json"
        # The UNCERTAIN write: the issue really is created, then the client dies before it can read
        # the answer. The adapter must not conclude "nothing happened".
        [ "${STUB_GH_CREATE_THEN_FAIL:-0}" != 1 ] \
          || { echo "gh: timeout awaiting response headers" >&2; exit 1; }
        echo "https://github.com/owner/repo/issues/$n" ;;
      *) echo "stub: gh issue $2" >&2; exit 1 ;;
    esac ;;
  api)
    if [ "${2:-}" = graphql ]; then
      # The pool query: answered from $G/pool-items.json, 2 nodes per page; the cursor is c<page>.
      # STUB_GH_POOL_STUCK (cursor never advances), STUB_GH_POOL_TOTAL (a wrong totalCount),
      # STUB_GH_NODEPS (a host without issue dependencies refuses blockedBy/blocking).
      cur=""; fname=""; q=""; shift 2
      while [ $# -gt 0 ]; do case "$1" in
        -f|-F) case "$2" in cursor=*) cur="${2#cursor=}" ;; fname=*) fname="${2#fname=}" ;;
                 query=*) q="${2#query=}" ;; esac; shift 2 ;;
        *) shift ;; esac; done
      echo "graphql fname=$fname" >> "$GH_LOG"
      nd=0; case "$q" in *blockedBy*) ;; *) nd=1 ;; esac
      if [ "$nd" = 0 ] && [ "${STUB_GH_NODEPS:-0}" = 1 ]; then
        echo "Field 'blockedBy' doesn't exist on type 'Issue'" >&2; exit 1
      fi
      k=0; [ -z "$cur" ] || k="${cur#c}"
      n=$(jq 'length' "$G/pool-items.json")
      start=$((k * 2)); more=false; [ $((start + 2)) -ge "$n" ] || more=true; ec="c$((k + 1))"
      if [ "${STUB_GH_POOL_STUCK:-0}" = 1 ]; then more=true; ec=c1; fi
      jq -c --argjson s "$start" --argjson tot "${STUB_GH_POOL_TOTAL:-$n}" --argjson more "$more" \
        --arg ec "$ec" --arg nd "$nd" '{data: {node: {items: {totalCount: $tot,
          pageInfo: {hasNextPage: $more, endCursor: $ec},
          nodes: (.[$s:($s + 2)] | if $nd == "1"
            then map(del(.content.blockedBy, .content.blocking)) else . end)}}}}' \
        "$G/pool-items.json"
      exit 0
    fi
    meth=GET; path=""; input=""; SUBID=0; shift
    while [ $# -gt 0 ]; do case "$1" in
      -X) meth="$2"; shift 2 ;; --input) input="$2"; shift 2 ;;
      -F) SUBID="${2#sub_issue_id=}"; shift 2 ;; -*) shift ;;
      *) path="$1"; shift ;; esac; done
    case "$meth $path" in
      "GET "*/sub_issues*)
        n="${path%/sub_issues*}"; n="${n##*/}"
        [ -f "$G/subs-$n.json" ] || echo '[]' > "$G/subs-$n.json"
        pages "$G/subs-$n.json" ;;
      "POST "*/sub_issues)
        [ "${STUB_GH_SUB_DENY:-0}" != 1 ] || { echo "gh: HTTP 422 sub-issue limit" >&2; exit 1; }
        n="${path%/sub_issues}"; n="${n##*/}"
        [ -f "$G/subs-$n.json" ] || echo '[]' > "$G/subs-$n.json"
        jq --argjson c "$(( SUBID - 10000 ))" '. + [{number: $c}]' "$G/subs-$n.json" > "$G/t" \
          && mv "$G/t" "$G/subs-$n.json"
        echo '{}' ;;
      "GET "*/comments)
        if [ -f "$G/race-reread.txt" ]; then
          if [ -f "$G/race-reread.seen" ]; then
            id=$(( $(jq 'length' "$G/comments.json") + 900 ))
            jq --argjson i "$id" --rawfile b "$G/race-reread.txt" \
              '. + [{id: $i, created_at: "2026-11-23T10:00:00Z", body: $b}]' \
              "$G/comments.json" > "$G/t" && mv "$G/t" "$G/comments.json"
            rm -f "$G/race-reread.txt" "$G/race-reread.seen"
          else
            : > "$G/race-reread.seen"
          fi
        fi
        pages "$G/comments.json" ;;
      "POST "*/comments)
        if [ -f "$G/post-fail-once" ]; then
          rm -f "$G/post-fail-once"; echo "gh: HTTP 502" >&2; exit 1
        fi
        if [ -f "$G/race-claim.txt" ]; then
          id=$(( $(jq 'length' "$G/comments.json") + 900 ))
          jq --argjson i "$id" --rawfile b "$G/race-claim.txt" \
            '. + [{id: $i, created_at: "2026-11-23T10:00:00Z", body: $b}]' \
            "$G/comments.json" > "$G/t" && mv "$G/t" "$G/comments.json"
          rm -f "$G/race-claim.txt"
        fi
        id=$(( $(jq 'length' "$G/comments.json") + 900 ))
        jq --argjson i "$id" --slurpfile p "$input" \
          '. + [{id: $i, created_at: "2026-11-23T10:00:00Z", body: $p[0].body}]' \
          "$G/comments.json" > "$G/t" && mv "$G/t" "$G/comments.json"
        # Same uncertain write for comments: stored, then a non-zero exit (error/timeout).
        [ "${STUB_GH_POST_THEN_FAIL:-0}" != 1 ] \
          || { echo "gh: HTTP 502 after the write" >&2; exit 1; }
        printf '{"id": %s}\n' "$id" ;;
      "GET "*issues\?*)
        pages "$G/issues.json" ;;
      "GET "*/issues/[0-9]*/timeline*)
        n="${path%/timeline*}"; n="${n##*/}"
        if [ -f "$G/timeline-$n.json" ]; then pages "$G/timeline-$n.json"; else echo '[]'; fi ;;
      "GET "*/issues/[0-9]*)
        n="${path##*/}"
        printf '{"id": %s, "number": %s}\n' "$(( 10000 + n ))" "$n" ;;
      *) echo "stub: gh api $meth $path" >&2; exit 1 ;;
    esac ;;
  project)
    case "${2:-}" in
      item-list)
        lim=1000
        while [ $# -gt 0 ]; do case "$1" in --limit) lim="$2"; shift 2 ;; *) shift ;; esac; done
        jq -c --argjson k "$lim" '{items: .[0:$k], totalCount: length}' "$G/items.json" ;;
      field-list)
        cat "$G/fields.json" ;;
      item-add)
        [ "${STUB_GH_ITEMADD_FAIL:-0}" != 1 ] \
          || { echo "your token has not been granted the required scopes: project" >&2; exit 1; }
        u=""; while [ $# -gt 0 ]; do case "$1" in --url) u="$2"; shift 2 ;; *) shift ;; esac; done
        jq --argjson n "${u##*/}" '. + [{id: ("item-new-" + ($n | tostring)), status: null,
            content: {type: "Issue", number: $n, repository: "owner/repo"}}]' \
          "$G/items.json" > "$G/t" && mv "$G/t" "$G/items.json"
        echo '{}' ;;
      item-edit)
        [ "${STUB_GH_EDIT_DENY:-0}" != 1 ] \
          || { echo "your token has not been granted the required scopes: project" >&2; exit 1; }
        id=""; opt=""; clr=0
        while [ $# -gt 0 ]; do case "$1" in
          --id) id="$2"; shift 2 ;; --single-select-option-id) opt="$2"; shift 2 ;;
          --clear) clr=1; shift ;;
          *) shift ;; esac; done
        if [ "$clr" = 1 ]; then
          jq --arg id "$id" 'map(if .id == $id then .status = null else . end)' \
            "$G/items.json" > "$G/t" && mv "$G/t" "$G/items.json"
          : > "$G/status"
          echo '{}'; exit 0
        fi
        name=$(jq -r --arg o "$opt" \
          '[.fields[]? | .options[]? | select(.id == $o) | .name] | .[0] // ""' "$G/fields.json")
        jq --arg id "$id" --arg s "$name" 'map(if .id == $id then .status = $s else . end)' \
          "$G/items.json" > "$G/t" && mv "$G/t" "$G/items.json"
        printf '%s\n' "$name" > "$G/status"
        echo '{}' ;;
      *) echo "stub: gh project $2" >&2; exit 1 ;;
    esac ;;
  pr)
    if [ "${2:-}" = view ] && [ -f "$G/pr-${3:-}.json" ]; then cat "$G/pr-$3.json"
    else echo "stub: gh pr $*" >&2; exit 1; fi ;;
  *) echo "stub: gh $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$WORK/bin/gh"
}
