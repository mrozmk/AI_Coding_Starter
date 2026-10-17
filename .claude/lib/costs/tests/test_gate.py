"""Exercise the real shell gate against temporary harness and .NET runner fixtures."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


class GateTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="cost-gate-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        tests = self.root / ".claude/lib/tests"
        tests.mkdir(parents=True)
        # The TakeTask gate is a project adapter, kept as a test fixture in the starter.
        source = Path(__file__).resolve().parents[2] / "tests" / "fixtures" / "tt" / "test-gate.sh"
        self.gate = tests.parent / "test-gate.sh"
        shutil.copyfile(source, self.gate)
        reference = self.root / ".agents/reference"
        reference.mkdir(parents=True)
        self.baseline = reference / "test-baseline.txt"
        self.baseline.write_text("# fixture baseline\nknown\n")
        (tests / "cost-tests.sh").write_text(
            'echo costs >> "$GATE_FIXTURE_ROOT/calls"\nexit "${COST_RC:-0}"\n')
        self.command("git", '#!/bin/sh\nprintf "%s\\n" "$GATE_FIXTURE_ROOT"\n')
        self.command("dotnet", f"#!{sys.executable}\n" + '''import os, pathlib, sys
root = pathlib.Path(os.environ["GATE_FIXTURE_ROOT"])
with (root / "calls").open("a") as out:
    out.write("dotnet\\n")
logger = sys.argv[sys.argv.index("--logger") + 1]
path = pathlib.Path(logger.split("LogFileName=", 1)[1])
extra = ('<UnitTestResult testName="new" outcome="Failed"/>'
         if os.getenv("NEW_FAIL") else '')
path.write_text('<TestRun xmlns="http://microsoft.com/schemas/VisualStudio/TeamTest/2010">'
                '<Results><UnitTestResult testName="known" outcome="Failed"/>'
                '<UnitTestResult testName="pass" outcome="Passed"/>' + extra
                + '</Results></TestRun>')
''')

    def command(self, name, body):
        path = self.bin / name
        path.write_text(body)
        path.chmod(0o755)

    def run_gate(self, *args, **overrides):
        env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                   GATE_FIXTURE_ROOT=str(self.root), TMPDIR=str(self.root),
                   COST_RC="0", NEW_FAIL="")
        env.update(overrides)
        return subprocess.run(["bash", str(self.gate), *args], env=env, capture_output=True,
                              text=True, check=False)

    def test_cost_failure_stops_before_dotnet_and_update(self):
        before = self.baseline.read_bytes()
        result = self.run_gate("--update", COST_RC="17")
        self.assertEqual(result.returncode, 17, result.stdout + result.stderr)
        self.assertEqual((self.root / "calls").read_text(), "costs\n")
        self.assertEqual(self.baseline.read_bytes(), before)

    def test_known_baseline_stays_green_and_unchanged(self):
        before = self.baseline.read_bytes()
        result = self.run_gate()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("new 0", result.stdout)
        calls = (self.root / "calls").read_text().splitlines()
        self.assertEqual(calls[0], "costs")
        self.assertTrue(calls[1:])
        self.assertEqual(set(calls[1:]), {"dotnet"})
        self.assertEqual(self.baseline.read_bytes(), before)

    def test_new_dotnet_failure_remains_red_and_update_still_works(self):
        result = self.run_gate(NEW_FAIL="1")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("NEW FAILURE: new", result.stdout)
        result = self.run_gate("--update", NEW_FAIL="1")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.baseline.read_text().splitlines()[1:], ["known", "new"])
