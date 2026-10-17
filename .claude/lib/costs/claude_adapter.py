"""Claude Code transcripts → occurrences, events, sessions, subagents (spec TT-813).

Python 3.9 stdlib only. Stores usage metadata and whitelisted identifiers only — never prompts,
message text or free-text arguments.
"""
import glob
import hashlib
import json
import os
import re

import config
import reader
import store

PLAN_PATH_RE = re.compile(r"^\.agents/(specs|plans)/[A-Za-z0-9._/-]+\.md$")
COMMAND_RE = re.compile(r"<command-name>/?([^<]+)</command-name>")
COMMAND_ARGS_RE = re.compile(r"<command-args>(.*?)</command-args>", re.S)
END_STEP_RE = re.compile(
    r"^bash \.claude/lib/costs/runtime-mark\.sh stage end ([A-Za-z0-9._:-]{1,64})$")


def extract_arg(value):
    if not isinstance(value, str):
        return None
    for token in value.split():
        if config.TICKET_RE.match(token) or PLAN_PATH_RE.match(token):
            return token
    return None


def collect_project(conn, cfg, project, dirs, stats):
    touched = set()
    for directory in dirs:
        root = os.path.join(cfg["claude_projects_dir"], config.slug(directory))
        if not os.path.isdir(root):
            continue
        for path in sorted(glob.glob(os.path.join(root, "*.jsonl"))):
            session = os.path.basename(path)[:-len(".jsonl")]
            _ingest(conn, {"path": path, "project": project, "session": session,
                           "agent_id": ""}, touched, stats)
        pattern = os.path.join(root, "*", "subagents", "**", "agent-*.jsonl")
        for path in sorted(glob.glob(pattern, recursive=True)):
            session = os.path.relpath(path, root).split(os.sep)[0]
            agent_id = os.path.basename(path)[len("agent-"):-len(".jsonl")]
            _ingest(conn, {"path": path, "project": project, "session": session,
                           "agent_id": agent_id}, touched, stats)
            _read_meta(conn, path[:-len(".jsonl")] + ".meta.json", session, agent_id)
    return touched


def _read_meta(conn, path, session, agent_id):
    try:
        with open(path, encoding="utf-8") as fh:
            meta = json.load(fh)
    except (OSError, json.JSONDecodeError):
        return
    if isinstance(meta, dict):
        store.replace_row(conn, "subagents", {
            "session": session, "agent_id": agent_id, "agent_type": meta.get("agentType"),
            "tool_use_id": meta.get("toolUseId")})


def _flag(conn, ctx, reason):
    store.flag(conn, "claude", ctx["session"], ctx["agent_id"], reason)


def _ingest(conn, ctx, touched, stats):
    result = reader.read_new(conn, ctx["path"], "claude", session=ctx["session"],
                             agent_id=ctx["agent_id"], project=ctx["project"])
    stats["files"] += 1
    touched.update(result.reset_keys)
    store.upsert_session(conn, "claude", ctx["session"], ctx["agent_id"], project=ctx["project"])
    for ordinal, offset, raw in result.lines:
        rec = reader.parse(raw)
        if rec is None:
            _flag(conn, ctx, "bad-json")
            continue
        line = dict(ctx, ordinal=ordinal, offset=offset, raw=raw)
        _handle(conn, line, rec, touched, stats)
    if result.pending_partial:
        _flag(conn, ctx, "pending-partial-line")
    else:
        store.clear_flag(conn, "claude", ctx["session"], ctx["agent_id"], "pending-partial-line")


def _handle(conn, line, rec, touched, stats):
    ts = config.safe_ts(rec.get("timestamp"))
    session, agent_id = line["session"], line["agent_id"]
    if ts:
        store.upsert_session(conn, "claude", session, agent_id, first_ts=ts, last_ts=ts,
                             cwd=rec.get("cwd"))
    kind = rec.get("type")
    if kind == "assistant":
        _assistant(conn, line, rec, ts, touched, stats)
    elif kind == "user":
        _user_command(conn, line, rec, ts)
    elif kind == "agent-name" and isinstance(rec.get("agentName"), str):
        store.upsert_session(conn, "claude", session, agent_id, agent_label=rec["agentName"])
    elif kind == "custom-title" and isinstance(rec.get("customTitle"), str):
        store.upsert_session(conn, "claude", session, agent_id,
                             agent_label_if_empty=rec["customTitle"])


