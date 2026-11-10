#!/usr/bin/env python3
"""Reproduction and contract tests for Anti-Recall in-place Unhide/Hide view hierarchy safety."""

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Sources"


class MockView:
    def __init__(self, name="View"):
        self.name = name
        self.subviews = []
        self.superview = None

    def add_subview(self, view):
        view.superview = self
        self.subviews.append(view)


class MockLabel(MockView):
    def __init__(self, text, name="Label"):
        super().__init__(name)
        self.text = text
        self.number_of_lines = 1
        self.associated_objects = {}

    def size_to_fit(self):
        pass


def zlmod_find_recall_label(view, is_unhiding, orig_key="ZLModOrigRecallText"):
    """Mirrors ZLModFindRecallLabel in ZLModAntiRecall.m."""
    if not view:
        return None
    if isinstance(view, MockLabel):
        if is_unhiding:
            cur_text = view.text or ""
            if "thu hồi" in cur_text.lower() or "recalled" in cur_text.lower():
                return view
        else:
            orig = view.associated_objects.get(orig_key)
            if orig and len(orig) > 0:
                return view
    for sub in view.subviews:
        found = zlmod_find_recall_label(sub, is_unhiding, orig_key)
        if found:
            return found
    return None


def zlmod_update_text_in_view_hierarchy(view, new_text, is_unhiding, orig_key="ZLModOrigRecallText"):
    """Mirrors fixed ZLModUpdateTextInViewHierarchy in ZLModAntiRecall.m."""
    target_label = zlmod_find_recall_label(view, is_unhiding, orig_key)
    if not target_label:
        return False

    if is_unhiding:
        cur_text = target_label.text
        target_label.associated_objects[orig_key] = cur_text
        target_label.text = new_text
        target_label.number_of_lines = 0
        target_label.size_to_fit()
        return True
    else:
        orig = target_label.associated_objects.get(orig_key)
        if orig and len(orig) > 0:
            target_label.text = orig
            target_label.associated_objects.pop(orig_key, None)
            target_label.size_to_fit()
            return True
        return False


def buggy_update_text_in_view_hierarchy(view, new_text, is_unhiding, orig_key="ZLModOrigRecallText"):
    """Simulates the buggy Build 9 implementation before the fix."""
    if not view:
        return False
    replaced = False
    if isinstance(view, MockLabel):
        cur_text = view.text or ""
        if len(cur_text) > 0:
            looks_like_recalled = "thu hồi" in cur_text.lower() or "recalled" in cur_text.lower()
            if is_unhiding and looks_like_recalled:
                view.associated_objects[orig_key] = cur_text
                view.text = new_text
                replaced = True
            elif not is_unhiding and not looks_like_recalled:
                # BUG: Overwrites every label that does not look like recalled!
                orig = view.associated_objects.get(orig_key)
                view.text = orig if (orig and len(orig)) else "Tin nhắn đã được thu hồi"
                replaced = True
    for sub in view.subviews:
        if buggy_update_text_in_view_hierarchy(sub, new_text, is_unhiding, orig_key):
            replaced = True
    return replaced


