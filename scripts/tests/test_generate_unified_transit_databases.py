from __future__ import annotations

import csv
import hashlib
import importlib.util
import json
import sqlite3
import tempfile
import unittest
from contextlib import closing
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
        "transport_mode_name_ko",
        "transport_mode_name_en",
        "transport_mode_name_ja",
        "transport_mode_name_hanja",
        "transport_mode_name_zh_hans",
        "transport_mode_name_zh_hant",
        "transport_class",
        "station_name_ko",
        "canonical_name_ko",
        "station_name_en",
        "station_name_ja",
        "station_name_hanja",
        "station_name_zh_hans",
        "station_name_zh_hant",
        "operator_name",
        "line_name",
        "latitude",
        "longitude",
        "province_code",
        "province_name",
        "district_code",
        "district_name",
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
                {"countryCode": "JP", "bucket": "fixture", "lines": [[[9.5, 9.5], [10.3, 10.3]]]}
            ],
            "mongoliaStationToBoundary": {"1": "mn:adm1:city1"},
        }
        self.province_catalog["boundaries"][0]["coverageName"] = (
            "China Coverage Province"
        )
        self.china_coverage = {
            "version": 1,
            "referenceBoundaryToProvince": {},
            "tUnion": {
                "cityToProvince": {
                    "1000": "China Coverage Province",
                    "1001": "China Coverage Province",
                    "1600": "China Coverage Province",
                },
                "cityToBoundaryAlias": {"1001": "1000"},
                "provinceOnlyCityCodes": ["1600"],
                "excludedCityBoundaryCodes": [],
                "cityCodeDisplayNames": {
                    "1000": "Reviewed Direct City",
                    "1001": "Reviewed China City",
                    "1600": "Reviewed China Province",
                },
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
                    "station_name_ko": "한국역 1번출구",
                    "canonical_name_ko": "한국역",
                    "station_name_en": "Korea Station",
                    "station_name_ja": "韓国駅",
                    "station_name_hanja": "韓國驛",
                    "station_name_zh_hans": "韩国站",
                    "station_name_zh_hant": "韓國站",
                    "latitude": "30.4",
                    "longitude": "30.4",
                    "operator_name": "  Operator   Co  ",
                    "line_name": " Line   One ",
                    "province_code": "11",
                    "province_name": "Province",
                    "district_code": "11710",
                    "district_name": "District",
                }
            )
            writer.writerow(
                {
                    "location_code": "00000002006B",
                    "station_id": "00000002",
                    "transport_mode_code": "107",
                    "station_name_ko": "무영문역",
                    "canonical_name_ko": "무영문역",
                    "station_name_en": "",
                    "station_name_ja": "",
                    "station_name_hanja": "",
                    "station_name_zh_hans": "",
                    "station_name_zh_hant": "",
                    "latitude": "",
                    "longitude": "",
                    "operator_name": "",
                    "line_name": "",
                    "province_code": "11",
                    "province_name": "Province",
                    "district_code": "11710",
                    "district_name": "District",
                }
            )
            writer.writerow(
                {
                    "location_code": "00000001006A",
                    "station_id": "00000001",
                    "transport_mode_code": "106",
                    "station_name_ko": "한국역 2번출구",
                    "canonical_name_ko": "한국역",
                    "station_name_en": "Korea Station Exit 2",
                    "station_name_ja": "韓国駅2番出口",
                    "station_name_hanja": "韓國驛",
                    "station_name_zh_hans": "韩国站2号出口",
                    "station_name_zh_hant": "韓國站2號出口",
                    "latitude": "30.4",
                    "longitude": "30.4",
                    "operator_name": "Operator Co",
                    "line_name": "Line One",
                    "province_code": "11",
                    "province_name": "Province",
                    "district_code": "11710",
                    "district_name": "District",
                }
            )

    def write_japan_database(self) -> None:
        path = self.resources / "jp_stations.sqlite"
        path.unlink(missing_ok=True)
        with closing(sqlite3.connect(path)) as connection, connection:
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
            connection.execute(
                "INSERT INTO station_edges VALUES ('L1', 'JP1', 'JP-GRAPH-ONLY', 1.25)"
            )

    def write_china_database(self) -> None:
        path = self.resources / "tunion_stations.sqlite"
        path.unlink(missing_ok=True)
        with closing(sqlite3.connect(path)) as connection, connection:
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
                    "10000001", "1000", "1000L1", 1, "中国站", "matched", 10.4, 10.4,
                    "China Station", "node", "1", "中国站", "China Station", "中国駅",
                    "0001", "metro", "Line 1",
                ),
            )
            connection.execute(
                "INSERT INTO station_edges VALUES "
                "('1000L1', '10000001', 'CN-GRAPH-ONLY', 2.5)"
            )

    def write_mongolia_database(self) -> None:
        path = self.resources / "ulaanbaatar_transit.sqlite"
        path.unlink(missing_ok=True)
        with closing(sqlite3.connect(path)) as connection, connection:
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


