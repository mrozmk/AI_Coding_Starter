"""Run the machine gate-lock smoke; cost-tests.sh, and so every test-gate run, executes it."""
import os
from pathlib import Path
import subprocess
import unittest

SMOKE = Path(__file__).resolve().parents[4] / ".claude/lib/tests/gate-lock-smoke.sh"


class GateLockSmokeTest(unittest.TestCase):
    def test_gate_lock_smoke(self):
        # A caller's lock settings (a merge check's token, a real root) must not reach the smoke.
        env = {k: v for k, v in os.environ.items() if not k.startswith("TEAM_GATE_LOCK_")}
        result = subprocess.run(["bash", str(SMOKE)], env=env, capture_output=True, text=True,
                                timeout=240, check=False)
        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, output)
        self.assertIn("gate-lock-smoke: OK", result.stdout, output)