class AntiRecallInPlaceSafetyTests(unittest.TestCase):
    def setUp(self):
        # Build standard chat cell hierarchy
        self.cell = MockView("ChatCell")
        self.header = MockView("HeaderView")
        self.sender_label = MockLabel("Lê Dương", "SenderLabel")
        self.time_label = MockLabel("10:15", "TimeLabel")
        self.header.add_subview(self.sender_label)
        self.header.add_subview(self.time_label)

        self.bubble = MockView("BubbleView")
        self.menu_button = MockView("MenuButton")
        self.content_label = MockLabel("Tin nhắn đã được thu hồi", "ContentLabel")
        self.menu_button.add_subview(self.content_label)
        self.bubble.add_subview(self.menu_button)

        self.footer = MockView("FooterView")
        self.status_label = MockLabel("Đã nhận", "StatusLabel")
        self.footer.add_subview(self.status_label)

        self.cell.add_subview(self.header)
        self.cell.add_subview(self.bubble)
        self.cell.add_subview(self.footer)

    def test_reproduction_demonstrates_bug_in_previous_implementation(self):
        """Demonstrates that the old logic corrupted sender and time labels on hide."""
        # 1. Unhide
        buggy_update_text_in_view_hierarchy(self.cell, "Tin nhắn bí mật", is_unhiding=True)
        self.assertEqual("Tin nhắn bí mật", self.content_label.text)
        self.assertEqual("Lê Dương", self.sender_label.text)
        self.assertEqual("10:15", self.time_label.text)

        # 2. Buggy Hide -> Corrupts non-recall labels!
        buggy_update_text_in_view_hierarchy(self.cell, "Tin nhắn đã được thu hồi", is_unhiding=False)
        self.assertEqual("Tin nhắn đã được thu hồi", self.content_label.text)
        # Old code overwrote sender, time, and status with placeholder!
        self.assertEqual("Tin nhắn đã được thu hồi", self.sender_label.text)
        self.assertEqual("Tin nhắn đã được thu hồi", self.time_label.text)
        self.assertEqual("Tin nhắn đã được thu hồi", self.status_label.text)

    def test_fixed_implementation_preserves_sender_time_and_status_labels(self):
        """Verifies that the fixed implementation leaves non-recall labels strictly untouched."""
        # 1. Unhide: Only content_label should change
        res_unhide = zlmod_update_text_in_view_hierarchy(self.cell, "Tin nhắn bí mật", is_unhiding=True)
        self.assertTrue(res_unhide)
        self.assertEqual("Tin nhắn bí mật", self.content_label.text)
        self.assertEqual("Lê Dương", self.sender_label.text)
        self.assertEqual("10:15", self.time_label.text)
        self.assertEqual("Đã nhận", self.status_label.text)

        # 2. Hide: Only content_label should be restored to its original text
        res_hide = zlmod_update_text_in_view_hierarchy(self.cell, "Tin nhắn đã được thu hồi", is_unhiding=False)
        self.assertTrue(res_hide)
        self.assertEqual("Tin nhắn đã được thu hồi", self.content_label.text)
        self.assertEqual("Lê Dương", self.sender_label.text, "Sender label MUST NOT be overwritten on hide!")
        self.assertEqual("10:15", self.time_label.text, "Time label MUST NOT be overwritten on hide!")
        self.assertEqual("Đã nhận", self.status_label.text, "Status label MUST NOT be overwritten on hide!")

        # 3. Subsequent Hide call when already hidden is safe no-op
        res_hide_again = zlmod_update_text_in_view_hierarchy(self.cell, "Tin nhắn đã được thu hồi", is_unhiding=False)
        self.assertFalse(res_hide_again)
        self.assertEqual("Lê Dương", self.sender_label.text)
        self.assertEqual("10:15", self.time_label.text)
        self.assertEqual("Tin nhắn đã được thu hồi", self.content_label.text)

    def test_source_code_contract_for_anti_recall_inplace_fixes(self):
        """Verifies required source patterns in Sources/ZLModAntiRecall.m."""
        src = (SOURCES / "ZLModAntiRecall.m").read_text(encoding="utf-8")

        # 1. Target recall label finder exists
        self.assertIn("ZLModFindRecallLabel", src)

        # 2. Associative key for original text
        self.assertIn("kZLModOrigRecallTextKey", src)

        # 3. Only restore when orig.length > 0; no fallback placeholder overwriting arbitrary labels
        self.assertIn("orig.length > 0", src)
        self.assertNotIn('orig.length ? orig : @"Tin nhắn đã được thu hồi"', src)

        # 4. Containing cell or root is searched once, without nested recursive ancestor loops
        self.assertIn("ZLModFindContainingCellOrRoot", src)

        # 5. gUnhiddenMessageKeys is scoped with accountScope and threadId
        self.assertIn("ZLModUnhiddenKey(NSString *accountScope, NSString *threadId", src)

        # 6. Clears unhidden keys on account change / logout
        self.assertIn("ZLModClearUnhiddenMessages()", src)


if __name__ == "__main__":
    unittest.main()
