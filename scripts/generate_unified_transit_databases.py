#!/usr/bin/env python3
"""Generate CardBal's unified station, city, and province SQLite catalogs.

The country-specific source files remain the reproducible inputs.  This script
packages their finalized data into three runtime databases while retaining the
existing boundary IDs and evidence lookups verbatim.  The three files are built
in temporary paths, attached to one validation connection, and only replaced
after all cross-file invariants pass.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import os
import sqlite3
import tempfile
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any, Iterable


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_RESOURCES = REPO_ROOT / "CardBal/Resources"
SUPPORTED_COUNTRIES = ("CN", "JP", "KR", "MN")
SCHEMA_VERSION = 1

STATIONS_FILENAME = "cardbal_stations.sqlite"
CITIES_FILENAME = "cardbal_cities.sqlite"
PROVINCES_FILENAME = "cardbal_provinces.sqlite"

REQUIRED_INPUTS = (
    "EastAsiaCityBoundaries.json",
    "EastAsiaProvinceBoundaries.json",
    "ChinaTransitCoverage.json",
    "JapanTransitCoverage.json",
    "jp_stations.sqlite",
    "tunion_stations.sqlite",
    "korean_stations.tsv",
    "ulaanbaatar_transit.sqlite",
)

KOREAN_EVENT_CONSTRAINTS = {
    "221000000368": ("entry",),
    "230000000368": ("entry",),
    "221022900368": ("exit",),
    "230022100368": ("exit",),
}


class CatalogError(RuntimeError):
    """Raised when source catalogs cannot form one internally consistent set."""


def canonical_json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def load_json(path: Path) -> dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise CatalogError(f"{path} must contain a JSON object")
    return payload


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def source_rows(resources: Path) -> list[tuple[str, str, str, str, str, str, str]]:
    descriptions = {
        "EastAsiaCityBoundaries.json": ("boundaries.city", "Finalized city boundary catalog"),
        "EastAsiaProvinceBoundaries.json": ("boundaries.province", "Finalized province boundary catalog"),
        "ChinaTransitCoverage.json": ("coverage.cn", "China transit coverage rules"),
        "JapanTransitCoverage.json": ("coverage.jp", "Japan transit coverage rules"),
        "jp_stations.sqlite": ("stations.jp", "Japanese station resolver database"),
        "tunion_stations.sqlite": ("stations.cn", "China T-Union station database"),
        "korean_stations.tsv": ("stations.kr", "iebb/korean-stations consumer export"),
        "ulaanbaatar_transit.sqlite": ("stations.mn", "UB Smart Bus station database"),
        "KOTRISTransportModes.json": ("modes.kr", "KORAIL KOTRIS transport modes"),
        "TUnionCityCodes.json": ("cities.cn", "China T-Union city-code registry"),
        "TUnionLineStations.json": ("lines.cn", "China T-Union line/station registry"),
        "JPStationCodes.csv": ("codes.jp", "Japanese FeliCa station-code registry"),
    }
    rows = []
    for filename, (source_id, title) in descriptions.items():
        path = resources / filename
        if not path.is_file():
            continue
        rows.append(
            (
                source_id,
                title,
                f"CardBal/Resources/{filename}",
                "",
                "",
                "",
                sha256_file(path),
            )
        )
    return sorted(rows)


def open_source_database(path: Path) -> sqlite3.Connection:
    uri = f"file:{path.resolve().as_posix()}?mode=ro&immutable=1"
    connection = sqlite3.connect(uri, uri=True)
    connection.row_factory = sqlite3.Row
    return connection


def table_exists(connection: sqlite3.Connection, name: str) -> bool:
    return connection.execute(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", (name,)
    ).fetchone() is not None


def configure_database(connection: sqlite3.Connection, application_id: int) -> None:
    connection.executescript(
        f"""
        PRAGMA page_size = 4096;
        PRAGMA journal_mode = OFF;
        PRAGMA synchronous = OFF;
        PRAGMA temp_store = MEMORY;
        PRAGMA foreign_keys = ON;
        PRAGMA application_id = {application_id};
        PRAGMA user_version = {SCHEMA_VERSION};
        """
    )


COMMON_SCHEMA = """
CREATE TABLE metadata (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
) WITHOUT ROWID;
CREATE TABLE sources (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    url TEXT NOT NULL,
    revision TEXT NOT NULL,
    retrieved_at TEXT NOT NULL,
    license TEXT NOT NULL,
    sha256 TEXT NOT NULL
) WITHOUT ROWID;
"""


STATIONS_SCHEMA = COMMON_SCHEMA + """
CREATE TABLE stations (
    id TEXT PRIMARY KEY,
    country_code TEXT NOT NULL CHECK (country_code IN ('CN', 'JP', 'KR', 'MN')),
    source_namespace TEXT NOT NULL,
    source_station_id TEXT NOT NULL,
    city_id TEXT,
    province_id TEXT,
    name TEXT NOT NULL,
    native_name TEXT,
    latitude REAL,
    longitude REAL,
    is_pseudo INTEGER NOT NULL CHECK (is_pseudo IN (0, 1)),
    match_status TEXT NOT NULL,
    confidence REAL,
    CHECK ((latitude IS NULL) = (longitude IS NULL)),
    UNIQUE (source_namespace, source_station_id)
);
CREATE INDEX stations_country_city_idx ON stations(country_code, city_id);
CREATE INDEX stations_country_province_idx ON stations(country_code, province_id);
CREATE TABLE station_names (
    station_id TEXT NOT NULL REFERENCES stations(id) ON DELETE CASCADE,
    language_code TEXT NOT NULL,
    name TEXT NOT NULL,
    is_primary INTEGER NOT NULL CHECK (is_primary IN (0, 1)),
    PRIMARY KEY (station_id, language_code, name)
) WITHOUT ROWID;
CREATE TABLE station_identifiers (
    namespace TEXT NOT NULL,
    code TEXT NOT NULL,
    event_kind TEXT NOT NULL CHECK (event_kind IN ('any', 'entry', 'exit')),
    station_id TEXT NOT NULL REFERENCES stations(id) ON DELETE CASCADE,
    PRIMARY KEY (namespace, code, event_kind)
) WITHOUT ROWID;
CREATE INDEX station_identifiers_station_idx ON station_identifiers(station_id);
CREATE TABLE station_sources (
    station_id TEXT NOT NULL REFERENCES stations(id) ON DELETE CASCADE,
    source_id TEXT NOT NULL REFERENCES sources(id),
    role TEXT NOT NULL,
    PRIMARY KEY (station_id, source_id, role)
) WITHOUT ROWID;
CREATE TABLE lines (
    id TEXT PRIMARY KEY,
    country_code TEXT NOT NULL CHECK (country_code IN ('CN', 'JP', 'KR', 'MN')),
    city_id TEXT,
    code TEXT NOT NULL,
    name TEXT,
    native_name TEXT,
    mode TEXT
);
CREATE TABLE station_line_stops (
    line_id TEXT NOT NULL REFERENCES lines(id) ON DELETE CASCADE,
    station_id TEXT NOT NULL REFERENCES stations(id) ON DELETE CASCADE,
    source_stop_code TEXT NOT NULL,
    sequence INTEGER,
    PRIMARY KEY (line_id, station_id, source_stop_code)
) WITHOUT ROWID;
CREATE TABLE station_edges (
    line_id TEXT NOT NULL REFERENCES lines(id) ON DELETE CASCADE,
    from_station_id TEXT NOT NULL REFERENCES stations(id) ON DELETE CASCADE,
    to_station_id TEXT NOT NULL REFERENCES stations(id) ON DELETE CASCADE,
    distance_km REAL NOT NULL CHECK (distance_km >= 0),
    PRIMARY KEY (line_id, from_station_id, to_station_id)
) WITHOUT ROWID;
"""


CITIES_SCHEMA = COMMON_SCHEMA + """
CREATE TABLE cities (
    id TEXT PRIMARY KEY,
    country_code TEXT NOT NULL CHECK (country_code IN ('CN', 'JP', 'KR', 'MN')),
    province_id TEXT NOT NULL,
    subdivision_code TEXT,
    name TEXT NOT NULL,
    native_name TEXT NOT NULL,
    center_longitude REAL NOT NULL,
    center_latitude REAL NOT NULL,
    bbox_min_longitude REAL NOT NULL,
    bbox_min_latitude REAL NOT NULL,
    bbox_max_longitude REAL NOT NULL,
    bbox_max_latitude REAL NOT NULL,
    components_json TEXT NOT NULL,
    station_count INTEGER NOT NULL CHECK (station_count >= 0),
    support_basis TEXT NOT NULL
);
CREATE INDEX cities_country_province_idx ON cities(country_code, province_id);
CREATE TABLE city_evidence_identifiers (
    namespace TEXT NOT NULL,
    code TEXT NOT NULL,
    city_id TEXT NOT NULL REFERENCES cities(id),
    evidence_kind TEXT NOT NULL,
    priority INTEGER NOT NULL,
    PRIMARY KEY (namespace, code)
) WITHOUT ROWID;
CREATE INDEX city_evidence_city_idx ON city_evidence_identifiers(city_id);
CREATE TABLE unresolved_city_evidence_identifiers (
    namespace TEXT NOT NULL,
    code TEXT NOT NULL,
    target_city_id TEXT NOT NULL,
    reason TEXT NOT NULL,
    PRIMARY KEY (namespace, code)
) WITHOUT ROWID;
CREATE TABLE city_sources (
    city_id TEXT NOT NULL REFERENCES cities(id) ON DELETE CASCADE,
    source_id TEXT NOT NULL REFERENCES sources(id),
    role TEXT NOT NULL,
    PRIMARY KEY (city_id, source_id, role)
) WITHOUT ROWID;
CREATE TABLE reference_line_batches (
    country_code TEXT NOT NULL CHECK (country_code IN ('CN', 'JP', 'KR', 'MN')),
    bucket TEXT NOT NULL,
    lines_json TEXT NOT NULL,
    PRIMARY KEY (country_code, bucket)
) WITHOUT ROWID;
"""


PROVINCES_SCHEMA = COMMON_SCHEMA + """
CREATE TABLE provinces (
    id TEXT PRIMARY KEY,
    country_code TEXT NOT NULL CHECK (country_code IN ('CN', 'JP', 'KR', 'MN')),
    subdivision_code TEXT,
    name TEXT NOT NULL,
    native_name TEXT NOT NULL,
    center_longitude REAL NOT NULL,
    center_latitude REAL NOT NULL,
    bbox_min_longitude REAL NOT NULL,
    bbox_min_latitude REAL NOT NULL,
    bbox_max_longitude REAL NOT NULL,
    bbox_max_latitude REAL NOT NULL,
    components_json TEXT NOT NULL,
    city_count INTEGER NOT NULL CHECK (city_count >= 0),
    station_count INTEGER NOT NULL CHECK (station_count >= 0)
);
CREATE INDEX provinces_country_idx ON provinces(country_code);
CREATE TABLE province_evidence_identifiers (
    namespace TEXT NOT NULL,
    code TEXT NOT NULL,
    province_id TEXT NOT NULL REFERENCES provinces(id),
    evidence_kind TEXT NOT NULL,
    PRIMARY KEY (namespace, code)
) WITHOUT ROWID;
CREATE INDEX province_evidence_province_idx ON province_evidence_identifiers(province_id);
CREATE TABLE province_sources (
    province_id TEXT NOT NULL REFERENCES provinces(id) ON DELETE CASCADE,
    source_id TEXT NOT NULL REFERENCES sources(id),
    role TEXT NOT NULL,
    PRIMARY KEY (province_id, source_id, role)
) WITHOUT ROWID;
CREATE TABLE reference_line_batches (
    country_code TEXT NOT NULL CHECK (country_code IN ('CN', 'JP', 'KR', 'MN')),
    bucket TEXT NOT NULL,
    lines_json TEXT NOT NULL,
    PRIMARY KEY (country_code, bucket)
) WITHOUT ROWID;
"""


def insert_sources(connection: sqlite3.Connection, rows: Iterable[tuple[str, ...]]) -> None:
    connection.executemany("INSERT INTO sources VALUES (?, ?, ?, ?, ?, ?, ?)", rows)


def point_in_ring(point: tuple[float, float], ring: list[list[float]]) -> bool:
    x, y = point
    inside = False
    for left, right in zip(ring, ring[1:] + ring[:1]):
        x1, y1 = float(left[0]), float(left[1])
        x2, y2 = float(right[0]), float(right[1])
        if (y1 > y) != (y2 > y):
            intersection_x = (x2 - x1) * (y - y1) / (y2 - y1) + x1
            if x < intersection_x:
                inside = not inside
    return inside


def boundary_contains(boundary: dict[str, Any], point: tuple[float, float]) -> bool:
    for component in boundary.get("components") or []:
        if not point_in_ring(point, component["outer"]):
            continue
        if any(point_in_ring(point, hole) for hole in component.get("holes") or []):
            continue
        return True
    return False


def bbox_area(boundary: dict[str, Any]) -> float:
    min_x, min_y, max_x, max_y = map(float, boundary["bbox"])
    return max(0.0, max_x - min_x) * max(0.0, max_y - min_y)


def bbox_distance(boundary: dict[str, Any], point: tuple[float, float]) -> float:
    x, y = point
    min_x, min_y, max_x, max_y = map(float, boundary["bbox"])
    dx = max(min_x - x, 0.0, x - max_x)
    dy = max(min_y - y, 0.0, y - max_y)
    return math.hypot(dx, dy)


def validate_boundary(boundary: dict[str, Any], label: str) -> None:
    required = {"id", "countryCode", "name", "nativeName", "center", "bbox", "components"}
    if not required.issubset(boundary):
        raise CatalogError(f"{label} is missing fields {sorted(required - set(boundary))}")
    if boundary["countryCode"] not in SUPPORTED_COUNTRIES:
        raise CatalogError(f"{label} has unsupported country {boundary['countryCode']!r}")
    if len(boundary["center"]) != 2 or len(boundary["bbox"]) != 4:
        raise CatalogError(f"{label} has an invalid center or bbox")
    if not boundary["components"]:
        raise CatalogError(f"{label} contains no polygon components")


def china_city_province_names(
    city_catalog: dict[str, Any], coverage: dict[str, Any], emitted_city_ids: set[str]
) -> dict[str, str]:
    city_lookup = {str(key): str(value) for key, value in city_catalog["chinaCityToBoundary"].items()}
    result = {
        str(boundary_id): str(province_name)
        for boundary_id, province_name in coverage.get("referenceBoundaryToProvince", {}).items()
        if boundary_id in emitted_city_ids
    }
    for namespace_name in ("tUnion", "cityUnion"):
        namespace = coverage.get(namespace_name) or {}
        province_only = set(map(str, namespace.get("provinceOnlyCityCodes") or []))
        aliases = {str(key): str(value) for key, value in (namespace.get("cityToBoundaryAlias") or {}).items()}
        for code, province_name in (namespace.get("cityToProvince") or {}).items():
            code = str(code)
            if code in province_only:
                continue
            boundary_code = aliases.get(code, code)
            boundary_id = city_lookup.get(boundary_code)
            if boundary_id not in emitted_city_ids:
                continue
            existing = result.setdefault(boundary_id, str(province_name))
            if existing != str(province_name):
                raise CatalogError(f"China city {boundary_id} maps to multiple provinces")
    return result


def resolve_city_parents(
    city_catalog: dict[str, Any],
    province_catalog: dict[str, Any],
    china_coverage: dict[str, Any],
) -> dict[str, str]:
    cities = city_catalog.get("boundaries") or []
    provinces = province_catalog.get("boundaries") or []
    city_ids = {str(city["id"]) for city in cities}
    province_by_id = {str(province["id"]): province for province in provinces}
    province_by_country: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for province in provinces:
        validate_boundary(province, f"province {province.get('id')}")
        province_by_country[province["countryCode"]].append(province)

    japan_by_subdivision = {
        str(province.get("subdivisionCode")): str(province["id"])
        for province in provinces
        if province["countryCode"] == "JP" and province.get("subdivisionCode")
    }
    china_by_name = {
        str(province["name"]).casefold(): str(province["id"])
        for province in provinces
        if province["countryCode"] == "CN"
    }
    china_names = china_city_province_names(city_catalog, china_coverage, city_ids)
    mongolia_parents = {
        str(city_id): str(province_id)
        for city_id, province_id in (city_catalog.get("mongoliaCityToProvince") or {}).items()
    }

    result: dict[str, str] = {}
    for city in cities:
        validate_boundary(city, f"city {city.get('id')}")
        city_id = str(city["id"])
        country = str(city["countryCode"])
        parent_id: str | None = None
        if country == "JP":
            parent_id = japan_by_subdivision.get(str(city.get("subdivisionCode") or ""))
        elif country == "CN":
            province_name = china_names.get(city_id)
            if province_name:
                parent_id = china_by_name.get(province_name.casefold())
        elif country == "MN":
            parent_id = mongolia_parents.get(city_id)
        else:
            source_feature_id = city_id.split(":")[-1]
            exact_id = f"{country.lower()}:adm1:{source_feature_id}"
            if exact_id in province_by_id:
                parent_id = exact_id
            else:
                center = (float(city["center"][0]), float(city["center"][1]))
                candidates = province_by_country[country]
                containing = [province for province in candidates if boundary_contains(province, center)]
                if containing:
                    parent_id = min(containing, key=lambda item: (bbox_area(item), item["id"]))["id"]
                else:
                    # A coastal city centroid may fall into a geometry hole after
                    # quantization. Bbox distance is deterministic and mirrors the
                    # app's nearest-province fallback without changing geometry.
                    parent_id = min(
                        candidates,
                        key=lambda item: (bbox_distance(item, center), bbox_area(item), item["id"]),
                    )["id"] if candidates else None
        if parent_id is None or parent_id not in province_by_id:
            raise CatalogError(f"Could not resolve parent province for city {city_id}")
        if province_by_id[parent_id]["countryCode"] != country:
            raise CatalogError(f"City {city_id} and province {parent_id} have different countries")
        result[city_id] = parent_id
    return result


def choose_text(values: Iterable[str]) -> str:
    counts = Counter(value.strip() for value in values if value and value.strip())
    if not counts:
        return ""
    return min(counts, key=lambda value: (-counts[value], value.casefold(), value))


def one_or_none(values: Iterable[Any], label: str) -> Any | None:
    unique = {value for value in values if value is not None and value != ""}
    if len(unique) > 1:
        raise CatalogError(f"{label} has conflicting values: {sorted(map(str, unique))[:5]}")
    return next(iter(unique), None)


def insert_station_names(
    connection: sqlite3.Connection,
    station_id: str,
    names: Iterable[tuple[str, str, int]],
) -> None:
    unique = sorted({(language, name.strip(), primary) for language, name, primary in names if name.strip()})
    connection.executemany(
        "INSERT OR IGNORE INTO station_names VALUES (?, ?, ?, ?)",
        [(station_id, language, name, primary) for language, name, primary in unique],
    )


def build_japanese_stations(
    output: sqlite3.Connection,
    source_path: Path,
    city_lookup: dict[str, str],
    city_parents: dict[str, str],
) -> None:
    with open_source_database(source_path) as source:
        rows = source.execute("SELECT * FROM jp_stations ORDER BY hex_code").fetchall()
        grouped: dict[str, list[sqlite3.Row]] = defaultdict(list)
        for row in rows:
            canonical_id = (
                f"jp:pseudo:{row['hex_code']}"
                if int(row["is_pseudo"])
                else f"jp:station:{row['station_code']}"
            )
            grouped[canonical_id].append(row)

        station_code_to_id: dict[str, str] = {}
        for station_id in sorted(grouped):
            group = grouped[station_id]
            is_pseudo = int(group[0]["is_pseudo"])
            source_station_id = str(group[0]["hex_code"] if is_pseudo else group[0]["station_code"])
            latitude = one_or_none((float(row["latitude"]) for row in group), f"{station_id} latitude")
            longitude = one_or_none((float(row["longitude"]) for row in group), f"{station_id} longitude")
            city_ids = {city_lookup[str(row["hex_code"])] for row in group if str(row["hex_code"]) in city_lookup}
            if len(city_ids) > 1:
                raise CatalogError(f"Japanese station {station_id} maps to multiple cities")
            city_id = next(iter(city_ids), None)
            province_id = city_parents.get(city_id) if city_id else None
            name = choose_text(str(row["station_name"]) for row in group)
            native_name = choose_text(str(row["station_original_name"]) for row in group) or name
            confidence = max(float(row["confidence"]) for row in group)
            status = choose_text(str(row["match_method"]) for row in group)
            output.execute(
                "INSERT INTO stations VALUES (?, 'JP', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (
                    station_id,
                    "jp.pseudo" if is_pseudo else "jp.station_database",
                    source_station_id,
                    city_id,
                    province_id,
                    name,
                    native_name,
                    latitude,
                    longitude,
                    is_pseudo,
                    status,
                    confidence,
                ),
            )
            insert_station_names(output, station_id, [("ja", name, 1), ("ja", native_name, 0)])
            output.execute("INSERT INTO station_sources VALUES (?, 'stations.jp', 'entity')", (station_id,))
            for row in group:
                hex_code = str(row["hex_code"]).upper()
                output.execute(
                    "INSERT INTO station_identifiers VALUES ('jp.felica.hex', ?, 'any', ?)",
                    (hex_code, station_id),
                )
                for line_code in sorted(set(json.loads(row["line_codes_json"] or "[]"))):
                    line_id = f"jp:line:{line_code}"
                    output.execute(
                        "INSERT OR IGNORE INTO lines VALUES (?, 'JP', ?, ?, NULL, NULL, 'rail')",
                        (line_id, city_id, str(line_code)),
                    )
                    output.execute(
                        "INSERT OR IGNORE INTO station_line_stops VALUES (?, ?, ?, NULL)",
                        (line_id, station_id, hex_code),
                    )
            if not is_pseudo:
                station_code_to_id[source_station_id] = station_id

        if table_exists(source, "station_edges"):
            for line_code, from_code, to_code, distance in source.execute(
                "SELECT line_code, from_station_code, to_station_code, distance_km "
                "FROM station_edges ORDER BY line_code, from_station_code, to_station_code"
            ):
                from_id = station_code_to_id.get(str(from_code))
                to_id = station_code_to_id.get(str(to_code))
                if not from_id or not to_id or from_id == to_id:
                    continue
                line_id = f"jp:line:{line_code}"
                output.execute(
                    "INSERT OR IGNORE INTO lines VALUES (?, 'JP', NULL, ?, NULL, NULL, 'rail')",
                    (line_id, str(line_code)),
                )
                output.execute(
                    "INSERT OR REPLACE INTO station_edges VALUES (?, ?, ?, ?)",
                    (line_id, from_id, to_id, float(distance)),
                )


def build_chinese_stations(
    output: sqlite3.Connection,
    source_path: Path,
    city_lookup: dict[str, str],
    city_parents: dict[str, str],
) -> None:
    with open_source_database(source_path) as source:
        rows = source.execute("SELECT * FROM tunion_stations ORDER BY station_key").fetchall()
        grouped: dict[str, list[sqlite3.Row]] = defaultdict(list)
        for row in rows:
            osm_id = str(row["osm_id"] or "")
            canonical_id = (
                f"cn:osm:{row['osm_type']}:{osm_id}"
                if osm_id
                else f"cn:tunion:{row['station_key']}"
            )
            grouped[canonical_id].append(row)

        key_to_station: dict[str, str] = {}
        for station_id in sorted(grouped):
            group = grouped[station_id]
            city_codes = {str(row["city_id"]) for row in group}
            if len(city_codes) != 1:
                raise CatalogError(f"Chinese station {station_id} spans multiple city codes")
            city_code = next(iter(city_codes))
            city_id = city_lookup.get(city_code)
            province_id = city_parents.get(city_id) if city_id else None
            latitude = one_or_none((row["latitude"] for row in group), f"{station_id} latitude")
            longitude = one_or_none((row["longitude"] for row in group), f"{station_id} longitude")
            name = choose_text(str(row["display_name"] or row["station_name"] or "") for row in group)
            native_name = choose_text(str(row["station_name"] or "") for row in group) or name
            status = choose_text(str(row["match_status"] or "") for row in group) or "unknown"
            source_namespace = "osm" if station_id.startswith("cn:osm:") else "cn.tunion"
            source_station_id = station_id.removeprefix("cn:")
            output.execute(
                "INSERT INTO stations VALUES (?, 'CN', ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, NULL)",
                (
                    station_id,
                    source_namespace,
                    source_station_id,
                    city_id,
                    province_id,
                    name,
                    native_name,
                    float(latitude) if latitude is not None else None,
                    float(longitude) if longitude is not None else None,
                    status,
                ),
            )
            localized_names = [("zh-Hans", native_name, 1), ("und", name, 0)]
            for language, column in (("en", "osm_name_en"), ("ja", "osm_name_ja"), ("zh-Hans", "osm_name_zh")):
                localized = choose_text(str(row[column] or "") for row in group)
                if localized:
                    localized_names.append((language, localized, 0))
            insert_station_names(output, station_id, localized_names)
            output.execute("INSERT INTO station_sources VALUES (?, 'stations.cn', 'entity')", (station_id,))
            for row in group:
                station_key = str(row["station_key"])
                key_to_station[station_key] = station_id
                output.execute(
                    "INSERT INTO station_identifiers VALUES ('cn.tunion.station_key', ?, 'any', ?)",
                    (station_key, station_id),
                )
                source_code = str(row["source_code"] or "")
                if source_code:
                    output.execute(
                        "INSERT OR IGNORE INTO station_identifiers VALUES "
                        "('cn.tripreader.source_code', ?, 'any', ?)",
                        (f"{row['city_id']}:{source_code}", station_id),
                    )
                line_id = f"cn:line:{row['line_key']}"
                output.execute(
                    "INSERT OR IGNORE INTO lines VALUES (?, 'CN', ?, ?, ?, ?, ?)",
                    (
                        line_id,
                        city_id,
                        str(row["line_key"]),
                        str(row["source_line_name"] or "") or None,
                        str(row["source_line_name"] or "") or None,
                        str(row["source_type"] or "") or None,
                    ),
                )
                output.execute(
                    "INSERT OR IGNORE INTO station_line_stops VALUES (?, ?, ?, ?)",
                    (line_id, station_id, station_key, int(row["sequence"])),
                )

        if table_exists(source, "station_edges"):
            for line_code, from_code, to_code, distance in source.execute(
                "SELECT line_code, from_station_code, to_station_code, distance_km "
                "FROM station_edges ORDER BY line_code, from_station_code, to_station_code"
            ):
                from_id = key_to_station.get(str(from_code))
                to_id = key_to_station.get(str(to_code))
                if not from_id or not to_id or from_id == to_id:
                    continue
                line_id = f"cn:line:{line_code}"
                output.execute(
                    "INSERT OR IGNORE INTO lines VALUES (?, 'CN', NULL, ?, NULL, NULL, NULL)",
                    (line_id, str(line_code)),
                )
                output.execute(
                    "INSERT OR REPLACE INTO station_edges VALUES (?, ?, ?, ?)",
                    (line_id, from_id, to_id, float(distance)),
                )


def korean_rows(path: Path) -> list[dict[str, str]]:
    with path.open(encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        required = {
            "location_code", "station_id", "transport_mode_code", "canonical_name_ko",
            "station_name_en", "station_name_ja", "station_name_zh_hans",
            "station_name_zh_hant", "latitude", "longitude", "operator_name", "line_name",
        }
        if reader.fieldnames is None or not required.issubset(reader.fieldnames):
            raise CatalogError(f"{path} has an unsupported Korean station header")
        return list(reader)


def build_korean_stations(
    output: sqlite3.Connection,
    source_path: Path,
    location_lookup: dict[str, str],
    city_parents: dict[str, str],
) -> None:
    grouped: dict[str, list[dict[str, str]]] = defaultdict(list)
    for row in korean_rows(source_path):
        grouped[f"kr:station:{row['station_id'].upper()}"].append(row)
    for station_id in sorted(grouped):
        group = grouped[station_id]
        city_ids = {location_lookup[row["location_code"].upper()] for row in group if row["location_code"].upper() in location_lookup}
        if len(city_ids) > 1:
            raise CatalogError(f"Korean station {station_id} maps to multiple cities")
        city_id = next(iter(city_ids), None)
        province_id = city_parents.get(city_id) if city_id else None
        latitude_text = one_or_none((row["latitude"] for row in group), f"{station_id} latitude")
        longitude_text = one_or_none((row["longitude"] for row in group), f"{station_id} longitude")
        name = choose_text(row["station_name_en"] for row in group)
        native_name = choose_text(row["canonical_name_ko"] for row in group)
        if not name:
            name = native_name
        output.execute(
            "INSERT INTO stations VALUES (?, 'KR', 'kr.korean_stations', ?, ?, ?, ?, ?, ?, ?, 0, 'reviewed', 1.0)",
            (
                station_id,
                group[0]["station_id"].upper(),
                city_id,
                province_id,
                name,
                native_name,
                float(latitude_text) if latitude_text else None,
                float(longitude_text) if longitude_text else None,
            ),
        )
        names = [("ko", native_name, 1), ("en", name, 0)]
        for language, column in (("ja", "station_name_ja"), ("zh-Hans", "station_name_zh_hans"), ("zh-Hant", "station_name_zh_hant")):
            value = choose_text(row[column] for row in group)
            if value:
                names.append((language, value, 0))
        insert_station_names(output, station_id, names)
        output.execute("INSERT INTO station_sources VALUES (?, 'stations.kr', 'entity')", (station_id,))
        for row in sorted(group, key=lambda item: item["location_code"]):
            location_code = row["location_code"].upper()
            for event_kind in KOREAN_EVENT_CONSTRAINTS.get(location_code, ("any",)):
                output.execute(
                    "INSERT INTO station_identifiers VALUES ('kr.ksx.location', ?, ?, ?)",
                    (location_code, event_kind, station_id),
                )
            line_key = "|".join((row["operator_name"].strip(), row["line_name"].strip()))
            if line_key.strip("|"):
                digest = hashlib.sha256(line_key.encode("utf-8")).hexdigest()[:20]
                line_id = f"kr:line:{digest}"
                output.execute(
                    "INSERT OR IGNORE INTO lines VALUES (?, 'KR', ?, ?, ?, ?, NULL)",
                    (line_id, city_id, digest, row["line_name"].strip() or None, row["line_name"].strip() or None),
                )
                output.execute(
                    "INSERT OR IGNORE INTO station_line_stops VALUES (?, ?, ?, NULL)",
                    (line_id, station_id, location_code),
                )


def build_mongolian_stations(
    output: sqlite3.Connection,
    source_path: Path,
    city_lookup: dict[str, str],
    province_lookup: dict[str, str],
) -> None:
    with open_source_database(source_path) as source:
        rows = source.execute("SELECT * FROM stations ORDER BY station_id").fetchall()
        for row in rows:
            source_id = str(row["station_id"])
            station_id = f"mn:station:{source_id}"
            city_id = city_lookup.get(source_id)
            province_id = province_lookup.get(source_id)
            output.execute(
                "INSERT INTO stations VALUES (?, 'MN', 'mn.ubsmartbus', ?, ?, ?, ?, ?, ?, ?, 0, 'official', 1.0)",
                (
                    station_id,
                    source_id,
                    city_id,
                    province_id,
                    str(row["station_name_en"]),
                    str(row["station_name_mn"]),
                    float(row["latitude"]),
                    float(row["longitude"]),
                ),
            )
            insert_station_names(
                output,
                station_id,
                [("mn", str(row["station_name_mn"]), 1), ("en", str(row["station_name_en"]), 0)],
            )
            output.execute("INSERT INTO station_sources VALUES (?, 'stations.mn', 'entity')", (station_id,))
            output.execute(
                "INSERT INTO station_identifiers VALUES ('mn.ubsmartbus.station_id', ?, 'any', ?)",
                (source_id, station_id),
            )

        if table_exists(source, "routes") and table_exists(source, "route_stations"):
            for route in source.execute("SELECT * FROM routes ORDER BY route_id"):
                line_id = f"mn:route:{route['route_id']}"
                output.execute(
                    "INSERT INTO lines VALUES (?, 'MN', NULL, ?, ?, ?, 'bus')",
                    (
                        line_id,
                        str(route["route_id"]),
                        str(route["route_name_en"]),
                        str(route["route_name_mn"]),
                    ),
                )
            for route_id, sequence, source_station_id in source.execute(
                "SELECT route_id, station_sequence, station_id FROM route_stations "
                "ORDER BY route_id, station_sequence"
            ):
                output.execute(
                    "INSERT INTO station_line_stops VALUES (?, ?, ?, ?)",
                    (
                        f"mn:route:{route_id}",
                        f"mn:station:{source_station_id}",
                        str(source_station_id),
                        int(sequence),
                    ),
                )


def write_metadata(connection: sqlite3.Connection, values: dict[str, Any]) -> None:
    connection.executemany(
        "INSERT INTO metadata VALUES (?, ?)",
        [(key, canonical_json(value) if not isinstance(value, str) else value) for key, value in sorted(values.items())],
    )


def finalize_database(connection: sqlite3.Connection) -> None:
    connection.commit()
    violations = connection.execute("PRAGMA foreign_key_check").fetchall()
    if violations:
        raise CatalogError(f"SQLite foreign-key violations: {violations[:5]}")
    integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
    if integrity != "ok":
        raise CatalogError(f"SQLite integrity check failed: {integrity}")
    connection.execute("VACUUM")


def build_stations_database(
    path: Path,
    resources: Path,
    sources: list[tuple[str, ...]],
    city_catalog: dict[str, Any],
    province_catalog: dict[str, Any],
    city_parents: dict[str, str],
    generated_at: str,
) -> tuple[Counter[str], Counter[str]]:
    city_ids = set(city_parents)
    japan_lookup = {str(key).upper(): str(value) for key, value in city_catalog["japanStationToBoundary"].items()}
    china_lookup = {
        str(key): str(value)
        for key, value in city_catalog["chinaCityToBoundary"].items()
        if str(value) in city_ids
    }
    korea_lookup = {str(key).upper(): str(value) for key, value in city_catalog["koreaLocationToBoundary"].items()}
    mongolia_city_lookup = {str(key): str(value) for key, value in city_catalog["mongoliaStationToBoundary"].items()}
    mongolia_province_lookup = {str(key): str(value) for key, value in province_catalog["mongoliaStationToBoundary"].items()}

    with sqlite3.connect(path) as connection:
        configure_database(connection, 0x43425354)  # CBST
        connection.executescript(STATIONS_SCHEMA)
        insert_sources(connection, sources)
        build_japanese_stations(connection, resources / "jp_stations.sqlite", japan_lookup, city_parents)
        build_chinese_stations(connection, resources / "tunion_stations.sqlite", china_lookup, city_parents)
        build_korean_stations(connection, resources / "korean_stations.tsv", korea_lookup, city_parents)
        build_mongolian_stations(
            connection,
            resources / "ulaanbaatar_transit.sqlite",
            mongolia_city_lookup,
            mongolia_province_lookup,
        )
        station_counts = Counter(
            {country: count for country, count in connection.execute("SELECT country_code, COUNT(*) FROM stations GROUP BY country_code")}
        )
        write_metadata(
            connection,
            {
                "format": "cardbal-unified-stations-v1",
                "generated_at": generated_at,
                "schema_version": str(SCHEMA_VERSION),
                "station_counts": dict(sorted(station_counts.items())),
            },
        )
        city_counts = Counter(
            {city_id: count for city_id, count in connection.execute("SELECT city_id, COUNT(*) FROM stations WHERE city_id IS NOT NULL AND is_pseudo = 0 GROUP BY city_id")}
        )
        province_counts = Counter(
            {province_id: count for province_id, count in connection.execute("SELECT province_id, COUNT(*) FROM stations WHERE province_id IS NOT NULL AND is_pseudo = 0 GROUP BY province_id")}
        )
        finalize_database(connection)
    return city_counts, province_counts


def boundary_row(boundary: dict[str, Any], parent_id: str | None, count_a: int, count_b: int | None = None) -> tuple[Any, ...]:
    center = boundary["center"]
    bbox = boundary["bbox"]
    common = (
        str(boundary["id"]),
        str(boundary["countryCode"]),
    )
    if parent_id is not None:
        return common + (
            parent_id,
            boundary.get("subdivisionCode"),
            str(boundary["name"]),
            str(boundary["nativeName"]),
            float(center[0]), float(center[1]),
            float(bbox[0]), float(bbox[1]), float(bbox[2]), float(bbox[3]),
            canonical_json(boundary["components"]),
            int(count_a),
            "station" if count_a else "network_or_mode",
        )
    return common + (
        boundary.get("subdivisionCode"),
        str(boundary["name"]),
        str(boundary["nativeName"]),
        float(center[0]), float(center[1]),
        float(bbox[0]), float(bbox[1]), float(bbox[2]), float(bbox[3]),
        canonical_json(boundary["components"]),
        int(count_a),
        int(count_b or 0),
    )


def insert_reference_lines(connection: sqlite3.Connection, catalog: dict[str, Any]) -> None:
    rows = []
    seen: set[tuple[str, str]] = set()
    for batch in catalog.get("referenceLines") or []:
        key = (str(batch["countryCode"]), str(batch["bucket"]))
        if key in seen:
            raise CatalogError(f"Duplicate reference-line bucket {key}")
        seen.add(key)
        rows.append((key[0], key[1], canonical_json(batch["lines"])))
    connection.executemany("INSERT INTO reference_line_batches VALUES (?, ?, ?)", sorted(rows))


def add_city_evidence(
    connection: sqlite3.Connection,
    namespace: str,
    mapping: dict[str, str],
    city_ids: set[str],
    evidence_kind: str,
    unresolved_reason: str | None = None,
) -> None:
    for code, city_id in sorted((str(key), str(value)) for key, value in mapping.items()):
        if city_id in city_ids:
            connection.execute(
                "INSERT INTO city_evidence_identifiers VALUES (?, ?, ?, ?, 100)",
                (namespace, code, city_id, evidence_kind),
            )
        elif unresolved_reason:
            connection.execute(
                "INSERT INTO unresolved_city_evidence_identifiers VALUES (?, ?, ?, ?)",
                (namespace, code, city_id, unresolved_reason),
            )
        else:
            raise CatalogError(f"{namespace} code {code} targets missing city {city_id}")


def build_cities_database(
    path: Path,
    sources: list[tuple[str, ...]],
    catalog: dict[str, Any],
    coverage: dict[str, Any],
    city_parents: dict[str, str],
    station_counts: Counter[str],
    generated_at: str,
) -> None:
    boundaries = catalog.get("boundaries") or []
    city_ids = {str(boundary["id"]) for boundary in boundaries}
    if city_ids != set(city_parents):
        raise CatalogError("City parent mapping does not exactly cover emitted city boundaries")
    china_mapping = {
        str(code): str(city_id)
        for code, city_id in catalog["chinaCityToBoundary"].items()
    }
    unresolved_china_codes = {
        code for code, city_id in china_mapping.items() if city_id not in city_ids
    }
    expected_unresolved_china_codes = set(
        map(str, (coverage.get("tUnion") or {}).get("excludedCityBoundaryCodes") or [])
    )
    if unresolved_china_codes != expected_unresolved_china_codes:
        raise CatalogError(
            "Unresolved China city mappings do not exactly match the reviewed exclusions: "
            f"actual={sorted(unresolved_china_codes)}, "
            f"expected={sorted(expected_unresolved_china_codes)}"
        )
    with sqlite3.connect(path) as connection:
        configure_database(connection, 0x43424354)  # CBCT
        connection.executescript(CITIES_SCHEMA)
        insert_sources(connection, sources)
        for boundary in sorted(boundaries, key=lambda item: str(item["id"])):
            city_id = str(boundary["id"])
            connection.execute(
                "INSERT INTO cities VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                boundary_row(boundary, city_parents[city_id], station_counts[city_id]),
            )
            connection.execute(
                "INSERT INTO city_sources VALUES (?, 'boundaries.city', 'geometry')",
                (city_id,),
            )

        add_city_evidence(
            connection, "jp.felica.station_hex", catalog["japanStationToBoundary"], city_ids, "station"
        )
        add_city_evidence(
            connection,
            "cn.tunion.city_code",
            china_mapping,
            city_ids,
            "city_code",
            unresolved_reason="not_in_current_supported_city_layer",
        )
        add_city_evidence(
            connection, "kr.kotris.mode", catalog["koreaModeToBoundary"], city_ids, "mode"
        )
        add_city_evidence(
            connection, "kr.ksx.location", catalog["koreaLocationToBoundary"], city_ids, "station"
        )
        add_city_evidence(
            connection, "mn.ubsmartbus.station_id", catalog["mongoliaStationToBoundary"], city_ids, "station"
        )

        china_exact = {str(key): str(value) for key, value in catalog["chinaCityToBoundary"].items()}
        for coverage_name, namespace in (("tUnion", "cn.tunion.city_alias"), ("cityUnion", "cn.city_union.city_code")):
            coverage_namespace = coverage.get(coverage_name) or {}
            aliases = coverage_namespace.get("cityToBoundaryAlias") or {}
            alias_mapping = {
                str(code): china_exact[str(target)]
                for code, target in aliases.items()
                if str(target) in china_exact
            }
            add_city_evidence(connection, namespace, alias_mapping, city_ids, "reviewed_alias")

        insert_reference_lines(connection, catalog)
        country_counts = Counter(boundary["countryCode"] for boundary in boundaries)
        write_metadata(
            connection,
            {
                "format": "cardbal-unified-cities-v1",
                "generated_at": generated_at,
                "schema_version": str(SCHEMA_VERSION),
                "boundary_counts": dict(sorted(country_counts.items())),
                "attribution": catalog.get("attribution") or [],
                "generation": catalog.get("generation") or {},
                "sources": catalog.get("sources") or {},
            },
        )
        finalize_database(connection)


def build_provinces_database(
    path: Path,
    sources: list[tuple[str, ...]],
    catalog: dict[str, Any],
    coverage: dict[str, Any],
    city_parents: dict[str, str],
    station_counts: Counter[str],
    generated_at: str,
) -> None:
    boundaries = catalog.get("boundaries") or []
    province_ids = {str(boundary["id"]) for boundary in boundaries}
    city_counts = Counter(city_parents.values())
    with sqlite3.connect(path) as connection:
        configure_database(connection, 0x43425052)  # CBPR
        connection.executescript(PROVINCES_SCHEMA)
        insert_sources(connection, sources)
        for boundary in sorted(boundaries, key=lambda item: str(item["id"])):
            province_id = str(boundary["id"])
            connection.execute(
                "INSERT INTO provinces VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                boundary_row(
                    boundary,
                    None,
                    city_counts[province_id],
                    station_counts[province_id],
                ),
            )
            connection.execute(
                "INSERT INTO province_sources VALUES (?, 'boundaries.province', 'geometry')",
                (province_id,),
            )

        for code, province_id in sorted(
            (str(key), str(value)) for key, value in (catalog.get("mongoliaStationToBoundary") or {}).items()
        ):
            if province_id not in province_ids:
                raise CatalogError(f"Mongolia station {code} targets missing province {province_id}")
            connection.execute(
                "INSERT INTO province_evidence_identifiers VALUES "
                "('mn.ubsmartbus.station_id', ?, ?, 'station')",
                (code, province_id),
            )

        province_by_name = {str(boundary["name"]).casefold(): str(boundary["id"]) for boundary in boundaries if boundary["countryCode"] == "CN"}
        for coverage_name, namespace in (("tUnion", "cn.tunion.province_only_city_code"), ("cityUnion", "cn.city_union.province_only_city_code")):
            coverage_namespace = coverage.get(coverage_name) or {}
            city_to_province = coverage_namespace.get("cityToProvince") or {}
            for code in sorted(map(str, coverage_namespace.get("provinceOnlyCityCodes") or [])):
                province_name = str(city_to_province.get(code) or "")
                province_id = province_by_name.get(province_name.casefold())
                if not province_id:
                    raise CatalogError(f"China province-only code {code} has no emitted province")
                connection.execute(
                    "INSERT INTO province_evidence_identifiers VALUES (?, ?, ?, 'city_code')",
                    (namespace, code, province_id),
                )

        insert_reference_lines(connection, catalog)
        country_counts = Counter(boundary["countryCode"] for boundary in boundaries)
        write_metadata(
            connection,
            {
                "format": "cardbal-unified-provinces-v1",
                "generated_at": generated_at,
                "schema_version": str(SCHEMA_VERSION),
                "boundary_counts": dict(sorted(country_counts.items())),
                "attribution": catalog.get("attribution") or [],
                "generation": catalog.get("generation") or {},
                "sources": catalog.get("sources") or {},
            },
        )
        finalize_database(connection)


def scalar(connection: sqlite3.Connection, query: str) -> Any:
    return connection.execute(query).fetchone()[0]


def validate_cross_file(stations: Path, cities: Path, provinces: Path) -> None:
    with sqlite3.connect(":memory:") as connection:
        connection.execute("ATTACH DATABASE ? AS stationdb", (str(stations),))
        connection.execute("ATTACH DATABASE ? AS citydb", (str(cities),))
        connection.execute("ATTACH DATABASE ? AS provincedb", (str(provinces),))
        for schema in ("stationdb", "citydb", "provincedb"):
            integrity = scalar(connection, f"PRAGMA {schema}.integrity_check")
            if integrity != "ok":
                raise CatalogError(f"{schema} integrity check failed: {integrity}")

        queries = {
            "station city references": """
                SELECT COUNT(*) FROM stationdb.stations s
                LEFT JOIN citydb.cities c ON c.id = s.city_id
                WHERE s.city_id IS NOT NULL AND c.id IS NULL
            """,
            "station province references": """
                SELECT COUNT(*) FROM stationdb.stations s
                LEFT JOIN provincedb.provinces p ON p.id = s.province_id
                WHERE s.province_id IS NOT NULL AND p.id IS NULL
            """,
            "city province references": """
                SELECT COUNT(*) FROM citydb.cities c
                LEFT JOIN provincedb.provinces p ON p.id = c.province_id
                WHERE p.id IS NULL
            """,
            "station/city country agreement": """
                SELECT COUNT(*) FROM stationdb.stations s
                JOIN citydb.cities c ON c.id = s.city_id
                WHERE s.country_code <> c.country_code
            """,
            "station/province country agreement": """
                SELECT COUNT(*) FROM stationdb.stations s
                JOIN provincedb.provinces p ON p.id = s.province_id
                WHERE s.country_code <> p.country_code
            """,
            "city/province country agreement": """
                SELECT COUNT(*) FROM citydb.cities c
                JOIN provincedb.provinces p ON p.id = c.province_id
                WHERE c.country_code <> p.country_code
            """,
            "station city-parent agreement": """
                SELECT COUNT(*) FROM stationdb.stations s
                JOIN citydb.cities c ON c.id = s.city_id
                WHERE s.province_id IS NULL OR s.province_id <> c.province_id
            """,
            "stationless Japan cities": """
                SELECT COUNT(*) FROM citydb.cities c
                WHERE c.country_code = 'JP' AND NOT EXISTS (
                    SELECT 1 FROM stationdb.stations s
                    WHERE s.city_id = c.id AND s.is_pseudo = 0
                )
            """,
            "Mongolia stations without cities": """
                SELECT COUNT(*) FROM stationdb.stations
                WHERE country_code = 'MN' AND city_id IS NULL
            """,
            "Mongolia stations without provinces": """
                SELECT COUNT(*) FROM stationdb.stations
                WHERE country_code = 'MN' AND province_id IS NULL
            """,
            "Japanese evidence/station city disagreement": """
                SELECT COUNT(*) FROM citydb.city_evidence_identifiers e
                LEFT JOIN stationdb.station_identifiers i
                    ON i.namespace = 'jp.felica.hex'
                    AND i.code = e.code
                    AND i.event_kind = 'any'
                LEFT JOIN stationdb.stations s ON s.id = i.station_id
                WHERE e.namespace = 'jp.felica.station_hex'
                    AND (s.id IS NULL OR s.city_id <> e.city_id)
            """,
            "Korean evidence/station city disagreement": """
                SELECT COUNT(*) FROM citydb.city_evidence_identifiers e
                LEFT JOIN stationdb.station_identifiers i
                    ON i.namespace = 'kr.ksx.location'
                    AND i.code = e.code
                LEFT JOIN stationdb.stations s ON s.id = i.station_id
                WHERE e.namespace = 'kr.ksx.location'
                    AND (s.id IS NULL OR s.city_id <> e.city_id)
            """,
            "Mongolia evidence/station city disagreement": """
                SELECT COUNT(*) FROM citydb.city_evidence_identifiers e
                LEFT JOIN stationdb.station_identifiers i
                    ON i.namespace = 'mn.ubsmartbus.station_id'
                    AND i.code = e.code
                    AND i.event_kind = 'any'
                LEFT JOIN stationdb.stations s ON s.id = i.station_id
                WHERE e.namespace = 'mn.ubsmartbus.station_id'
                    AND (s.id IS NULL OR s.city_id <> e.city_id)
            """,
            "city station-count disagreement": """
                SELECT COUNT(*) FROM citydb.cities c
                WHERE c.station_count <> (
                    SELECT COUNT(*) FROM stationdb.stations s
                    WHERE s.city_id = c.id AND s.is_pseudo = 0
                )
            """,
            "province station-count disagreement": """
                SELECT COUNT(*) FROM provincedb.provinces p
                WHERE p.station_count <> (
                    SELECT COUNT(*) FROM stationdb.stations s
                    WHERE s.province_id = p.id AND s.is_pseudo = 0
                )
            """,
            "province city-count disagreement": """
                SELECT COUNT(*) FROM provincedb.provinces p
                WHERE p.city_count <> (
                    SELECT COUNT(*) FROM citydb.cities c WHERE c.province_id = p.id
                )
            """,
        }
        failures = {}
        for label, query in queries.items():
            count = int(scalar(connection, query))
            if count:
                failures[label] = count
        if failures:
            raise CatalogError(f"Cross-database validation failed: {failures}")

        for schema, table in (("stationdb", "stations"), ("citydb", "cities"), ("provincedb", "provinces")):
            countries = tuple(
                row[0]
                for row in connection.execute(
                    f"SELECT DISTINCT country_code FROM {schema}.{table} ORDER BY country_code"
                )
            )
            if countries != tuple(sorted(SUPPORTED_COUNTRIES)):
                raise CatalogError(f"{schema}.{table} country set is {countries}, expected {SUPPORTED_COUNTRIES}")


def validate_input_catalogs(
    city_catalog: dict[str, Any], province_catalog: dict[str, Any], china_coverage: dict[str, Any]
) -> str:
    for name, catalog in (("city", city_catalog), ("province", province_catalog)):
        if catalog.get("version") != 2:
            raise CatalogError(f"Unsupported {name} catalog version {catalog.get('version')!r}")
        boundaries = catalog.get("boundaries")
        if not isinstance(boundaries, list) or not boundaries:
            raise CatalogError(f"{name} catalog contains no boundaries")
        ids = [str(boundary.get("id") or "") for boundary in boundaries]
        if len(ids) != len(set(ids)) or "" in ids:
            raise CatalogError(f"{name} catalog boundary IDs are empty or duplicated")
    if china_coverage.get("version") != 1:
        raise CatalogError(f"Unsupported China coverage version {china_coverage.get('version')!r}")
    city_generated = str(city_catalog.get("generatedAt") or "")
    province_generated = str(province_catalog.get("generatedAt") or "")
    if not city_generated or city_generated != province_generated:
        raise CatalogError(
            f"City/province catalogs are not one finalized generation: {city_generated!r} vs {province_generated!r}"
        )
    return city_generated


def generate(resources: Path, output_directory: Path, generated_at: str | None = None) -> dict[str, Path]:
    resources = resources.resolve()
    for filename in REQUIRED_INPUTS:
        if not (resources / filename).is_file():
            raise FileNotFoundError(resources / filename)
    city_catalog = load_json(resources / "EastAsiaCityBoundaries.json")
    province_catalog = load_json(resources / "EastAsiaProvinceBoundaries.json")
    china_coverage = load_json(resources / "ChinaTransitCoverage.json")
    catalog_generated_at = validate_input_catalogs(city_catalog, province_catalog, china_coverage)
    generated_at = generated_at or catalog_generated_at
    sources = source_rows(resources)
    source_ids = {row[0] for row in sources}
    required_source_ids = {
        "boundaries.city", "boundaries.province", "coverage.cn", "coverage.jp",
        "stations.jp", "stations.cn", "stations.kr", "stations.mn",
    }
    if not required_source_ids.issubset(source_ids):
        raise CatalogError(f"Missing source rows: {sorted(required_source_ids - source_ids)}")
    city_parents = resolve_city_parents(city_catalog, province_catalog, china_coverage)

    output_directory.mkdir(parents=True, exist_ok=True)
    final_paths = {
        "stations": output_directory / STATIONS_FILENAME,
        "cities": output_directory / CITIES_FILENAME,
        "provinces": output_directory / PROVINCES_FILENAME,
    }
    temporary_paths: dict[str, Path] = {}
    try:
        for key, final_path in final_paths.items():
            descriptor, temporary_name = tempfile.mkstemp(
                prefix=f".{final_path.stem}-", suffix=".sqlite", dir=final_path.parent
            )
            os.close(descriptor)
            temporary = Path(temporary_name)
            temporary.unlink()
            temporary_paths[key] = temporary
        city_station_counts, province_station_counts = build_stations_database(
            temporary_paths["stations"],
            resources,
            sources,
            city_catalog,
            province_catalog,
            city_parents,
            generated_at,
        )
        build_cities_database(
            temporary_paths["cities"],
            sources,
            city_catalog,
            china_coverage,
            city_parents,
            city_station_counts,
            generated_at,
        )
        build_provinces_database(
            temporary_paths["provinces"],
            sources,
            province_catalog,
            china_coverage,
            city_parents,
            province_station_counts,
            generated_at,
        )
        validate_cross_file(
            temporary_paths["stations"], temporary_paths["cities"], temporary_paths["provinces"]
        )
        for key in ("stations", "cities", "provinces"):
            os.replace(temporary_paths[key], final_paths[key])
        return final_paths
    finally:
        for path in temporary_paths.values():
            path.unlink(missing_ok=True)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--resources", type=Path, default=DEFAULT_RESOURCES)
    parser.add_argument("--output-directory", type=Path, default=DEFAULT_RESOURCES)
    parser.add_argument(
        "--generated-at",
        help="Override the shared catalog timestamp for deterministic verification builds.",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    outputs = generate(args.resources, args.output_directory, args.generated_at)
    print(
        canonical_json(
            {
                key: {
                    "path": str(path),
                    "bytes": path.stat().st_size,
                    "sha256": sha256_file(path),
                }
                for key, path in sorted(outputs.items())
            }
        )
    )


if __name__ == "__main__":
    main()
