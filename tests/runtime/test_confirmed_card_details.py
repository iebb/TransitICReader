"""Normal detail presentation contracts; decoder/runtime tests cover the values.

These source checks are not rendered UI tests. They keep the unknown-value guards
on both platforms and ensure raw Hanica diagnostics remain available.
"""
import unittest

from tools.paths import ROOT


def source(path):
    return (ROOT / path).read_text()


class ConfirmedCardDetailsTests(unittest.TestCase):
    def test_android_normal_details_do_not_render_free_form_decoder_notes(self):
        activity = source("android/app/src/main/java/ad/neko/cardbal/android/MainActivity.kt")
        details = activity.split("private fun CardDetails(", 1)[1].split("@Composable", 1)[0]
        self.assertNotIn("card.balanceDetail", details)
        self.assertNotIn('DetailRow("Decoder"', details)
        self.assertIn("card.balanceScopeNote", details)
        saved = source("android/app/src/main/java/ad/neko/cardbal/android/ui/TransitWidgets.kt")
        self.assertNotIn("card.balanceDetail", saved)
        self.assertIn("card.balanceScopeNote", saved)

    def test_unsupported_fares_are_omitted_not_replaced_with_zero(self):
        swift = source("ios/CardBal/NFC/NFCUtils.swift")
        row = swift.split("struct TransitTransactionRow: View {", 1)[1].split("struct TransactionDetailView:", 1)[0]
        self.assertNotIn('Text("Fare unavailable")', row)
        self.assertNotIn('Text("Fare unknown")', row)
        self.assertIn("if tx.amountKnown && tx.amount != 0", row)
        self.assertIn("else if tx.amountKnown && !(brand.isKorean && tx.hasUnresolvedKoreanTransitFare)", row)
        self.assertIn("if let bal = tx.balanceAfter", row)
        android = source("android/app/src/main/java/ad/neko/cardbal/android/ui/TransitWidgets.kt")
        row = android.split("fun TransactionRow(", 1)[1].split("fun TransitRouteMap(", 1)[0]
        self.assertNotIn("Fare unavailable", row)
        self.assertIn("if (tx.amountKnown && tx.amount != 0L)", row)
        self.assertIn("tx.balanceAfter?.let", row)

    def test_missing_application_and_secondary_balances_have_no_placeholder(self):
        saved = source("ios/CardBal/Views/SavedCardDetailView.swift")
        self.assertIn("if let balance = application.balanceText, !balance.isEmpty", saved)
        self.assertNotIn('application.balanceText ?? String(localized: "Unavailable")', saved)
        swift = source("ios/CardBal/Views/SecondaryViews.swift").split("struct BalanceRows: View {", 1)[1]
        self.assertNotIn('"Unavailable"', swift)
        self.assertIn("if let yuan = dual.yuanBalance", swift)
        android = source("android/app/src/main/java/ad/neko/cardbal/android/ui/CardWidgets.kt")
        dual = android.split("fun DualBalanceRows(", 1)[1].split("private fun BalanceValueRow", 1)[0]
        self.assertNotIn('"Unavailable"', dual)
        self.assertIn("if (yuan != null)", dual)

    def test_hanica_raw_diagnostics_and_confirmed_only_balance_are_preserved(self):
        swift = source("ios/CardBal/NFC/Decoders/JapaneseICDecoder.swift")
        android = source("android/app/src/main/java/ad/neko/cardbal/android/nfc/JapaneseICDecoder.kt")
        self.assertIn('RawDataField(title: "Decoder", value: detail)', swift)
        self.assertIn('RawDataField("Decoder", detail)', android)
        self.assertIn('balanceText: confirmed.map', swift)
        self.assertIn('balanceText = confirmed?.let', android)
        for code in (swift, android):
            self.assertIn("Hanica balance layout unconfirmed", code)
            self.assertIn("Log Block", code)

    def test_cepas_scope_note_is_the_balance_qualification_on_both_platforms(self):
        cepas = "On-card stored-value purse only. SimplyGo account balances are not read."
        record = source("ios/CardBal/Models/SavedCardRecord.swift")
        scope = record.split("static func balanceScopeNote(", 1)[1].split("var hasNoStoredBalance", 1)[0]
        self.assertIn(cepas, scope)
        rows = source("ios/CardBal/Views/SecondaryViews.swift").split("struct BalanceRows: View {", 1)[1]
        self.assertIn("if let scopeNote", rows)
        for path in ("ios/CardBal/Views/SavedCardDetailView.swift", "ios/CardBal/ContentView.swift"):
            self.assertIn("scopeNote: SavedCardRecord.balanceScopeNote(", source(path))
        models = source("android/app/src/main/java/ad/neko/cardbal/android/data/Models.kt")
        self.assertIn(cepas, models.split("val balanceScopeNote", 1)[1].split("val finalIsUsingImage", 1)[0])

    def test_orphaned_cepas_reader_string_is_gone(self):
        orphan = "EZ-Link (CEPAS) requires an external reader."
        paths = [p for p in ROOT.glob("ios/CardBal/Resources/*.lproj/Localizable.strings")]
        paths += list(ROOT.glob("android/app/src/main/res/values*/localized.xml"))
        paths.append(ROOT / "android/app/src/main/java/ad/neko/cardbal/android/ui/LocalizedResources.kt")
        self.assertGreater(len(paths), 8)
        for path in paths:
            text = path.read_text()
            self.assertNotIn(orphan, text, path)
            self.assertNotIn("text_64d9ed0495217375", text, path)
