"""Jira report comment: marker, stable body, add-or-edit decision (spec TT-821).

Python 3.9 stdlib only. Never posts — the caller runs the Jira MCP tool it recommends.
"""
import json
from datetime import datetime

import config
import report

MARKER = "token-usage-report: {ticket}"
# mcp-atlassian returns at most this many comments per call; a full page may hide older ones.
PAGE_LIMIT = 100


def body(data):
    return MARKER.format(ticket=data["header"]["ticket"]) + "\n\n" + report.render_md(
        data, stable=True)


def load_comments(path):
    """Comments list from a saved jira_get_issue result (raw, MCP-wrapped or a bare list)."""
    try:
        with open(path, encoding="utf-8") as fh:
            payload = json.load(fh)
        if isinstance(payload, dict) and isinstance(payload.get("result"), str):
            payload = json.loads(payload["result"])
    except (OSError, json.JSONDecodeError) as err:
        config.fail(2, f"cannot read comments from {path}: {err}")
    if isinstance(payload, dict) and isinstance(payload.get("comments"), list):
        payload = payload["comments"]
    if not isinstance(payload, list) or not all(isinstance(c, dict) for c in payload):
        config.fail(2, f"{path}: not a comments list or an issue with comments")
    return payload


def _created(comment):
    try:
        return datetime.strptime(comment.get("created") or "", "%Y-%m-%dT%H:%M:%S.%f%z")
    except ValueError:
        return None


def _newest(comments):
    dated = [(c, _created(c)) for c in comments]
    if all(when is not None for _, when in dated):
        return max(dated, key=lambda pair: pair[1])[0]
    return comments[-1]


def decide(comments, ticket, text):
    marker = MARKER.format(ticket=ticket)
    # Whole-line match: "…: TT-1" is a prefix of "…: TT-10".
    ours = [c for c in comments
            if marker in {ln.strip() for ln in (c.get("body") or "").splitlines()}]
    if ours:
        newest = _newest(ours)
        return {"action": "edit", "comment_id": str(newest["id"]),
                "duplicates": [str(c["id"]) for c in ours if c is not newest], "body": text}
    if len(comments) >= PAGE_LIMIT:
        config.fail(3, f"comment history may be incomplete (≥{PAGE_LIMIT} comments, no report"
                       " marker) — point at the report comment by hand")
    return {"action": "add", "comment_id": None, "duplicates": [], "body": text}
