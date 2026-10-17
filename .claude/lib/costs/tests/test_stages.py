"""Stage split: Σ check, sub-agent placement, turn exclusion, runtime markers (TT-813, TT-821)."""
import unittest
from unittest import mock

import bindings
import config
import jira_comment
import report
import runtime
import stages
from tests import helpers

S = "0a1b2c3d-0000-4000-8000-0000000000aa"
S2 = "0a1b2c3d-0000-4000-8000-0000000000bb"
END = "bash .claude/lib/costs/runtime-mark.sh stage end "


def _ts(n):
    return f"2026-10-06T10:{n:02d}:00Z"


def _a(n, req, content=None, ts=None, output=10):
    return helpers.claude_assistant(S, ts or _ts(n), request_id=req, content=content,
                                    output=output, inp=0, cache_write=0)


def _skill(name, tool_id):
    return [helpers.skill_block(name, tool_id=tool_id)]


def _end_block(name, tool_id):
    return [{"type": "tool_use", "id": tool_id, "name": "Bash", "input": {"command": END + name}}]


def _mark(event, name, minute=None, tool_use_id=None, source="hook-skill", ts=None,
          session=S):
    rec = {"v": 1, "type": "stage", "session": session, "event": event, "name": name,
           "source": source, "at": ts or _ts(minute)}
    if tool_use_id:
        rec["tool_use_id"] = tool_use_id
    return rec


