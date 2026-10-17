"""Codex rollouts → occurrences, turns, counters, sessions; token_count fallback (spec TT-813).

Python 3.9 stdlib only. Reads `session_meta` fields by name — account ids and instructions in
the same payload never reach the DB.
"""
import glob
import hashlib
import json
import os

import config
import reader
import store

TOTAL_FIELDS = ("input_tokens", "cached_input_tokens", "cache_write_input_tokens",
                "output_tokens", "reasoning_output_tokens", "total_tokens")


def label(source):
    if isinstance(source, str):
        return f"codex:{source}"
    if isinstance(source, dict):
        sub = source.get("subagent")
        if isinstance(sub, dict) and isinstance(sub.get("other"), str):
            return f"codex:subagent:{sub['other']}"
        return "codex:subagent"
    return "codex"


def _normalize(usage):
    cached = reader.as_int(usage.get("cached_input_tokens"))
    return {"input": reader.as_int(usage.get("input_tokens")) - cached,
            "cache_write": reader.as_int(usage.get("cache_write_input_tokens")),
            "cache_read": cached,
            "output": reader.as_int(usage.get("output_tokens")),
            "reasoning": reader.as_int(usage.get("reasoning_output_tokens"))}


def _totals(usage):
    return {f: reader.as_int(usage.get(f)) for f in TOTAL_FIELDS}


def _first_meta(path):
    try:
        with open(path, "rb") as fh:
            for raw in fh:
                rec = reader.parse(raw)
                if rec and rec.get("type") == "session_meta":
                    payload = rec.get("payload")
                    return payload if isinstance(payload, dict) else {}
    except OSError:
        return None
    return None


def collect_codex(conn, cfg, stats, only_project=None):
    touched = set()
    for codex_home in cfg["codex_homes"]:
        pattern = os.path.join(codex_home, "sessions", "**", "rollout-*.jsonl")
        for path in sorted(glob.glob(pattern, recursive=True)):
            project, reset_keys, was_reset = _scope(conn, cfg, path, stats)
            touched |= reset_keys
            if project and (was_reset or only_project in (None, project)):
                touched |= _collect_file(conn, path, project, stats)
    return touched


def _scope(conn, cfg, path, stats):
    """Recheck the header before ingest: rotation can change scope without a config change."""
    st = os.stat(path)
    cur = conn.execute("SELECT * FROM files WHERE path = ?", (path,)).fetchone()
    meta = _first_meta(path) or {}
    project = config.project_for_cwd(cfg, meta.get("cwd")) if meta.get("cwd") else None
    if cur and cur["skipped"] and project is None:
        stats["codex_skipped"] += 1
        return None, set(), False
    reset_keys = set()
    was_reset = bool(cur and (cur["skipped"] or cur["project"] != project))
    if was_reset:
        reset_keys = store.delete_file_rows(conn, path)
        conn.execute("DELETE FROM files WHERE path = ?", (path,))
    if project is None:
        store.replace_row(conn, "files", {"path": path, "provider": "codex", "inode": st.st_ino,
                                          "size": st.st_size, "offset": 0, "ordinal": 0,
                                          "skipped": 1})
        stats["codex_skipped"] += 1
        return None, reset_keys, was_reset
    return project, reset_keys, was_reset


def _state(conn, path, project, result):
    frow = conn.execute("SELECT session FROM files WHERE path = ?", (path,)).fetchone()
    # A read from byte 0 re-reads the header, which re-derives the session row's fields.
    session = frow["session"] if frow and result.start > 0 else None
    srow = conn.execute("SELECT cwd, history_start_ordinal FROM sessions WHERE provider = 'codex'"
                        " AND session = ? AND agent_id = ''", (session,)).fetchone()
    return {"path": path, "project": project, "session": session,
            "cwd": srow["cwd"] if srow else None,
            "start": srow["history_start_ordinal"] if srow else None, "last_turn": None,
            "from_start": result.start == 0, "pending": []}


