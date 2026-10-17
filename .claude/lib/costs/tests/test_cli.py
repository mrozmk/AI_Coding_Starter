"""CLI: exit codes, JSON shape, full collect → bind → report flow (spec TT-813)."""
import contextlib
import io
import json
import os
import unittest

import config
import cost
from tests import helpers

P, CO = "sess-planner-01", "sess-coder-0001"
U = "00000000-0000-4000-8000-000000000001"
U2 = "00000000-0000-4000-8000-000000000002"
RUN = "beta-20261006-125347"


def run(*argv):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = cost.main(list(argv))
    return code, out.getvalue()


class CliTest(unittest.TestCase):
    def test_exit_codes(self):
        with helpers.TempEnv() as env:
            self.assertEqual(run("report", "TT-1")[0], 4)
            self.assertEqual(run("unassigned", "--since", "2026-10-06")[0], 4)
            self.assertEqual(run("collect")[0], 0)
            self.assertEqual(run("bind", "TT-1", "--session", U, "--share", "2")[0], 3)
            self.assertEqual(run("bind", "TT-1", "--session", U)[0], 0)
            self.assertEqual(run("bind", "TT-2", "--session", U)[0], 3)
            self.assertEqual(run("bind", "TT-2", "--window", "2026-10-06", "2026-10-07")[0], 2)
            self.assertEqual(run("bind", "TT-2")[0], 2)
            os.remove(os.path.join(env.root, "config.json"))
            self.assertEqual(run("collect")[0], 2)

    def _fixture(self, env):
        helpers.write_jsonl(env.claude_file(P, cwd=helpers.ALFA), [
            helpers.claude_agent_name(P, "alfa-planner"),
            helpers.claude_assistant(P, "2026-10-06T10:00:00Z", "req_p", cwd=helpers.ALFA)])
        helpers.write_jsonl(env.claude_file(CO, cwd=helpers.ALFA), [
            helpers.claude_agent_name(CO, "alfa-coder"),
            helpers.claude_assistant(CO, "2026-10-06T11:00:00Z", "req_c", cwd=helpers.ALFA,
                                     content=[helpers.agent_block("code-reviewer", "toolu_1")])])
        sub = env.claude_file(CO, cwd=helpers.ALFA, agent_id="a1")
        helpers.write_jsonl(sub, [helpers.claude_assistant(
            CO, "2026-10-06T11:01:00Z", "req_s", cwd=helpers.ALFA, agent_id="a1")])
        helpers.write_meta(sub, "code-reviewer", "toolu_1")
        helpers.write_jsonl(env.codex_file("x"), [
            helpers.codex_meta("thread-exec-1", "2026-10-06T11:02:00Z", cwd=helpers.ALFA),
            helpers.codex_turn("t1", "2026-10-06T11:02:01Z", cwd=helpers.ALFA),
            helpers.codex_usage("thread-exec-1", "t1", "resp_1", "2026-10-06T11:02:02Z")])

    def test_full_flow_and_json_shape(self):
        with helpers.TempEnv() as env:
            self._fixture(env)
            self.assertEqual(run("collect")[0], 0)
            code, out = run("bind", "TT-805", "--window", "2026-10-06T09:00:00Z",
                            "2026-10-06T12:00:00Z", "--cwd", helpers.ALFA)
            self.assertEqual(code, 0)
            self.assertIn("basis=inferred-window", out)
            code, out = run("report", "TT-805", "--format", "json", "--by-stage")
            self.assertEqual(code, 0)
            data = json.loads(out)
            for key in ("header", "rows", "totals", "unassigned", "conflicts", "unknown",
                        "reconciliation"):
                self.assertIn(key, data)
            agents = {r["agent"]: r for r in data["rows"]}
            self.assertEqual({r["role"] for r in data["rows"] if r["provider"] == "claude"},
                             {"planner", "coder"})
            self.assertIn("alfa-coder/code-reviewer", agents)
            codex = [r for r in data["rows"] if r["provider"] == "codex"]
            self.assertEqual([r["basis"] for r in codex], ["inferred-window"])
            code, md = run("report", "TT-805", "--by-stage")
            self.assertIn("| codex |", md)
            code, out = run("unassigned", "--since", "2026-10-06")
            self.assertEqual(code, 0)

    def _team_run(self, env, sessions=None):
        clone = os.path.join(env.root, "clone")
        run_dir = os.path.join(clone, ".agents", "team", "runs", RUN)
        os.makedirs(run_dir)
        with open(os.path.join(run_dir, "coder-1-1.json"), "w") as fh:
            json.dump({"ticket": "TT-797", "written_at": "2026-10-06T13:00:00Z"}, fh)
        for key, sid in (sessions or {}).items():
            for suffix, text in ((".prompt.md", "p"), (".session", sid)):
                with open(os.path.join(run_dir, key + suffix), "w") as fh:
                    fh.write(text)
        env.write_config([clone])
        return clone

    def test_bind_team_run(self):
        with helpers.TempEnv() as env:
            clone = self._team_run(env)
            run("collect")
            code, out = run("bind", "TT-813", "--team-run", clone, RUN)
            self.assertEqual(code, 0)
            self.assertIn("window share=1 basis=inferred-window", out)

    def test_bind_team_run_explicit(self):
        with helpers.TempEnv() as env:
            clone = self._team_run(env, {"planner-1": U, "coder-1": U2})
            run("collect")
            self.assertEqual(run("bind", "TT-813", "--team-run", clone, RUN, "--share",
                                 "0.5")[0], 2)
            code, out = run("bind", "TT-813", "--team-run", clone, RUN)
            self.assertEqual(code, 0)
            lines = out.splitlines()
            self.assertEqual(len(lines), 3)
            self.assertEqual(sum("session share=1 basis=explicit" in ln for ln in lines), 2)
            self.assertIn("window provider=codex share=1 basis=inferred-window", lines[2])

    def test_bind_session_by_registered_name(self):
        with helpers.TempEnv():
            helpers.write_jsonl(config.runtime_path(), [
                {"v": 1, "type": "session", "provider": "claude", "session": U,
                 "source": "mail-tt", "name": "OpusTT", "at": "2026-10-06T10:00:00.000Z"},
                {"v": 1, "type": "session", "provider": "claude", "session": U2,
                 "source": "mail-tt", "name": "Twin", "at": "2026-10-06T10:00:00.000Z"},
                {"v": 1, "type": "session", "provider": "claude", "session": U,
                 "source": "start-team", "name": "Twin", "at": "2026-10-06T10:00:00.000Z"}])
            run("collect")
            code, out = run("bind", "TT-1", "--session", "OpusTT")
            self.assertEqual(code, 0)
            self.assertIn("session share=1 basis=explicit", out)
            self.assertEqual(run("bind", "TT-2", "--session", "Twin")[0], 2)
            self.assertEqual(run("bind", "TT-2", "--session", "Nobody")[0], 2)

    def test_report_jira_formats(self):
        with helpers.TempEnv() as env:
            self._fixture(env)
            run("collect")
            run("bind", "TT-805", "--window", "2026-10-06T09:00:00Z", "2026-10-06T12:00:00Z",
                "--cwd", helpers.ALFA)
            code, out = run("report", "TT-805", "--format", "jira")
            self.assertEqual((code, out.splitlines()[0]), (0, "token-usage-report: TT-805"))
            comments = os.path.join(env.root, "comments.json")
            with open(comments, "w") as fh:
                json.dump({"comments": [{"id": "7", "body": out}]}, fh)
            code, out = run("report", "TT-805", "--jira-action", comments)
            self.assertEqual(code, 0)
            self.assertEqual(json.loads(out)["action"], "edit")
            self.assertEqual(run("report", "TT-805", "--jira-action", comments, "--format",
                                 "json")[0], 2)
            code, out = run("report", "TT-805")
            self.assertTrue(out.startswith("## Token usage — TT-805"))


    def test_zoneless_window_clock_is_usage_error(self):
        with helpers.TempEnv():
            run("collect")
            self.assertEqual(run("bind", "TT-1", "--window", "2026-10-06T10:00:00",
                                 "2026-10-06T11:00:00Z", "--cwd", helpers.PROJ)[0], 2)
            self.assertEqual(run("unassigned", "--since", "2026-10-06T10:00:00")[0], 2)


if __name__ == "__main__":
    unittest.main()
