from __future__ import annotations

import json
import sqlite3
import tempfile
import unittest
from unittest.mock import patch
from contextlib import closing
from pathlib import Path


import tools.stations.build as packager
from tools.paths import ROOT
PROJECT_PATH = ROOT / "CardBal.xcodeproj/project.pbxproj"


class UnifiedAssetRoutingTests(unittest.TestCase):
    def test_copy_only_projects_platform_outputs_and_android_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            portable, ios, android = (root / name for name in ("portable", "ios", "android"))
            portable.mkdir()
            for name in packager.asset_names("all"):
                (portable / name).write_bytes(b"runtime-or-build-input")
            files = {name: {"bytes": 22, "sha256": "fixture"} for name in packager.asset_names("all")}
            files["debug-cache.json"] = {"bytes": 1, "sha256": "fixture"}
            def manifest(*_):
                (portable / "manifest.json").write_text(json.dumps({"files": files, "sqlite": {}}))
            with patch("sys.argv", ["packager", "--copy-only", "--portable-assets", str(portable),
                                     "--ios-resources", str(ios), "--android-assets", str(android)]), \
                 patch.object(packager, "write_manifest", side_effect=manifest):
                packager.main()
            self.assertEqual({p.name for p in ios.iterdir()}, {
                "JPBusCodes.csv", "JPStationCodes.csv", "TUnionCardNames.json",
                "TUnionCityCodes.json", "TUnionLineStations.json", "KOTRISTransportModes.json",
                "cardbal_transit.sqlite",
            })
            expected_android = {"JPBusCodes.csv", "JPStationCodes.csv", "jp_stations.sqlite", "tunion_stations.sqlite", "KOTRISTransportModes.json", "cardbal_transit.sqlite", "ClipperTransit.json"}
            self.assertEqual({p.name for p in android.iterdir()}, expected_android | {"manifest.json"})
            self.assertEqual(set(json.loads((android / "manifest.json").read_text())["files"]), expected_android)

    def test_platform_lists_contain_only_actual_runtime_readers(self) -> None:
        self.assertEqual(set(packager.platform_asset_names("all")), {
            "JPBusCodes.csv", "JPStationCodes.csv", "jp_stations.sqlite",
            "tunion_stations.sqlite", "cardbal_transit.sqlite", "KOTRISTransportModes.json",
            "ClipperTransit.json",
        })
        self.assertEqual(set(packager.ios_asset_names("all")), {
            "JPBusCodes.csv", "JPStationCodes.csv", "TUnionCardNames.json",
            "TUnionCityCodes.json", "TUnionLineStations.json",
            "KOTRISTransportModes.json", "cardbal_transit.sqlite",
        })

    def test_one_unified_database_is_shared_by_both_platforms(self) -> None:
        self.assertEqual(packager.UNIFIED_ASSETS, ["cardbal_transit.sqlite"])
        unified = set(packager.UNIFIED_ASSETS)

        self.assertTrue(unified.issubset(packager.asset_names("all")))
        self.assertTrue(unified.issubset(packager.ios_asset_names("all")))
        self.assertTrue(unified.issubset(packager.platform_asset_names("all")))

    def test_partial_targets_never_copy_the_unified_database(self) -> None:
        unified = set(packager.UNIFIED_ASSETS)

        for target in ("japanese", "tunion", "korean", "ulaanbaatar"):
            with self.subTest(target=target):
                self.assertTrue(unified.isdisjoint(packager.asset_names(target)))
                self.assertTrue(unified.isdisjoint(packager.ios_asset_names(target)))
                self.assertTrue(unified.isdisjoint(packager.platform_asset_names(target)))

    def test_partial_refresh_rebuilds_ios_runtime_without_sending_it_to_android(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            portable, ios, android = (root / name for name in ("portable", "ios", "android"))
            portable.mkdir()
            (portable / "cardbal_transit.sqlite").write_bytes(b"old-runtime")

            def refresh(*_):
                (portable / "ulaanbaatar_transit.sqlite").write_bytes(b"fresh-stops")

            def rebuild(*_):
                self.assertEqual((portable / "ulaanbaatar_transit.sqlite").read_bytes(), b"fresh-stops")
                (portable / "cardbal_transit.sqlite").write_bytes(b"fresh-runtime")

            def manifest(*_):
                self.assertEqual((portable / "cardbal_transit.sqlite").read_bytes(), b"fresh-runtime")
                (portable / "manifest.json").write_text('{"files":{}}')

            with patch("sys.argv", [
                "packager", "--target", "ulaanbaatar", "--rebuild-unified",
                "--source", "upstream",
                "--portable-assets", str(portable), "--ios-resources", str(ios),
                "--android-assets", str(android),
            ]), patch.object(packager, "build_ulaanbaatar", side_effect=refresh), \
                 patch.object(packager, "build_unified_database", side_effect=rebuild) as build, \
                 patch.object(packager, "write_manifest", side_effect=manifest):
                packager.main()
            build.assert_called_once()
            self.assertEqual((ios / "cardbal_transit.sqlite").read_bytes(), b"fresh-runtime")
            self.assertFalse((android / "ulaanbaatar_transit.sqlite").exists())
            self.assertEqual(json.loads((android / "manifest.json").read_text())["files"], {})
            self.assertFalse((android / "cardbal_transit.sqlite").exists())

    def test_split_unified_database_names_are_not_routed(self) -> None:
        split_names = {
            "cardbal_stations.sqlite",
            "cardbal_cities.sqlite",
            "cardbal_provinces.sqlite",
        }

        for target in ("all", "japanese", "tunion", "korean", "ulaanbaatar"):
            with self.subTest(target=target):
                routed = (
                    set(packager.asset_names(target))
                    | set(packager.ios_asset_names(target))
                    | set(packager.platform_asset_names(target))
                )
                self.assertTrue(split_names.isdisjoint(routed))

    def test_manifest_counts_all_unified_tables_from_one_database(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            assets = Path(temporary_directory)
            database = assets / "cardbal_transit.sqlite"
            with closing(sqlite3.connect(database)) as connection, connection:
                connection.executescript(
                    """
                    CREATE TABLE stations (id TEXT PRIMARY KEY);
                    CREATE TABLE cities (id TEXT PRIMARY KEY);
                    CREATE TABLE provinces (id TEXT PRIMARY KEY);
                    INSERT INTO stations VALUES ('station:1'), ('station:2');
                    INSERT INTO cities VALUES ('city:1');
                    INSERT INTO provinces VALUES ('province:1'), ('province:2'), ('province:3');
                    """
                )

            packager.write_manifest(assets)
            manifest = json.loads((assets / "manifest.json").read_text(encoding="utf-8"))

        self.assertEqual(manifest["sqlite"]["cardbal_transit_stations"], 2)
        self.assertEqual(manifest["sqlite"]["cardbal_transit_cities"], 1)
        self.assertEqual(manifest["sqlite"]["cardbal_transit_provinces"], 3)
        self.assertNotIn("cardbal_stations", manifest["sqlite"])
        self.assertNotIn("cardbal_cities", manifest["sqlite"])
        self.assertNotIn("cardbal_provinces", manifest["sqlite"])

    def test_xcode_bundles_only_the_unified_transit_sqlite(self) -> None:
        project = PROJECT_PATH.read_text(encoding="utf-8")

        self.assertEqual(project.count("cardbal_transit.sqlite in Resources"), 2)
        for legacy_name in (
            "jp_stations.sqlite",
            "tunion_stations.sqlite",
            "ulaanbaatar_transit.sqlite",
            "cardbal_stations.sqlite",
            "cardbal_cities.sqlite",
            "cardbal_provinces.sqlite",
        ):
            with self.subTest(legacy_name=legacy_name):
                self.assertNotIn(f"{legacy_name} in Resources", project)

        for source_catalog in (
            "korean_stations.tsv",
            "EastAsiaCityBoundaries.json",
            "EastAsiaProvinceBoundaries.json",
            "ChinaTransitCoverage.json",
            "JapanTransitCoverage.json",
        ):
            with self.subTest(source_catalog=source_catalog):
                self.assertNotIn(f"{source_catalog} in Resources", project)


if __name__ == "__main__":
    unittest.main()
