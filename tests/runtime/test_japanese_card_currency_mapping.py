import re
import unittest


from tools.paths import ROOT
NFC_UTILS = ROOT / "ios/CardBal/NFC/NFCUtils.swift"
FELICA_PROFILES = ROOT / "ios/CardBal/NFC/Profiles/FeliCaProfiles.swift"


class JapaneseCardCurrencyMappingTests(unittest.TestCase):
    def test_every_japanese_detected_family_uses_jpy(self) -> None:
        utils = NFC_UTILS.read_text(encoding="utf-8")
        profiles = FELICA_PROFILES.read_text(encoding="utf-8")

        family_set_match = re.search(
            r"japaneseFeliCaFamilies: Set<String> = \[(.*?)\n    \]",
            utils,
            re.DOTALL,
        )
        self.assertIsNotNone(family_set_match)
        mapped_families = {
            value.lower()
            for value in re.findall(r'"([^"]+)"', family_set_match.group(1))
        }

        sc_map_match = re.search(
            r"let scMap: \[String: String\] = \[(.*?)\n        \]",
            profiles,
            re.DOTALL,
        )
        self.assertIsNotNone(sc_map_match)
        detected_families = {
            family.lower()
            for _, family in re.findall(
                r'"([0-9A-F]{4})": "([^"]+)"', sc_map_match.group(1)
            )
        }

        dedicated_japanese_families = {
            "suica",
            "hayakaken",
            "nanaco",
            "rakuten edy",
            "okica",
        }
        non_japanese_families = {"shenzhen tong", "octopus"}
        expected_generic_families = (
            detected_families
            - dedicated_japanese_families
            - non_japanese_families
        )

        self.assertEqual(mapped_families, expected_generic_families)
        self.assertRegex(
            utils,
            r"case .*\.japaneseFeliCa: return \.japan",
        )
        self.assertRegex(
            utils,
            r"if japaneseFeliCaFamilies\.contains\(f\) \{ return \.japaneseFeliCa \}",
        )


if __name__ == "__main__":
    unittest.main()
