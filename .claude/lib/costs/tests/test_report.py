"""Report: rollup, sub-agents, lineage, coverage, unknown, conflicts, reconciliation (TT-813)."""
import unittest

import bindings
import report
import store
from tests import helpers

S = "sess-main-aaaa"
U = "0a1b2c3d-0000-4000-8000-0000000000cc"
T, C = "thread-parent-1", "thread-child-22"


def _a(ts, req, output=10, session=S, **kw):
    return helpers.claude_assistant(session, ts, request_id=req, output=output, **kw)


class ReportTest(unittest.TestCase):
    def setUp(self):
        self.env = helpers.TempEnv().__enter__()
        self.conn = self.env.conn()
        self.cfg = self.env.cfg()

    def tearDown(self):
        self.env.__exit__(None, None, None)

    def bind(self, ticket, **kw):
        return bindings.add_binding(self.conn, self.cfg, ticket, **kw)[0]

    def build(self, ticket="TT-1", children=()):
        return report.build(self.conn, self.cfg, ticket, children)

    def main_session(self, records=None):
        helpers.write_jsonl(self.env.claude_file(S), records or [
            helpers.claude_agent_name(S, "alfa-coder"),
            _a("2026-10-06T10:00:00Z", "req_1", output=10, inp=1, cache_write=0)])

    def test_epic_rollup_counts_split_row_once(self):
        self.main_session()
        self.env.collect()
        self.bind("TT-1", session=S, share=0.5)
        self.bind("TT-2", session=S, share=0.5)
        data = self.build("TT-1", ["TT-2"])
        self.assertEqual(data["totals"]["total"], 11)
        self.assertEqual({r["ticket"] for r in data["rows"]}, {"TT-1", "TT-2"})
        self.assertEqual(self.build("TT-1")["totals"]["total"], 5.5)

    def test_subagent_tokens_only_on_subagent_row(self):
        self.main_session()
        sub = self.env.claude_file(S, agent_id="a1")
        helpers.write_jsonl(sub, [_a("2026-10-06T10:01:00Z", "req_s", output=100, inp=0,
                                     cache_write=0, agent_id="a1")])
        helpers.write_meta(sub, "structure-reviewer", "toolu_1")
        self.env.collect()
        self.bind("TT-1", session=S)
        rows = {r["agent"]: r["total"] for r in self.build()["rows"]}
        self.assertEqual(rows, {"alfa-coder": 11, "alfa-coder/structure-reviewer": 100})
        roles = {(r["team"], r["role"]) for r in self.build()["rows"]}
        self.assertEqual(roles, {("alfa", "coder")})

    def _register(self, session, **fields):
        store.replace_row(self.conn, "registrations", dict(
            {"provider": "claude", "session": session, "at": "2026-10-06T10:00:00.000Z"},
            **fields))

    def test_registry_fills_role_and_name(self):
        self.main_session([_a("2026-10-06T10:00:00Z", "req_1", inp=1, cache_write=0)])
        helpers.write_jsonl(self.env.claude_file(U), [
            _a("2026-10-06T10:01:00Z", "req_2", session=U, inp=1, cache_write=0)])
        self.env.collect()
        self._register(S, source="team-run", name="x", team="beta", role="qa")
        self._register(U, source="mail-tt", name="OpusTT")
        self.bind("TT-1", session=S)
        self.bind("TT-1", session=U)
        rows = {r["agent"]: (r["team"], r["role"]) for r in self.build()["rows"]}
        self.assertEqual(rows, {"x": ("beta", "qa"), "OpusTT": (None, None)})

    def test_codex_child_allocated_via_parent_and_separate_thread_rows(self):
        helpers.write_jsonl(self.env.codex_file("p"), [
            helpers.codex_meta(T, "2026-10-06T10:00:00Z"),
            helpers.codex_turn("t1", "2026-10-06T10:00:01Z"),
            helpers.codex_usage(T, "t1", "resp_1", "2026-10-06T10:00:02Z")])
        helpers.write_jsonl(self.env.codex_file("c"), [
            helpers.codex_meta(C, "2026-10-06T10:01:00Z", parent=T),
            helpers.codex_turn("t2", "2026-10-06T10:01:01Z"),
            helpers.codex_usage(C, "t2", "resp_2", "2026-10-06T10:01:02Z")])
        self.env.collect()
        self.bind("TT-1", session=T, provider="codex")
        rows = self.build()["rows"]
        self.assertEqual(sorted(r["agent"] for r in rows),
                         ["codex:exec:thread-c", "codex:exec:thread-p"])
        self.assertEqual(rows[0]["total"], rows[1]["total"])

    def test_partial_coverage_propagates(self):
        self.main_session([_a("2026-10-06T10:00:00Z", "req_1"),
                           _a("2026-10-06T10:00:01Z", "req_2", usage=False)])
        self.env.collect()
        self.bind("TT-1", session=S)
        data = self.build()
        self.assertEqual([r["coverage"] for r in data["rows"]], ["partial"])
        self.assertEqual(data["header"]["coverage"], {"observed": 0, "partial": 1})

    def test_unknown_binding(self):
        bid = self.bind("TT-1", session="never-collected")
        self.assertEqual([u["id"] for u in self.build()["unknown"]], [bid])

    def test_fully_conflicted_session_listed_not_unknown(self):
        turn_id = self.bind("TT-1", turn="req_1", share=0.6)
        session_id = self.bind("TT-1", session=S, share=0.6)
        self.main_session()
        self.env.collect()
        data = self.build()
        self.assertEqual(data["totals"]["total"], 0)
        self.assertEqual(data["unknown"], [])
        self.assertEqual(len(data["conflicts"]), 1)
        self.assertEqual(data["conflicts"][0]["ids"], [turn_id, session_id])
        self.assertEqual(sum(data["conflicts"][0][k] for k in bindings.TOKENS), 11)

    def test_reconciliation_listed_totals_unchanged(self):
        helpers.write_jsonl(self.env.codex_file("p"), [
            helpers.codex_meta(T, "2026-10-06T10:00:00Z"),
            helpers.codex_usage(T, "t1", "resp_1", "2026-10-06T10:00:02Z", inp=100,
                                cached=0, output=10, thread_total={
                                    "input_tokens": 150, "cached_input_tokens": 0,
                                    "output_tokens": 10})])
        self.env.collect()
        self.bind("TT-1", session=T)
        data = self.build()
        self.assertEqual(data["reconciliation"], [{"session": T, "field": "input_tokens",
                                                   "provider": 150, "ingested": 100}])
        self.assertEqual(data["totals"]["total"], 110)

    def test_header_and_model_switch(self):
        self.main_session([_a("2026-10-06T10:00:00Z", "req_1"),
                           _a("2026-10-06T10:05:00Z", "req_2", model="claude-sonnet-5-5")])
        self.env.collect()
        self.bind("TT-1", session=S)
        data = self.build()
        self.assertEqual(sorted(r["model"] for r in data["rows"]),
                         ["claude-opus-5-5", "claude-sonnet-5-5"])
        header = data["header"]
        self.assertEqual(header["as_of"], "2026-10-06T10:05:00.000Z")
        self.assertIn("schema v2", header["revision"])
        self.assertIsNotNone(header["last_collect_at"])
        md = report.render_md(data)
        self.assertIn("As of: 2026-10-06T10:05:00.000Z", md)
        self.assertIn("Coverage:", md)
        self.assertIn("**Total**", md)
        lines = md.splitlines()
        head = next(x for x in lines if x.startswith("| Provider"))
        total = next(x for x in lines if x.startswith("| **Total**"))
        self.assertEqual(total.count("|"), head.count("|"))
        self.assertTrue(total.endswith(f"| {round(data['totals']['total'])} |"))


    def test_fallback_child_reconciles_after_replay_baseline(self):
        helpers.write_jsonl(self.env.codex_file("c"), [
            helpers.codex_meta(C, "2026-10-06T10:00:00Z", parent=T, start=2),
            helpers.codex_token_count("2026-10-06T10:00:01Z", 100, cached=30, output=10,
                                      ordinal=1),
            helpers.codex_token_count("2026-10-06T10:00:02Z", 150, cached=40, output=15,
                                      ordinal=2)])
        self.env.collect()
        self.bind("TT-1", session=C)
        data = self.build()
        self.assertEqual(data["reconciliation"], [])
        self.assertEqual(data["totals"]["total"], 55)
        self.conn.execute("UPDATE usage SET output = output + 1 WHERE session = ?", (C,))
        self.assertEqual(self.build()["reconciliation"], [{"session": C,
                         "field": "output_tokens", "provider": 5, "ingested": 6}])


if __name__ == "__main__":
    unittest.main()
