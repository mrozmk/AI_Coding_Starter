"""Bindings: validation, overlap refusal, allocation precedence, team-run window (TT-813)."""
import contextlib
import io
import json
import os
import shutil
import unittest

import bindings
import report
import store
from tests import helpers

W1 = ("2026-10-06T10:00:00Z", "2026-10-06T11:00:00Z")
W2 = ("2026-10-06T11:00:00Z", "2026-10-06T12:00:00Z")
RUN1, RUN2 = "alfa-20261006-093042", "alfa-20261006-120000"
PLANNER = "0a1b2c3d-0000-4000-8000-00000000000a"
CODER = "0a1b2c3d-0000-4000-8000-00000000000b"
CODER2 = "0a1b2c3d-0000-4000-8000-00000000000c"


def usage_row(conn, key, session="s1", provider="claude", ts="2026-10-06T10:30:00.000Z",
              cwd=helpers.PROJ, turn=None, agent_id=""):
    row = {"provider": provider, "response_key": key, "project": "proj", "session": session,
           "agent_id": agent_id, "turn": turn or key, "parent_session": None, "ts": ts,
           "model": "m", "effort": "e", "cwd": cwd, "input": 10, "cache_write": 0,
           "cache_read": 0, "output": 0, "reasoning": 0, "source_kind": "response",
           "occurrence_count": 1}
    store.replace_row(conn, "usage", row)
    return row


