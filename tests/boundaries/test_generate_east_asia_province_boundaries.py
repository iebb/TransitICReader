from __future__ import annotations

import json
import unittest
from collections import Counter


import tools.boundaries.provinces as generator
from tools.paths import BOUNDARIES
PROVINCE_CATALOG = BOUNDARIES / "EastAsiaProvinceBoundaries.json"
CHINA_COVERAGE = BOUNDARIES / "ChinaTransitCoverage.json"


class ReviewedProvinceNameTests(unittest.TestCase):
    def test_reviewed_name_catalogs_cover_every_pinned_adm1_source(self) -> None:
        self.assertEqual(len(generator.CHINA_NATIVE_NAMES), 33)
        self.assertEqual(len(generator.JAPAN_NAMES_BY_SUBDIVISION_CODE), 47)
        self.assertEqual(len(generator.KOREA_NAMES_BY_SUBDIVISION_CODE), 17)
        self.assertEqual(len(generator.MONGOLIA_NAMES_BY_SUBDIVISION_CODE), 22)

    def test_normalization_separates_display_native_and_coverage_names(self) -> None:
        self.assertEqual(
            generator.normalized_province_names(
                "CN",
                "Guangzhou Province",
                "",
            ),
            ("Guangdong", "广东省", "Guangdong Province"),
        )
        self.assertEqual(
            generator.normalized_province_names(
                "JP",
                "Kyoto Prefecture",
                "JP-26",
            ),
            ("Kyoto", "京都府", None),
        )
        self.assertEqual(
            generator.normalized_province_names(
                "KR",
                "Gangwon",
                "KR-42",
            ),
            ("Gangwon", "강원특별자치도", None),
        )
        self.assertEqual(
            generator.normalized_province_names(
                "MN",
                "Hovsgel",
                "MN-041",
            ),
            ("Khövsgöl", "Хөвсгөл аймаг", None),
        )


class GeneratedProvinceCatalogTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.catalog = json.loads(PROVINCE_CATALOG.read_bytes())
        cls.boundaries = cls.catalog["boundaries"]

    def test_supported_counts_and_names_are_normalized(self) -> None:
        self.assertEqual(
            Counter(boundary["countryCode"] for boundary in self.boundaries),
            Counter({"CN": 33, "JP": 46, "KR": 13, "MN": 2}),
        )
        redundant_suffixes = (
            " Province",
            " Prefecture",
            " Municipality",
            " Autonomous Region",
            " Special Administrative Region",
            " State",
        )
        for boundary in self.boundaries:
            with self.subTest(boundary=boundary["id"]):
                self.assertFalse(boundary["name"].endswith(redundant_suffixes))
                self.assertNotEqual(boundary["name"], boundary["nativeName"])
                self.assertTrue(any(ord(character) > 127 for character in boundary["nativeName"]))

    def test_china_coverage_names_are_a_unique_exact_registry_join(self) -> None:
        coverage = json.loads(CHINA_COVERAGE.read_text(encoding="utf-8"))
        china_boundaries = [
            boundary for boundary in self.boundaries if boundary["countryCode"] == "CN"
        ]
        coverage_names = [boundary["coverageName"] for boundary in china_boundaries]

        self.assertEqual(len(coverage_names), len(set(coverage_names)))
        self.assertEqual(set(coverage_names), set(coverage["supportedProvinceNames"]))
        for boundary in china_boundaries:
            with self.subTest(boundary=boundary["id"]):
                self.assertEqual(
                    boundary["nativeName"],
                    generator.CHINA_NATIVE_NAMES[boundary["coverageName"]],
                )
                self.assertEqual(
                    boundary["name"],
                    generator.CHINA_CONCISE_NAMES[boundary["coverageName"]],
                )

    def test_japanese_labels_use_concise_english_and_native_admin_suffixes(self) -> None:
        japan_boundaries = [
            boundary for boundary in self.boundaries if boundary["countryCode"] == "JP"
        ]
        for boundary in japan_boundaries:
            with self.subTest(boundary=boundary["id"]):
                expected_name, expected_native_name = (
                    generator.JAPAN_NAMES_BY_SUBDIVISION_CODE[
                        boundary["subdivisionCode"]
                    ]
                )
                self.assertEqual(boundary["name"], expected_name)
                self.assertEqual(boundary["nativeName"], expected_native_name)
                self.assertTrue(boundary["nativeName"].endswith(("都", "道", "府", "県")))

    def test_jeonnam_gwangju_is_one_dissolved_authoritative_boundary(self) -> None:
        change = self.catalog["generation"]["administrativeChanges"][0]
        self.assertEqual(change["kind"], "provinceMerge")
        self.assertEqual(change["newBoundaryID"], "kr:province:jeonnam-gwangju")
        self.assertEqual(change["name"], "Jeonnam-Gwangju")
        self.assertEqual(change["nativeName"], "전남광주통합특별시")
        self.assertEqual(
            change["statutoryEnglishName"],
            "Jeonnam-Gwangju Special Metropolitan City",
        )
        self.assertEqual(change["mergedFromSubdivisionCodes"], ["KR-29", "KR-46"])
        self.assertEqual(change["effectiveDate"], "2026-07-01")
        self.assertEqual(len(change["mergedFromBoundaryIDs"]), 2)
        self.assertEqual(len(change["supportedCityIDs"]), 6)
        self.assertEqual(change["supportedCityIDs"], sorted(set(change["supportedCityIDs"])))

        merged = [
            boundary
            for boundary in self.boundaries
            if boundary["id"] == change["newBoundaryID"]
        ]
        self.assertEqual(len(merged), 1)
        self.assertEqual(merged[0]["name"], change["name"])
        self.assertEqual(merged[0]["nativeName"], change["nativeName"])
        self.assertNotIn("subdivisionCode", merged[0])
        self.assertEqual(sum(len(component["holes"]) for component in merged[0]["components"]), 0)

        emitted_ids = {boundary["id"] for boundary in self.boundaries}
        emitted_codes = {
            boundary.get("subdivisionCode") for boundary in self.boundaries
        }
        self.assertTrue(set(change["mergedFromBoundaryIDs"]).isdisjoint(emitted_ids))
        self.assertTrue(set(change["mergedFromSubdivisionCodes"]).isdisjoint(emitted_codes))


if __name__ == "__main__":
    unittest.main()