class StagesTest(unittest.TestCase):
    def setUp(self):
        self.env = helpers.TempEnv().__enter__()
        self.conn = self.env.conn()
        self.cfg = self.env.cfg()

    def tearDown(self):
        self.env.__exit__(None, None, None)

    def run_report(self, records, subagents=(), marks=()):
        helpers.write_jsonl(config.runtime_path(), marks)
        helpers.write_jsonl(self.env.claude_file(S),
                            [helpers.claude_agent_name(S, "beta-coder")] + records)
        for agent_id, tool_id, output in subagents:
            path = self.env.claude_file(S, agent_id=agent_id)
            helpers.write_jsonl(path, [helpers.claude_assistant(
                S, _ts(50), request_id=f"req_{agent_id}", output=output, inp=0, cache_write=0,
                agent_id=agent_id)])
            helpers.write_meta(path, "general-purpose", tool_id)
        self.env.collect()
        runtime.ingest(self.conn)
        self.conn.commit()
        bindings.add_binding(self.conn, self.cfg, "TT-1", session=S)
        data = report.build(self.conn, self.cfg, "TT-1", by_stage=True)
        by_stage = {}
        for row in data["stages"]["rows"]:
            by_stage[row["stage"]] = by_stage.get(row["stage"], 0) + row["output"]
        return data, by_stage

    def test_sum_and_non_stage_skills(self):
        data, got = self.run_report([
            _a(0, "req_0", output=1),
            _a(1, "req_1", _skill("check-implementation", "t1"), output=2),
            _a(2, "req_2", _skill("code-review", "t2"), output=4),
            _a(3, "req_3", _skill("pr-create", "t3"), output=8),
            _a(4, "req_4", _skill("push", "t4"), output=16),
            _a(5, "req_5", output=32)])
        self.assertEqual(got, {"outside-stage": 3, "check-implementation": 12, "pr-create": 48})
        check = data["stages"]["check"]
        self.assertEqual(check["stages"], check["allocated"])
        self.assertEqual(check["allocated"], data["totals"]["total"])
        self.assertIn("approximation", report.render_md(data))

    def test_typed_command_opens_stage(self):
        _, got = self.run_report([
            helpers.claude_user_command(S, _ts(0), "prime"), _a(1, "req_1", output=5)])
        self.assertEqual(got, {"prime": 5})

    def test_streamed_skill_response_stays_in_previous_stage(self):
        call = _skill("plan-feature", "t2")
        _, got = self.run_report([
            _a(0, "req_0", _skill("brainstorm", "t1"), output=1),
            _a(1, "req_1", output=2),
            helpers.claude_assistant(S, "2026-10-06T10:02:00.113Z", request_id="req_2",
                                     content=call, output=3, inp=0, cache_write=0),
            helpers.claude_assistant(S, "2026-10-06T10:02:01.039Z", request_id="req_2",
                                     content=call, output=4, inp=0, cache_write=0),
            _a(3, "req_3", output=8)])
        self.assertEqual(got, {"outside-stage": 1, "brainstorm": 6, "plan-feature": 8})

    def test_subagent_lands_in_spawn_stage_once(self):
        _, got = self.run_report([
            _a(0, "req_0", _skill("execute", "t1"), output=1),
            _a(1, "req_1", [helpers.agent_block("general-purpose", "toolu_x"),
                            helpers.agent_block("general-purpose", "toolu_y")], output=2),
            _a(2, "req_2", _skill("check-implementation", "t2"), output=4)],
            subagents=[("ax", "toolu_x", 100), ("ay", "toolu_y", 200)])
        self.assertEqual(got, {"outside-stage": 1, "execute": 306})

    def test_typed_execute_then_subagent(self):
        _, got = self.run_report([
            helpers.claude_user_command(S, _ts(0), "execute"),
            _a(1, "req_1", [helpers.agent_block("general-purpose", "toolu_z")], output=2)],
            subagents=[("az", "toolu_z", 50), ("orphan", None, 7)])
        self.assertEqual(got, {"execute": 59})

    def header(self, data):
        return data["stages"]["header"]

    def test_marker_nested_stage_returns_to_outer(self):
        data, got = self.run_report(
            [_a(0, "req_0", output=1), _a(2, "req_2", output=2), _a(4, "req_4", output=4),
             _a(6, "req_6", output=8)],
            marks=[_mark("start", "orchestrate", 1), _mark("start", "execute", 3),
                   _mark("end", "execute", 5)])
        self.assertEqual(got, {"outside-stage": 1, "orchestrate": 10, "execute": 4})
        self.assertIn("runtime markers for 1 sessions, transcript approximation for 0;"
                      " inferred ends 1, unmatched ends 0.", self.header(data))

    def test_marker_inferred_ends(self):
        data, got = self.run_report(
            [_a(3, "req_3", output=1), _a(5, "req_5", output=2)],
            marks=[_mark("start", "prime", 1), _mark("start", "brainstorm", 2),
                   _mark("start", "brainstorm", 4)])
        self.assertEqual(got, {"brainstorm": 3})
        self.assertIn("inferred ends 3, unmatched ends 0", self.header(data))

    def test_marker_lone_start(self):
        data, got = self.run_report([_a(2, "req_2", output=5)],
                                    marks=[_mark("start", "execute", 1)])
        self.assertEqual(got, {"execute": 5})
        self.assertIn("inferred ends 1,", self.header(data))

    def test_unmatched_end_has_no_effect(self):
        data, got = self.run_report([_a(2, "req_2", output=5)],
                                    marks=[_mark("end", "qa-verify", 1, source="skill-end")])
        self.assertEqual(got, {"outside-stage": 5})
        self.assertIn("runtime markers for 0 sessions, transcript approximation for 1;"
                      " inferred ends 0, unmatched ends 1.", self.header(data))

    def test_stray_end_keeps_transcript_mode(self):
        data, got = self.run_report(
            [_a(1, "req_1", _skill("check-implementation", "t1"), output=1),
             _a(2, "req_2", output=2), _a(4, "req_4", output=4)],
            marks=[_mark("end", "qa-verify", 3, source="skill-end")])
        self.assertEqual(got, {"outside-stage": 1, "check-implementation": 6})
        self.assertIn("runtime markers for 0 sessions, transcript approximation for 1;",
                      self.header(data))

    def _subagent(self, agent_id, records, tool_id=None):
        path = self.env.claude_file(S, agent_id=agent_id)
        helpers.write_jsonl(path, records)
        helpers.write_meta(path, "orchestrator-executor", tool_id)

    def test_subagent_marks_never_move_parent(self):
        self._subagent("ax", [
            helpers.claude_assistant(S, _ts(3), request_id="req_ax", agent_id="ax", output=16,
                                     inp=0, cache_write=0,
                                     content=_skill("execute", "toolu_sub")),
            helpers.claude_assistant(S, _ts(4), request_id="req_ay", agent_id="ax", output=32,
                                     inp=0, cache_write=0,
                                     content=_end_block("orchestrate", "toolu_subend"))])
        _, got = self.run_report(
            [_a(1, "req_1", _skill("orchestrate", "t1"), output=1), _a(5, "req_5", output=2)],
            marks=[_mark("start", "orchestrate", 1, "t1"),
                   _mark("start", "execute", 3, "toolu_sub"),
                   _mark("end", "orchestrate", 4, "toolu_subend", source="skill-end")])
        self.assertEqual(got, {"outside-stage": 1, "orchestrate": 50})

    def test_marker_workflow_subagent_uses_first_ts(self):
        _, got = self.run_report([_a(2, "req_2", output=1)], subagents=[("wf", None, 7)],
                                 marks=[_mark("start", "execute", 1)])
        self.assertEqual(got, {"execute": 8})

    def test_mixed_header_counts_both_modes(self):
        helpers.write_jsonl(self.env.claude_file(S2), [helpers.claude_assistant(
            S2, _ts(2), request_id="req_s2", output=3, inp=0, cache_write=0)])
        bindings.add_binding(self.conn, self.cfg, "TT-1", session=S2)
        data, got = self.run_report([_a(2, "req_2", output=5)],
                                    marks=[_mark("start", "execute", 1)])
        self.assertEqual(got, {"execute": 5, "outside-stage": 3})
        self.assertIn("runtime markers for 1 sessions, transcript approximation for 1;",
                      self.header(data))

    def test_same_second_boundary_excludes_emitting_turn(self):
        def at(clock, req, content=None, output=1):
            return _a(0, req, content, ts=f"2026-10-06T10:{clock}Z", output=output)
        _, got = self.run_report(
            [at("02:01.000", "req_7", _skill("plan-feature", "toolu_7"), 1),
             at("02:01.400", "req_7", _skill("plan-feature", "toolu_7"), 1),
             at("02:01.600", "req_8", output=2),
             at("02:02.400", "req_9", _end_block("plan-feature", "toolu_9"), 4),
             at("02:02.600", "req_10", output=8)],
            marks=[_mark("start", "brainstorm", 1, source="hook-prompt"),
                   _mark("start", "plan-feature", ts="2026-10-06T10:02:01.100Z",
                         tool_use_id="toolu_7"),
                   _mark("end", "plan-feature", ts="2026-10-06T10:02:02.100Z",
                         tool_use_id="toolu_9", source="skill-end")])
        self.assertEqual(got, {"brainstorm": 9, "plan-feature": 6})

    def test_header_and_jira_body_scoped_to_report_sessions(self):
        helpers.write_jsonl(self.env.claude_file(S2), [helpers.claude_assistant(
            S2, _ts(2), request_id="req_s2", output=3, inp=0, cache_write=0)])
        bindings.add_binding(self.conn, self.cfg, "TT-2", session=S2)
        data, _ = self.run_report([_a(2, "req_2", output=5)])
        self.assertIn("inferred ends 0, unmatched ends 0", self.header(data))
        before = jira_comment.body(data)
        helpers.write_jsonl(config.runtime_path(), [
            _mark("start", "execute", 1, session=S2),
            _mark("end", "qa-verify", 3, source="skill-end", session=S2)])
        runtime.ingest(self.conn)
        after = report.build(self.conn, self.cfg, "TT-1", by_stage=True)
        self.assertEqual(jira_comment.body(after), before)
        other = report.build(self.conn, self.cfg, "TT-2", by_stage=True)
        self.assertIn("inferred ends 1, unmatched ends 1", self.header(other))

    def test_stage_at(self):
        starts = [{"ts": "2026-10-06T10:00:00.000Z", "turn": "r1", "name": "execute"}]
        self.assertEqual(stages.stage_at(starts, "2026-10-06T10:00:01.000Z", "r1"),
                         "outside-stage")
        self.assertEqual(stages.stage_at(starts, "2026-10-06T10:00:01.000Z", "r2"), "execute")
        self.assertEqual(stages.stage_at(starts, None), "outside-stage")


    def test_dropped_stage_item_fails_independent_report_total(self):
        original = stages.build
        def drop(conn, cfg, items, totals):
            return original(conn, cfg, items[1:], totals)
        with mock.patch.object(stages, "build", side_effect=drop):
            with self.assertRaises(AssertionError):
                self.run_report([_a(1, "req_1"), _a(2, "req_2")])

    def test_per_field_check_catches_equal_total_corruption(self):
        row = dict(provider="codex", input=2, cache_write=0, cache_read=0, output=3)
        totals = dict(input=3, cache_write=0, cache_read=0, output=2, total=5)
        with self.assertRaises(AssertionError):
            stages.build(self.conn, self.cfg, [(row, 1, None)], totals)

    def test_fractional_allocations_match_report_totals(self):
        helpers.write_jsonl(self.env.claude_file(S), [_a(1, "req_1", output=7)])
        self.env.collect()
        bindings.add_binding(self.conn, self.cfg, "TT-1", session=S, share=0.25)
        data = report.build(self.conn, self.cfg, "TT-1", by_stage=True)
        self.assertEqual(data["stages"]["check"]["allocated"], 1.75)


if __name__ == "__main__":
    unittest.main()
