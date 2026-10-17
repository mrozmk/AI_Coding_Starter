"""Fixture builders for the token-usage tests: temp env + record shapes (spec TT-813)."""
import contextlib
import io
import json
import os
import shutil
import tempfile

import config
import cost
import store

PROJ = "/work/proj"
ALFA = "/work/proj-alfa"
FIXTURES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures")


class TempEnv:
    """Temp AGENT_COSTS_HOME with a config whose transcript roots live under it."""

    def __init__(self, dirs=(PROJ, ALFA)):
        self.dirs = list(dirs)

    def __enter__(self):
        self.root = tempfile.mkdtemp(prefix="cost-tests-")
        self._saved = os.environ.get("AGENT_COSTS_HOME")
        os.environ["AGENT_COSTS_HOME"] = self.root
        self.claude_dir = os.path.join(self.root, "claude-projects")
        self.codex_home = os.path.join(self.root, "codex")
        self.write_config()
        return self

    def write_config(self, dirs=None):
        self.dirs = list(dirs or self.dirs)
        with open(os.path.join(self.root, "config.json"), "w", encoding="utf-8") as fh:
            json.dump({"projects": {"proj": self.dirs}, "claude_projects_dir": self.claude_dir,
                       "codex_homes": [self.codex_home]}, fh)

    def __exit__(self, *exc):
        if self._saved is None:
            os.environ.pop("AGENT_COSTS_HOME", None)
        else:
            os.environ["AGENT_COSTS_HOME"] = self._saved
        shutil.rmtree(self.root, ignore_errors=True)

    def cfg(self):
        return config.load_config()

    def conn(self):
        conn = store.connect(config.db_path())
        store.migrate(conn)
        return conn

    def claude_file(self, session, cwd=PROJ, agent_id=None, nested=""):
        root = os.path.join(self.claude_dir, config.slug(cwd))
        if agent_id is None:
            return os.path.join(root, f"{session}.jsonl")
        return os.path.join(root, session, "subagents", nested, f"agent-{agent_id}.jsonl")

    def codex_file(self, name):
        return os.path.join(self.codex_home, "sessions", "2026", "10", "06",
                            f"rollout-{name}.jsonl")

    def collect(self):
        with contextlib.redirect_stdout(io.StringIO()):
            return cost.main(["collect"])


def write_jsonl(path, records, trailing_partial=None, mode="w"):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, mode, encoding="utf-8") as fh:
        for rec in records:
            fh.write(json.dumps(rec) + "\n")
        if trailing_partial is not None:
            fh.write(trailing_partial)


def write_meta(jsonl_path, agent_type, tool_use_id=None):
    meta = {"agentType": agent_type, "description": "fixture", "spawnDepth": 1}
    if tool_use_id:
        meta["toolUseId"] = tool_use_id
    with open(jsonl_path[:-len(".jsonl")] + ".meta.json", "w", encoding="utf-8") as fh:
        json.dump(meta, fh)


def claude_assistant(session, ts, request_id="req_1", output=10, inp=2, cache_write=100,
                     cache_read=0, model="claude-opus-5-5", effort="medium", cwd=PROJ,
                     content=None, usage=True, msg_id=None, agent_id=None, thinking=4):
    msg = {"id": msg_id or f"msg_{request_id}", "model": model, "content": content or []}
    if usage:
        msg["usage"] = {"input_tokens": inp, "cache_creation_input_tokens": cache_write,
                        "cache_read_input_tokens": cache_read, "output_tokens": output,
                        "output_tokens_details": {"thinking_tokens": thinking}}
    rec = {"type": "assistant", "timestamp": ts, "sessionId": session, "cwd": cwd,
           "effort": effort, "isSidechain": agent_id is not None, "message": msg}
    if request_id:
        rec["requestId"] = request_id
    if agent_id:
        rec["agentId"] = agent_id
    return rec


def skill_block(skill, args="", tool_id="toolu_s"):
    return {"type": "tool_use", "id": tool_id, "name": "Skill",
            "input": {"skill": skill, "args": args}}


def agent_block(subagent_type, tool_id, description="d", prompt="p"):
    return {"type": "tool_use", "id": tool_id, "name": "Agent",
            "input": {"subagent_type": subagent_type, "description": description,
                      "prompt": prompt}}


def claude_user_command(session, ts, name, args="", as_blocks=False):
    text = f"<command-name>/{name}</command-name>\n<command-args>{args}</command-args>"
    content = [{"type": "text", "text": text}] if as_blocks else text
    return {"type": "user", "timestamp": ts, "sessionId": session, "message": {"content": content}}


def claude_agent_name(session, name):
    return {"type": "agent-name", "agentName": name, "sessionId": session}


def codex_meta(thread, ts, cwd=PROJ, source="exec", parent=None, start=None):
    return {"timestamp": ts, "type": "session_meta",
            "payload": {"id": thread, "cwd": cwd, "source": source, "parent_thread_id": parent,
                        "forked_from_id": None, "subagent_history_start_ordinal": start,
                        "creator_account_id": "acct-fixture-0001",
                        "base_instructions": {"text": "fixture instructions"}}}


def codex_turn(turn_id, ts, model="gpt-6.1-sol", effort="high", cwd=PROJ, ordinal=None):
    rec = {"timestamp": ts, "type": "turn_context",
           "payload": {"turn_id": turn_id, "model": model, "effort": effort, "cwd": cwd}}
    if ordinal is not None:
        rec["ordinal"] = ordinal
    return rec


def _totals(inp, cached, output, reasoning=0, cache_write=0):
    return {"input_tokens": inp, "cached_input_tokens": cached,
            "cache_write_input_tokens": cache_write, "output_tokens": output,
            "reasoning_output_tokens": reasoning, "total_tokens": inp + output}


def codex_usage(thread, turn_id, response_id, ts, inp=20506, cached=4864, output=333,
                reasoning=267, cache_write=0, ordinal=None, thread_total=None):
    rec = {"timestamp": ts, "type": "token_usage_record",
           "payload": {"thread_id": thread, "turn_id": turn_id, "response_id": response_id,
                       "usage": _totals(inp, cached, output, reasoning, cache_write),
                       "thread_token_usage": thread_total or
                       _totals(inp, cached, output, reasoning, cache_write)}}
    if ordinal is not None:
        rec["ordinal"] = ordinal
    return rec


def codex_token_count(ts, inp, cached=0, output=0, reasoning=0, ordinal=None, info=True):
    rec = {"timestamp": ts, "type": "event_msg",
           "payload": {"type": "token_count",
                       "info": {"total_token_usage": _totals(inp, cached, output, reasoning)}
                       if info else None}}
    if ordinal is not None:
        rec["ordinal"] = ordinal
    return rec


def usage_sums(conn):
    return tuple(conn.execute("SELECT COUNT(*), SUM(input), SUM(cache_write), SUM(cache_read),"
                              " SUM(output) FROM usage").fetchone())


def reasons(conn, provider, session, agent_id=""):
    row = conn.execute("SELECT coverage_reasons FROM sessions WHERE provider = ? AND session = ?"
                       " AND agent_id = ?", (provider, session, agent_id)).fetchone()
    return set(filter(None, ((row and row[0]) or "").split(",")))
