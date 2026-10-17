"""Claude adapter: dedupe, coverage flags, sub-agents, events, privacy (spec TT-813)."""
import json
import os
import unittest

from tests import helpers

S = "sess-main-0001"


def _a(ts, req, **kw):
    return helpers.claude_assistant(S, ts, request_id=req, **kw)


class ClaudeAdapterTest(unittest.TestCase):
    def setUp(self):
        self.env = helpers.TempEnv().__enter__()
        self.conn = self.env.conn()

    def tearDown(self):
        self.env.__exit__(None, None, None)

    def usage(self):
        return self.conn.execute("SELECT * FROM usage ORDER BY response_key").fetchall()

    def test_streaming_duplicate_is_one_row_final_chunk_wins(self):
        helpers.write_jsonl(self.env.claude_file(S), [
            _a("2026-10-06T10:00:00.113Z", "req_a", output=5),
            _a("2026-10-06T10:00:01.039Z", "req_a", output=181),
            _a("2026-10-06T10:00:01.100Z", "req_a", output=181)])
        self.env.collect()
        rows = self.usage()
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["output"], 181)
        self.assertEqual(rows[0]["occurrence_count"], 3)
        self.assertEqual(rows[0]["reasoning"], 4)

    def test_missing_usage_flags_partial_and_adds_no_row(self):
        helpers.write_jsonl(self.env.claude_file(S), [
            _a("2026-10-06T10:00:00Z", "req_a", usage=False),
            _a("2026-10-06T10:00:01Z", "req_b"),
            _a("2026-10-06T10:00:02Z", "req_c", model="<synthetic>"),
            dict(_a("2026-10-06T10:00:03Z", "req_d"), message={"id": "m", "usage": {}})])
        self.env.collect()
        self.assertEqual([r["response_key"] for r in self.usage()], ["req_b"])
        self.assertIn("missing-usage", helpers.reasons(self.conn, "claude", S))

    def test_message_id_fallback(self):
        helpers.write_jsonl(self.env.claude_file(S),
                            [_a("2026-10-06T10:00:00Z", None, msg_id="msg_only")])
        self.env.collect()
        self.assertEqual(self.usage()[0]["response_key"], "msg_only")

    def test_subagents_flat_and_nested_workflow(self):
        flat = self.env.claude_file(S, agent_id="a220")
        nested = self.env.claude_file(S, agent_id="wf1", nested="workflows/wf_x")
        helpers.write_jsonl(flat, [helpers.claude_assistant(S, "2026-10-06T10:01:00Z",
                                                            "req_f", agent_id="a220")])
        helpers.write_jsonl(nested, [helpers.claude_assistant(S, "2026-10-06T10:02:00Z",
                                                              "req_n", agent_id="wf1")])
        helpers.write_meta(flat, "structure-reviewer", "toolu_015")
        helpers.write_meta(nested, "workflow-agent")
        self.env.collect()
        rows = {r["response_key"]: r for r in self.usage()}
        self.assertEqual((rows["req_f"]["session"], rows["req_f"]["agent_id"]), (S, "a220"))
        self.assertEqual((rows["req_n"]["session"], rows["req_n"]["agent_id"]), (S, "wf1"))
        subs = {r["agent_id"]: tuple(r) for r in self.conn.execute("SELECT * FROM subagents")}
        self.assertEqual(subs["a220"], (S, "a220", "structure-reviewer", "toolu_015"))
        self.assertEqual(subs["wf1"], (S, "wf1", "workflow-agent", None))

    def test_rewrite_dropping_agent_name_clears_label(self):
        path = self.env.claude_file(S)
        helpers.write_jsonl(path, [helpers.claude_agent_name(S, "alfa-coder"),
                                   _a("2026-10-06T10:00:00Z", "req_a")])
        self.env.collect()
        label = "SELECT agent_label FROM sessions WHERE session = ? AND agent_id = ''"
        self.assertEqual(self.conn.execute(label, (S,)).fetchone()[0], "alfa-coder")
        tmp = path + ".tmp"
        helpers.write_jsonl(tmp, [_a("2026-10-06T10:00:00Z", "req_a")])
        os.replace(tmp, path)
        self.env.collect()
        self.assertIsNone(self.conn.execute(label, (S,)).fetchone()[0])

    def test_events_skill_command_agent(self):
        helpers.write_jsonl(self.env.claude_file(S), [
            helpers.claude_user_command(S, "2026-10-06T10:00:00Z", "prime"),
            helpers.claude_user_command(S, "2026-10-06T10:00:01Z", "execute",
                                        ".agents/plans/active/x.md", as_blocks=True),
            _a("2026-10-06T10:00:02Z", "req_a", content=[
                helpers.skill_block("plan-feature", "TT-805 extra words"),
                helpers.agent_block("structure-reviewer", "toolu_1"),
                helpers.agent_block("structure-reviewer", "toolu_2")])])
        self.env.collect()
        events = [tuple(r) for r in self.conn.execute(
            "SELECT kind, name, args, turn, tool_use_id FROM events ORDER BY ts, block")]
        self.assertEqual(events, [
            ("command", "prime", None, None, None),
            ("command", "execute", ".agents/plans/active/x.md", None, None),
            ("skill", "plan-feature", "TT-805", "req_a", "toolu_s"),
            ("agent_spawn", "structure-reviewer", None, "req_a", "toolu_1"),
            ("agent_spawn", "structure-reviewer", None, "req_a", "toolu_2")])

    def test_end_step_bash_is_stage_end_event(self):
        end = "bash .claude/lib/costs/runtime-mark.sh stage end execute"
        helpers.write_jsonl(self.env.claude_file(S), [_a("2026-10-06T10:00:02Z", "req_e", content=[
            {"type": "tool_use", "id": "toolu_e", "name": "Bash", "input": {"command": end}},
            {"type": "tool_use", "id": "toolu_g", "name": "Bash",
             "input": {"command": "git status"}}])])
        self.env.collect()
        events = [tuple(r) for r in self.conn.execute(
            "SELECT kind, name, args, turn, tool_use_id FROM events")]
        self.assertEqual(events, [("stage_end", "execute", None, "req_e", "toolu_e")])
        dump = "\n".join(self.conn.iterdump())
        self.assertNotIn("runtime-mark.sh", dump)
        self.assertNotIn("git status", dump)

    def test_privacy_no_free_text_reaches_db(self):
        with open(os.path.join(helpers.FIXTURES, "privacy-args.json")) as fh:
            strings = json.load(fh)["strings"]
        records = [helpers.claude_agent_name(S, "alfa-coder")]
        for n, s in enumerate(strings):
            ts = f"2026-10-06T10:{n:02d}:00Z"
            records.append(helpers.claude_user_command(S, ts, "execute", s))
            records.append(_a(ts, f"req_{n}", content=[
                helpers.skill_block("execute", s, tool_id=f"toolu_s{n}"),
                helpers.agent_block("general-purpose", f"toolu_a{n}", description=s, prompt=s)]))
        records.append(_a("2026-10-06T11:00:00Z", "req_keep", content=[
            helpers.skill_block("execute", "TT-805"),
            helpers.skill_block("execute", ".agents/plans/active/x.md", tool_id="toolu_k")]))
        helpers.write_jsonl(self.env.claude_file(S), records)
        self.env.collect()
        dump = "\n".join(self.conn.iterdump())
        for s in strings:
            self.assertNotIn(s, dump)
        self.assertNotIn("fixture", dump.replace("cost-tests-", ""))
        self.assertIn("TT-805", dump)
        self.assertIn(".agents/plans/active/x.md", dump)


if __name__ == "__main__":
    unittest.main()
