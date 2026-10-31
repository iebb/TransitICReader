"""Source-contract checks for the Duo layout pass (not UI/runtime evidence)."""
import re
import unittest
from tools.paths import ROOT


class DuoStateContractTests(unittest.TestCase):
    def test_root_owns_one_reader_wallet_and_tab_selection(self):
        source = (ROOT / "ios/CardBal/ContentView.swift").read_text()
        root = source[source.index("struct ContentView: View"):source.index("struct ScanHomeView: View")]
        self.assertEqual(root.count("@StateObject private var reader = NFCTransitReader()"), 1)
        self.assertEqual(root.count("@StateObject private var cardStore = CardWalletStore()"), 1)
        self.assertEqual(root.count("TabView(selection: $selectedTab)"), 1)
        for tag in range(5):
            self.assertIn(f".tag({tag})", root)
        self.assertNotRegex(root, r"\.id\([^\n]*(?:width|height|size|hinge)")

    def test_detail_route_seeds_state_without_appearance_reset(self):
        source = (ROOT / "ios/CardBal/Views/SavedCardDetailView.swift").read_text()
        detail = source[:source.index("private func detailContent")]
        self.assertIn("_viewSelection = State(initialValue: initialSelection)", detail)
        self.assertNotRegex(detail, r"\.onAppear\s*\{\s*viewSelection\s*=")
        for state in ("draftDeleteConfirmation", "activeHistoryItem", "pendingDeletions", "calypsoOnlineLookup"):
            self.assertIn("@State private var " + state, detail)

    def test_minimum_os_and_phone_scope_are_not_raised(self):
        project = (ROOT / "CardBal.xcodeproj/project.pbxproj").read_text()
        targets = re.findall(r"IPHONEOS_DEPLOYMENT_TARGET = ([^;]+);", project)
        self.assertTrue(targets)
        self.assertEqual(set(targets), {"16.0"})
        # 2.5.0 itself added iPad (and its multitasking orientations); the Duo
        # work leaves the device family exactly as the release defines it.
        self.assertEqual(set(re.findall(r"TARGETED_DEVICE_FAMILY = ([^;]+);", project)), {'"1,2"'})

    def test_no_global_device_geometry_added(self):
        forbidden = re.compile(r"UIScreen\s*\.\s*main|UIDevice\s*\.\s*current\s*\.\s*userInterfaceIdiom|UIApplication\s*\.\s*shared\s*\.\s*(?:windows|connectedScenes)")
        # The 2.5.0 reader picks an external NFC reader on iPad by idiom; that is
        # a hardware choice, not layout, so only that file may ask for the idiom.
        allowed = {ROOT / "ios/CardBal/NFC/NFCTransitReader.swift"}
        for path in (ROOT / "ios/CardBal").rglob("*.swift"):
            if path in allowed:
                self.assertNotRegex(path.read_text(), r"UIScreen\s*\.\s*main|UIApplication\s*\.\s*shared\s*\.\s*(?:windows|connectedScenes)", str(path))
                continue
            self.assertNotRegex(path.read_text(), forbidden, str(path))

    def test_transaction_close_has_symbol_for_vertical_bars(self):
        source = (ROOT / "ios/CardBal/NFC/NFCUtils.swift").read_text()
        self.assertIn('Label("Close", systemImage: "xmark")', source)


if __name__ == "__main__":
    unittest.main()
