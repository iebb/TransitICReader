from __future__ import annotations

import csv
import hashlib
import importlib.util
import json
import sqlite3
import tempfile
import unittest
from pathlib import Path


SCRIPT_PATH = Path(__file__).resolve().parents[1] / "generate_unified_transit_databases.py"
SPEC = importlib.util.spec_from_file_location("generate_unified_transit_databases", SCRIPT_PATH)
assert SPEC and SPEC.loader
generator = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(generator)


GENERATED_AT = "2026-08-11T00:00:00Z"


def square(minimum_x: float, minimum_y: float, size: float = 0.8) -> list[dict]:
    maximum_x = minimum_x + size
    maximum_y = minimum_y + size
    return [
        {
            "outer": [
                [minimum_x, minimum_y],
                [maximum_x, minimum_y],
                [maximum_x, maximum_y],
                [minimum_x, maximum_y],
                [minimum_x, minimum_y],
            ],
            "holes": [],
        }
    ]


def boundary(
    boundary_id: str,
    country: str,
    name: str,
    minimum_x: float,
    minimum_y: float,
    subdivision_code: str | None = None,
) -> dict:
    result = {
        "id": boundary_id,
        "countryCode": country,
        "name": name,
        "nativeName": name,
        "center": [minimum_x + 0.4, minimum_y + 0.4],
        "bbox": [minimum_x, minimum_y, minimum_x + 0.8, minimum_y + 0.8],
        "components": square(minimum_x, minimum_y),
    }
    if subdivision_code:
        result["subdivisionCode"] = subdivision_code
    return result


