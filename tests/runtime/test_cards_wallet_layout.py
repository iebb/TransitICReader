"""Source contracts for the rev 1.4 Wallet-style Cards layout; not rendered UI tests."""
import re
import unittest

from tools.paths import ROOT


def between(text, start, end):
    return text.split(start, 1)[1].split(end, 1)[0]


class CardsWalletLayoutTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source = (ROOT / "ios/CardBal/ContentView.swift").read_text()
        cls.source = source
        cls.cards = between(source, "struct CardsView: View {", "private struct WalletStackPane: View {")
        cls.stack = between(source, "private struct WalletStackPane: View {", "private struct CardHistoryPane: View {")
        cls.pane = between(source, "private struct CardHistoryPane: View {", "struct RideMapTabView")
        cls.body = between(cls.cards, "var body: some View {", "private var emptyWallet")
        cls.wide = between(cls.cards, "private func wideLayout(", "private func walletStackPane(")
        cls.compact = between(cls.cards, "private func compactStack(", "private func walletCard(")
        secondary = (ROOT / "ios/CardBal/Views/SecondaryViews.swift").read_text()
        cls.sheet = between(secondary, "struct QuickHistorySheet: View {", "struct CardHistoryList: View {")
        cls.history_list = between(secondary, "struct CardHistoryList: View {", "struct HistorySheetItem")
        cls.secondary = secondary
        utils = (ROOT / "ios/CardBal/NFC/NFCUtils.swift").read_text()
        cls.row = between(utils, "struct TransitTransactionRow: View {", "struct TransactionDetailView: View {")
        cls.wallet_card = (ROOT / "ios/CardBal/Views/WalletCardView.swift").read_text()
        cls.strings = (ROOT / "ios/CardBal/Resources/en.lproj/Localizable.strings").read_text()

    def test_grid_branch_is_removed(self):
        for token in ("LazyVGrid", "GridItem", "usesGrid", ">= 620"):
            self.assertNotIn(token, self.cards)
            self.assertNotIn(token, self.stack)

    def test_wide_layout_is_a_live_fit_test(self):
        fit = between(self.cards, "private func usesWideLayout(in proxy: GeometryProxy) -> Bool {", "\n    }\n")
        for condition in (
            "let width = proxy.size.width",
            # The large title collapsing moves height into the top inset; their
            # sum is stable, so scrolling near square never flips the layout.
            "let fullHeight = proxy.size.height + proxy.safeAreaInsets.top",
            "horizontalSizeClass == .regular",
            "width > fullHeight",
            "width >= 720",
            "!dynamicTypeSize.isAccessibilitySize",
            "!store.cards.isEmpty",
        ):
            self.assertIn(condition, fit)
        self.assertNotIn("size.width > size.height", fit)
        self.assertNotRegex(fit, r"@State|hysteresis")
        self.assertIn("if usesWideLayout(in: proxy), let selectedCard = effectiveSelectedCard {", self.body)
        self.assertIn("compactStack(width: proxy.size.width)", self.body)
        for forbidden in ("UIScreen", "userInterfaceIdiom", "verticalSizeClass"):
            self.assertNotIn(forbidden, self.cards)

    def test_fit_examples_cover_inner_portrait_accessibility_and_narrow(self):
        # Arithmetic examples only; the source assertion above ties them to Swift.
        def fits(width, height, top, regular=True, accessibility=False):
            return regular and width > height + top and width >= 720 and not accessibility

        for width, height, top, regular, accessibility, expected in (
            (1024, 600, 100, True, False, True),
            (720, 500, 100, True, False, True),
            (719, 400, 100, True, False, False),   # narrow window
            (700, 924, 100, True, False, False),   # inner display held portrait
            (1024, 600, 100, True, True, False),   # accessibility text size
            (1024, 600, 100, False, False, False),  # compact size class
        ):
            actual = fits(width, height, top, regular, accessibility)
            self.assertEqual(actual, expected, (width, height, top, regular, accessibility))
        # Near square: a large title (top 140) collapsing to inline (top 88)
        # moves 52 points into the height; the decision does not change.
        for width, total in ((800, 780), (800, 820), (800, 920), (1000, 880)):
            large = fits(width, total - 140, 140)
            inline = fits(width, total - 88, 88)
            self.assertEqual(large, inline, (width, total))
        # The old height-only comparison flipped while scrolling at 800 x 920.
        self.assertNotEqual(800 > 920 - 140, 800 > 920 - 88)

    def test_arrangement_is_guarded_with_equal_hstack_fallback(self):
        self.assertIn("if #available(iOS 27.1, *)", self.wide)
        self.assertLess(self.wide.index("if #available(iOS 27.1, *)"), self.wide.index("ArrangementView {"))
        self.assertIn("} secondary: {", self.wide)
        self.assertIn(".arrangementViewStyle(.split.axes(.horizontal))", self.wide)
        fallback = self.wide.split("} else {", 1)[1]
        self.assertIn("HStack(spacing: 0)", fallback)
        self.assertEqual(fallback.count(".frame(maxWidth: .infinity)"), 2)
        self.assertLess(fallback.index("walletStackPane("), fallback.index("historyPane("))
        # Navigation stays outside; no hinge gutter or reserved-region query.
        for forbidden in ("ScrollView", "List {", "NavigationStack", "NavigationSplitView", "reservedRegions", "splitArrangementLayout"):
            self.assertNotIn(forbidden, self.wide)
        self.assertNotIn("reservedRegions", self.stack + self.pane)
        self.assertEqual(self.source.count("ArrangementView {"), 2)  # Scan + Cards

    def test_effective_selection_is_display_only_and_validated(self):
        selection = between(self.cards, "private var effectiveSelectedCardID: String? {", "private var effectiveSelectedCard:")
        self.assertIn("if let previewCardID, store.cards.contains(where: { $0.id == previewCardID }) {", selection)
        self.assertIn("return store.cards.first?.id", selection)
        self.assertNotIn("previewCardID =", selection)
        # Only explicit taps write the shared selection; layout changes never do.
        writes = re.findall(r"previewCardID = [^\n=]+", self.cards)
        self.assertEqual(sorted(writes), sorted(["previewCardID = nil", "previewCardID = card.id", "previewCardID = id"]))
        select = between(self.cards, "private func selectInWideLayout(_ id: String) {", "\n    }\n")
        self.assertLess(select.index("guard id != effectiveSelectedCardID else { return }"), select.index("store.bringToFront(id)"))
        self.assertLess(select.index("store.bringToFront(id)"), select.index("previewCardID = id"))

    def test_selection_and_mode_state_live_above_the_branch(self):
        head = self.cards.split("var body: some View {", 1)[0]
        for state in (
            "@State private var previewCardID: String?",
            "@State private var historyModeCardID: String?",
            "@State private var historyMode: QuickHistorySheet.HistoryMode",
            "@State private var activeHistoryItem: HistorySheetItem?",
            "@State private var detailRoute: CardDetailRoute?",
            "@State private var transactionDetailItem: TransactionDetailSheetItem?",
        ):
            self.assertIn(state, head)
        self.assertNotIn("@State", self.stack)
        self.assertNotIn("@State", self.pane)
        self.assertNotRegex(self.cards + self.stack + self.pane, r"\.id\([^\n]*(?:width|height|size|hinge)")
        self.assertNotRegex(self.cards, r"\.onChange\(of:")

    def test_sheets_attach_outside_compact_wide_branch(self):
        title = self.body.index('.navigationTitle("Cards")')
        branch = self.body[:title]
        self.assertNotIn(".sheet", branch)
        for binding in ("$activeHistoryItem", "$detailRoute", "$transactionDetailItem"):
            self.assertEqual(self.cards.count(".sheet(item: " + binding), 1)
            self.assertGreater(self.body.index(".sheet(item: " + binding), title)
        for builder in (self.wide, self.compact, self.stack, self.pane):
            self.assertNotIn(".sheet", builder)
        self.assertIn("QuickHistorySheet(mode: item.mode, card: item.card, store: store)", self.body)

    def test_compact_stack_keeps_existing_behavior(self):
        self.assertIn("private let stackedSpacing: CGFloat = 64", self.cards)
        self.assertIn("private let expandedStackGap: CGFloat = 12", self.cards)
        self.assertIn("expanded: previewCardID == card.id", self.compact)
        self.assertIn(".zIndex(zIndex(for: index))", self.compact)
        compact_card = between(self.cards, "private func walletCard(", "private func stackHeight(")
        self.assertIn("previewCardID = nil", compact_card)
        self.assertIn("store.bringToFront(card.id)", compact_card)
        self.assertIn("showTransactions: { activeHistoryItem = HistorySheetItem(mode: .transactions, card: card) }", compact_card)
        self.assertIn("showTransit: { activeHistoryItem = HistorySheetItem(mode: .transit, card: card) }", compact_card)
        self.assertIn('Text("No Cards Yet")', self.cards)

    def test_wide_history_buttons_choose_pane_mode_with_sheet_safety_net(self):
        show = between(self.cards, "private func showHistoryInWideLayout(", "// MARK: - Compact stack")
        self.assertIn("guard isHistoryPaneShown else {", show)
        self.assertIn("activeHistoryItem = HistorySheetItem(mode: mode, card: card)", show)
        self.assertIn("selectInWideLayout(card.id)", show)
        self.assertIn("historyModeCardID = card.id", show)
        self.assertIn("historyMode = mode", show)
        self.assertIn("storedMode: historyModeCardID == card.id ? historyMode : nil", self.cards)
        self.assertIn(".onAppear { isHistoryPaneShown = true }", self.cards)
        self.assertIn(".onDisappear { isHistoryPaneShown = false }", self.cards)
        self.assertIn("showDetails: { id in detailRoute = CardDetailRoute(id: id) }", self.cards)

    def test_wallet_stack_pane_uses_one_card_open_geometry(self):
        self.assertIn("ScrollView {", self.stack)
        self.assertIn("min(proxy.size.width - 40, WalletCardLayout.maximumWidth)", self.stack)
        self.assertIn("cardWidth / WalletCardLayout.aspectRatio", self.stack)
        self.assertIn(".padding(20)", self.stack)
        self.assertIn("return [selected] + cards.filter { $0.id != selectedCardID }", self.stack)
        self.assertIn("isExpanded: isFront", self.stack)
        self.assertIn(".zIndex(Double(index))", self.stack)
        # "Selected" goes on the card's title/balance element only, not on the
        # whole card (whose buttons would each announce it).
        self.assertIn("isSelected: isFront", self.stack)
        self.assertNotIn("accessibilityAddTraits", self.stack)
        self.assertIn("if !isFront { select(card.id) }", self.stack)
        self.assertIn("private let stackedSpacing: CGFloat = 64", self.stack)
        self.assertIn("private let expandedStackGap: CGFloat = 12", self.stack)
        self.assertIn("index == 0 ? 0 : cardHeight + expandedStackGap + CGFloat(index - 1) * stackedSpacing", self.stack)
        self.assertIn("return offset(for: cards.count - 1, cardHeight: cardHeight) + cardHeight", self.stack)

    def test_stack_geometry_keeps_last_card_fully_visible(self):
        def offset(index, card_height):
            return 0 if index == 0 else card_height + 12 + (index - 1) * 64

        for pane_width, count in ((512, 1), (512, 2), (512, 5), (360, 7), (900, 3)):
            card_width = max(min(pane_width - 40, 480), 1)
            card_height = card_width / (27 / 17)
            height = card_height if count == 1 else offset(count - 1, card_height) + card_height
            self.assertLessEqual(card_width, 480)
            self.assertLessEqual(card_width, pane_width - 40)
            for index in range(count):
                self.assertLessEqual(offset(index, card_height) + card_height, height + 1e-9)
            if count > 1:
                self.assertAlmostEqual(offset(1, card_height), card_height + 12)

    def test_history_pane_picker_default_and_empty_state(self):
        self.assertIn("if hasTransactions && hasTransit {", self.pane)
        self.assertIn(".pickerStyle(.segmented)", self.pane)
        self.assertLess(self.pane.index('Text("Transactions")'), self.pane.index('Text("Transit Activity")'))
        self.assertIn("return storedMode ?? .transit", self.pane)
        self.assertIn("return hasTransit ? .transit : .transactions", self.pane)
        self.assertIn('Image(systemName: "list.bullet.rectangle")', self.pane)
        self.assertIn(".font(.system(size: 40))", self.pane)
        self.assertIn('Text("No records found")', self.pane)
        self.assertIn(".font(.headline)", self.pane)
        self.assertIn(".id(card.id)", self.pane)
        self.assertIn("appearance: .pane", self.pane)
        for forbidden in ("NavigationStack", '"Done"', "List {", "ScrollView"):
            self.assertNotIn(forbidden, self.pane)
        for key in ("Transactions", "Transit Activity", "No records found", "Cards", "Reorder Cards"):
            self.assertIn(f'"{key}" = ', self.strings)

    def test_history_list_is_shared_by_sheet_and_pane(self):
        self.assertIn("CardHistoryList(mode: mode, card: card, store: store)", self.sheet)
        self.assertIn("NavigationStack {", self.sheet)
        self.assertIn('Label("Done", systemImage: "checkmark")', self.sheet)
        self.assertIn('.navigationTitle(mode == .transactions ? "Transactions" : "Transit Activity")', self.sheet)
        for moved in ("List {", "pendingDeletions", ".listStyle", ".scrollContentBackground"):
            self.assertNotIn(moved, self.sheet)
        shared = self.history_list
        self.assertIn("@State private var pendingDeletions: Set<String> = []", shared)
        self.assertEqual(shared.count("sortTransactionsByRecency("), 2)
        self.assertEqual(shared.count("pendingDeletions.insert(rawData)"), 2)
        self.assertEqual(shared.count(".swipeActions(edge: .trailing, allowsFullSwipe: false)"), 2)
        self.assertEqual(shared.count(
            "TransitTransactionRow(tx: tx, cardFamily: card.cardFamily, reportCard: card, onOpenDetails: onOpenDetails)"
        ), 2)
        self.assertIn("kind: .transactions", shared)
        self.assertIn("kind: .transit", shared)
        self.assertIn("var appearance: Appearance = .sheet", shared)
        pane_look = between(shared, "case .pane:", "private var list")
        for modifier in (".listStyle(.insetGrouped)", ".scrollContentBackground(.hidden)", "Color(uiColor: .systemBackground)"):
            self.assertIn(modifier, pane_look)
        sheet_look = between(shared, "case .sheet:", "case .pane:")
        self.assertEqual(sheet_look.strip(), "list")
        self.assertIn(".listRowBackground(Color(uiColor: .secondarySystemBackground))", shared)

    def test_row_detail_callback_defaults_to_the_rows_own_sheet(self):
        row = self.row
        self.assertIn("let onOpenDetails: ((TransitTransaction) -> Void)?", row)
        self.assertIn("onOpenDetails: ((TransitTransaction) -> Void)? = nil", row)
        self.assertIn("self.onOpenDetails = onOpenDetails", row)
        action = between(row, "Button {", "} label: {")
        self.assertIn("if let onOpenDetails {", action)
        self.assertIn("onOpenDetails(tx)", action)
        self.assertIn("showingDetails = true", action)
        self.assertLess(action.index("onOpenDetails(tx)"), action.index("} else {"))
        self.assertLess(action.index("} else {"), action.index("showingDetails = true"))
        # Without a callback the row still presents its own detail sheet.
        self.assertIn("@State private var showingDetails = false", row)
        self.assertIn(".sheet(isPresented: $showingDetails) {", row)
        self.assertIn("TransactionDetailView(tx: tx, cardFamily: cardFamily, reportCard: reportCard)", row)
        # The shared list only passes the optional callback through.
        self.assertIn("var onOpenDetails: ((TransitTransaction) -> Void)? = nil", self.history_list)
        self.assertNotIn(".sheet(", self.history_list)
        # The Quick History sheet (and every other row call site) keeps self-presenting rows.
        self.assertNotIn("onOpenDetails", self.sheet)
        for other in (self.source.split("struct CardsView: View {", 1)[0],
                      (ROOT / "ios/CardBal/Views/SavedCardDetailView.swift").read_text()):
            self.assertNotIn("onOpenDetails", other)

    def test_wide_pane_transaction_sheet_is_held_by_cards_view(self):
        self.assertIn("let openDetails: (TransitTransaction) -> Void", self.pane)
        self.assertIn("onOpenDetails: openDetails", self.pane)
        history_pane = between(self.cards, "private func historyPane(for card: SavedCardRecord)", "private func selectInWideLayout(")
        self.assertIn("openDetails: { tx in", history_pane)
        self.assertIn("transactionDetailItem = TransactionDetailSheetItem(", history_pane)
        for field in ("cardID: card.id", "tx: tx", "cardFamily: card.cardFamily", "reportCard: card"):
            self.assertIn(field, history_pane)
        # The sheet is resolved from the stored record values, not from the pane.
        item = between(self.secondary, "struct TransactionDetailSheetItem: Identifiable {", "\n}\n")
        for field in ("let id = UUID()", "let cardID: String", "let tx: TransitTransaction",
                      "let cardFamily: String?", "let reportCard: SavedCardRecord"):
            self.assertIn(field, item)
        sheet = between(self.body, ".sheet(item: $transactionDetailItem) { item in", "}")
        self.assertIn("TransactionDetailView(tx: item.tx, cardFamily: item.cardFamily, reportCard: item.reportCard)", sheet)
        # Attached beside the other routes, above the compact/wide branch.
        title = self.body.index('.navigationTitle("Cards")')
        self.assertGreater(self.body.index(".sheet(item: $transactionDetailItem)"), title)
        self.assertGreater(self.body.index(".sheet(item: $transactionDetailItem)"), self.body.index(".sheet(item: $detailRoute)"))

    def test_history_mode_resets_when_a_card_is_selected_again(self):
        reset = between(self.cards, "private func resetHistoryMode() {", "\n    }\n")
        self.assertIn("historyModeCardID = nil", reset)
        self.assertIn("historyMode = .transit", reset)
        select = between(self.cards, "private func selectInWideLayout(_ id: String) {", "\n    }\n")
        self.assertLess(select.index("previewCardID = id"), select.index("resetHistoryMode()"))
        compact_card = between(self.cards, "private func walletCard(", "private func stackHeight(")
        selecting = between(compact_card, "} else {", "}")
        self.assertIn("previewCardID = card.id", selecting)
        self.assertLess(selecting.index("previewCardID = card.id"), selecting.index("resetHistoryMode()"))
        # Collapsing the open card is not a new selection.
        collapsing = between(compact_card, "if previewCardID == card.id {", "} else {")
        self.assertNotIn("resetHistoryMode()", collapsing)
        # The card's own history buttons still set an explicit mode after selecting.
        show = between(self.cards, "private func showHistoryInWideLayout(", "// MARK: - Compact stack")
        self.assertLess(show.index("selectInWideLayout(card.id)"), show.index("historyModeCardID = card.id"))
        self.assertLess(show.index("selectInWideLayout(card.id)"), show.index("historyMode = mode"))

    def test_selected_trait_is_on_the_card_identity_element_only(self):
        card = self.wallet_card
        self.assertIn("var isSelected: Bool = false", card)
        identity = between(card, "HStack(alignment: .firstTextBaseline, spacing: 8) {", "HStack(alignment: .firstTextBaseline, spacing: 8) {")
        self.assertIn("card.localizedDisplayTitle", identity)  # 2.5.0 localizes card titles
        self.assertIn("card.visibleBalance", identity)
        self.assertIn(".modifier(SelectedCardIdentity(isSelected: isSelected))", identity)
        self.assertEqual(card.count("SelectedCardIdentity(isSelected:"), 1)
        modifier = between(card, "private struct SelectedCardIdentity: ViewModifier {", "extension SavedCardRecord")
        self.assertIn("if isSelected {", modifier)
        self.assertIn(".accessibilityElement(children: .combine)", modifier)
        self.assertIn(".accessibilityAddTraits(.isSelected)", modifier)
        # Unselected cards keep their existing accessibility elements.
        self.assertEqual(between(modifier, "} else {", "}").strip(), "content")
        self.assertEqual(card.count("accessibilityAddTraits"), 1)
        # Every other call site compiles with the default; only the wide stack passes it.
        calls = []
        for path in ("ios/CardBal/ContentView.swift", "ios/CardBal/Views/SavedCardDetailView.swift"):
            calls += re.findall(r"WalletCardView\(\n(.*?)\n\s*\)", (ROOT / path).read_text(), re.S)
        self.assertEqual(len(calls), 5)
        self.assertEqual([call for call in calls if "isSelected" in call], [call for call in calls if "isFront" in call])
        self.assertEqual(sum("isSelected: isFront" in call for call in calls), 1)

    def test_reorder_list_is_capped_at_regular_width(self):
        reorder = self.source.split("struct ReorderCardsView: View {", 1)[1]
        self.assertIn(".frame(maxWidth: horizontalSizeClass == .regular ? 560 : .infinity)", reorder)
        self.assertIn(".onMove { from, to in", reorder)
        self.assertIn("EditButton()", reorder)


if __name__ == "__main__":
    unittest.main()
