"""Summary: period, scope, tickets, Codex roles, supervisor context, low cache, CLI (TT-980)."""
import contextlib
import io
import unittest
from datetime import date

import bindings
import config
import cost
import summary
from tests import helpers

BETA = "/work/proj-beta"
S = "0a1b2c3d-0000-4000-8000-0000000000a1"
S2 = "1a1b2c3d-0000-4000-8000-0000000000a2"
S3 = "2a1b2c3d-0000-4000-8000-0000000000a3"
CO = "3a1b2c3d-0000-4000-8000-0000000000c0"
QA = "4a1b2c3d-0000-4000-8000-0000000000c1"
TP = "5a1b2c3d-0000-4000-8000-0000000000d0"
TC = "6a1b2c3d-0000-4000-8000-0000000000d1"
D1, D3 = date(2026, 10, 6), date(2026, 10, 8)


def _a(session, ts, req, **kw):
    return helpers.claude_assistant(session, ts, request_id=req, **kw)


def _reg(session, at, provider="claude", **extra):
    return dict({"v": 1, "type": "session", "provider": provider, "session": session, "at": at},
                **extra)


def _team_run(session, role, at):
    return _reg(session, at, source="team-run", team="alfa", role=role,
                run="alfa-20261006-090000", cwd=helpers.ALFA)


def _codex(env, name, thread, ts, cwd=helpers.PROJ, inp=100, cached=40, output=7, parent=None,
           meta_ts=None):
    helpers.write_jsonl(env.codex_file(name), [
        helpers.codex_meta(thread, meta_ts or ts, cwd=cwd, parent=parent),
        helpers.codex_turn(f"turn-{name}", ts, cwd=cwd),
        helpers.codex_usage(thread, f"turn-{name}", f"resp-{name}", ts, inp=inp, cached=cached,
                            output=output)])


def run(*argv):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = cost.main(list(argv))
    return code, out.getvalue()