def _flag(conn, state, reason):
    if state["session"]:
        store.flag(conn, "codex", state["session"], "", reason)
    else:
        state["pending"].append(reason)


def _collect_file(conn, path, project, stats):
    result = reader.read_new(conn, path, "codex", project=project)
    stats["files"] += 1
    touched = set(result.reset_keys)
    state = _state(conn, path, project, result)
    for ordinal, offset, raw in result.lines:
        rec = reader.parse(raw)
        if rec is None:
            _flag(conn, state, "bad-json")
            continue
        if state["from_start"] and ordinal == 0 and rec.get("type") != "session_meta":
            _flag(conn, state, "history-starts-mid-session")
        line = {"ordinal": ordinal, "offset": offset, "raw": raw,
                "rec_ordinal": rec["ordinal"] if isinstance(rec.get("ordinal"), int) else ordinal}
        _handle(conn, state, line, rec, touched, stats)
    if not state["session"]:
        return touched
    for reason in state["pending"]:
        store.flag(conn, "codex", state["session"], "", reason)
    if result.pending_partial:
        store.flag(conn, "codex", state["session"], "", "pending-partial-line")
    else:
        store.clear_flag(conn, "codex", state["session"], "", "pending-partial-line")
    if result.lines or result.reset:
        touched |= apply_fallback(conn, state["session"])
    return touched


def _handle(conn, state, line, rec, touched, stats):
    kind = rec.get("type")
    payload = rec.get("payload") if isinstance(rec.get("payload"), dict) else {}
    ts = config.safe_ts(rec.get("timestamp"))
    if kind == "session_meta":
        _session_meta(conn, state, payload)
    if not state["session"]:
        return
    if ts:
        store.upsert_session(conn, "codex", state["session"], "", first_ts=ts, last_ts=ts)
    if kind == "turn_context" and payload.get("turn_id"):
        store.replace_row(conn, "codex_turns", {
            "session": state["session"], "turn_id": payload["turn_id"],
            "ordinal": line["rec_ordinal"], "model": payload.get("model"),
            "effort": payload.get("effort"), "cwd": payload.get("cwd"),
            "source_file": state["path"]})
        state["last_turn"] = payload["turn_id"]
    elif kind == "token_usage_record":
        if reader.has_counts(payload.get("usage"), "input_tokens", "output_tokens"):
            _record(conn, state, line, payload, ts, touched, stats)
        else:
            _flag(conn, state, "missing-usage")
    elif kind == "event_msg" and payload.get("type") == "token_count":
        _counter(conn, state, line, payload, ts)


def _session_meta(conn, state, payload):
    # A sub-agent rollout may replay the parent's header; the file's own header comes first.
    if state["session"] or not isinstance(payload.get("id"), str):
        return
    state.update(session=payload["id"], cwd=payload.get("cwd"),
                 start=payload.get("subagent_history_start_ordinal"))
    store.set_file_session(conn, state["path"], payload["id"])
    store.upsert_session(conn, "codex", payload["id"], "", project=state["project"],
                         cwd=payload.get("cwd"), source_label=label(payload.get("source")),
                         parent_session=payload.get("parent_thread_id"),
                         history_start_ordinal=payload.get("subagent_history_start_ordinal"))


def _record(conn, state, line, payload, ts, touched, stats):
    session, ordinal = state["session"], line["rec_ordinal"]
    thread = payload.get("thread_id") or session
    is_copy = thread != session or (state["start"] is not None and ordinal < state["start"])
    key = payload.get("response_id")
    if not key:
        _flag(conn, state, "no-response-key")
        basis = f"{session}|{ts}|{json.dumps(payload['usage'], sort_keys=True)}"
        key = "h:" + hashlib.sha256(basis.encode()).hexdigest()
    row = {"provider": "codex", "response_key": key, "session": session, "agent_id": "",
           "project": state["project"], "source_file": state["path"],
           "line_ordinal": line["ordinal"], "byte_offset": line["offset"],
           "line_hash": hashlib.sha256(line["raw"]).hexdigest(), "ts": ts,
           "turn": payload.get("turn_id"), "model": None, "effort": None, "cwd": state["cwd"],
           "source_kind": "response", "is_copy": int(is_copy), "owner_hint": thread}
    row.update(_normalize(payload["usage"]))
    if row["cache_write"] > 0:
        _flag(conn, state, "codex-cache-write-unverified")
    stats["new_occurrences"] += store.add_occurrence(conn, row)
    touched.add(("codex", key))
    if not is_copy and isinstance(payload.get("thread_token_usage"), dict):
        store.upsert_session(conn, "codex", session, "", provider_total_json=json.dumps(
            _totals(payload["thread_token_usage"])))


