import importlib.util
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
GATE_PATH = ROOT / "Scripts" / "project_gate.py"


def load_gate():
    spec = importlib.util.spec_from_file_location("zlmod_project_gate", GATE_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError("unable to load project gate")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ProductIdentityTests(unittest.TestCase):
    def test_gate_rejects_upstream_runtime_identity(self):
        gate = load_gate()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "Sources").mkdir()
            (root / "Sources" / "ZyncCore.m").write_text(
                'NSLog(@"[Zync] loaded");', encoding="utf-8"
            )
            violations = gate.audit_identity(root)
        self.assertTrue(any("Zync" in item for item in violations))

    def test_zlmod_tree_has_one_product_identity(self):
        gate = load_gate()
        self.assertEqual([], gate.audit_identity(ROOT))

    def test_makefile_builds_expected_dylib(self):
        makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
        self.assertIn("build/libZLMod.dylib", makefile)
        self.assertIn("@rpath/libZLMod.dylib", makefile)


if __name__ == "__main__":
    unittest.main()
