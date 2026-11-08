import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Sources"


class Phase2ContractTests(unittest.TestCase):
    def test_makefile_links_security_framework(self):
        makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
        self.assertIn("-framework Security", makefile)

    def test_core_installs_all_ten_modules_and_session_observers(self):
        core = (SOURCES / "ZLModCore.m").read_text(encoding="utf-8")
        for module_name, installer in (
            ("URIFilter", "ZLModURIFilterInstall"),
            ("Privacy", "ZLModPrivacyInstall"),
            ("Ads", "ZLModAdsInstall"),
            ("Features", "ZLModFeaturesInstall"),
            ("Settings", "ZLModSettingsInstall"),
            ("Glass", "ZLModGlassInstall"),
            ("ConversationMenu", "ZLModConversationMenuInstall"),
            ("AntiRecall", "ZLModAntiRecallInstall"),
            ("Utilities", "ZLModUtilitiesInstall"),
            ("Theme", "ZLModThemeInstall"),
        ):
            self.assertIn(f'ZLModRunInstaller(@"{module_name}", {installer});', core)
        self.assertIn("kNotifyDidLogoutAnimation", core)
        self.assertIn("ZLModAccountDidChangeNotification", core)

    def test_privacy_uses_verified_macho_hooks_and_avoids_parqueue_getter(self):
        privacy = (SOURCES / "ZLModPrivacy.m").read_text(encoding="utf-8")
        anchors = (ROOT / "Scripts" / "anchors.txt").read_text(encoding="utf-8")
        self.assertNotIn("sendSeenServerPARQueue", privacy)
        self.assertNotIn("sendSeenServerPARQueue", anchors)
        self.assertIn("ZLModReplaceClassMethod(sockCls, singleAckSel, 2, \"v\"", privacy)
        self.assertIn("ZLModReplaceClassMethod(sockCls, groupAckSel, 2, \"v\"", privacy)
        self.assertIn("ZLModReplaceClassMethod(sockCls, socketTypingSel, 5, \"Q\"", privacy)
        self.assertIn("ZLModReplaceMethod(chatDataCls, sendTypingSel, 4, \"Bc\"", privacy)
        self.assertIn("sendSeenLastMessageWithThreadIds:withMessageType:", privacy)

    def test_crypto_store_is_fail_closed_and_uses_keychain_encrypt_then_mac(self):
        crypto = (SOURCES / "ZLModCryptoStore.m").read_text(encoding="utf-8")
        self.assertIn("kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly", crypto)
        self.assertIn("kCCAlgorithmAES", crypto)
        self.assertIn("kCCHmacAlgSHA256", crypto)
        self.assertIn("return nil; // fail-closed", crypto)

    def test_conversation_menu_hooks_both_cell_families_and_uses_3arg_action_selector(self):
        menu = (SOURCES / "ZLModConversationMenu.m").read_text(encoding="utf-8")
        self.assertIn('contextMenu:didSelectActionId:forIdentifier:', menu)
        self.assertIn('ZLModReplaceMethod(mgrClass, selectSel, 3, "v"', menu)
        self.assertIn('UXInboxMessageCell', menu)
        self.assertIn('ChatListItemCell', menu)
        self.assertNotIn('setTextColor:', menu)
        self.assertNotIn('setIconColor:', menu)

    def test_anti_recall_is_non_mutating_and_labels_local_copy(self):
        anti = (SOURCES / "ZLModAntiRecall.m").read_text(encoding="utf-8")
        self.assertIn("[ZLMod Bản sao cục bộ — tin nhắn gốc đã thu hồi]", anti)
        self.assertIn("_getRecalledMsgPreviewFromSource:", anti)
        self.assertIn('ZLModReplaceMethod(chatEntityCls, previewSel, 1, "@"', anti)
        self.assertNotIn("setMessage:", anti)
        self.assertNotIn("toUid", anti)

    def test_utilities_avoid_nonexistent_touid_and_never_autosend_quick_replies(self):
        utils = (SOURCES / "ZLModUtilities.m").read_text(encoding="utf-8")
        self.assertIn("sendChat:checkUpload:", utils)
        self.assertIn("fillChatBarWithText:", utils)
        self.assertNotIn("toUid", utils)
        self.assertIn("ZLModDelaySendStatePending", utils)
        self.assertIn("ZLModDelaySendStateDispatching", utils)

    def test_anchors_manifest_is_well_formed(self):
        lines = [
            line.strip()
            for line in (ROOT / "Scripts" / "anchors.txt").read_text(encoding="utf-8").splitlines()
            if line.strip() and not line.strip().startswith("#")
        ]
        self.assertGreaterEqual(len(lines), 80)
        for line in lines:
            parts = line.split("\t")
            self.assertEqual(2, len(parts), f"malformed anchor line: {line}")
            self.assertIn(parts[0], {"sel", "cls", "key", "url"})
            self.assertTrue(parts[1])


if __name__ == "__main__":
    unittest.main()
