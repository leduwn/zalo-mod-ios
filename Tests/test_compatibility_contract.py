import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
GENERATOR = ROOT / "Scripts" / "generate_compatibility.py"
MANIFEST = ROOT / "Resources" / "compatibility.json"


class CompatibilityContractTests(unittest.TestCase):
    def run_generator(self, manifest, output):
        return subprocess.run(
            [sys.executable, str(GENERATOR), str(manifest), str(output)],
            text=True,
            capture_output=True,
        )

    def test_generator_emits_exact_supported_targets(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "generated.h"
            result = self.run_generator(MANIFEST, output)
            self.assertEqual(0, result.returncode, result.stderr)
            generated = output.read_text(encoding="utf-8")
        for literal in (
            "261002",
            "261002802",
            "261101",
            "261101802",
            "vn.com.vng.zingalo",
            "vn.com.vng.zingalo2",
        ):
            self.assertIn(f'@"{literal}"', generated)

    def test_generator_rejects_incomplete_target(self):
        with tempfile.TemporaryDirectory() as tmp:
            manifest = Path(tmp) / "bad.json"
            output = Path(tmp) / "generated.h"
            manifest.write_text(json.dumps({"targets": [{"version": "261002"}]}), encoding="utf-8")
            result = self.run_generator(manifest, output)
        self.assertNotEqual(0, result.returncode)
        self.assertIn("build", result.stderr)

    def test_runtime_uses_generated_exact_policy_and_reason(self):
        source = (ROOT / "Sources" / "ZLModCompatibility.m").read_text(encoding="utf-8")
        header = (ROOT / "Sources" / "ZLModCompatibilityData.h").read_text(encoding="utf-8")
        self.assertIn('#import "ZLModCompatibilityData.h"', source)
        self.assertIn("isEqualToString", source)
        self.assertNotIn("hasPrefix:", source)
        self.assertIn("supportReason", source)
        self.assertIn("261002802", header)

    def test_makefile_regenerates_compatibility_header(self):
        makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
        self.assertIn("Scripts/generate_compatibility.py", makefile)
        self.assertIn("Resources/compatibility.json", makefile)
        self.assertIn("Sources/ZLModCompatibilityData.h", makefile)

    def test_checked_in_header_matches_manifest(self):
        import importlib.util

        spec = importlib.util.spec_from_file_location(
            "zlmod_compat_gen", ROOT / "Scripts" / "generate_compatibility.py"
        )
        self.assertIsNotNone(spec)
        self.assertIsNotNone(spec.loader)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        expected = mod.render_header(mod.load_targets(MANIFEST))
        actual = (ROOT / "Sources" / "ZLModCompatibilityData.h").read_text(encoding="utf-8")
        self.assertEqual(expected, actual)


if __name__ == "__main__":
    unittest.main()
