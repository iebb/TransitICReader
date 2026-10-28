from __future__ import annotations

import unittest
from unittest.mock import patch


import tools.boundaries.optimize as optimizer


def boundary(
    boundary_id: str,
    country_code: str,
    name: str,
    *,
    subdivision_code: str | None = None,
    coverage_name: str | None = None,
) -> dict:
    value = {
        "id": boundary_id,
        "countryCode": country_code,
        "name": name,
    }
    if subdivision_code is not None:
        value["subdivisionCode"] = subdivision_code
    if coverage_name is not None:
        value["coverageName"] = coverage_name
    return value


class ProvinceCoverageJoinTests(unittest.TestCase):
    def setUp(self) -> None:
        self.province_catalog = {
            "version": 2,
            "boundaries": [
                boundary(
                    "cn:province:guangxi",
                    "CN",
                    "Guangxi",
                    coverage_name="Guangxi Zhuang Autonomous Region",
                ),
                boundary(
                    "jp:province:hokkaido",
                    "JP",
                    "Hokkaido",
                    subdivision_code="JP-01",
                ),
                boundary("kr:adm1:seoul", "KR", "Seoul"),
                boundary("mn:province:tov", "MN", "Tov"),
            ],
            "mongoliaStationToBoundary": {"station:1": "mn:province:tov"},
        }
        self.city_catalog = {
            "version": 2,
            "boundaries": [
                boundary(
                    "jp:city:sapporo",
                    "JP",
                    "Sapporo",
                    subdivision_code="JP-01",
                ),
                boundary("kr:seoul", "KR", "Seoul"),
                boundary("mn:city:ulaanbaatar", "MN", "Ulaanbaatar"),
            ],
            "mongoliaCityToProvince": {
                "mn:city:ulaanbaatar": "mn:province:tov",
            },
        }
        self.coverage = {
            "supportedProvinceNames": ["Guangxi Zhuang Autonomous Region"],
        }

    def prune(self) -> dict:
        with patch.object(optimizer, "boundary_geometry", return_value=object()):
            return optimizer.prune_province_catalog_to_supported_boundaries(
                self.province_catalog,
                self.city_catalog,
                self.coverage,
                tools={},
            )

    def test_concise_display_name_is_retained_via_formal_coverage_name(self) -> None:
        output = self.prune()

        china_boundary = next(
            item for item in output["boundaries"] if item["countryCode"] == "CN"
        )
        self.assertEqual(china_boundary["name"], "Guangxi")
        self.assertEqual(
            china_boundary["coverageName"],
            "Guangxi Zhuang Autonomous Region",
        )

    def test_coverage_name_mismatch_fails(self) -> None:
        self.coverage["supportedProvinceNames"] = ["Guangxi Province"]

        with self.assertRaisesRegex(
            RuntimeError,
            "China supported province names do not match",
        ):
            self.prune()

    def test_duplicate_coverage_names_fail_before_pruning(self) -> None:
        self.province_catalog["boundaries"].insert(
            1,
            boundary(
                "cn:province:duplicate",
                "CN",
                "Different display name",
                coverage_name="Guangxi Zhuang Autonomous Region",
            ),
        )

        with self.assertRaisesRegex(RuntimeError, "coverage names must be unique"):
            self.prune()


if __name__ == "__main__":
    unittest.main()