def _counter(conn, state, line, payload, ts):
    info = payload.get("info")
    total = info.get("total_token_usage") if isinstance(info, dict) else None
    if not isinstance(total, dict):
        return
    turn = state["last_turn"]
    if turn is None:
        row = conn.execute("SELECT turn_id FROM codex_turns WHERE session = ? AND ordinal < ?"
                           " ORDER BY ordinal DESC LIMIT 1",
                           (state["session"], line["rec_ordinal"])).fetchone()
        turn = row[0] if row else None
    store.replace_row(conn, "codex_counters", {
        "session": state["session"], "ordinal": line["rec_ordinal"], "ts": ts, "turn_id": turn,
        "totals_json": json.dumps(_totals(total)), "source_file": state["path"]})


def _fallback_row(session, cwd, project, counter, delta):
    row = {"provider": "codex", "response_key": f"tc:{session}:{counter['ordinal']}",
           "session": session, "agent_id": "", "project": project,
           "source_file": counter["source_file"], "line_ordinal": counter["ordinal"],
           "byte_offset": None, "line_hash": None, "ts": counter["ts"],
           "turn": counter["turn_id"], "model": None, "effort": None, "cwd": cwd,
           "source_kind": "token_count", "is_copy": 0, "owner_hint": session}
    row.update(_normalize(delta))
    return row


def apply_fallback(conn, session):
    """Rebuild token_count rows for a thread with no own records; return every key it touched."""
    old = {("codex", r[0]) for r in conn.execute(
        "SELECT response_key FROM occurrences WHERE provider = 'codex' AND session = ?"
        " AND source_kind = 'token_count'", (session,))}
    conn.execute("DELETE FROM occurrences WHERE provider = 'codex' AND session = ?"
                 " AND source_kind = 'token_count'", (session,))
    for reason in ("token-count-fallback", "counter-discontinuity"):
        store.clear_flag(conn, "codex", session, "", reason)
    if conn.execute("SELECT 1 FROM occurrences WHERE provider = 'codex' AND session = ? AND"
                    " source_kind = 'response' AND is_copy = 0 LIMIT 1", (session,)).fetchone():
        return old
    srow = conn.execute("SELECT cwd, project, history_start_ordinal FROM sessions WHERE"
                        " provider = 'codex' AND session = ? AND agent_id = ''",
                        (session,)).fetchone()
    start = srow["history_start_ordinal"] if srow else None
    new, prev = set(), None
    for counter in conn.execute("SELECT * FROM codex_counters WHERE session = ? ORDER BY ordinal",
                                (session,)).fetchall():
        totals = json.loads(counter["totals_json"])
        delta = {f: totals[f] - (prev[f] if prev else 0) for f in TOTAL_FIELDS}
        replayed = start is not None and counter["ordinal"] < start
        prev = totals
        if replayed or not any(delta.values()):
            continue
        if any(v < 0 for v in delta.values()):
            store.flag(conn, "codex", session, "", "counter-discontinuity")
            continue
        row = _fallback_row(session, srow["cwd"], srow["project"], counter, delta)
        store.add_occurrence(conn, row)
        new.add(("codex", row["response_key"]))
    if new:
        store.flag(conn, "codex", session, "", "token-count-fallback")
    return old | new
