import unittest
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class VendorSnapshotTests(unittest.TestCase):
    def test_upstream_provenance_is_pinned(self):
        upstream = (ROOT / "UPSTREAM.md").read_text(encoding="utf-8")
        self.assertIn("https://github.com/d3vin4/Zync", upstream)
        self.assertIn("2429c28a96e7a84ef7097ff4cd755694d0ab8d0d", upstream)

    def test_clone_tracks_upstream_repository(self):
        probe = subprocess.run(
            ["git", "-C", str(ROOT), "remote"], text=True, capture_output=True
        )
        if "upstream" not in probe.stdout.split():
            self.skipTest("no upstream remote in this checkout (e.g. CI clone)")
        result = subprocess.run(
            ["git", "-C", str(ROOT), "remote", "get-url", "upstream"],
            text=True,
            capture_output=True,
        )
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual("https://github.com/d3vin4/Zync.git", result.stdout.strip())

    def test_expected_upstream_modules_are_present(self):
        expected = {
            "ZLModCore.m",
            "ZLModCompatibility.m",
            "ZLModHookEngine.m",
            "ZLModPreferences.m",
            "ZLModSettings.m",
            "ZLModUI.m",
        }
        actual = {path.name for path in (ROOT / "Sources").glob("*.m")}
        self.assertTrue(expected.issubset(actual))


if __name__ == "__main__":
    unittest.main()
