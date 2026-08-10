from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path


SCRIPT_PATH = Path(__file__).resolve().parents[1] / "build_cross_platform_station_assets.py"
SPEC = importlib.util.spec_from_file_location("build_cross_platform_station_assets", SCRIPT_PATH)
assert SPEC and SPEC.loader
packager = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(packager)


class UnifiedAssetRoutingTests(unittest.TestCase):
    def test_unified_databases_are_cardbal_ios_and_portable_only(self) -> None:
        unified = set(packager.UNIFIED_ASSETS)

        self.assertTrue(unified.issubset(packager.asset_names("all")))
        self.assertTrue(unified.issubset(packager.ios_asset_names("all")))
        self.assertTrue(unified.isdisjoint(packager.platform_asset_names("all")))

    def test_partial_targets_never_copy_stale_unified_databases(self) -> None:
        unified = set(packager.UNIFIED_ASSETS)

        for target in ("japanese", "tunion", "korean", "ulaanbaatar"):
            with self.subTest(target=target):
                self.assertTrue(unified.isdisjoint(packager.asset_names(target)))
                self.assertTrue(unified.isdisjoint(packager.ios_asset_names(target)))
                self.assertTrue(unified.isdisjoint(packager.platform_asset_names(target)))


if __name__ == "__main__":
    unittest.main()
