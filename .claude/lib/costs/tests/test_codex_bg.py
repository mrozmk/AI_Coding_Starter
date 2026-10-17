"""codex-bg.sh: thread registration, exit-code passthrough, OUT/LOG truncation (TT-821),
Codex profile check (TT-912)."""
import json
import os
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[4]
SRC_WRAPPER = REPO / ".claude" / "lib" / "codex-bg.sh"
THREAD = "01a11286-3740-7c31-b61d-bbd99e92c84d"
OLD_THREAD = "01a11286-3740-7c31-b61d-000000000000"
PARENT = "0a1b2c3d-0000-4000-8000-0000000000dd"
FAKE = f"""#!/usr/bin/env bash
out=""
while [ $# -gt 0 ]; do [ "$1" = --output-last-message ] && out="$2"; shift; done
sleep "${{FAKE_DELAY:-0}}"
echo "session id: {THREAD}" >&2
printf '{{}}' > "$out"
sleep 1
exit "${{FAKE_RC:-0}}"
"""


class CodexBgTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        assert SRC_WRAPPER.is_file(), SRC_WRAPPER

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="codex-bg-")
        # Isolated tree: wrapper + its relative costs/runtime-mark.sh + a codex-profile with a value,
        # so the test does not depend on the repo's (template) .claude/codex-profile.
        tree = os.path.join(self.tmp, "tree", ".claude")
        shutil.copytree(REPO / ".claude" / "lib", os.path.join(tree, "lib"),
                        ignore=shutil.ignore_patterns("tests", "__pycache__"))
        with open(os.path.join(tree, "codex-profile"), "w", encoding="utf-8") as fh:
            fh.write("# test fixture\n~/.codex-taketask\n")
        self.wrapper = os.path.join(tree, "lib", "codex-bg.sh")
        self.home = os.path.join(self.tmp, "home")
        self.repo = os.path.join(self.tmp, "repo")
        os.makedirs(self.home)
        os.makedirs(self.repo)
        # The wrapper reads the committed .claude/codex-profile; its ~ expands against this HOME.
        self.user_home = os.path.join(self.tmp, "userhome")
        self.profile = os.path.join(self.user_home, ".codex-taketask")
        os.makedirs(self.profile)
        bin_dir = os.path.join(self.tmp, "bin")
        os.makedirs(bin_dir)
        fake = os.path.join(bin_dir, "codex")
        with open(fake, "w", encoding="utf-8") as fh:
            fh.write(FAKE)
        os.chmod(fake, 0o755)
        self.out = os.path.join(self.tmp, "out.md")
        self.log = os.path.join(self.tmp, "run.log")
        self.env = {k: v for k, v in os.environ.items() if k != "CLAUDE_CODE_SESSION_ID"}
        self.env.update(PATH=f"{bin_dir}:{os.environ['PATH']}", PROMPT="review", OUT=self.out,
                        LOG=self.log, CODEX_EFFORT="high", REPO=self.repo,
                        AGENT_COSTS_HOME=self.home, CLAUDE_CODE_SESSION_ID=PARENT,
                        HOME=self.user_home, CODEX_HOME=self.profile)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_wrapper(self, **extra):
        return self.run_full(**extra).returncode

    def run_full(self, drop=(), **extra):
        env = {k: v for k, v in dict(self.env, **extra).items() if k not in drop}
        return subprocess.run(["bash", self.wrapper], env=env, capture_output=True, text=True,
                              check=False, timeout=30)

    def read(self, path):
        with open(path, encoding="utf-8") as fh:
            return fh.read()

    def assert_refused(self, proc, message):
        self.assertEqual(proc.returncode, 2, proc.stderr)
        self.assertIn(message, proc.stderr)
        self.assertIn(message, self.read(self.log))
        self.assertEqual(self.read(self.out), "")

    def lines(self, wait=3.0):
        path = os.path.join(self.home, "runtime.jsonl")
        deadline = time.time() + wait
        while time.time() < deadline and not os.path.exists(path):
            time.sleep(0.1)
        if not os.path.exists(path):
            return []
        time.sleep(0.2)
        with open(path, encoding="utf-8") as fh:
            return [json.loads(ln) for ln in fh if ln.strip()]

    def test_registers_thread_with_parent(self):
        self.assertEqual(self.run_wrapper(), 0)
        [line] = self.lines()
        self.assertEqual((line["type"], line["provider"], line["session"], line["source"],
                          line["parent_session"], line["cwd"]),
                         ("session", "codex", THREAD, "codex-bg", PARENT, self.repo))

    def test_exit_code_passes_through(self):
        self.assertEqual(self.run_wrapper(FAKE_RC="3"), 3)
        self.assertEqual(len(self.lines()), 1)

    def test_team_session_fields(self):
        team = os.path.join(self.repo, ".agents", "team")
        os.makedirs(team)
        with open(os.path.join(team, "session.json"), "w", encoding="utf-8") as fh:
            json.dump({"ticket": "TT-821", "team": "alfa", "role": "planner",
                       "run": "alfa-20261006-190718", "attempt": 1}, fh)
        self.run_wrapper()
        [line] = self.lines()
        self.assertEqual((line["ticket"], line["team"], line["role"], line["run"],
                          line["attempt"]), ("TT-821", "alfa", "planner",
                                             "alfa-20261006-190718", 1))

    def test_stale_out_and_log_are_truncated(self):
        with open(self.out, "w", encoding="utf-8") as fh:
            fh.write("previous review")
        with open(self.log, "w", encoding="utf-8") as fh:
            fh.write(f"session id: {OLD_THREAD}\n")
        self.run_wrapper(FAKE_DELAY="1")
        with open(self.out, encoding="utf-8") as fh:
            self.assertEqual(fh.read(), "{}")
        self.assertEqual([ln["session"] for ln in self.lines()], [THREAD])

    def test_missing_or_empty_required_parameters_truncate_stale_out(self):
        for key in ("PROMPT", "LOG", "CODEX_EFFORT"):
            for value in (None, ""):
                with self.subTest(parameter=key, value=value):
                    Path(self.out).write_text("previous review", encoding="utf-8")
                    proc = self.run_full(drop=(key,)) if value is None else self.run_full(**{key: value})
                    self.assertEqual(proc.returncode, 1, proc.stderr)
                    self.assertIn(f"{key} is required", proc.stderr)
                    self.assertEqual(self.read(self.out), "")

    def test_invalid_effort_truncates_stale_out(self):
        Path(self.out).write_text("previous review", encoding="utf-8")
        proc = self.run_full(CODEX_EFFORT="bogus")
        self.assertEqual(proc.returncode, 2, proc.stderr)
        self.assertEqual(proc.stderr.strip(),
                         "codex-bg.sh: CODEX_EFFORT='bogus' is not one of low|medium|high|xhigh")
        self.assertEqual(self.read(self.out), "")

    def test_missing_codex_truncates_stale_out(self):
        Path(self.out).write_text("previous review", encoding="utf-8")
        bin_dir = Path(self.tmp) / "no-codex-bin"
        bin_dir.mkdir()
        (bin_dir / "bash").symlink_to(shutil.which("bash"))
        proc = self.run_full(PATH=str(bin_dir))
        self.assertEqual(proc.returncode, 127, proc.stderr)
        self.assertEqual(proc.stderr.strip(), "codex-bg.sh: codex not on PATH — cannot run review")
        self.assertEqual(self.read(self.out), "")

    def test_no_home_no_file(self):
        shutil.rmtree(self.home)
        self.assertEqual(self.run_wrapper(), 0)
        self.assertEqual(self.lines(wait=1.5), [])
        self.assertFalse(os.path.exists(self.home))

    def test_refuses_without_codex_home(self):
        with open(self.out, "w", encoding="utf-8") as fh:
            fh.write("previous review")
        proc = self.run_full(drop=("CODEX_HOME",))
        self.assert_refused(proc, "CODEX_HOME is not set")
        self.assertEqual(self.lines(wait=1.5), [])

    def test_refuses_other_profile(self):
        other = os.path.join(self.user_home, ".codex")
        os.makedirs(other)
        self.assert_refused(self.run_full(CODEX_HOME=other), "is not the project profile")

    def test_refuses_missing_profile_dirs(self):
        shutil.rmtree(self.profile)
        proc = self.run_full(CODEX_HOME=os.path.join(self.tmp, "missing"))
        self.assert_refused(proc, "does not exist")

    def test_refuses_unresolvable_codex_home(self):
        Path(self.out).write_text("previous review", encoding="utf-8")
        proc = self.run_full(CODEX_HOME=os.path.join(self.tmp, "missing"))
        self.assert_refused(proc, "is not the project profile")

    def test_logs_profile_first_line(self):
        self.assertEqual(self.run_wrapper(), 0)
        log = self.read(self.log).splitlines()
        self.assertEqual(log[0], f"codex-bg.sh: CODEX_HOME={os.path.realpath(self.profile)}")
        self.assertIn(f"session id: {THREAD}", log)
        self.assertEqual([ln["session"] for ln in self.lines()], [THREAD])


if __name__ == "__main__":
    unittest.main()
