import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class LicenseBoundaryTests(unittest.TestCase):
    def test_third_party_notice_records_both_sources(self):
        notice = (ROOT / "THIRD_PARTY_NOTICES.md").read_text(encoding="utf-8")
        self.assertIn("d3vin4/Zync", notice)
        self.assertIn("MIT", notice)
        self.assertIn("milanvudev/ZepLaoModMilanVu", notice)
        self.assertIn("AGPL-3.0", notice)
        self.assertIn("not copied", notice.lower())

    def test_agpl_runtime_symbols_are_absent(self):
        offenders = []
        for path in (ROOT / "Sources").glob("*"):
            if "ZX" in path.name:
                offenders.append(path.name)
            if path.is_file() and "ZX" in path.read_text(encoding="utf-8", errors="ignore"):
                offenders.append(path.name)
        self.assertEqual([], offenders)


if __name__ == "__main__":
    unittest.main()