def configure_jeonnam_gwangju_merge(fixture: Fixture) -> None:
    merged = boundary(
        "kr:province:jeonnam-gwangju",
        "KR",
        "Jeonnam-Gwangju",
        30.0,
        30.0,
    )
    merged["nativeName"] = "전남광주통합특별시"
    fixture.province_catalog["boundaries"] = [
        province
        for province in fixture.province_catalog["boundaries"]
        if province["countryCode"] != "KR"
    ] + [merged]
    fixture.province_catalog["generation"]["administrativeChanges"] = [
        {
            "kind": "provinceMerge",
            "newBoundaryID": "kr:province:jeonnam-gwangju",
            "name": "Jeonnam-Gwangju",
            "nativeName": "전남광주통합특별시",
            "statutoryEnglishName": "Jeonnam-Gwangju Special Metropolitan City",
            "mergedFromSubdivisionCodes": ["KR-29", "KR-46"],
            "mergedFromBoundaryIDs": [
                "kr:province:1",
                "kr:province:legacy-46",
            ],
            "effectiveDate": "2026-07-01",
            "legalSourceURL": "https://law.go.kr/fixture",
            "supportedCityIDs": ["kr:city:1"],
            "supportedCityResolution": "fixture predecessor geometry",
        }
    ]
    fixture.write()


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class UnifiedTransitDatabaseGeneratorTests(unittest.TestCase):
    def test_generates_one_deterministic_relational_database(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            fixture = Fixture(root)
            first = generator.generate(fixture.resources, root / "first", GENERATED_AT)
            second = generator.generate(fixture.resources, root / "second", GENERATED_AT)

            self.assertEqual(first.name, "cardbal_transit.sqlite")
            self.assertEqual(second.name, "cardbal_transit.sqlite")
            self.assertEqual(
                [path.name for path in (root / "first").iterdir()],
                ["cardbal_transit.sqlite"],
            )
            self.assertEqual(digest(first), digest(second))

            with closing(sqlite3.connect(first)) as connection:
                connection.execute("PRAGMA foreign_keys = ON")
                self.assertEqual(connection.execute("PRAGMA integrity_check").fetchone()[0], "ok")
                self.assertEqual(connection.execute("PRAGMA foreign_key_check").fetchall(), [])
                self.assertEqual(
                    dict(connection.execute("SELECT country_code, COUNT(*) FROM stations GROUP BY country_code")),
                    {"CN": 1, "JP": 1, "KR": 2, "MN": 1},
                )
                self.assertEqual(
                    connection.execute(
                        "SELECT city_id, province_id FROM stations WHERE id = 'mn:station:1'"
                    ).fetchone(),
                    ("mn:adm1:city1", "mn:adm1:city1"),
                )
                self.assertEqual(connection.execute("SELECT COUNT(*) FROM cities").fetchone()[0], 4)
                self.assertEqual(
                    connection.execute(
                        "SELECT station_count, support_basis FROM cities "
                        "WHERE id = 'jp:city:1'"
                    ).fetchone(),
                    (1, "station"),
                )
                self.assertEqual(
                    connection.execute("SELECT COUNT(*) FROM city_identifiers").fetchone()[0],
                    6,
                )
                table_names = {
                    row[0]
                    for row in connection.execute(
                        "SELECT name FROM sqlite_master WHERE type = 'table'"
                    )
                }
                self.assertIn("city_identifiers", table_names)
                self.assertIn("province_identifiers", table_names)
                self.assertEqual(
                    {name for name in table_names if name.endswith("_identifiers")},
                    {"city_identifiers", "province_identifiers", "station_identifiers"},
                )
                self.assertFalse(any(name.startswith("unresolved_") for name in table_names))
                for table_name in table_names:
                    self.assertNotIn("evidence", table_name.casefold())
                    self.assertNotIn("confidence", table_name.casefold())
                    for column in connection.execute(
                        f'SELECT name FROM pragma_table_info("{table_name}")'
                    ):
                        self.assertNotIn("evidence", column[0].casefold())
                        self.assertNotIn("confidence", column[0].casefold())
                self.assertEqual(
                    [row[1] for row in connection.execute("PRAGMA table_info(city_identifiers)")],
                    ["namespace", "code", "city_id", "display_name"],
                )
                self.assertEqual(
                    [
                        row[1]
                        for row in connection.execute(
                            "PRAGMA table_info(province_identifiers)"
                        )
                    ],
                    ["namespace", "code", "province_id", "display_name"],
                )
                self.assertEqual(
                    connection.execute(
                        """
                        SELECT namespace, code, display_name
                        FROM city_identifiers
                        WHERE display_name IS NOT NULL
                        UNION ALL
                        SELECT namespace, code, display_name
                        FROM province_identifiers
                        WHERE display_name IS NOT NULL
                        ORDER BY code
                        """
                    ).fetchall(),
                    [
                        ("cn.tunion.city_code", "1000", "Reviewed Direct City"),
                        ("cn.tunion.city_alias", "1001", "Reviewed China City"),
                        (
                            "cn.tunion.province_only_city_code",
                            "1600",
                            "Reviewed China Province",
                        ),
                    ],
                )
                self.assertEqual(
                    connection.execute(
                        "SELECT value FROM metadata "
                        "WHERE key = 'china_city_code_display_name_count'"
                    ).fetchone()[0],
                    "3",
                )
                self.assertEqual(
                    connection.execute(
                        "SELECT namespace, code, lookup_name FROM station_identifiers "
                        "WHERE namespace IN ('jp.felica.hex', 'cn.tunion.station_key') "
                        "ORDER BY namespace"
                    ).fetchall(),
                    [
                        ("cn.tunion.station_key", "10000001", "中国站"),
                        ("jp.felica.hex", "AAAAA", "日本駅"),
                    ],
                )
                self.assertEqual(
                    connection.execute(
                        """
                        SELECT DISTINCT i.namespace
                        FROM station_identifiers i
                        JOIN stations s ON s.id = i.station_id
                        WHERE s.country_code = 'CN'
                        """
                    ).fetchall(),
                    [("cn.tunion.station_key",)],
                )
                korean_aliases = connection.execute(
                    "SELECT code, lookup_name, map_group_id, source_properties_json "
                    "FROM station_identifiers "
                    "WHERE namespace = 'kr.ksx.location' ORDER BY code"
                ).fetchall()
                expected_map_group = (
                    "11|11710|한국역|Operator Co|Line One|"
                    "4629250056974132838|4629250056974132838"
                )
                self.assertEqual(
                    [row[:3] for row in korean_aliases],
                    [
                        ("000000010069", "한국역", expected_map_group),
                        ("00000001006A", "한국역", expected_map_group),
                        ("00000002006B", "무영문역", "00000002"),
                    ],
                )
                self.assertEqual(
                    json.loads(korean_aliases[0][3]),
                    {
                        "station_name_ko": "한국역 1번출구",
                        "canonical_name_ko": "한국역",
                        "latitude": "30.4",
                        "longitude": "30.4",
                        "station_name_hanja": "韓國驛",
                        "station_name_en": "Korea Station",
                        "station_name_ja": "韓国駅",
                        "station_name_zh_hans": "韩国站",
                        "station_name_zh_hant": "韓國站",
                        "operator_name": "  Operator   Co  ",
                        "line_name": " Line   One ",
                        "province_code": "11",
                        "district_code": "11710",
                    },
                )
                self.assertEqual(
                    json.loads(korean_aliases[1][3]),
                    {
                        "station_name_ko": "한국역 2번출구",
                        "canonical_name_ko": "한국역",
                        "latitude": "30.4",
                        "longitude": "30.4",
                        "station_name_hanja": "韓國驛",
                        "station_name_en": "Korea Station Exit 2",
                        "station_name_ja": "韓国駅2番出口",
                        "station_name_zh_hans": "韩国站2号出口",
                        "station_name_zh_hant": "韓國站2號出口",
                        "operator_name": "Operator Co",
                        "line_name": "Line One",
                        "province_code": "11",
                        "district_code": "11710",
                    },
                )
                self.assertEqual(
                    json.loads(korean_aliases[2][3]),
                    {
                        "station_name_ko": "무영문역",
                        "canonical_name_ko": "무영문역",
                        "latitude": "",
                        "longitude": "",
                        "station_name_hanja": "",
                        "station_name_en": "",
                        "station_name_ja": "",
                        "station_name_zh_hans": "",
                        "station_name_zh_hant": "",
                        "operator_name": "",
                        "line_name": "",
                        "province_code": "11",
                        "district_code": "11710",
                    },
                )
                self.assertEqual(
                    connection.execute(
                        "SELECT name FROM stations WHERE id = 'kr:station:00000002'"
                    ).fetchone()[0],
                    "무영문역",
                )
                self.assertEqual(
                    connection.execute(
                        "SELECT COUNT(*) FROM station_names "
                        "WHERE station_id = 'kr:station:00000002' AND language_code = 'en'"
                    ).fetchone()[0],
                    0,
                )
                self.assertEqual(
                    connection.execute(
                        "SELECT COUNT(*) FROM station_identifiers "
                        "WHERE namespace <> 'kr.ksx.location' AND "
                        "(map_group_id IS NOT NULL OR source_properties_json IS NOT NULL)"
                    ).fetchone()[0],
                    0,
                )
                self.assertEqual(
                    dict(
                        connection.execute(
                            "SELECT key, value FROM metadata "
                            "WHERE key IN ('korean_alias_count', 'korean_map_group_count')"
                        )
                    ),
                    {"korean_alias_count": "3", "korean_map_group_count": "2"},
                )
                self.assertEqual(
                    connection.execute(
                        "SELECT country_code, line_code, from_station_code, "
                        "to_station_code, distance_km, source_id "
                        "FROM station_graph_edges ORDER BY country_code"
                    ).fetchall(),
                    [
                        (
                            "CN", "1000L1", "10000001", "CN-GRAPH-ONLY", 2.5,
                            "stations.cn",
                        ),
                        ("JP", "L1", "JP1", "JP-GRAPH-ONLY", 1.25, "stations.jp"),
                    ],
                )
                self.assertEqual(connection.execute("SELECT COUNT(*) FROM provinces").fetchone()[0], 4)
                self.assertEqual(
                    connection.execute(
                        "SELECT name, native_name FROM provinces "
                        "WHERE id = 'cn:province:1'"
                    ).fetchone(),
                    ("China Province", "China Province"),
                )
                self.assertEqual(
                    connection.execute(
                        "SELECT city_count, station_count FROM provinces WHERE id = 'jp:province:1'"
                    ).fetchone(),
                    (1, 1),
                )
                self.assertEqual(
                    connection.execute(
                        "SELECT boundary_level, country_code, bucket, source_id "
                        "FROM reference_line_batches ORDER BY boundary_level"
                    ).fetchall(),
                    [
                        ("city", "JP", "fixture", "boundaries.city"),
                        ("province", "JP", "fixture", "boundaries.province"),
                    ],
                )
                self.assertEqual(
                    connection.execute(
                        "SELECT value FROM metadata WHERE key = 'format'"
                    ).fetchone()[0],
                    "cardbal-unified-transit-v1",
                )

                def foreign_keys(table: str) -> set[tuple[str, str, str]]:
                    return {
                        (row[3], row[2], row[4])
                        for row in connection.execute(f"PRAGMA foreign_key_list({table})")
                    }

                self.assertEqual(
                    foreign_keys("stations"),
                    {
                        ("city_id", "cities", "id"),
                        ("province_id", "provinces", "id"),
                    },
                )
                self.assertEqual(
                    foreign_keys("cities"), {("province_id", "provinces", "id")}
                )
                self.assertEqual(
                    foreign_keys("lines"), {("city_id", "cities", "id")}
                )
                self.assertIn(
                    ("city_id", "cities", "id"), foreign_keys("city_identifiers")
                )
                self.assertIn(
                    ("province_id", "provinces", "id"),
                    foreign_keys("province_identifiers"),
                )
                self.assertIn(
                    ("source_id", "sources", "id"), foreign_keys("station_sources")
                )
                self.assertIn(
                    ("station_id", "stations", "id"), foreign_keys("station_sources")
                )
                self.assertIn(
                    ("source_id", "sources", "id"), foreign_keys("city_sources")
                )
                self.assertIn(
                    ("city_id", "cities", "id"), foreign_keys("city_sources")
                )
                self.assertIn(
                    ("source_id", "sources", "id"), foreign_keys("province_sources")
                )
                self.assertIn(
                    ("province_id", "provinces", "id"), foreign_keys("province_sources")
                )
                self.assertIn(
                    ("source_id", "sources", "id"),
                    foreign_keys("reference_line_batches"),
                )
                self.assertEqual(
                    foreign_keys("station_graph_edges"),
                    {("source_id", "sources", "id")},
                )

                with self.assertRaises(sqlite3.IntegrityError):
                    connection.execute(
                        """
                        INSERT INTO stations (
                            id, country_code, source_namespace, source_station_id,
                            city_id, province_id, name, is_pseudo, match_status
                        ) VALUES (
                            'mn:station:invalid', 'MN', 'test', 'invalid',
                            'mn:city:missing', 'mn:adm1:city1', 'Invalid', 0, 'test'
                        )
                        """
                    )

    def test_korean_parity_rejects_identifier_property_drift(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            fixture = Fixture(root)
            database = generator.generate(fixture.resources, root / "output", GENERATED_AT)
            with closing(sqlite3.connect(database)) as connection:
                connection.execute(
                    "UPDATE station_identifiers SET source_properties_json = '{}' "
                    "WHERE namespace = 'kr.ksx.location' AND code = '000000010069'"
                )
                with self.assertRaisesRegex(
                    generator.CatalogError, "Korean station aliases runtime parity failed"
                ):
                    generator.validate_korean_source_parity(
                        connection, fixture.resources / "korean_stations.tsv"
                    )

    def test_china_parent_resolution_falls_back_to_display_name(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            fixture = Fixture(root)
            fixture.province_catalog["boundaries"][0].pop("coverageName")
            for code in ("1000", "1001", "1600"):
                fixture.china_coverage["tUnion"]["cityToProvince"][code] = (
                    "China Province"
                )
            fixture.write()

            database = generator.generate(fixture.resources, root / "output", GENERATED_AT)
            with closing(sqlite3.connect(database)) as connection:
                self.assertEqual(
                    connection.execute(
                        "SELECT province_id FROM cities WHERE id = 'cn:city:1'"
                    ).fetchone()[0],
                    "cn:province:1",
                )

    def test_korean_merged_province_parents_supported_cities_by_geometry(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            fixture = Fixture(root)
            configure_jeonnam_gwangju_merge(fixture)

            database = generator.generate(fixture.resources, root / "output", GENERATED_AT)
            with closing(sqlite3.connect(database)) as connection:
                self.assertEqual(
                    connection.execute(
                        "SELECT province_id FROM cities WHERE id = 'kr:city:1'"
                    ).fetchone()[0],
                    "kr:province:jeonnam-gwangju",
                )
                self.assertEqual(
                    connection.execute(
                        "SELECT name, native_name FROM provinces "
                        "WHERE id = 'kr:province:jeonnam-gwangju'"
                    ).fetchone(),
                    ("Jeonnam-Gwangju", "전남광주통합특별시"),
                )

    def test_korean_merged_province_rejects_predecessor_rows(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            fixture = Fixture(root)
            configure_jeonnam_gwangju_merge(fixture)
            fixture.province_catalog["boundaries"].append(
                boundary(
                    "kr:province:1",
                    "KR",
                    "Legacy Gwangju",
                    29.0,
                    29.0,
                    "KR-29",
                )
            )
            fixture.write()

            with self.assertRaisesRegex(
                generator.CatalogError,
                "still contains predecessor province rows",
            ):
                generator.generate(fixture.resources, root / "output", GENERATED_AT)

    def test_korean_merged_province_rejects_incomplete_geometry(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            fixture = Fixture(root)
            configure_jeonnam_gwangju_merge(fixture)
            merged = next(
                province
                for province in fixture.province_catalog["boundaries"]
                if province["id"] == "kr:province:jeonnam-gwangju"
            )
            moved = boundary(
                "kr:province:jeonnam-gwangju",
                "KR",
                "Jeonnam-Gwangju",
                50.0,
                50.0,
            )
            moved["nativeName"] = merged["nativeName"]
            merged.update(moved)
            fixture.write()

            with self.assertRaisesRegex(
                generator.CatalogError,
                "geometry and supportedCityIDs disagree",
            ):
                generator.generate(fixture.resources, root / "output", GENERATED_AT)
                self.assertEqual(
                    connection.execute(
                        "SELECT province_id FROM province_identifiers "
                        "WHERE namespace = 'cn.tunion.province_only_city_code' "
                        "AND code = '1600'"
                    ).fetchone()[0],
                    "cn:province:1",
                )

    def test_configured_unsupported_city_codes_are_not_published(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            fixture = Fixture(root)
            fixture.city_catalog["chinaCityToBoundary"]["1999"] = "cn:city:not-supported"
            fixture.china_coverage["tUnion"]["excludedCityBoundaryCodes"] = ["1999"]
            fixture.write()

            database = generator.generate(fixture.resources, root / "output", GENERATED_AT)
            with closing(sqlite3.connect(database)) as connection:
                self.assertEqual(
                    connection.execute(
                        "SELECT COUNT(*) FROM city_identifiers WHERE code = '1999'"
                    ).fetchone()[0],
                    0,
                )
                self.assertFalse(
                    any(
                        row[0].startswith("unresolved_")
                        for row in connection.execute(
                            "SELECT name FROM sqlite_master WHERE type = 'table'"
                        )
                    )
                )

    def test_china_bare_source_codes_can_repeat_across_cities(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            fixture = Fixture(root)
            fixture.city_catalog["chinaCityToBoundary"]["1002"] = "cn:city:1"
            fixture.china_coverage["tUnion"]["cityToProvince"]["1002"] = (
                "China Coverage Province"
            )
            fixture.write()
            with closing(
                sqlite3.connect(fixture.resources / "tunion_stations.sqlite")
            ) as source, source:
                source.execute(
                    "INSERT INTO tunion_stations VALUES "
                    "(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    (
                        "10020001", "1002", "1002L1", 1, "第二站", "matched",
                        10.45, 10.45, "Second Station", "node", "2", "第二站",
                        "Second Station", "第二駅", "0001", "metro", "Line 1",
                    ),
                )

            database = generator.generate(fixture.resources, root / "output", GENERATED_AT)
            with closing(sqlite3.connect(database)) as connection:
                self.assertEqual(
                    connection.execute(
                        """
                        SELECT i.namespace, i.code
                        FROM station_identifiers i
                        JOIN stations s ON s.id = i.station_id
                        WHERE s.country_code = 'CN'
                        ORDER BY i.code
                        """
                    ).fetchall(),
                    [
                        ("cn.tunion.station_key", "10000001"),
                        ("cn.tunion.station_key", "10020001"),
                    ],
                )

    def test_rejects_china_source_code_that_disagrees_with_station_key(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            fixture = Fixture(root)
            with closing(
                sqlite3.connect(fixture.resources / "tunion_stations.sqlite")
            ) as source, source:
                source.execute(
                    "UPDATE tunion_stations SET source_code = '0002' "
                    "WHERE station_key = '10000001'"
                )

            with self.assertRaisesRegex(
                generator.CatalogError,
                "source_code does not reproduce its canonical station_key",
            ):
                generator.generate(fixture.resources, root / "output", GENERATED_AT)

    def test_rejects_stationless_japanese_city(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            fixture = Fixture(root)
            fixture.city_catalog["boundaries"].append(
                boundary("jp:city:empty", "JP", "Empty City", 20.05, 20.05, "JP-01")
            )
            fixture.write()
            output_directory = root / "output"
            output_directory.mkdir()
            published = output_directory / "cardbal_transit.sqlite"
            published.write_bytes(b"existing-catalog")
            with self.assertRaisesRegex(generator.CatalogError, "stationless Japan cities"):
                generator.generate(fixture.resources, output_directory, GENERATED_AT)
            self.assertEqual(published.read_bytes(), b"existing-catalog")

    def test_refresh_resolves_new_mongolia_stops_and_removes_retired_identifiers(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            fixture = Fixture(root)
            expected = dict(fixture.city_catalog["mongoliaStationToBoundary"])
            fixture.city_catalog["mongoliaStationToBoundary"] = {"retired": next(iter(expected.values()))}
            fixture.province_catalog["mongoliaStationToBoundary"]["retired"] = next(
                iter(fixture.province_catalog["mongoliaStationToBoundary"].values())
            )
            fixture.write()
            output = generator.generate(fixture.resources, root / "output", GENERATED_AT)
            with closing(sqlite3.connect(output)) as connection:
                actual = dict(connection.execute(
                    "SELECT code, city_id FROM city_identifiers WHERE namespace = 'mn.ubsmartbus.station_id'"
                ))
                self.assertEqual(actual, expected)
                self.assertEqual(connection.execute(
                    "SELECT COUNT(*) FROM province_identifiers WHERE code = 'retired'"
                ).fetchone()[0], 0)
                generator.validate_database(connection)

    def test_rejects_mongolia_station_without_city(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            fixture = Fixture(root)
            fixture.city_catalog["mongoliaStationToBoundary"] = {}
            fixture.write()
            with closing(sqlite3.connect(fixture.resources / "ulaanbaatar_transit.sqlite")) as connection, connection:
                connection.execute("UPDATE stations SET latitude = 0, longitude = 0")
            output_directory = root / "output"
            output_directory.mkdir()
            published = output_directory / "cardbal_transit.sqlite"
            published.write_bytes(b"existing-catalog")
            with self.assertRaisesRegex(generator.CatalogError, "has no unambiguous supported city"):
                generator.generate(fixture.resources, output_directory, GENERATED_AT)
            self.assertEqual(published.read_bytes(), b"existing-catalog")


if __name__ == "__main__":
    unittest.main()
