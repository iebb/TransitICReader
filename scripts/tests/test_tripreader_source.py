"""Regression coverage for source identity, merge preservation, and refreshes."""

import contextlib
import hashlib
import io
import json
import shutil
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import enrich_tunion_source as enrichment
import tripreader_source as source


def csv_bytes(*rows):
    return ("City,Code,Type,Line,Station\n" + "\n".join(rows) + "\n").encode()


class TripReaderSourceTests(unittest.TestCase):
    def test_recursive_fetch_is_pinned_and_fails_instead_of_skipping_a_city(self):
        path = "Zhejiang/Ningbo/metro-tu.csv"
        tree = {"tree": [{"type": "blob", "path": path}], "truncated": False}
        with patch.object(source, "fetch", side_effect=[json.dumps(tree).encode(), b"data"]) as fetch:
            self.assertEqual(source.source_files(), {path: b"data"})
            self.assertIn(source.REVISION + "?recursive=1", fetch.call_args_list[0].args[0])
            self.assertIn(source.REVISION + "/" + path, fetch.call_args_list[1].args[0])
        with patch.object(source, "fetch", side_effect=[json.dumps(tree).encode(), OSError("offline")]):
            with self.assertRaises(OSError):
                source.source_files()
        with patch.object(source, "fetch", return_value=b'{"truncated": true}'):
            with self.assertRaisesRegex(ValueError, "truncated"):
                source.source_files()

    def test_station_prefixes_terminals_and_operator_names_are_not_interchangeable(self):
        payload = source.parse_sources({
            "Zhejiang/Ningbo/metro-tu.csv": csv_bytes("3320,01,地铁,1号线,", "3320,0101,地铁,1号线,高桥西"),
            "Zhejiang/Hangzhou/metro-tu.csv": csv_bytes("3310,413101784816,地铁,4,市民中心"),
            "Anhui/Hefei/brt-tu.csv": csv_bytes("3610,0000413106085352,BRT,,铜陵新村"),
            "Shaanxi/Xi'an/metro-tu.csv": csv_bytes("7910,0221,地铁,2号线,北客站"),
            "Liaoning/Dalian/bus-tu.csv": csv_bytes("2220,29010000,公交,顺通空调车,开发区公交"),
        })
        self.assertEqual(set(payload["stations"]), {"33200101"})
        self.assertEqual(payload["lines"]["3320|01|1号线|地铁"]["station_count"], 1)
        self.assertEqual(set(payload["terminal_stations"]), {"18:3310:413101784816", "1e:3610:0000413106085352"})
        self.assertEqual(payload["excluded_rows"], {"bus_route_or_operator": 1, "xian_terminal_subfield": 1})
        self.assertEqual(source.station_line_code("00010001"), "0001")
        self.assertEqual(source.station_line_code("010001"), "0100")
        self.assertEqual(source.station_line_code("0101"), "01")

    def test_shanghai_city_union_is_separate_from_tunion(self):
        payload = source.parse_sources({
            "Shanghai/cu.csv": csv_bytes("2000,110111,地铁,1号线,莘庄"),
            "Shanghai/metro-tu.csv": csv_bytes("2900,00010011,地铁,1号线,莘庄"),
        })
        self.assertEqual(set(payload["city_union_stations"]), {"2000110111"})
        self.assertEqual(set(payload["stations"]), {"290000010011"})
        with self.assertRaisesRegex(ValueError, "Unreviewed City Union city"):
            source.parse_sources({"Shanghai/cu.csv": csv_bytes("2900,110111,地铁,1号线,莘庄")})
        with self.assertRaisesRegex(ValueError, "Conflicting City Union prefix"):
            source.parse_sources({"Shanghai/cu.csv": csv_bytes(
                "2000,110111,地铁,1号线,莘庄", "2000,110111,地铁,1号线,别的站"
            )})

    def test_shanghai_bundles_preserve_prefix_provenance_and_safe_links(self):
        assets = SCRIPTS.parent / "StationAssets"
        resources = SCRIPTS.parent / "CardBal/Resources"
        for name in ("tunion_stations.sqlite", "cardbal_transit.sqlite", "tunion_tripreader_source.json"):
            self.assertEqual(hashlib.sha256((assets / name).read_bytes()).digest(),
                             hashlib.sha256((resources / name).read_bytes()).digest())
        payload = json.loads((assets / "tunion_tripreader_source.json").read_text())
        self.assertEqual(len(payload["city_union_stations"]), 614)
        with contextlib.closing(sqlite3.connect(assets / "cardbal_transit.sqlite")) as connection:
            rows = connection.execute("SELECT terminal_prefix, station_key, source_json FROM cityunion_terminal_prefixes").fetchall()
            self.assertEqual(len(rows), 614)
            self.assertEqual(sum(key is not None for _, key, _ in rows), 577)
            for prefix, key, metadata in rows:
                self.assertEqual(json.loads(metadata), payload["city_union_stations"][prefix])
                if key:
                    self.assertTrue(key.startswith("2900"))
                    self.assertEqual(connection.execute(
                        "SELECT i.station_id = j.station_id FROM station_identifiers i "
                        "JOIN station_identifiers j ON j.namespace = 'cn.tunion.station_key' AND j.code = ? "
                        "WHERE i.namespace = 'cn.cityunion.terminal_prefix' AND i.code = ?", (key, prefix)
                    ).fetchone(), (1,))
            self.assertEqual(connection.execute(
                "SELECT station_name, station_key FROM cityunion_terminal_prefixes WHERE terminal_prefix = '2000110111'"
            ).fetchone(), ("莘庄", "290000010011"))

    def test_conflicting_station_keys_fail_closed(self):
        with self.assertRaisesRegex(ValueError, "Conflicting station"):
            source.parse_sources({"Example/metro-tu.csv": csv_bytes(
                "3320,0101,地铁,1号线,高桥西", "3320,0101,地铁,1号线,别的站"
            )})

    def test_merge_preserves_current_names_coordinates_and_edges_and_is_repeatable(self):
        payload = source.parse_sources({"Zhejiang/Ningbo/metro-tu.csv": csv_bytes(
            "3320,00010001,地铁,1号线,高桥西", "3320,0101,地铁,1号线,高桥西",
            "3320,0102,地铁,1号线,新站"
        ), "Zhejiang/Hangzhou/metro-tu.csv": csv_bytes("3310,413101784816,地铁,4,市民中心")})
        payload["terminal_stations"]["18:3320:413101784822"] = {
            "city_id": "3320", "code": "413101784822", "station": "曾用名", "line": "1号线",
            "type": "地铁", "city_folder": "fixture", "csv_file": "fixture.csv",
            "station_key": "332000010001",
        }
        payload["terminal_stations"]["18:3320:413101784855"] = {
            "city_id": "3320", "code": "413101784855", "station": "新站", "line": "",
            "type": "自行车", "city_folder": "fixture", "csv_file": "fixture.csv",
        }
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            db = root / "tunion_stations.sqlite"
            shutil.copyfile(SCRIPTS.parent / "StationAssets/tunion_stations.sqlite", db)
            with contextlib.closing(sqlite3.connect(db)) as connection, connection:
                # Keep one real, geocoded baseline and ensure both aliases are absent.
                connection.execute("DELETE FROM tunion_stations WHERE station_key <> '332000010001'")
                original = connection.execute("SELECT station_name, latitude, longitude FROM tunion_stations").fetchone()
                edges = connection.execute("SELECT * FROM station_edges ORDER BY 1, 2, 3").fetchall()
                connection.execute("UPDATE tunion_stations SET source_line_name = 'Current Line'")
            cache = root / "tunion_tripreader_source.json"
            cache.write_text(json.dumps(payload, ensure_ascii=False))
            with contextlib.redirect_stdout(io.StringIO()):
                enrichment.merge_into_database(db, cache, offline=True)
            with contextlib.closing(sqlite3.connect(db)) as connection:
                self.assertEqual(connection.execute(
                    "SELECT station_name, latitude, longitude FROM tunion_stations WHERE station_key = '332000010001'"
                ).fetchone(), original)
                self.assertEqual(connection.execute("SELECT * FROM station_edges ORDER BY 1, 2, 3").fetchall(), edges)
                self.assertEqual(connection.execute(
                    "SELECT source_line_name FROM tunion_stations WHERE station_key = '332000010001'"
                ).fetchone()[0], "Current Line")
                self.assertEqual(connection.execute(
                    "SELECT station_name, latitude, longitude FROM tunion_stations WHERE station_key = '33200101'"
                ).fetchone(), original)
                self.assertEqual(connection.execute(
                    "SELECT line_key, sequence FROM tunion_stations WHERE station_key = '33200101'"
                ).fetchone(), ("332001", 1))
                self.assertEqual(connection.execute("SELECT COUNT(*) FROM tunion_terminal_stations").fetchone()[0], 3)
                terminal = connection.execute(
                    "SELECT station_name, source_json FROM tunion_terminal_stations WHERE terminal_code = '413101784822'"
                ).fetchone()
                self.assertEqual(terminal[0], original[0])
                self.assertEqual(json.loads(terminal[1])["station"], "曾用名")
                self.assertIsNone(connection.execute(
                    "SELECT station_key FROM tunion_terminal_stations WHERE terminal_code = '413101784855'"
                ).fetchone()[0])
                before = list(connection.iterdump())
            registry = json.loads((root / "TUnionLineStations.json").read_text())
            self.assertEqual(set(registry), {"332000010001", "33200101", "33200102"})
            cache_hash = hashlib.sha256(cache.read_bytes()).hexdigest()
            with contextlib.redirect_stdout(io.StringIO()):
                enrichment.merge_into_database(db, cache, offline=True)
            with contextlib.closing(sqlite3.connect(db)) as connection:
                self.assertEqual(list(connection.iterdump()), before)
            self.assertEqual(hashlib.sha256(cache.read_bytes()).hexdigest(), cache_hash)


if __name__ == "__main__":
    unittest.main()
