import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts/validate-release-version.py"


class ReleaseVersionTest(unittest.TestCase):
    def run_validator(self, tag: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--tag", tag],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_current_release_succeeds(self) -> None:
        result = self.run_validator("v0.2.5")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_different_release_fails(self) -> None:
        result = self.run_validator("v0.2.6")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("expected v0.2.5, got v0.2.6", result.stderr)


if __name__ == "__main__":
    unittest.main()