class BindingsTest(unittest.TestCase):
    def setUp(self):
        self.env = helpers.TempEnv().__enter__()
        self.conn = self.env.conn()
        self.cfg = self.env.cfg()

    def tearDown(self):
        self.env.__exit__(None, None, None)

    def bind(self, ticket, **kw):
        return bindings.add_binding(self.conn, self.cfg, ticket, **kw)

    def refused(self, ticket, **kw):
        with self.assertRaises(SystemExit) as ctx:
            self.bind(ticket, **kw)
        return ctx.exception.code

    def alloc(self, *rows):
        return bindings.allocate(self.conn, self.conn.execute(
            "SELECT * FROM usage WHERE response_key IN (%s) ORDER BY response_key"
            % ",".join("?" for _ in rows), rows).fetchall())

    def test_shares_residual_and_refusal(self):
        usage_row(self.conn, "r1")
        self.assertEqual(self.bind("TT-1", session="s1", share=0.6)[1], "manual-share")
        self.bind("TT-2", session="s1", share=0.3)
        self.assertEqual(self.refused("TT-3", session="s1", share=0.2), 3)
        a = self.alloc("r1")[0]
        self.assertAlmostEqual(a["unassigned_share"], 0.1)
        self.assertEqual(sorted(b["ticket"] for b in a["bindings"]), ["TT-1", "TT-2"])

    def test_bad_ticket_and_share_refused(self):
        self.assertEqual(self.refused("tt-1", session="s1"), 3)
        self.assertEqual(self.refused("TT-1", session="s1", share=0), 3)
        self.assertEqual(self.refused("TT-1", session="s1", share=1.5), 3)

    def test_window_overlap_refused_adjacent_accepted(self):
        self.bind("TT-1", window=W1, cwd=helpers.PROJ)
        self.assertEqual(self.bind("TT-2", window=W2, cwd=helpers.PROJ)[1], "inferred-window")
        self.assertEqual(self.refused("TT-3", window=("2026-10-06T10:30:00Z",
                                                      "2026-10-06T10:45:00Z"),
                                      cwd=helpers.PROJ), 3)

    def test_disjoint_halves_plus_spanning_window_accepted(self):
        self.bind("TT-1", window=W1, cwd=helpers.PROJ, share=0.5)
        self.bind("TT-2", window=W2, cwd=helpers.PROJ, share=0.5)
        self.bind("TT-3", window=(W1[0], W2[1]), cwd=helpers.PROJ, share=0.5)

    def test_distinct_turns_do_not_add_up(self):
        usage_row(self.conn, "r1", turn="turn_a")
        usage_row(self.conn, "r2", turn="turn_b")
        self.bind("TT-1", turn="turn_a")
        self.bind("TT-2", turn="turn_b")
        self.assertEqual(self.refused("TT-3", session="s1", share=0.1), 3)

    def test_provider_partitions(self):
        self.bind("TT-1", window=W1, cwd=helpers.PROJ, share=0.5, provider="claude")
        self.bind("TT-2", window=W1, cwd=helpers.PROJ, share=0.5, provider="codex")
        self.bind("TT-3", window=W1, cwd=helpers.PROJ, share=0.5)
        self.assertEqual(self.refused("TT-4", window=W1, cwd=helpers.PROJ, share=0.1), 3)

    def test_window_boundaries_use_normalized_timestamps(self):
        self.bind("TT-1", window=W1, cwd=helpers.PROJ)
        usage_row(self.conn, "in", ts="2026-10-06T10:00:00.500Z")
        usage_row(self.conn, "out", ts="2026-10-06T11:00:00.500Z")
        got = {a["row"]["response_key"]: [b["ticket"] for b in a["bindings"]]
               for a in self.alloc("in", "out")}
        self.assertEqual(got, {"in": ["TT-1"], "out": []})

    def test_explicit_beats_window(self):
        usage_row(self.conn, "r1")
        self.bind("TT-1", window=W1, cwd=helpers.PROJ)
        self.bind("TT-2", session="s1")
        a = self.alloc("r1")[0]
        self.assertEqual([(b["ticket"], b["basis"]) for b in a["bindings"]],
                         [("TT-2", "explicit")])

    def test_codex_child_inherits_parent_binding(self):
        store.upsert_session(self.conn, "codex", "child", "", parent_session="parent")
        usage_row(self.conn, "c1", session="child", provider="codex")
        self.bind("TT-1", session="parent")
        self.assertEqual([b["ticket"] for b in self.alloc("c1")[0]["bindings"]], ["TT-1"])

    def test_window_does_not_match_sibling_dir(self):
        self.bind("TT-1", window=W1, cwd=helpers.PROJ)
        usage_row(self.conn, "r1", cwd=helpers.ALFA)
        self.assertEqual(self.alloc("r1")[0]["bindings"], [])

    def _run(self, clone, where, run_id, written_at="2026-10-06T09:40:00Z"):
        run_dir = os.path.join(clone, ".agents", "team", *where, "runs", run_id)
        os.makedirs(run_dir)
        record = {"team": "alfa", "ticket": "TT-805", "run": run_id, "role": "wrapup",
                  "attempt": 1, "seq": 1, "branch": "b", "input_rev": "x", "output_rev": "y",
                  "verdict": "done", "pr_id": 1, "artifacts": [], "evidence": [],
                  "notes": "n", "message": "", "written_at": written_at}
        with open(os.path.join(run_dir, "wrapup-1-1.json"), "w") as fh:
            json.dump(record, fh)
        return run_dir

    def _session_files(self, run_dir, sessions):
        for key, sid in sessions.items():
            with open(os.path.join(run_dir, f"{key}.prompt.md"), "w") as fh:
                fh.write("prompt")
            if sid:
                with open(os.path.join(run_dir, f"{key}.session"), "w") as fh:
                    fh.write(sid.upper() + "\n")

    def _clone_run(self, run_id, sessions):
        clone = os.path.join(self.env.root, "clone")
        self.cfg["projects"]["clone"] = [clone]
        self._session_files(self._run(clone, (), run_id), sessions)
        return clone

    def bind_team(self, ticket, clone, run_id):
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            created, _ = bindings.bind_team_run(self.conn, self.cfg, ticket, clone, run_id)
        return created, err.getvalue()

    def _register_codex(self, thread, parent):
        store.replace_row(self.conn, "registrations", {
            "provider": "codex", "session": thread, "source": "codex-bg",
            "parent_session": parent, "at": "2026-10-06T10:00:00.000Z"})

    def test_team_run_explicit_bindings(self):
        clone = self._clone_run(RUN1, {"planner-1": PLANNER, "coder-1": CODER})
        created, err = self.bind_team("TT-1", clone, RUN1)
        self.assertEqual(err, "")
        self.assertEqual([c[1:] for c in created], [("session", None, "explicit")] * 2
                         + [("window", "codex", "inferred-window")])
        rows = [tuple(r) for r in self.conn.execute(
            "SELECT kind, provider, session, basis, note FROM bindings ORDER BY id")]
        note = "team-run " + RUN1
        self.assertEqual(rows, [("session", None, PLANNER, "explicit", note),
                                ("session", None, CODER, "explicit", note),
                                ("window", "codex", None, "inferred-window", note)])

    def test_team_run_codex_safety_net(self):
        clone = self._clone_run(RUN1, {"planner-1": PLANNER, "coder-1": CODER})
        self.bind_team("TT-1", clone, RUN1)
        self._register_codex("thr-registered", CODER)
        for key, session, provider in (("u", "thr-unregistered", "codex"),
                                       ("r", "thr-registered", "codex"),
                                       ("c", "claude-other", "claude")):
            usage_row(self.conn, key, session=session, provider=provider, cwd=clone)
        got = {a["row"]["response_key"]: ([b["basis"] for b in a["bindings"]], a["conflict"])
               for a in self.alloc("u", "r", "c")}
        self.assertEqual(got, {"u": (["inferred-window"], False), "r": (["explicit"], False),
                               "c": ([], False)})

    def test_team_run_idle_safety_net_not_unknown(self):
        clone = self._clone_run(RUN1, {"planner-1": PLANNER, "coder-1": CODER})
        self.bind_team("TT-1", clone, RUN1)
        usage_row(self.conn, "p", session=PLANNER, cwd=clone)
        usage_row(self.conn, "c", session=CODER, cwd=clone)
        self.assertEqual(report.build(self.conn, self.cfg, "TT-1")["unknown"], [])
        self.conn.execute("DELETE FROM usage")
        kinds = [u["kind"] for u in report.build(self.conn, self.cfg, "TT-1")["unknown"]]
        self.assertEqual(kinds, ["session", "session", "window"])

    def test_team_run_incomplete_or_empty_uses_window(self):
        for sessions, why in (({"planner-1": PLANNER, "coder-1": None},
                               "coder-1 has no session file"), ({}, "no session files")):
            with self.subTest(why=why):
                self.conn.execute("DELETE FROM bindings")
                clone = self._clone_run(RUN1, sessions)
                created, err = self.bind_team("TT-1", clone, RUN1)
                self.assertIn(why, err)
                self.assertEqual([c[1:] for c in created],
                                 [("window", None, "inferred-window")])
                self.assertIsNone(self.conn.execute("SELECT provider FROM bindings").fetchone()[0])
                shutil.rmtree(clone)

    def test_explicit_run_closes_previous_window(self):
        clone = self._clone_run(RUN1, {})
        self.bind_team("TT-1", clone, RUN1)
        self._session_files(self._run(clone, (), RUN2), {"coder-1": CODER})
        self.bind_team("TT-2", clone, RUN2)
        ends = [r[0] for r in self.conn.execute("SELECT win_to FROM bindings WHERE kind ="
                                                " 'window' ORDER BY id")]
        self.assertEqual(ends, ["2026-10-06T12:00:00.000Z", "9999-12-31T00:00:00.000Z"])

    def test_refused_batch_leaves_nothing(self):
        clone = self._clone_run(RUN1, {})
        self.bind_team("TT-1", clone, RUN1)
        self.bind("TT-9", session=CODER2)
        self._session_files(self._run(clone, (), RUN2), {"coder-1": CODER, "coder-2": CODER2})
        with self.assertRaises(SystemExit) as ctx:
            self.bind_team("TT-2", clone, RUN2)
        self.assertEqual(ctx.exception.code, 3)
        rows = [tuple(r) for r in self.conn.execute("SELECT ticket, win_to FROM bindings")]
        self.assertEqual(rows, [("TT-1", "9999-12-31T00:00:00.000Z"), ("TT-9", None)])

    def test_registered_codex_parent_links_lineage(self):
        self._register_codex("thr", CODER)
        store.upsert_session(self.conn, "codex", "thr", "")
        store.upsert_session(self.conn, "codex", "thr-child", "", parent_session="thr")
        usage_row(self.conn, "t", session="thr", provider="codex")
        usage_row(self.conn, "tc", session="thr-child", provider="codex")
        self.bind("TT-1", session=CODER)
        self.assertEqual([[b["ticket"] for b in a["bindings"]] for a in self.alloc("t", "tc")],
                         [["TT-1"], ["TT-1"]])

    def test_rollout_parent_beats_registered_parent(self):
        store.upsert_session(self.conn, "codex", "thr", "", parent_session="rollout-parent")
        self._register_codex("thr", CODER)
        usage_row(self.conn, "t", session="thr", provider="codex")
        self.bind("TT-1", session=CODER)
        self.assertEqual(self.alloc("t")[0]["bindings"], [])

    def test_team_run_window(self):
        clone = os.path.join(self.env.root, "clone")
        self._run(clone, ("archive", "TT-805-20261006T100000Z"), "alfa-20261006-093042")
        start, end, got_clone, ticket, _ = bindings.team_run_window(clone,
                                                                    "alfa-20261006-093042")
        self.assertEqual((start, end, got_clone, ticket),
                         ("2026-10-06T09:30:42.000Z", "9999-12-31T00:00:00.000Z", clone,
                          "TT-805"))
        self._run(clone, (), "alfa-20261006-120000")
        self.assertEqual(bindings.team_run_window(clone, "alfa-20261006-093042")[1],
                         "2026-10-06T12:00:00.000Z")
        tail = "2026-10-06T09:40:08.000Z"
        self.assertTrue(start <= tail < end)
        with self.assertRaises(SystemExit):
            bindings.team_run_window(clone, "alfa-20261006-999999")

    def bind_run(self, ticket, clone, run_id):
        start, end, clone, _, _ = bindings.team_run_window(clone, run_id)
        return self.bind(ticket, window=(start, end), cwd=clone, team_run=run_id)

    def test_next_team_run_closes_open_window(self):
        clone = os.path.join(self.env.root, "clone")
        self.cfg["projects"]["clone"] = [clone]
        self._run(clone, (), "alfa-20261006-093042")
        self.bind_run("TT-1", clone, "alfa-20261006-093042")
        self._run(clone, (), "alfa-20261006-120000")
        self.bind_run("TT-2", clone, "alfa-20261006-120000")
        ends = [r[0] for r in self.conn.execute("SELECT win_to FROM bindings ORDER BY id")]
        self.assertEqual(ends, ["2026-10-06T12:00:00.000Z", "9999-12-31T00:00:00.000Z"])
        usage_row(self.conn, "late", cwd=clone, ts="2026-10-06T13:00:00.000Z")
        self.assertEqual([b["ticket"] for b in self.alloc("late")[0]["bindings"]], ["TT-2"])

    def test_team_run_keeps_manual_open_window(self):
        clone = os.path.join(self.env.root, "clone")
        self.cfg["projects"]["clone"] = [clone]
        self.bind("TT-1", window=("2026-10-06T08:00:00Z", "9999-12-31T00:00:00Z"), cwd=clone,
                  share=0.5)
        self._run(clone, (), "alfa-20261006-120000")
        start, end, clone, _, _ = bindings.team_run_window(clone, "alfa-20261006-120000")
        self.bind("TT-2", window=(start, end), cwd=clone, share=0.5,
                  team_run="alfa-20261006-120000")
        self.assertEqual(self.conn.execute("SELECT win_to FROM bindings WHERE id = 1"
                                           ).fetchone()[0], "9999-12-31T00:00:00.000Z")


    def test_lineage_overlap_refused_in_both_orders(self):
        for first, second in (("parent", "child"), ("child", "parent")):
            with self.subTest(first=first):
                self.conn.execute("DELETE FROM bindings")
                store.upsert_session(self.conn, "codex", "child", "", parent_session="parent")
                usage_row(self.conn, "r-child", session="child", provider="codex")
                self.bind("TT-1", session=first, share=0.6, provider="codex")
                self.assertEqual(self.refused("TT-2", session=second, share=0.6,
                                             provider="codex"), 3)
                self.bind("TT-2", session=second, share=0.4, provider="codex")
                self.assertFalse(self.alloc("r-child")[0]["conflict"])

    def test_turn_response_aliases_refused_in_both_orders(self):
        usage_row(self.conn, "response-1", provider="codex", turn="turn-1")
        for first, second in (("turn-1", "response-1"), ("response-1", "turn-1")):
            with self.subTest(first=first):
                self.conn.execute("DELETE FROM bindings")
                self.bind("TT-1", turn=first, share=0.6)
                self.assertEqual(self.refused("TT-2", turn=second, share=0.5), 3)
                self.assertEqual(self.conn.execute("SELECT COUNT(*) FROM bindings").fetchone()[0],
                                 1)

    def test_uncollected_lineage_and_distinct_siblings(self):
        store.upsert_session(self.conn, "codex", "child", "", parent_session="parent")
        store.upsert_session(self.conn, "codex", "sibling", "", parent_session="parent")
        self.bind("TT-1", session="child", provider="codex")
        self.bind("TT-2", session="sibling", provider="codex")
        self.assertEqual(self.refused("TT-3", session="parent", provider="codex"), 3)
        self.bind("TT-3", session="parent", provider="claude")

    def test_nested_window_overlap_uses_same_path_boundary(self):
        nested = helpers.PROJ + "/sub"
        self.cfg["projects"]["nested"] = [nested]
        self.bind("TT-1", window=W1, cwd=helpers.PROJ, share=0.6)
        self.assertEqual(self.refused("TT-2", window=W1, cwd=nested, share=0.5), 3)
        self.bind("TT-2", window=W1, cwd=nested, share=0.4)
        usage_row(self.conn, "nested", cwd=nested)
        self.assertFalse(self.alloc("nested")[0]["conflict"])


if __name__ == "__main__":
    unittest.main()
