"""City Union / T-Union are read before the Chinese local reader, as in 2.5.2.

The local reader's SELECTs (and Beijing's OC/PBOC names, which Core NFC cannot
select) ran first in 2.6.0 and left City Union-only cards unreadable.
"""
import re
import unittest

from tools.paths import ROOT

IOS = ROOT / "ios/CardBal/NFC"
ANDROID = ROOT / "android/app/src/main/java/ad/neko/cardbal/android/nfc"


def names(text, suffix):
    return re.findall(r"\b(\w+Decoder)" + suffix, text)


class ChinaLocalOrderTests(unittest.TestCase):
    def test_built_in_reader_tries_2_5_2_iso_readers_first(self):
        reader = (IOS / "NFCTransitReader.swift").read_text()
        start = reader.index(": phase == .octopus ? [OctopusFeliCaDecoder.self] : [")
        regular = names(reader[start:reader.index("]", reader.index("JapaneseICDecoder.self", start))], r"\.self")[1:]
        self.assertEqual(regular, [
            "CEPASDecoder", "MacauPassDecoder", "ClipperDecoder", "ClipperUltralightDecoder",
            "StoredValueDecoder", "TianfuTongDecoder", "ChineseTransitDecoder", "CalypsoDecoder", "KSX6924Decoder",
            "ChineseLocalDecoder", "EdyDecoder", "WAONDecoder", "NanacoDecoder", "JapaneseICDecoder",
        ])
        self.assertLess(regular.index("ChineseTransitDecoder"), regular.index("ChineseLocalDecoder"))
        self.assertEqual(regular.index("KSX6924Decoder") + 1, regular.index("ChineseLocalDecoder"))
        # La Carte reordering is untouched.
        self.assertIn("decoders.insert(decoders.remove(at: index), at: 0)", reader)
        # A local application found beside City Union / T-Union is added after that read.
        loop = reader.index("for decoder in decoders {", start)
        added = reader.index("ChineseLocalDecoder.addingLocalApplication(to: primary, tag: cardTag)", loop)
        self.assertLess(loop, added)
        self.assertIn("if phase == .regular, let primary = snapshot {", reader[loop:added])

    def test_external_reader_tries_city_union_before_local(self):
        source = (IOS / "ExternalCardReader.swift").read_text()
        scan = source[source.index("if options.contains(.iso14443) {"):source.index("struct ACR122UltralightCard")]
        city_union = scan.index("let aids = [CityUnionDecoder.applicationAID, TUnionDecoder.applicationAID,")
        local = scan.index("try? await ChineseLocalDecoder.decode(")
        self.assertLess(city_union, local)
        self.assertEqual(scan.count("ChineseLocalDecoder.decode("), 1)
        self.assertLess(scan.index("for aid in aids {"), scan.index("ChineseLocalDecoder.addingLocalApplication("))
        self.assertLess(scan.index("ChineseLocalDecoder.addingLocalApplication("), local)
        self.assertIn("var selectsUnlistedApplications: Bool { true }", source)

    def test_beijing_names_only_on_readers_that_can_select_them(self):
        transport = (IOS / "CardTransport.swift").read_text()
        protocol = transport[transport.index("protocol ISO7816Card {"):]
        self.assertIn("var selectsUnlistedApplications: Bool { get }", protocol[:protocol.index("\n}")])
        self.assertRegex(transport, r"extension ISO7816Card \{\s*var selectsUnlistedApplications: Bool \{ false \}")
        core = (IOS / "CoreNFCCardTransport.swift").read_text()
        self.assertNotIn("selectsUnlistedApplications", core)
        decoder = (IOS / "Decoders/ChineseLocalDecoder.swift").read_text()
        self.assertIn("iso.selectsUnlistedApplications ? ChineseLocalProtocol.Kind.allCases : [.shenzhen, .wuhan]", decoder)
        self.assertIn("ChineseLocalProtocol.read(kinds: kinds,", decoder)
        protocol = (IOS / "Profiles/ChineseLocalProtocol.swift").read_text()
        self.assertIn("static func read(kinds: [Kind] = Kind.allCases,", protocol)
        self.assertIn("for kind in kinds {", protocol)
        self.assertNotIn("for kind in Kind.allCases", protocol)
        plist = (ROOT / "ios/CardBal/Info.plist").read_text()
        identifiers = plist[plist.index("select-identifiers"):]
        identifiers = identifiers[:identifiers.index("</array>")]
        self.assertIn("<string>5041592E535A54</string>", identifiers)
        self.assertIn("<string>4150312E5748435443</string>", identifiers)
        self.assertNotIn("<string>4F43</string>", identifiers)
        self.assertNotIn("<string>50424F43</string>", identifiers)

    def test_android_reads_iso7816_before_local(self):
        reader = (ANDROID / "CardBalNfcReader.kt").read_text()
        listing = reader[reader.index("fun orderedDecoders("):]
        listing = listing[:listing.index("\n        )")]
        order = names(listing, r"\(")
        self.assertEqual(order, [
            "CEPASDecoder", "MacauPassDecoder", "ClipperDecoder", "ClipperUltralightDecoder",
            "StoredValueDecoder", "CalypsoDecoder", "Iso7816Decoder", "ChineseLocalDecoder", "JapaneseICDecoder",
        ])


if __name__ == "__main__":
    unittest.main()