class Fixture:
    korean_header = [
        "location_code",
        "station_id",
        "transport_mode_code",
        "canonical_name_ko",
        "station_name_en",
        "station_name_ja",
        "station_name_zh_hans",
        "station_name_zh_hant",
        "latitude",
        "longitude",
        "operator_name",
        "line_name",
    ]

    def __init__(self, root: Path):
        self.resources = root / "Resources"
        self.resources.mkdir()
        self.city_catalog = {
            "version": 2,
            "generatedAt": GENERATED_AT,
            "attribution": ["test"],
            "sources": {"fixture": True},
            "generation": {"fixture": True},
            "boundaries": [
                boundary("cn:city:1", "CN", "China City", 10, 10),
                boundary("jp:city:1", "JP", "Japan City", 20, 20, "JP-01"),
                boundary("kr:city:1", "KR", "Korea City", 30, 30),
                boundary("mn:adm1:city1", "MN", "Ulaanbaatar", 40, 40, "MN-1"),
            ],
            "referenceLines": [
                {"countryCode": "JP", "bucket": "fixture", "lines": [[[20, 20], [20.8, 20.8]]]}
            ],
            "japanStationToBoundary": {"AAAAA": "jp:city:1"},
            "chinaCityToBoundary": {"1000": "cn:city:1"},
            "koreaModeToBoundary": {"105": "kr:city:1"},
            "koreaLocationToBoundary": {"000000010069": "kr:city:1"},
            "mongoliaStationToBoundary": {"1": "mn:adm1:city1"},
            "mongoliaCityToProvince": {"mn:adm1:city1": "mn:adm1:city1"},
        }
        self.province_catalog = {
            "version": 2,
            "generatedAt": GENERATED_AT,
            "attribution": ["test"],
            "sources": {"fixture": True},
            "generation": {"fixture": True},
            "boundaries": [
                boundary("cn:province:1", "CN", "China Province", 9.5, 9.5),
                boundary("jp:province:1", "JP", "Japan Province", 19.5, 19.5, "JP-01"),
                boundary("kr:province:1", "KR", "Korea Province", 29.5, 29.5),
                boundary("mn:adm1:city1", "MN", "Ulaanbaatar", 39.5, 39.5, "MN-1"),
            ],
            "referenceLines": [
                {"countryCode": "CN", "bucket": "fixture", "lines": [[[9.5, 9.5], [10.3, 10.3]]]}
            ],
            "mongoliaStationToBoundary": {"1": "mn:adm1:city1"},
        }
        self.china_coverage = {
            "version": 1,
            "referenceBoundaryToProvince": {},
            "tUnion": {
                "cityToProvince": {"1000": "China Province"},
                "cityToBoundaryAlias": {},
                "provinceOnlyCityCodes": [],
                "excludedCityBoundaryCodes": [],
            },
            "cityUnion": {
                "cityToProvince": {},
                "cityToBoundaryAlias": {},
                "provinceOnlyCityCodes": [],
                "excludedCityBoundaryCodes": [],
            },
        }
        self.write()

    def write(self) -> None:
        (self.resources / "EastAsiaCityBoundaries.json").write_text(
            json.dumps(self.city_catalog, ensure_ascii=False), encoding="utf-8"
        )
        (self.resources / "EastAsiaProvinceBoundaries.json").write_text(
            json.dumps(self.province_catalog, ensure_ascii=False), encoding="utf-8"
        )
        (self.resources / "ChinaTransitCoverage.json").write_text(
            json.dumps(self.china_coverage), encoding="utf-8"
        )
        (self.resources / "JapanTransitCoverage.json").write_text(
            json.dumps({"version": 1}), encoding="utf-8"
        )
        self.write_japan_database()
        self.write_china_database()
        self.write_mongolia_database()
        with (self.resources / "korean_stations.tsv").open("w", encoding="utf-8", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=self.korean_header, delimiter="\t")
            writer.writeheader()
            writer.writerow(
                {
                    "location_code": "000000010069",
                    "station_id": "00000001",
                    "transport_mode_code": "105",
                    "canonical_name_ko": "한국역",
                    "station_name_en": "Korea Station",
                    "station_name_ja": "韓国駅",
                    "station_name_zh_hans": "韩国站",
                    "station_name_zh_hant": "韓國站",
                    "latitude": "30.4",
                    "longitude": "30.4",
                    "operator_name": "Operator",
                    "line_name": "Line",
                }
            )

    def write_japan_database(self) -> None:
        path = self.resources / "jp_stations.sqlite"
        path.unlink(missing_ok=True)
        with sqlite3.connect(path) as connection:
            connection.executescript(
                """
                CREATE TABLE jp_stations (
                    hex_code TEXT PRIMARY KEY,
                    station_code TEXT NOT NULL,
                    station_name TEXT NOT NULL,
                    station_original_name TEXT NOT NULL,
                    latitude REAL NOT NULL,
                    longitude REAL NOT NULL,
                    is_pseudo INTEGER NOT NULL,
                    confidence REAL NOT NULL,
                    match_method TEXT NOT NULL,
                    line_codes_json TEXT NOT NULL
                );
                CREATE TABLE station_edges (
                    line_code TEXT NOT NULL,
                    from_station_code TEXT NOT NULL,
                    to_station_code TEXT NOT NULL,
                    distance_km REAL NOT NULL
                );
                """
            )
            connection.execute(
                "INSERT INTO jp_stations VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                ("AAAAA", "JP1", "日本駅", "日本駅", 20.4, 20.4, 0, 1.0, "unique", '["L1"]'),
            )

    def write_china_database(self) -> None:
        path = self.resources / "tunion_stations.sqlite"
        path.unlink(missing_ok=True)
        with sqlite3.connect(path) as connection:
            connection.executescript(
                """
                CREATE TABLE tunion_stations (
                    station_key TEXT PRIMARY KEY,
                    city_id TEXT NOT NULL,
                    line_key TEXT NOT NULL,
                    sequence INTEGER NOT NULL,
                    station_name TEXT NOT NULL,
                    match_status TEXT NOT NULL,
                    latitude REAL,
                    longitude REAL,
                    display_name TEXT,
                    osm_type TEXT,
                    osm_id TEXT,
                    osm_name_zh TEXT,
                    osm_name_en TEXT,
                    osm_name_ja TEXT,
                    source_code TEXT,
                    source_type TEXT,
                    source_line_name TEXT
                );
                CREATE TABLE station_edges (
                    line_code TEXT NOT NULL,
                    from_station_code TEXT NOT NULL,
                    to_station_code TEXT NOT NULL,
                    distance_km REAL NOT NULL
                );
                """
            )
            connection.execute(
                "INSERT INTO tunion_stations VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (
                    "CN1", "1000", "1000L1", 1, "中国站", "matched", 10.4, 10.4,
                    "China Station", "node", "1", "中国站", "China Station", "中国駅",
                    "01", "metro", "Line 1",
                ),
            )

    def write_mongolia_database(self) -> None:
        path = self.resources / "ulaanbaatar_transit.sqlite"
        path.unlink(missing_ok=True)
        with sqlite3.connect(path) as connection:
            connection.executescript(
                """
                CREATE TABLE stations (
                    station_id INTEGER PRIMARY KEY,
                    station_name_mn TEXT NOT NULL,
                    station_name_en TEXT NOT NULL,
                    latitude REAL NOT NULL,
                    longitude REAL NOT NULL
                );
                CREATE TABLE routes (
                    route_id INTEGER PRIMARY KEY,
                    route_name_mn TEXT NOT NULL,
                    route_name_en TEXT NOT NULL,
                    endpoint_name_mn TEXT NOT NULL,
                    endpoint_name_en TEXT NOT NULL
                );
                CREATE TABLE route_stations (
                    route_id INTEGER NOT NULL,
                    station_sequence INTEGER NOT NULL,
                    station_id INTEGER NOT NULL
                );
                """
            )
            connection.execute("INSERT INTO stations VALUES (1, 'Монгол буудал', 'Mongolia Station', 40.4, 40.4)")
            connection.execute("INSERT INTO routes VALUES (1, 'Чиглэл', 'Route', 'Төгсгөл', 'Endpoint')")
            connection.execute("INSERT INTO route_stations VALUES (1, 1, 1)")


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class UnifiedTransitDatabaseGeneratorTests(unittest.TestCase):
    def test_generates_three_deterministic_cross_linked_databases(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            fixture = Fixture(root)
            first = generator.generate(fixture.resources, root / "first", GENERATED_AT)
            second = generator.generate(fixture.resources, root / "second", GENERATED_AT)

            self.assertEqual(set(first), {"stations", "cities", "provinces"})
            for key in first:
                self.assertEqual(digest(first[key]), digest(second[key]), key)

            with sqlite3.connect(first["stations"]) as connection:
                self.assertEqual(connection.execute("PRAGMA integrity_check").fetchone()[0], "ok")
                self.assertEqual(
                    dict(connection.execute("SELECT country_code, COUNT(*) FROM stations GROUP BY country_code")),
                    {"CN": 1, "JP": 1, "KR": 1, "MN": 1},
                )
                self.assertEqual(
                    connection.execute(
                        "SELECT city_id, province_id FROM stations WHERE id = 'mn:station:1'"
                    ).fetchone(),
                    ("mn:adm1:city1", "mn:adm1:city1"),
                )

            with sqlite3.connect(first["cities"]) as connection:
                self.assertEqual(connection.execute("SELECT COUNT(*) FROM cities").fetchone()[0], 4)
                self.assertEqual(
                    connection.execute(
                        "SELECT station_count FROM cities WHERE id = 'jp:city:1'"
                    ).fetchone()[0],
                    1,
                )
                self.assertEqual(
                    connection.execute("SELECT COUNT(*) FROM city_evidence_identifiers").fetchone()[0],
                    5,
                )

            with sqlite3.connect(first["provinces"]) as connection:
                self.assertEqual(connection.execute("SELECT COUNT(*) FROM provinces").fetchone()[0], 4)
                self.assertEqual(
                    connection.execute(
                        "SELECT city_count, station_count FROM provinces WHERE id = 'jp:province:1'"
                    ).fetchone(),
                    (1, 1),
                )

    def test_rejects_stationless_japanese_city(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            fixture = Fixture(root)
            fixture.city_catalog["boundaries"].append(
                boundary("jp:city:empty", "JP", "Empty City", 20.05, 20.05, "JP-01")
            )
            fixture.write()
            with self.assertRaisesRegex(generator.CatalogError, "stationless Japan cities"):
                generator.generate(fixture.resources, root / "output", GENERATED_AT)

    def test_rejects_mongolia_station_without_city(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            fixture = Fixture(root)
            fixture.city_catalog["mongoliaStationToBoundary"] = {}
            fixture.write()
            with self.assertRaisesRegex(generator.CatalogError, "Mongolia stations without cities"):
                generator.generate(fixture.resources, root / "output", GENERATED_AT)


if __name__ == "__main__":
    unittest.main()