class SummaryTest(unittest.TestCase):
    def setUp(self):
        self.env = helpers.TempEnv(dirs=(helpers.PROJ, helpers.ALFA, BETA)).__enter__()
        self.conn = self.env.conn()
        self.cfg = self.env.cfg()

    def tearDown(self):
        self.env.__exit__(None, None, None)

    def build(self, since=D1, until=D3):
        return summary.build(self.conn, self.cfg, since, until)

    def runtime(self, records):
        helpers.write_jsonl(config.runtime_path(), records)

    def test_period_boundaries_are_inclusive_utc_days(self):
        helpers.write_jsonl(self.env.claude_file(S), [
            _a(S, "2026-10-05T23:59:59Z", "r0"), _a(S, "2026-10-06T00:00:00Z", "r1"),
            _a(S, "2026-10-08T23:59:59Z", "r2"), _a(S, "2026-10-09T00:00:00Z", "r3")])
        self.env.collect()
        data = self.build()
        self.assertEqual([d for d, _ in data["days"]], ["2026-10-06", "2026-10-08"])
        self.assertEqual(sum(a["calls"] for a in data["totals"].values()), 2)

    def test_scope_and_metrics(self):
        helpers.write_jsonl(self.env.claude_file(S), [_a(
            S, "2026-10-06T10:00:00Z", "r1", inp=10, cache_write=20, cache_read=70, output=5)])
        helpers.write_jsonl(self.env.claude_file(S2, cwd=helpers.ALFA), [_a(
            S2, "2026-10-06T10:00:00Z", "r2", inp=1, cache_write=0, cache_read=9, output=2,
            cwd=helpers.ALFA)])
        _codex(self.env, "sup", "thread-sup", "2026-10-06T11:00:00Z")
        _codex(self.env, "team", "thread-team", "2026-10-06T11:00:00Z", cwd=helpers.ALFA,
               inp=50, cached=0, output=1)
        self.env.collect()
        totals = self.build()["totals"]
        sup, team = totals[("claude", "supervisor")], totals[("claude", "team")]
        self.assertEqual((summary.total(sup), summary.full(sup), summary.hit(sup)),
                         (105, 35, 0.7))
        self.assertEqual((summary.total(team), summary.full(team), summary.hit(team),
                          team["output"]), (12, 3, 0.9, 2))
        codex = totals[("codex", "supervisor")]
        self.assertEqual((codex["input"], codex["cache_read"], summary.total(codex),
                          summary.full(codex)), (60, 40, 107, 67))
        self.assertEqual(summary.total(totals[("codex", "team")]), 51)
        md = summary.render_md(self.build())
        self.assertIn("| Claude supervisor | 105 | 35 | 70.0% | 5 |", md)
        self.assertIn("| **Razem** | 275 | 156 |", md)

    def test_ticket_shares_clones_and_conflicts(self):
        bindings.add_binding(self.conn, self.cfg, "TT-1", session=S, share=0.5)
        bindings.add_binding(self.conn, self.cfg, "TT-2", session=S, share=0.5)
        bindings.add_binding(self.conn, self.cfg, "TT-3", session=S2)
        bindings.add_binding(self.conn, self.cfg, "TT-4", session=S3, share=0.6)
        bindings.add_binding(self.conn, self.cfg, "TT-4", turn="r9", share=0.6)
        helpers.write_jsonl(self.env.claude_file(S, cwd=helpers.ALFA), [_a(
            S, "2026-10-06T10:00:00Z", "r1", inp=100, cache_write=0, output=0, cwd=helpers.ALFA)])
        helpers.write_jsonl(self.env.claude_file(S2, cwd=helpers.ALFA), [
            _a(S2, "2026-10-06T10:00:00Z", "r2", cwd=helpers.ALFA),
            _a(S2, "2026-10-06T10:05:00Z", "r3", cwd=BETA)])
        helpers.write_jsonl(self.env.claude_file(S3), [_a(
            S3, "2026-10-06T10:00:00Z", "r9", inp=1000, cache_write=0, output=0)])
        self.env.collect()
        data = self.build()
        tickets = {t["ticket"]: t for t in data["tickets"]}
        self.assertEqual(set(tickets), {"TT-1", "TT-2", "TT-3"})
        self.assertEqual(summary.total(tickets["TT-1"]["claude"]), 50)
        self.assertEqual(summary.total(tickets["TT-2"]["claude"]), 50)
        self.assertEqual(tickets["TT-3"]["clones"], 2)
        self.assertIn("⚠ 2 klony", summary.render_md(data))
        self.assertAlmostEqual(data["coverage"]["unassigned_pct"], 1000 / (100 + 224 + 1000))

    def test_codex_role_follows_lineage_before_time(self):
        self.runtime([_team_run(CO, "coder", "2026-10-06T10:00:00.000Z"),
                      _team_run(QA, "qa", "2026-10-06T10:30:00.000Z"),
                      _reg(TP, "2026-10-06T10:05:00.000Z", provider="codex", source="codex-bg",
                           parent_session=CO)])
        _codex(self.env, "p", TP, "2026-10-06T10:10:00Z", cwd=helpers.ALFA)
        _codex(self.env, "c", TC, "2026-10-06T11:00:00Z", cwd=helpers.ALFA, parent=TP)
        self.env.collect()
        roles = dict(self.build()["roles"])
        self.assertEqual(set(roles), {"coder"})
        self.assertEqual(roles["coder"]["codex"]["calls"], 2)

    def test_codex_inferred_role_uses_own_first_usage(self):
        self.runtime([_team_run(CO, "coder", "2026-10-06T10:00:00.000Z"),
                      _team_run(QA, "qa", "2026-10-06T10:30:00.000Z")])
        # The 09:00 header stands in for replayed history: it lowers sessions.first_ts only.
        _codex(self.env, "u", TC, "2026-10-06T11:00:00Z", cwd=helpers.ALFA,
               meta_ts="2026-10-06T09:00:00Z")
        _codex(self.env, "early", TP, "2026-10-06T09:30:00Z", cwd=helpers.ALFA)
        self.env.collect()
        first = self.conn.execute("SELECT first_ts FROM sessions WHERE session = ?",
                                  (TC,)).fetchone()[0]
        self.assertEqual(first, "2026-10-06T09:00:00.000Z")
        roles = dict(self.build()["roles"])
        self.assertEqual(roles["qa (inferred)"]["codex"]["calls"], 1)
        self.assertEqual(roles["-"]["codex"]["calls"], 1)

    def test_supervisor_average_context_counts_main_thread_only(self):
        records = [_a(S, "2026-10-06T10:00:00Z", "main", inp=0, cache_write=0,
                      cache_read=100000, output=10)]
        helpers.write_jsonl(self.env.claude_file(S), records)
        sub = self.env.claude_file(S, agent_id="a1")
        helpers.write_jsonl(sub, [_a(S, f"2026-10-06T10:{i + 1:02d}:00Z", f"sub{i}", inp=0,
                                     cache_write=0, cache_read=100000, output=1, agent_id="a1")
                                  for i in range(10)])
        helpers.write_meta(sub, "code-reviewer", "toolu_1")
        self.env.collect()
        [row] = self.build()["supervisor"]
        self.assertEqual((row["avg_context"], row["calls"]), (100000, 1))
        self.assertEqual(summary.total(row["agg"]), 1_100_020)
        self.assertEqual(row["duration"], "0:10")
        self.assertIn("| 100 k | 1 | 0:10 |", summary.render_md(self.build()))

    def test_low_cache_threshold_and_order(self):
        for session, inp, read in ((S, 200_000, 900_000), (S2, 600_000, 500_000),
                                   (S3, 10, 0)):
            helpers.write_jsonl(self.env.claude_file(session), [_a(
                session, "2026-10-06T10:00:00Z", f"r-{session[:2]}", inp=inp, cache_write=0,
                cache_read=read, output=0)])
        self.env.collect()
        low = self.build()["low_cache"]
        self.assertEqual([name for name, _, _ in low], [f"claude:{S2[:8]}", f"claude:{S[:8]}"])
        self.assertIn(f"Razem ≥ {summary._fmt(summary.LOW_CACHE_MIN_TOTAL)}",
                      summary.render_md(self.build()))

    def test_empty_period_prints_no_data(self):
        self.env.collect()
        data = self.build()
        self.assertTrue(data["empty"])
        self.assertIn("no data", summary.render_md(data))
        code, out = run("summary", "--since", "2026-10-06", "--until", "2026-10-08")
        self.assertEqual(code, 0)
        self.assertIn("no data", out)
        self.assertIn("2026-10-06..2026-10-08 (UTC)", out)


class SummaryCliTest(unittest.TestCase):
    def test_exit_codes(self):
        with helpers.TempEnv():
            self.assertEqual(run("summary")[0], 4)
            for argv in (["--since", "2026-13-01"], ["--days", "0"],
                         ["--since", "2026-10-11", "--until", "2026-10-06"],
                         ["--until", "2026-10-06"], ["--days", "3", "--since", "2026-10-01"],
                         ["--since", "2026-10-1"]):
                self.assertEqual(run("summary", *argv)[0], 2, argv)
            self.assertEqual(run("collect")[0], 0)
            self.assertEqual(run("summary", "--days", "7")[0], 0)


if __name__ == "__main__":
    unittest.main()
