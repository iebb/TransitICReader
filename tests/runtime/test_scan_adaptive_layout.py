"""Focused source contracts for Scan reflow; these are not rendered UI tests."""
import unittest

from tools.paths import ROOT


class ScanAdaptiveLayoutTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = (ROOT / "ios/CardBal/ContentView.swift").read_text()
        cls.scan = cls.source.split("struct ScanHomeView: View {", 1)[1].split("struct CardsView: View {", 1)[0]

    def region(self, start, end):
        return self.scan.split(start, 1)[1].split(end, 1)[0]

    def test_panes_require_live_regular_width_and_readable_sizes(self):
        body = self.region("var body: some View", "// These builders")
        for condition in (
            "horizontalSizeClass == .regular",
            "!dynamicTypeSize.isAccessibilitySize",
            "primaryWidth >= 240 && secondaryWidth >= 300",
        ):
            self.assertIn(condition, body)
        self.assertIn("if #available(iOS 27.1, *)", body)
        self.assertIn("let primaryWidth = min(proxy.size.width * 0.42, 400)", body)
        self.assertNotIn("proxy.size.width >= 700", body)
        self.assertIn(".splitArrangementLayoutSize(", body)
        self.assertIn("idealWidth: primaryWidth", body)
        self.assertIn("idealHeight: min(420, proxy.size.height * 0.6)", body)
        self.assertNotIn(".splitArrangementLayoutRatio", body)
        self.assertIn(".arrangementViewStyle(.split)", body)
        # Excluding an axis can show only the primary and strand content.
        self.assertNotIn(".split.axes", body)
        self.assertNotRegex(self.scan, r"\.id\([^\n]*(?:width|height|size|hinge)")

    def test_stacked_height_is_a_soft_locally_bounded_ideal(self):
        body = self.region("var body: some View", "// These builders")
        constraints = body.split(".splitArrangementLayoutSize(", 1)[1].split("} secondary:", 1)[0]
        self.assertNotIn("minHeight:", constraints)
        self.assertNotIn("maxHeight:", constraints)
        for height, expected in ((900, 420), (700, 420), (500, 300), (300, 180)):
            ideal = min(420, height * 0.6)
            self.assertEqual(ideal, expected)
            self.assertLess(ideal, height)

    def test_capacity_examples_cover_inner_portrait_and_narrow_windows(self):
        # Arithmetic examples only; source assertions above tie these to Swift.
        for width, regular, accessibility, expected in (
            (669, True, False, True),
            (867, True, False, True),
            (1200, True, False, True),
            (540, True, False, False),
            (867, False, False, False),
            (867, True, True, False),
        ):
            primary = min(width * 0.42, 400)
            secondary = width - primary
            actual = regular and not accessibility and primary >= 240 and secondary >= 300
            self.assertEqual(actual, expected, (width, regular, accessibility))

    def test_presentation_and_autostart_have_one_stable_host(self):
        body = self.region("var body: some View", "// These builders")
        branch_end = body.index('.navigationTitle("Scan")')
        self.assertNotIn(".sheet", body[:branch_end])
        self.assertNotIn(".onAppear", body[:branch_end])
        for binding in ("$activeHistoryItem", "$detailRoute", "$isShowingSNScanner"):
            self.assertEqual(self.scan.count(".sheet(item: " + binding) + self.scan.count(".sheet(isPresented: " + binding), 1)
        self.assertEqual(self.scan.count(".onAppear"), 1)
        self.assertEqual(self.scan.count("didAutoStartScan = true"), 1)
        self.assertEqual(self.scan.count("didAutoStartScan = false"), 1)
        builders = self.scan.split("// These builders", 1)[1]
        self.assertNotIn("@State", builders)

    def test_compact_retains_original_section_order(self):
        compact = self.region("private var compactList", "private var primaryPane")
        tokens = ["welcomeSection", "cardReaderSection", "cardPreviewSection", "resultSection", "secondarySections", "readySection", "scanningSection", "howToSection"]
        positions = [compact.index(token) for token in tokens]
        self.assertEqual(positions, sorted(positions))

    def test_result_and_ready_panes_follow_content_contract(self):
        primary = self.region("private var primaryPane", "private var secondaryPane")
        secondary = self.region("private var secondaryPane", "private func hasSecondarySections")
        self.assertIn("resultSection(snapshot: snapshot)", primary)
        self.assertNotIn("secondarySections(", primary)
        self.assertIn("secondarySections(snapshot: snapshot, cardToDisplay: card)", secondary)
        self.assertIn("if hasSecondarySections(snapshot: snapshot, card: card)", primary)
        self.assertIn("if !hasSecondarySections(snapshot: snapshot, card: card)", secondary)
        ready_primary = primary.split("} else {", 1)[1]
        ready_secondary = secondary.split("} else {", 1)[1]
        self.assertIn("readySection", ready_primary)
        self.assertIn("scanningSection", ready_primary)
        self.assertIn("welcomeSection", ready_secondary)
        self.assertIn("howToSection", ready_secondary)

    def test_cards_keep_wallet_stack_and_expansion_owner(self):
        cards = self.source.split("struct CardsView: View {", 1)[1].split("struct RideMapTabView", 1)[0]
        # Rev 1.4: the regular-width grid is replaced by the Wallet-style stack
        # (see test_cards_wallet_layout.py for the full contract).
        self.assertNotIn("usesGrid", cards)
        self.assertNotIn("LazyVGrid", cards)
        self.assertIn("horizontalSizeClass == .regular", cards)
        self.assertIn("!dynamicTypeSize.isAccessibilitySize", cards)
        self.assertIn("@State private var previewCardID: String?", cards)
        self.assertNotRegex(cards, r"\.onChange\(of:.*(?:size|width|horizontalSizeClass)")

    def test_panes_keep_a_gap_between_their_lists(self):
        primary = self.region("private var primaryPane", "private var secondaryPane")
        secondary = self.region("private var secondaryPane", "private func hasSecondarySections")
        self.assertIn(".modifier(ScanPaneMargins(leading: 20, trailing: 10))", primary)
        self.assertIn(".modifier(ScanPaneMargins(leading: 10, trailing: nil))", secondary)
        margins = self.source.split("private struct ScanPaneMargins: ViewModifier {", 1)[1].split("private struct", 1)[0]
        self.assertIn(".contentMargins(.leading, leading, for: .scrollContent)", margins)
        self.assertIn(".contentMargins(.trailing, trailing, for: .scrollContent)", margins)

    def test_reader_switch_needs_a_connected_external_reader(self):
        reader = (ROOT / "ios/CardBal/NFC/NFCTransitReader.swift").read_text()
        self.assertIn("var hasConnectedExternalReader: Bool { !externalReaderNames.isEmpty }", reader)
        self.assertIn("requiresExternalReader || (prefersExternalReader && hasConnectedExternalReader)", reader)
        section = self.region("private var cardReaderSection: some View", "private func cardPreviewSection(")
        self.assertIn("if !reader.requiresExternalReader && reader.hasConnectedExternalReader {\n"
                      "                Picker(\"Read Using\"", section)
        self.assertIn("if reader.hasConnectedExternalReader {\n"
                      "                    Picker(\"Reader\"", section)
        # Both layouts show the reader section ahead of the scan prompt.
        for builder in ("private var compactList", "private var primaryPane"):
            self.assertIn("cardReaderSection", self.region(builder, "private var secondaryPane"))

    def test_native_toolbar_labels_keep_existing_titles(self):
        self.assertEqual(self.source.count('Label("Done", systemImage: "checkmark")'), 2)
        toolbar = self.source.split("struct ScanToolbarItem: ToolbarContent", 1)[1].split("struct ReorderCardsView", 1)[0]
        self.assertIn('Label("Scan a Card", systemImage: "sensor.tag.radiowaves.forward.fill")', toolbar)
        self.assertIn('.accessibilityLabel(Text("Scan a Card"))', toolbar)


if __name__ == "__main__":
    unittest.main()