def _response_key(conn, line, rec, msg, usage):
    key = rec.get("requestId") or msg.get("id")
    if key:
        return key
    _flag(conn, line, "no-response-key")
    basis = f"{line['session']}|{rec.get('timestamp')}|{json.dumps(usage, sort_keys=True)}"
    return "h:" + hashlib.sha256(basis.encode()).hexdigest()


def _assistant(conn, line, rec, ts, touched, stats):
    msg = rec.get("message") if isinstance(rec.get("message"), dict) else {}
    if msg.get("model") == "<synthetic>":
        return
    usage = msg.get("usage")
    if reader.has_counts(usage, "input_tokens", "output_tokens"):
        key = _response_key(conn, line, rec, msg, usage)
        details = usage.get("output_tokens_details") or {}
        stats["new_occurrences"] += store.add_occurrence(conn, {
            "provider": "claude", "response_key": key, "session": line["session"],
            "agent_id": line["agent_id"], "project": line["project"],
            "source_file": line["path"], "line_ordinal": line["ordinal"],
            "byte_offset": line["offset"],
            "line_hash": hashlib.sha256(line["raw"]).hexdigest(), "ts": ts,
            "turn": rec.get("requestId"), "model": msg.get("model"), "effort": rec.get("effort"),
            "cwd": rec.get("cwd"), "input": reader.as_int(usage.get("input_tokens")),
            "cache_write": reader.as_int(usage.get("cache_creation_input_tokens")),
            "cache_read": reader.as_int(usage.get("cache_read_input_tokens")),
            "output": reader.as_int(usage.get("output_tokens")),
            "reasoning": reader.as_int(details.get("thinking_tokens")
                                       if isinstance(details, dict) else None),
            "source_kind": "response",
            "is_copy": int(rec.get("sessionId") not in (None, line["session"])),
            "owner_hint": None})
        touched.add(("claude", key))
    else:
        _flag(conn, line, "missing-usage")
    content = msg.get("content")
    for block_no, block in enumerate(content if isinstance(content, list) else []):
        _tool_event(conn, line, rec, ts, block_no, block)


def _tool_event(conn, line, rec, ts, block_no, block):
    if not isinstance(block, dict) or block.get("type") != "tool_use":
        return
    args = block.get("input") if isinstance(block.get("input"), dict) else {}
    if block.get("name") == "Skill":
        kind, name, arg = "skill", args.get("skill"), extract_arg(args.get("args"))
    elif block.get("name") == "Agent":
        kind, name, arg = "agent_spawn", args.get("subagent_type"), None
    elif block.get("name") == "Bash" and isinstance(args.get("command"), str):
        m = END_STEP_RE.match(args["command"])
        if not m:
            return
        kind, name, arg = "stage_end", m.group(1), None
    else:
        return
    store.add_event(conn, {
        "provider": "claude", "project": line["project"], "session": line["session"],
        "agent_id": line["agent_id"], "ts": ts, "turn": rec.get("requestId"), "kind": kind,
        "name": name if isinstance(name, str) else None, "args": arg,
        "tool_use_id": block.get("id"), "source_file": line["path"],
        "line_ordinal": line["ordinal"], "block": block_no})


def _text(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(b.get("text", "") for b in content
                         if isinstance(b, dict) and isinstance(b.get("text"), str))
    return ""


def _user_command(conn, line, rec, ts):
    msg = rec.get("message") if isinstance(rec.get("message"), dict) else {}
    text = _text(msg.get("content"))
    match = COMMAND_RE.search(text)
    if not match:
        return
    args = COMMAND_ARGS_RE.search(text)
    store.add_event(conn, {
        "provider": "claude", "project": line["project"], "session": line["session"],
        "agent_id": line["agent_id"], "ts": ts, "turn": None, "kind": "command",
        "name": match.group(1).strip(), "args": extract_arg(args.group(1) if args else None),
        "tool_use_id": None, "source_file": line["path"], "line_ordinal": line["ordinal"],
        "block": 0})
