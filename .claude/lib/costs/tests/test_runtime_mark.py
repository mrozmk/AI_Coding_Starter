"""runtime-mark.sh + stage-mark.sh: validation, opt-in, sub-agent drop, anchored end (TT-821)."""
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[4]
MARK = REPO / ".claude" / "lib" / "costs" / "runtime-mark.sh"
HOOK = REPO / ".claude" / "hooks" / "stage-mark.sh"
SID = "0a1b2c3d-0000-4000-8000-000000000001"
ENV_SID = "0a1b2c3d-0000-4000-8000-000000000002"


class RuntimeMarkTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        assert MARK.is_file(), MARK
        assert HOOK.is_file(), HOOK

    def setUp(self):
        self.home = tempfile.mkdtemp(prefix="runtime-mark-")
        self.log = os.path.join(self.home, "runtime.jsonl")

    def tearDown(self):
        shutil.rmtree(self.home, ignore_errors=True)

    def env(self, **extra):
        env = {k: v for k, v in os.environ.items() if k != "CLAUDE_CODE_SESSION_ID"}
        env["AGENT_COSTS_HOME"] = self.home
        env.update(extra)
        return env

    def run_sh(self, script, args=(), payload=None, **extra):
        proc = subprocess.run(["bash", str(script), *args], env=self.env(**extra),
                              input=payload, capture_output=True, text=True, check=False)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout, "")
        return proc

    def mark(self, *args, **extra):
        return self.run_sh(MARK, args, **extra)

    def hook(self, payload):
        text = payload if isinstance(payload, str) else json.dumps(payload)
        return self.run_sh(HOOK, payload=text)

    def lines(self):
        if not os.path.exists(self.log):
            return []
        with open(self.log, encoding="utf-8") as fh:
            return [json.loads(ln) for ln in fh if ln.strip()]

    def test_session_with_all_fields(self):
        self.mark("session", "--provider", "claude", "--session", SID.upper(), "--source",
                  "team-run", "--name", "alfa-coder", "--ticket", "TT-821", "--team", "alfa",
                  "--role", "coder", "--run", "alfa-20261006-190718", "--attempt", "2",
                  "--parent", ENV_SID, "--cwd", "/work/clone")
        [line] = self.lines()
        at = line.pop("at")
        self.assertRegex(at, r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$")
        self.assertEqual(line, {
            "v": 1, "type": "session", "provider": "claude", "session": SID,
            "source": "team-run", "name": "alfa-coder", "ticket": "TT-821", "team": "alfa",
            "role": "coder", "run": "alfa-20261006-190718", "attempt": 2,
            "parent_session": ENV_SID, "cwd": "/work/clone"})

    def test_bad_optional_field_dropped(self):
        self.mark("session", "--provider", "claude", "--session", SID, "--source", "mail-tt",
                  "--ticket", "tt-1", "--name", "a b")
        [line] = self.lines()
        self.assertNotIn("ticket", line)
        self.assertNotIn("name", line)

    def test_bad_session_skips_line(self):
        proc = self.mark("session", "--provider", "claude", "--session", "not-a-uuid",
                         "--source", "mail-tt")
        self.assertEqual(self.lines(), [])
        self.assertIn("runtime-mark:", proc.stderr)

    def test_session_from_env(self):
        self.mark("session", "--provider", "claude", "--source", "start-team",
                  CLAUDE_CODE_SESSION_ID=ENV_SID)
        self.assertEqual(self.lines()[0]["session"], ENV_SID)

    def test_team_json_fills_fields(self):
        path = os.path.join(self.home, "session.json")
        with open(path, "w", encoding="utf-8") as fh:
            json.dump({"ticket": "TT-821", "team": "alfa", "role": "planner",
                       "run": "alfa-20261006-190718", "attempt": 1}, fh)
        self.mark("session", "--provider", "codex", "--session", SID, "--source", "codex-bg",
                  "--team-json", path, "--role", "qa")
        line = self.lines()[0]
        self.assertEqual((line["ticket"], line["team"], line["role"], line["run"],
                          line["attempt"]), ("TT-821", "alfa", "qa", "alfa-20261006-190718", 1))

    def _team_json_ticket(self, data):
        path = os.path.join(self.home, "session.json")
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(data, fh)
        self.mark("session", "--provider", "codex", "--session", SID, "--source", "codex-bg",
                  "--team-json", path)
        return self.lines()[0].get("ticket")

    def test_team_json_cost_key_wins_over_ticket(self):
        self.assertEqual(self._team_json_ticket({"ticket": "7", "cost_key": "o/r#7"}), "o/r#7")

    def test_team_json_empty_or_missing_cost_key_uses_ticket(self):
        self.assertEqual(self._team_json_ticket({"ticket": "TT-821", "cost_key": ""}), "TT-821")

    def test_team_json_without_cost_key_uses_ticket(self):
        self.assertEqual(self._team_json_ticket({"ticket": "TT-821"}), "TT-821")

    def test_missing_home_is_noop(self):
        missing = os.path.join(self.home, "nope")
        self.run_sh(MARK, ("session", "--provider", "claude", "--session", SID, "--source",
                           "mail-tt"), AGENT_COSTS_HOME=missing)
        self.assertFalse(os.path.exists(missing))

    def test_bare_stage_end_is_noop(self):
        self.mark("stage", "end", "prime", CLAUDE_CODE_SESSION_ID=ENV_SID)
        self.assertEqual(self.lines(), [])

    def _pre(self, tool, tool_input, **extra):
        return dict({"hook_event_name": "PreToolUse", "session_id": SID, "tool_name": tool,
                     "tool_input": tool_input, "tool_use_id": "toolu_01"}, **extra)

    def test_hook_skill_start(self):
        self.hook(self._pre("Skill", {"skill": "execute", "args": "x"}))
        [line] = self.lines()
        self.assertEqual((line["event"], line["name"], line["source"], line["tool_use_id"]),
                         ("start", "execute", "hook-skill", "toolu_01"))

    def test_hook_typed_command_start(self):
        self.hook({"hook_event_name": "UserPromptExpansion", "session_id": SID,
                   "expansion_type": "slash_command", "command_name": "prime",
                   "command_args": "full", "prompt": "/prime full"})
        [line] = self.lines()
        self.assertEqual((line["event"], line["name"], line["source"]),
                         ("start", "prime", "hook-prompt"))
        self.assertNotIn("tool_use_id", line)

    def test_hook_end_step(self):
        cmd = "bash .claude/lib/costs/runtime-mark.sh stage end execute"
        self.hook(self._pre("Bash", {"command": cmd}))
        [line] = self.lines()
        self.assertEqual((line["event"], line["name"], line["source"]),
                         ("end", "execute", "skill-end"))

    def test_hook_ignores_subagents_and_other_commands(self):
        end = "bash .claude/lib/costs/runtime-mark.sh stage end execute"
        for payload in (
                self._pre("Skill", {"skill": "execute"}, agent_id="a1"),
                self._pre("Bash", {"command": end}, agent_id="a1"),
                self._pre("Bash", {"command": "git status"}),
                self._pre("Bash", {"command": end.replace("execute", "x; rm -rf /")}),
                self._pre("Bash", {"command": end + "\nrm -rf /"}),
                {"hook_event_name": "UserPromptExpansion", "session_id": SID,
                 "expansion_type": "mcp_prompt", "command_name": "prime"},
                "{not json"):
            with self.subTest(payload=payload):
                self.hook(payload)
        self.assertEqual(self.lines(), [])


if __name__ == "__main__":
    unittest.main()
