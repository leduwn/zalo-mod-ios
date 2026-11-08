import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class SmokeContractTests(unittest.TestCase):
    def test_unset_feature_preferences_are_off(self):
        source = (ROOT / "Sources" / "ZLModPreferences.m").read_text(encoding="utf-8")
        self.assertNotIn("return [self.standard boolForKey:key]", source)
        self.assertIn("return NO;", source)

    def test_each_installer_is_observable_and_isolated(self):
        source = (ROOT / "Sources" / "ZLModCore.m").read_text(encoding="utf-8")
        self.assertIn('module %@ start', source)
        self.assertIn('module %@ success', source)
        self.assertIn('module %@ failed', source)
        self.assertIn("@try", source)
        self.assertIn("@catch", source)

    def test_boot_has_loader_compatibility_and_completion_events(self):
        source = (ROOT / "Sources" / "ZLModCore.m").read_text(encoding="utf-8")
        self.assertIn('loaded %@ (%@)', source)
        self.assertIn('compatibility: %@', source)
        self.assertIn('boot complete', source)
        self.assertIn('![ZLModCompatibility hostSupported]', source)

    def test_about_ui_exposes_compatibility_diagnostics(self):
        ui = (ROOT / "Sources" / "ZLModUI.m").read_text(encoding="utf-8")
        self.assertIn('[ZLModCompatibility hostVersion]', ui)
        self.assertIn('[ZLModCompatibility supportReason]', ui)

    def test_glass_toggle_off_cleans_up_overlay(self):
        glass = (ROOT / "Sources" / "ZLModGlass.m").read_text(encoding="utf-8")
        self.assertIn('ZLModGlassRemove();', glass)


if __name__ == "__main__":
    unittest.main()
