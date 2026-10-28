#!/usr/bin/env python3
"""Generate CardBal's unified East Asia transit SQLite catalog.

The country-specific source files remain the reproducible inputs.  This script
packages their finalized station, city, and province data into one runtime
database while retaining the existing boundary IDs and authoritative identifier
lookups verbatim.  The database is built in a temporary path and only replaces
the published file after every relational and catalog invariant passes.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import os
import sqlite3
import struct
import tempfile
import unicodedata
from collections import Counter, defaultdict
from contextlib import closing, contextmanager
from pathlib import Path
from typing import Any, Iterable, Iterator


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_RESOURCES = REPO_ROOT / "CardBal/Resources"
SUPPORTED_COUNTRIES = ("CN", "JP", "KR", "MN")
SCHEMA_VERSION = 1

OUTPUT_FILENAME = "cardbal_transit.sqlite"

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
        "tunion_tripreader_source.json": ("sources.cn.tripreader", "Trip Reader source snapshot and attribution"),
    }
    rows = []
    csv_manifest_path = resources / "card-stations-manifest.json"
    if csv_manifest_path.is_file():
        csv_manifest = load_json(csv_manifest_path)
        rows.append((
            "sources.card-stations", "iebb/card-stations CSV catalog",
            csv_manifest["repository"], csv_manifest["revision"], "",
            "See card-stations DATA_SOURCES.md for per-source terms",
            csv_manifest["source_sha256"],
        ))
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
    tripreader_path = resources / "tunion_tripreader_source.json"
    if tripreader_path.is_file():
        for index, upstream in enumerate(load_json(tripreader_path).get("sources", [])):
            rows.append((
                f"sources.cn.tripreader.{index}", upstream["attribution"], upstream["url"],
                upstream["revision"], "", upstream["license"],
                upstream.get("sha256") or hashlib.sha256(canonical_json(upstream["files"]).encode()).hexdigest(),
            ))
    return sorted(rows)


@contextmanager
def open_source_database(path: Path) -> Iterator[sqlite3.Connection]:
    uri = f"file:{path.resolve().as_posix()}?mode=ro&immutable=1"
    connection = sqlite3.connect(uri, uri=True)
    connection.row_factory = sqlite3.Row
    try:
        yield connection
    finally:
        connection.close()


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


TRANSIT_SCHEMA = COMMON_SCHEMA + """
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
CREATE TABLE province_identifiers (
    namespace TEXT NOT NULL,
    code TEXT NOT NULL,
    province_id TEXT NOT NULL REFERENCES provinces(id),
    display_name TEXT,
    PRIMARY KEY (namespace, code)
) WITHOUT ROWID;
CREATE INDEX province_identifiers_province_idx ON province_identifiers(province_id);
CREATE TABLE province_sources (
    province_id TEXT NOT NULL REFERENCES provinces(id) ON DELETE CASCADE,
    source_id TEXT NOT NULL REFERENCES sources(id),
    role TEXT NOT NULL,
    PRIMARY KEY (province_id, source_id, role)
) WITHOUT ROWID;
CREATE TABLE cities (
    id TEXT PRIMARY KEY,
    country_code TEXT NOT NULL CHECK (country_code IN ('CN', 'JP', 'KR', 'MN')),
    province_id TEXT NOT NULL REFERENCES provinces(id),
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
CREATE TABLE city_identifiers (
    namespace TEXT NOT NULL,
    code TEXT NOT NULL,
    city_id TEXT NOT NULL REFERENCES cities(id),
    display_name TEXT,
    PRIMARY KEY (namespace, code)
) WITHOUT ROWID;
CREATE INDEX city_identifiers_city_idx ON city_identifiers(city_id);
CREATE TABLE city_sources (
    city_id TEXT NOT NULL REFERENCES cities(id) ON DELETE CASCADE,
    source_id TEXT NOT NULL REFERENCES sources(id),
    role TEXT NOT NULL,
    PRIMARY KEY (city_id, source_id, role)
) WITHOUT ROWID;
CREATE TABLE stations (
    id TEXT PRIMARY KEY,
    country_code TEXT NOT NULL CHECK (country_code IN ('CN', 'JP', 'KR', 'MN')),
    source_namespace TEXT NOT NULL,
    source_station_id TEXT NOT NULL,
    city_id TEXT REFERENCES cities(id),
    province_id TEXT REFERENCES provinces(id),
    name TEXT NOT NULL,
    native_name TEXT,
    latitude REAL,
    longitude REAL,
    is_pseudo INTEGER NOT NULL CHECK (is_pseudo IN (0, 1)),
    match_status TEXT NOT NULL,
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
    lookup_name TEXT,
    map_group_id TEXT,
    source_properties_json TEXT,
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
    city_id TEXT REFERENCES cities(id),
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
CREATE TABLE station_graph_edges (
    country_code TEXT NOT NULL CHECK (country_code IN ('JP', 'CN')),
    line_code TEXT NOT NULL,
    from_station_code TEXT NOT NULL,
    to_station_code TEXT NOT NULL,
    distance_km REAL NOT NULL CHECK (distance_km >= 0),
    source_id TEXT NOT NULL REFERENCES sources(id),
    PRIMARY KEY (country_code, line_code, from_station_code, to_station_code)
) WITHOUT ROWID;
CREATE INDEX station_graph_edges_country_idx ON station_graph_edges(country_code);
CREATE TABLE station_edge_paths (
    country_code TEXT NOT NULL CHECK (country_code IN ('JP', 'CN')),
    line_code TEXT NOT NULL,
    from_station_code TEXT NOT NULL,
    to_station_code TEXT NOT NULL,
    geohash_path TEXT NOT NULL,
    PRIMARY KEY (country_code, line_code, from_station_code, to_station_code),
    FOREIGN KEY (country_code, line_code, from_station_code, to_station_code)
      REFERENCES station_graph_edges(country_code, line_code, from_station_code, to_station_code)
) WITHOUT ROWID;

CREATE TABLE tunion_terminal_stations (
    record_kind TEXT NOT NULL CHECK (record_kind IN ('18', '1e')),
    city_id TEXT NOT NULL,
    terminal_code TEXT NOT NULL,
    station_name TEXT NOT NULL,
    line_name TEXT NOT NULL,
    station_type TEXT NOT NULL,
    station_key TEXT,
    source_json TEXT NOT NULL,
    PRIMARY KEY (record_kind, city_id, terminal_code)
) WITHOUT ROWID;
CREATE TABLE cityunion_terminal_prefixes (
    terminal_prefix TEXT PRIMARY KEY, city_id TEXT NOT NULL,
    station_name TEXT NOT NULL, line_name TEXT NOT NULL,
    station_type TEXT NOT NULL, station_key TEXT, source_json TEXT NOT NULL
) WITHOUT ROWID;
CREATE TABLE reference_line_batches (
    boundary_level TEXT NOT NULL CHECK (boundary_level IN ('city', 'province')),
    country_code TEXT NOT NULL CHECK (country_code IN ('CN', 'JP', 'KR', 'MN')),
    bucket TEXT NOT NULL,
    lines_json TEXT NOT NULL,
    source_id TEXT NOT NULL REFERENCES sources(id),
    PRIMARY KEY (boundary_level, country_code, bucket)
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


def boundary_coverage_name(boundary: dict[str, Any]) -> str:
    return str(boundary.get("coverageName") or boundary["name"])


def province_ids_by_coverage_name(
    boundaries: Iterable[dict[str, Any]], country_code: str
) -> dict[str, str]:
    result: dict[str, str] = {}
    for boundary in boundaries:
        if boundary["countryCode"] != country_code:
            continue
        key = boundary_coverage_name(boundary).casefold()
        if key in result:
            raise CatalogError(
                f"Duplicate {country_code} province coverage name "
                f"{boundary_coverage_name(boundary)!r}"
            )
        result[key] = str(boundary["id"])
    return result


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


JEONNAM_GWANGJU_BOUNDARY_ID = "kr:province:jeonnam-gwangju"
JEONNAM_GWANGJU_PREDECESSOR_CODES = ("KR-29", "KR-46")
JEONNAM_GWANGJU_EFFECTIVE_DATE = "2026-07-01"
JEONNAM_GWANGJU_STATUTORY_NAME = "Jeonnam-Gwangju Special Metropolitan City"


def validate_korean_province_merge(
    city_catalog: dict[str, Any],
    province_catalog: dict[str, Any],
    city_parents: dict[str, str],
) -> None:
    provinces = province_catalog.get("boundaries") or []
    province_by_id = {str(province["id"]): province for province in provinces}
    merged = province_by_id.get(JEONNAM_GWANGJU_BOUNDARY_ID)
    changes = province_catalog.get("generation", {}).get("administrativeChanges") or []
    matching_changes = [
        change
        for change in changes
        if str(change.get("newBoundaryID") or "") == JEONNAM_GWANGJU_BOUNDARY_ID
    ]
    if merged is None:
        if matching_changes:
            raise CatalogError(
                "Korean province merger metadata exists without its merged boundary"
            )
        return
    if merged.get("countryCode") != "KR":
        raise CatalogError("Jeonnam-Gwangju merged boundary must belong to Korea")
    if len(matching_changes) != 1:
        raise CatalogError(
            "Jeonnam-Gwangju requires exactly one administrativeChanges entry"
        )
    change = matching_changes[0]
    if change.get("kind") != "provinceMerge":
        raise CatalogError("Jeonnam-Gwangju administrative change must be a provinceMerge")
    if str(change.get("name") or "") != str(merged["name"]):
        raise CatalogError("Jeonnam-Gwangju metadata and boundary names disagree")
    if str(change.get("nativeName") or "") != str(merged["nativeName"]):
        raise CatalogError("Jeonnam-Gwangju metadata and native boundary names disagree")
    if change.get("statutoryEnglishName") != JEONNAM_GWANGJU_STATUTORY_NAME:
        raise CatalogError("Jeonnam-Gwangju statutory English name is missing or incorrect")
    if change.get("effectiveDate") != JEONNAM_GWANGJU_EFFECTIVE_DATE:
        raise CatalogError("Jeonnam-Gwangju effective date is missing or incorrect")
    if not str(change.get("legalSourceURL") or "").startswith("https://"):
        raise CatalogError("Jeonnam-Gwangju requires an official HTTPS legal source")
    if not str(change.get("supportedCityResolution") or "").strip():
        raise CatalogError("Jeonnam-Gwangju requires its supported-city resolution method")

    predecessor_codes = list(change.get("mergedFromSubdivisionCodes") or [])
    if predecessor_codes != list(JEONNAM_GWANGJU_PREDECESSOR_CODES):
        raise CatalogError(
            "Jeonnam-Gwangju predecessor subdivision codes must be KR-29 and KR-46"
        )
    predecessor_ids = list(map(str, change.get("mergedFromBoundaryIDs") or []))
    if len(predecessor_ids) != 2 or predecessor_ids != sorted(set(predecessor_ids)):
        raise CatalogError(
            "Jeonnam-Gwangju requires two sorted unique predecessor boundary IDs"
        )
    legacy_rows = [
        str(province["id"])
        for province in provinces
        if str(province.get("subdivisionCode") or "") in predecessor_codes
        or str(province["id"]) in predecessor_ids
    ]
    if legacy_rows:
        raise CatalogError(
            "Jeonnam-Gwangju catalog still contains predecessor province rows: "
            f"{sorted(legacy_rows)}"
        )

    supported_city_ids = list(map(str, change.get("supportedCityIDs") or []))
    if not supported_city_ids or supported_city_ids != sorted(set(supported_city_ids)):
        raise CatalogError(
            "Jeonnam-Gwangju supportedCityIDs must be nonempty, sorted, and unique"
        )
    korean_cities = {
        str(city["id"]): city
        for city in city_catalog.get("boundaries") or []
        if city.get("countryCode") == "KR"
    }
    missing_city_ids = sorted(set(supported_city_ids) - set(korean_cities))
    if missing_city_ids:
        raise CatalogError(
            "Jeonnam-Gwangju metadata references unsupported Korean cities: "
            f"{missing_city_ids}"
        )
    geometrically_contained = {
        city_id
        for city_id, city in korean_cities.items()
        if boundary_contains(
            merged,
            (float(city["center"][0]), float(city["center"][1])),
        )
    }
    if geometrically_contained != set(supported_city_ids):
        raise CatalogError(
            "Jeonnam-Gwangju geometry and supportedCityIDs disagree: "
            f"geometry={sorted(geometrically_contained)}, "
            f"metadata={supported_city_ids}"
        )
    incorrect_parents = sorted(
        city_id
        for city_id in supported_city_ids
        if city_parents.get(city_id) != JEONNAM_GWANGJU_BOUNDARY_ID
    )
    if incorrect_parents:
        raise CatalogError(
            "Jeonnam-Gwangju cities did not resolve to the merged province: "
            f"{incorrect_parents}"
        )


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
    china_by_name = province_ids_by_coverage_name(provinces, "CN")
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
    validate_korean_province_merge(city_catalog, province_catalog, result)
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
            status = choose_text(str(row["match_method"]) for row in group)
            output.execute(
                "INSERT INTO stations VALUES (?, 'JP', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
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
                ),
            )
            insert_station_names(output, station_id, [("ja", name, 1), ("ja", native_name, 0)])
            output.execute("INSERT INTO station_sources VALUES (?, 'stations.jp', 'entity')", (station_id,))
            for row in group:
                hex_code = str(row["hex_code"]).upper()
                output.execute(
                    "INSERT INTO station_identifiers VALUES "
                    "('jp.felica.hex', ?, 'any', ?, ?, NULL, NULL)",
                    (hex_code, station_id, str(row["station_name"])),
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
                line_code = str(line_code)
                from_code = str(from_code)
                to_code = str(to_code)
                output.execute(
                    "INSERT INTO station_graph_edges VALUES ('JP', ?, ?, ?, ?, 'stations.jp')",
                    (line_code, from_code, to_code, float(distance)),
                )
                from_id = station_code_to_id.get(from_code)
                to_id = station_code_to_id.get(to_code)
                if not from_id or not to_id or from_id == to_id:
                    continue
                line_id = f"jp:line:{line_code}"
                output.execute(
                    "INSERT OR IGNORE INTO lines VALUES (?, 'JP', NULL, ?, NULL, NULL, 'rail')",
                    (line_id, line_code),
                )
                output.execute(
                    "INSERT OR REPLACE INTO station_edges VALUES (?, ?, ?, ?)",
                    (line_id, from_id, to_id, float(distance)),
                )


def validate_chinese_station_identifier(row: sqlite3.Row) -> str:
    station_key = str(row["station_key"])
    if station_key != station_key.upper():
        raise CatalogError(f"Chinese station_key is not canonical uppercase: {station_key}")
    source_code = str(row["source_code"] or "")
    if source_code:
        expected = f"{row['city_id']}{source_code}".replace(":", "").upper()
        if station_key != expected:
            raise CatalogError(
                "Chinese source_code does not reproduce its canonical station_key: "
                f"station_key={station_key}, city_id={row['city_id']}, "
                f"source_code={source_code}, expected={expected}"
            )
    return station_key


def build_chinese_stations(
    output: sqlite3.Connection,
    source_path: Path,
    city_lookup: dict[str, str],
    city_parents: dict[str, str],
) -> None:
    with open_source_database(source_path) as source:
        if table_exists(source, "cityunion_terminal_prefixes"):
            output.executemany(
                "INSERT INTO cityunion_terminal_prefixes VALUES (?, ?, ?, ?, ?, ?, ?)",
                source.execute("SELECT * FROM cityunion_terminal_prefixes ORDER BY terminal_prefix").fetchall(),
            )
        if table_exists(source, "tunion_terminal_stations"):
            output.executemany(
                "INSERT INTO tunion_terminal_stations VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                source.execute(
                    "SELECT record_kind, city_id, terminal_code, station_name, line_name, "
                    "station_type, station_key, source_json FROM tunion_terminal_stations "
                    "ORDER BY record_kind, city_id, terminal_code"
                ),
            )
        rows = source.execute("SELECT * FROM tunion_stations ORDER BY station_key").fetchall()
        grouped: dict[str, list[sqlite3.Row]] = defaultdict(list)
        for row in rows:
            station_key = validate_chinese_station_identifier(row)
            osm_id = str(row["osm_id"] or "")
            canonical_id = (
                f"cn:osm:{row['osm_type']}:{osm_id}"
                if osm_id
                else f"cn:tunion:{station_key}"
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
                "INSERT INTO stations VALUES (?, 'CN', ?, ?, ?, ?, ?, ?, ?, ?, 0, ?)",
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
                station_key = validate_chinese_station_identifier(row)
                key_to_station[station_key] = station_id
                output.execute(
                    "INSERT INTO station_identifiers VALUES "
                    "('cn.tunion.station_key', ?, 'any', ?, ?, NULL, NULL)",
                    (station_key, station_id, str(row["station_name"])),
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

        if table_exists(source, "cityunion_terminal_prefixes"):
            for prefix, station_key, name in source.execute(
                "SELECT terminal_prefix, station_key, station_name "
                "FROM cityunion_terminal_prefixes WHERE station_key IS NOT NULL ORDER BY terminal_prefix"
            ):
                station_id = key_to_station.get(station_key)
                if station_id:
                    output.execute(
                        "INSERT INTO station_identifiers VALUES "
                        "('cn.cityunion.terminal_prefix', ?, 'any', ?, ?, NULL, NULL)",
                        (prefix, station_id, name),
                    )

        if table_exists(source, "station_edges"):
            for line_code, from_code, to_code, distance in source.execute(
                "SELECT line_code, from_station_code, to_station_code, distance_km "
                "FROM station_edges ORDER BY line_code, from_station_code, to_station_code"
            ):
                line_code = str(line_code)
                from_code = str(from_code)
                to_code = str(to_code)
                output.execute(
                    "INSERT INTO station_graph_edges VALUES ('CN', ?, ?, ?, ?, 'stations.cn')",
                    (line_code, from_code, to_code, float(distance)),
                )
                from_id = key_to_station.get(from_code)
                to_id = key_to_station.get(to_code)
                if not from_id or not to_id or from_id == to_id:
                    continue
                line_id = f"cn:line:{line_code}"
                output.execute(
                    "INSERT OR IGNORE INTO lines VALUES (?, 'CN', NULL, ?, NULL, NULL, NULL)",
                    (line_id, line_code),
                )
                output.execute(
                    "INSERT OR REPLACE INTO station_edges VALUES (?, ?, ?, ?)",
                    (line_id, from_id, to_id, float(distance)),
                )


def korean_rows(path: Path) -> list[dict[str, str]]:
    with path.open(encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        required = {
            "location_code", "station_id", "transport_mode_code", "station_name_ko",
            "canonical_name_ko", "station_name_hanja", "province_code", "district_code",
            "station_name_en", "station_name_ja", "station_name_zh_hans",
            "station_name_zh_hant", "latitude", "longitude", "operator_name", "line_name",
        }
        if reader.fieldnames is None or not required.issubset(reader.fieldnames):
            raise CatalogError(f"{path} has an unsupported Korean station header")
        return list(reader)


KOREAN_SOURCE_PROPERTY_COLUMNS = (
    "latitude",
    "longitude",
    "station_name_ko",
    "canonical_name_ko",
    "station_name_hanja",
    "station_name_en",
    "station_name_ja",
    "station_name_zh_hans",
    "station_name_zh_hant",
    "operator_name",
    "line_name",
    "province_code",
    "district_code",
)


def normalized_korean_map_component(value: str) -> str:
    """Match KoreanTransitCatalog's NFC and whitespace map-key normalization."""
    return " ".join(unicodedata.normalize("NFC", value).split())


def double_bit_pattern(value: str) -> str:
    """Return the unsigned IEEE-754 bit pattern used by Swift Double.bitPattern."""
    return str(struct.unpack(">Q", struct.pack(">d", float(value)))[0])


def korean_map_group_id(row: dict[str, str]) -> str:
    station_id = row["station_id"].upper()
    latitude = row["latitude"]
    longitude = row["longitude"]
    if bool(latitude) != bool(longitude):
        raise CatalogError(
            f"Korean station {station_id} has only one coordinate component"
        )
    if not latitude:
        return station_id
    components = (
        row["province_code"],
        row["district_code"],
        row["canonical_name_ko"],
        row["operator_name"],
        row["line_name"],
        double_bit_pattern(latitude),
        double_bit_pattern(longitude),
    )
    return "|".join(normalized_korean_map_component(value) for value in components)


def korean_source_properties(row: dict[str, str]) -> str:
    return canonical_json({column: row[column] for column in KOREAN_SOURCE_PROPERTY_COLUMNS})


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
        english_name = choose_text(row["station_name_en"] for row in group)
        native_name = choose_text(row["canonical_name_ko"] for row in group)
        name = english_name or native_name
        output.execute(
            "INSERT INTO stations VALUES (?, 'KR', 'kr.korean_stations', ?, ?, ?, ?, ?, ?, ?, 0, 'reviewed')",
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
        names = [("ko", native_name, 1)]
        if english_name:
            names.append(("en", english_name, 0))
        for language, column in (("ja", "station_name_ja"), ("zh-Hans", "station_name_zh_hans"), ("zh-Hant", "station_name_zh_hant")):
            value = choose_text(row[column] for row in group)
            if value:
                names.append((language, value, 0))
        insert_station_names(output, station_id, names)
        output.execute("INSERT INTO station_sources VALUES (?, 'stations.kr', 'entity')", (station_id,))
        for row in sorted(group, key=lambda item: item["location_code"]):
            location_code = row["location_code"].upper()
            map_group_id = korean_map_group_id(row)
            source_properties_json = korean_source_properties(row)
            for event_kind in KOREAN_EVENT_CONSTRAINTS.get(location_code, ("any",)):
                output.execute(
                    "INSERT INTO station_identifiers VALUES "
                    "('kr.ksx.location', ?, ?, ?, ?, ?, ?)",
                    (
                        location_code,
                        event_kind,
                        station_id,
                        row["canonical_name_ko"],
                        map_group_id,
                        source_properties_json,
                    ),
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


def refresh_mongolian_station_mappings(
    resources: Path,
    city_catalog: dict[str, Any],
    province_catalog: dict[str, Any],
    city_parents: dict[str, str],
) -> None:
    """Reconcile a fresh bus snapshot with the reviewed boundary catalogs.

    Retain reviewed assignments for existing IDs, discard removed IDs, and
    spatially resolve new stops. Never guess a city outside the known geometry.
    Only the generated database is changed; source boundary catalogs stay intact.
    """
    cities = {
        str(city["id"]): city for city in city_catalog["boundaries"]
        if city["countryCode"] == "MN"
    }
    previous = city_catalog.get("mongoliaStationToBoundary") or {}
    city_lookup: dict[str, str] = {}
    province_lookup: dict[str, str] = {}
    with open_source_database(resources / "ulaanbaatar_transit.sqlite") as source:
        for row in source.execute("SELECT station_id, longitude, latitude FROM stations ORDER BY station_id"):
            station_id = str(row["station_id"])
            city_id = previous.get(station_id)
            if city_id not in cities:
                point = (float(row["longitude"]), float(row["latitude"]))
                containing = [city_id for city_id, city in cities.items() if boundary_contains(city, point)]
                if len(containing) != 1:
                    raise CatalogError(
                        f"Mongolia station {station_id} has no unambiguous supported city; "
                        "refresh the boundary catalogs before publishing this snapshot"
                    )
                city_id = containing[0]
            city_lookup[station_id] = city_id
            province_lookup[station_id] = city_parents[city_id]
    city_catalog["mongoliaStationToBoundary"] = city_lookup
    province_catalog["mongoliaStationToBoundary"] = province_lookup


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
                "INSERT INTO stations VALUES (?, 'MN', 'mn.ubsmartbus', ?, ?, ?, ?, ?, ?, ?, 0, 'official')",
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
                "INSERT INTO station_identifiers VALUES "
                "('mn.ubsmartbus.station_id', ?, 'any', ?, NULL, NULL, NULL)",
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


def import_edge_paths(output: sqlite3.Connection, resources: Path) -> None:
    for country, filename in (("JP", "jp_stations.sqlite"), ("CN", "tunion_stations.sqlite")):
        with open_source_database(resources / filename) as source:
            if table_exists(source, "station_edge_paths"):
                output.executemany(
                    "INSERT INTO station_edge_paths VALUES (?, ?, ?, ?, ?)",
                    [(country, *tuple(row)) for row in source.execute(
                        "SELECT line_code, from_station_code, to_station_code, geohash_path "
                        "FROM station_edge_paths ORDER BY line_code, from_station_code, to_station_code"
                    )],
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


def build_stations(
    connection: sqlite3.Connection,
    resources: Path,
    city_catalog: dict[str, Any],
    province_catalog: dict[str, Any],
    city_parents: dict[str, str],
) -> Counter[str]:
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

    build_japanese_stations(
        connection, resources / "jp_stations.sqlite", japan_lookup, city_parents
    )
    build_chinese_stations(
        connection, resources / "tunion_stations.sqlite", china_lookup, city_parents
    )
    build_korean_stations(
        connection, resources / "korean_stations.tsv", korea_lookup, city_parents
    )
    build_mongolian_stations(
        connection,
        resources / "ulaanbaatar_transit.sqlite",
        mongolia_city_lookup,
        mongolia_province_lookup,
    )
    station_counts = Counter(
        {
            country: count
            for country, count in connection.execute(
                "SELECT country_code, COUNT(*) FROM stations GROUP BY country_code"
            )
        }
    )
    return station_counts


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


def insert_reference_lines(
    connection: sqlite3.Connection,
    catalog: dict[str, Any],
    boundary_level: str,
    source_id: str,
) -> None:
    rows = []
    seen: set[tuple[str, str]] = set()
    for batch in catalog.get("referenceLines") or []:
        key = (str(batch["countryCode"]), str(batch["bucket"]))
        if key in seen:
            raise CatalogError(f"Duplicate {boundary_level} reference-line bucket {key}")
        seen.add(key)
        rows.append(
            (boundary_level, key[0], key[1], canonical_json(batch["lines"]), source_id)
        )
    connection.executemany(
        "INSERT INTO reference_line_batches VALUES (?, ?, ?, ?, ?)", sorted(rows)
    )


def add_city_identifiers(
    connection: sqlite3.Connection,
    namespace: str,
    mapping: dict[str, str],
    city_ids: set[str],
    display_names: dict[str, str] | None = None,
) -> None:
    display_names = display_names or {}
    for code, city_id in sorted((str(key), str(value)) for key, value in mapping.items()):
        if city_id not in city_ids:
            raise CatalogError(f"{namespace} code {code} targets missing city {city_id}")
        connection.execute(
            "INSERT INTO city_identifiers VALUES (?, ?, ?, ?)",
            (namespace, code, city_id, display_names.get(code)),
        )


def build_cities(
    connection: sqlite3.Connection,
    catalog: dict[str, Any],
    coverage: dict[str, Any],
    city_parents: dict[str, str],
) -> None:
    boundaries = catalog.get("boundaries") or []
    city_ids = {str(boundary["id"]) for boundary in boundaries}
    if city_ids != set(city_parents):
        raise CatalogError("City parent mapping does not exactly cover emitted city boundaries")
    china_mapping = {
        str(code): str(city_id)
        for code, city_id in catalog["chinaCityToBoundary"].items()
    }
    t_union_coverage = coverage.get("tUnion") or {}
    reviewed_t_union_names = {
        str(code): str(name)
        for code, name in (t_union_coverage.get("cityCodeDisplayNames") or {}).items()
    }
    aliased_t_union_codes = set(
        map(str, (t_union_coverage.get("cityToBoundaryAlias") or {}).keys())
    )
    province_only_t_union_codes = set(
        map(str, t_union_coverage.get("provinceOnlyCityCodes") or [])
    )
    direct_t_union_names = {
        code: name
        for code, name in reviewed_t_union_names.items()
        if code not in aliased_t_union_codes and code not in province_only_t_union_codes
    }
    excluded_china_codes = {
        code for code, city_id in china_mapping.items() if city_id not in city_ids
    }
    expected_excluded_china_codes = set(
        map(str, (coverage.get("tUnion") or {}).get("excludedCityBoundaryCodes") or [])
    )
    if excluded_china_codes != expected_excluded_china_codes:
        raise CatalogError(
            "China city mappings outside the supported layer do not exactly match "
            "the configured exclusions: "
            f"actual={sorted(excluded_china_codes)}, "
            f"expected={sorted(expected_excluded_china_codes)}"
        )
    supported_china_mapping = {
        code: city_id
        for code, city_id in china_mapping.items()
        if code not in excluded_china_codes
    }
    for boundary in sorted(boundaries, key=lambda item: str(item["id"])):
        city_id = str(boundary["id"])
        connection.execute(
            "INSERT INTO cities VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            boundary_row(boundary, city_parents[city_id], 0),
        )
        connection.execute(
            "INSERT INTO city_sources VALUES (?, 'boundaries.city', 'geometry')",
            (city_id,),
        )

    add_city_identifiers(
        connection,
        "jp.felica.station_hex",
        catalog["japanStationToBoundary"],
        city_ids,
    )
    add_city_identifiers(
        connection,
        "cn.tunion.city_code",
        supported_china_mapping,
        city_ids,
        display_names=direct_t_union_names,
    )
    add_city_identifiers(
        connection, "kr.kotris.mode", catalog["koreaModeToBoundary"], city_ids
    )
    add_city_identifiers(
        connection, "kr.ksx.location", catalog["koreaLocationToBoundary"], city_ids
    )
    add_city_identifiers(
        connection,
        "mn.ubsmartbus.station_id",
        catalog["mongoliaStationToBoundary"],
        city_ids,
    )

    china_exact = {
        str(key): str(value) for key, value in catalog["chinaCityToBoundary"].items()
    }
    for coverage_name, namespace in (
        ("tUnion", "cn.tunion.city_alias"),
        ("cityUnion", "cn.city_union.city_code"),
    ):
        coverage_namespace = coverage.get(coverage_name) or {}
        aliases = coverage_namespace.get("cityToBoundaryAlias") or {}
        alias_mapping = {
            str(code): china_exact[str(target)]
            for code, target in aliases.items()
            if str(target) in china_exact
        }
        display_names = {
            str(code): str(name)
            for code, name in (coverage_namespace.get("cityCodeDisplayNames") or {}).items()
        }
        add_city_identifiers(
            connection,
            namespace,
            alias_mapping,
            city_ids,
            display_names=display_names,
        )

    insert_reference_lines(connection, catalog, "city", "boundaries.city")


def build_provinces(
    connection: sqlite3.Connection,
    catalog: dict[str, Any],
    coverage: dict[str, Any],
    city_parents: dict[str, str],
) -> None:
    boundaries = catalog.get("boundaries") or []
    province_ids = {str(boundary["id"]) for boundary in boundaries}
    city_counts = Counter(city_parents.values())
    for boundary in sorted(boundaries, key=lambda item: str(item["id"])):
        province_id = str(boundary["id"])
        connection.execute(
            "INSERT INTO provinces VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            boundary_row(boundary, None, city_counts[province_id], 0),
        )
        connection.execute(
            "INSERT INTO province_sources VALUES (?, 'boundaries.province', 'geometry')",
            (province_id,),
        )

    for code, province_id in sorted(
        (str(key), str(value))
        for key, value in (catalog.get("mongoliaStationToBoundary") or {}).items()
    ):
        if province_id not in province_ids:
            raise CatalogError(f"Mongolia station {code} targets missing province {province_id}")
        connection.execute(
            "INSERT INTO province_identifiers VALUES "
            "('mn.ubsmartbus.station_id', ?, ?, NULL)",
            (code, province_id),
        )

    province_by_name = province_ids_by_coverage_name(boundaries, "CN")
    for coverage_name, namespace in (
        ("tUnion", "cn.tunion.province_only_city_code"),
        ("cityUnion", "cn.city_union.province_only_city_code"),
    ):
        coverage_namespace = coverage.get(coverage_name) or {}
        city_to_province = coverage_namespace.get("cityToProvince") or {}
        display_names = {
            str(code): str(name)
            for code, name in (coverage_namespace.get("cityCodeDisplayNames") or {}).items()
        }
        for code in sorted(map(str, coverage_namespace.get("provinceOnlyCityCodes") or [])):
            province_name = str(city_to_province.get(code) or "")
            province_id = province_by_name.get(province_name.casefold())
            if not province_id:
                raise CatalogError(f"China province-only code {code} has no emitted province")
            connection.execute(
                "INSERT INTO province_identifiers VALUES (?, ?, ?, ?)",
                (namespace, code, province_id, display_names.get(code)),
            )

    insert_reference_lines(connection, catalog, "province", "boundaries.province")


def scalar(connection: sqlite3.Connection, query: str) -> Any:
    return connection.execute(query).fetchone()[0]


def validate_database(connection: sqlite3.Connection) -> None:
    integrity = scalar(connection, "PRAGMA integrity_check")
    if integrity != "ok":
        raise CatalogError(f"SQLite integrity check failed: {integrity}")
    foreign_key_violations = connection.execute("PRAGMA foreign_key_check").fetchall()
    if foreign_key_violations:
        raise CatalogError(f"SQLite foreign-key violations: {foreign_key_violations[:5]}")

    queries = {
        "station city references": """
            SELECT COUNT(*) FROM stations s
            LEFT JOIN cities c ON c.id = s.city_id
            WHERE s.city_id IS NOT NULL AND c.id IS NULL
        """,
        "station province references": """
            SELECT COUNT(*) FROM stations s
            LEFT JOIN provinces p ON p.id = s.province_id
            WHERE s.province_id IS NOT NULL AND p.id IS NULL
        """,
        "city province references": """
            SELECT COUNT(*) FROM cities c
            LEFT JOIN provinces p ON p.id = c.province_id
            WHERE p.id IS NULL
        """,
        "station/city country agreement": """
            SELECT COUNT(*) FROM stations s
            JOIN cities c ON c.id = s.city_id
            WHERE s.country_code <> c.country_code
        """,
        "station/province country agreement": """
            SELECT COUNT(*) FROM stations s
            JOIN provinces p ON p.id = s.province_id
            WHERE s.country_code <> p.country_code
        """,
        "city/province country agreement": """
            SELECT COUNT(*) FROM cities c
            JOIN provinces p ON p.id = c.province_id
            WHERE c.country_code <> p.country_code
        """,
        "line/city country agreement": """
            SELECT COUNT(*) FROM lines l
            JOIN cities c ON c.id = l.city_id
            WHERE l.country_code <> c.country_code
        """,
        "station city-parent agreement": """
            SELECT COUNT(*) FROM stations s
            JOIN cities c ON c.id = s.city_id
            WHERE s.province_id IS NULL OR s.province_id <> c.province_id
        """,
        "stationless Japan cities": """
            SELECT COUNT(*) FROM cities c
            WHERE c.country_code = 'JP' AND NOT EXISTS (
                SELECT 1 FROM stations s
                WHERE s.city_id = c.id AND s.is_pseudo = 0
            )
        """,
        "Mongolia stations without cities": """
            SELECT COUNT(*) FROM stations
            WHERE country_code = 'MN' AND city_id IS NULL
        """,
        "Mongolia stations without provinces": """
            SELECT COUNT(*) FROM stations
            WHERE country_code = 'MN' AND province_id IS NULL
        """,
        "runtime resolver lookup names missing": """
            SELECT COUNT(*) FROM station_identifiers
            WHERE namespace IN ('jp.felica.hex', 'cn.tunion.station_key')
                AND (lookup_name IS NULL OR lookup_name = '')
        """,
        "unexpected Chinese station identifier namespace": """
            SELECT COUNT(*)
            FROM station_identifiers i
            JOIN stations s ON s.id = i.station_id
            WHERE s.country_code = 'CN'
                AND i.namespace NOT IN ('cn.tunion.station_key', 'cn.cityunion.terminal_prefix')
        """,
        "invalid Shanghai City Union mappings": """
            SELECT COUNT(*) FROM cityunion_terminal_prefixes t
            WHERE t.city_id <> '2000' OR t.terminal_prefix NOT LIKE '2000%'
                OR length(t.terminal_prefix) NOT IN (8, 10, 12)
                OR t.terminal_prefix GLOB '*[^0-9A-F]*'
                OR t.station_name = ''
                OR (t.station_key IS NOT NULL AND NOT EXISTS (
                    SELECT 1 FROM station_identifiers i
                    WHERE i.namespace = 'cn.tunion.station_key'
                        AND i.code = t.station_key AND i.code LIKE '2900%'
                ))
        """,
        "invalid China terminal station mappings": """
            SELECT COUNT(*) FROM tunion_terminal_stations t
            WHERE t.station_name = '' OR length(t.city_id) <> 4
                OR length(t.terminal_code) <> CASE t.record_kind WHEN '18' THEN 12 ELSE 16 END
                OR t.terminal_code GLOB '*[^0-9A-F]*'
                OR (t.station_key IS NOT NULL AND NOT EXISTS (
                    SELECT 1 FROM station_identifiers i
                    WHERE i.namespace = 'cn.tunion.station_key' AND i.code = t.station_key
                        AND substr(i.code, 1, 4) = t.city_id AND i.lookup_name = t.station_name
                ))
        """,
        "Korean compatibility properties missing": """
            SELECT COUNT(*) FROM station_identifiers
            WHERE namespace = 'kr.ksx.location'
                AND (
                    map_group_id IS NULL OR map_group_id = ''
                    OR source_properties_json IS NULL OR source_properties_json = ''
                )
        """,
        "unexpected identifier compatibility properties": """
            SELECT COUNT(*) FROM station_identifiers
            WHERE namespace <> 'kr.ksx.location'
                AND (map_group_id IS NOT NULL OR source_properties_json IS NOT NULL)
        """,
        "runtime graph-edge provenance disagreement": """
            SELECT COUNT(*) FROM station_graph_edges
            WHERE (country_code = 'JP' AND source_id <> 'stations.jp')
                OR (country_code = 'CN' AND source_id <> 'stations.cn')
        """,
        "unexpected city identifier display names": """
            SELECT COUNT(*) FROM city_identifiers
            WHERE display_name IS NOT NULL
                AND namespace NOT IN ('cn.tunion.city_code', 'cn.tunion.city_alias')
        """,
        "unexpected province identifier display names": """
            SELECT COUNT(*) FROM province_identifiers
            WHERE display_name IS NOT NULL
                AND namespace <> 'cn.tunion.province_only_city_code'
        """,
        "Japanese identifier/station city disagreement": """
            SELECT COUNT(*) FROM city_identifiers m
            LEFT JOIN station_identifiers i
                ON i.namespace = 'jp.felica.hex'
                AND i.code = m.code
                AND i.event_kind = 'any'
            LEFT JOIN stations s ON s.id = i.station_id
            WHERE m.namespace = 'jp.felica.station_hex'
                AND (s.id IS NULL OR s.city_id <> m.city_id)
        """,
        "Korean identifier/station city disagreement": """
            SELECT COUNT(*) FROM city_identifiers m
            LEFT JOIN station_identifiers i
                ON i.namespace = 'kr.ksx.location'
                AND i.code = m.code
            LEFT JOIN stations s ON s.id = i.station_id
            WHERE m.namespace = 'kr.ksx.location'
                AND (s.id IS NULL OR s.city_id <> m.city_id)
        """,
        "Mongolia identifier/station city disagreement": """
            SELECT COUNT(*) FROM city_identifiers m
            LEFT JOIN station_identifiers i
                ON i.namespace = 'mn.ubsmartbus.station_id'
                AND i.code = m.code
                AND i.event_kind = 'any'
            LEFT JOIN stations s ON s.id = i.station_id
            WHERE m.namespace = 'mn.ubsmartbus.station_id'
                AND (s.id IS NULL OR s.city_id <> m.city_id)
        """,
        "Mongolia identifier/station province disagreement": """
            SELECT COUNT(*) FROM province_identifiers m
            LEFT JOIN station_identifiers i
                ON i.namespace = 'mn.ubsmartbus.station_id'
                AND i.code = m.code
                AND i.event_kind = 'any'
            LEFT JOIN stations s ON s.id = i.station_id
            WHERE m.namespace = 'mn.ubsmartbus.station_id'
                AND (s.id IS NULL OR s.province_id <> m.province_id)
        """,
        "city station-count disagreement": """
            SELECT COUNT(*) FROM cities c
            WHERE c.station_count <> (
                SELECT COUNT(*) FROM stations s
                WHERE s.city_id = c.id AND s.is_pseudo = 0
            )
        """,
        "city support-basis disagreement": """
            SELECT COUNT(*) FROM cities
            WHERE support_basis <> CASE
                WHEN station_count > 0 THEN 'station'
                ELSE 'network_or_mode'
            END
        """,
        "province station-count disagreement": """
            SELECT COUNT(*) FROM provinces p
            WHERE p.station_count <> (
                SELECT COUNT(*) FROM stations s
                WHERE s.province_id = p.id AND s.is_pseudo = 0
            )
        """,
        "province city-count disagreement": """
            SELECT COUNT(*) FROM provinces p
            WHERE p.city_count <> (
                SELECT COUNT(*) FROM cities c WHERE c.province_id = p.id
            )
        """,
    }
    failures = {
        label: count
        for label, query in queries.items()
        if (count := int(scalar(connection, query)))
    }
    if failures:
        raise CatalogError(f"Unified database validation failed: {failures}")

    expected_countries = tuple(sorted(SUPPORTED_COUNTRIES))
    for table in ("stations", "cities", "provinces"):
        countries = tuple(
            row[0]
            for row in connection.execute(
                f"SELECT DISTINCT country_code FROM {table} ORDER BY country_code"
            )
        )
        if countries != expected_countries:
            raise CatalogError(
                f"{table} country set is {countries}, expected {SUPPORTED_COUNTRIES}"
            )


def require_runtime_parity(
    label: str,
    expected: Counter[tuple[Any, ...]],
    actual: Counter[tuple[Any, ...]],
) -> None:
    if expected == actual:
        return
    missing = list((expected - actual).elements())[:3]
    unexpected = list((actual - expected).elements())[:3]
    raise CatalogError(
        f"{label} runtime parity failed: expected={sum(expected.values())}, "
        f"actual={sum(actual.values())}, missing={missing}, unexpected={unexpected}"
    )


def validate_china_display_name_parity(
    connection: sqlite3.Connection,
    coverage: dict[str, Any],
) -> int:
    expected = Counter(
        (str(code), str(name))
        for code, name in (
            ((coverage.get("tUnion") or {}).get("cityCodeDisplayNames") or {})
        ).items()
    )
    actual = Counter(
        tuple(row)
        for row in connection.execute(
            """
            SELECT code, display_name
            FROM city_identifiers
            WHERE namespace IN ('cn.tunion.city_code', 'cn.tunion.city_alias')
                AND display_name IS NOT NULL
            UNION ALL
            SELECT code, display_name
            FROM province_identifiers
            WHERE namespace = 'cn.tunion.province_only_city_code'
                AND display_name IS NOT NULL
            """
        )
    )
    require_runtime_parity("China city-code labels", expected, actual)
    return sum(actual.values())


def validate_korean_source_parity(
    connection: sqlite3.Connection,
    source_path: Path,
) -> tuple[int, int]:
    rows = korean_rows(source_path)
    expected = Counter(
        (
            row["location_code"].upper(),
            event_kind,
            row["station_id"].upper(),
            row["canonical_name_ko"],
            korean_map_group_id(row),
            korean_source_properties(row),
        )
        for row in rows
        for event_kind in KOREAN_EVENT_CONSTRAINTS.get(
            row["location_code"].upper(), ("any",)
        )
    )
    actual = Counter(
        tuple(row)
        for row in connection.execute(
            """
            SELECT i.code, i.event_kind, s.source_station_id, i.lookup_name,
                   i.map_group_id, i.source_properties_json
            FROM station_identifiers AS i
            JOIN stations AS s ON s.id = i.station_id
            WHERE i.namespace = 'kr.ksx.location'
            """
        )
    )
    require_runtime_parity("Korean station aliases", expected, actual)

    expected_group_count = len({korean_map_group_id(row) for row in rows})
    actual_group_count = int(
        scalar(
            connection,
            "SELECT COUNT(DISTINCT map_group_id) FROM station_identifiers "
            "WHERE namespace = 'kr.ksx.location'",
        )
    )
    if actual_group_count != expected_group_count:
        raise CatalogError(
            "Korean map-group count parity failed: "
            f"expected={expected_group_count}, actual={actual_group_count}"
        )
    return sum(actual.values()), actual_group_count


def validate_runtime_source_parity(
    connection: sqlite3.Connection,
    resources: Path,
) -> None:
    with open_source_database(resources / "jp_stations.sqlite") as source:
        expected_japan = Counter(
            (
                str(row["hex_code"]).upper(),
                "0" if int(row["is_pseudo"]) else str(row["station_code"]),
                str(row["station_name"]),
                float(row["latitude"]),
                float(row["longitude"]),
                int(row["is_pseudo"]),
            )
            for row in source.execute(
                "SELECT hex_code, station_code, station_name, latitude, longitude, is_pseudo "
                "FROM jp_stations"
            )
        )
        expected_japan_edges = Counter(
            (
                "JP",
                str(row["line_code"]),
                str(row["from_station_code"]),
                str(row["to_station_code"]),
                float(row["distance_km"]),
                "stations.jp",
            )
            for row in source.execute(
                "SELECT line_code, from_station_code, to_station_code, distance_km "
                "FROM station_edges"
            )
        )

    actual_japan = Counter(
        tuple(row)
        for row in connection.execute(
            """
            SELECT i.code,
                   CASE WHEN s.is_pseudo = 1 THEN '0' ELSE s.source_station_id END,
                   i.lookup_name, s.latitude, s.longitude, s.is_pseudo
            FROM station_identifiers i
            JOIN stations s ON s.id = i.station_id
            WHERE i.namespace = 'jp.felica.hex' AND i.event_kind = 'any'
            """
        )
    )
    require_runtime_parity("Japanese station lookup", expected_japan, actual_japan)

    with open_source_database(resources / "tunion_stations.sqlite") as source:
        cu_query = "SELECT * FROM cityunion_terminal_prefixes"
        expected_cu = Counter(tuple(row) for row in source.execute(cu_query)) if table_exists(source, "cityunion_terminal_prefixes") else Counter()
        require_runtime_parity("City Union terminal prefixes", expected_cu,
                               Counter(tuple(row) for row in connection.execute(cu_query)))
        terminal_query = (
            "SELECT record_kind, city_id, terminal_code, station_name, line_name, "
            "station_type, station_key, source_json FROM tunion_terminal_stations"
        )
        expected_terminals = Counter(
            tuple(row) for row in source.execute(terminal_query)
        ) if table_exists(source, "tunion_terminal_stations") else Counter()
        actual_terminals = Counter(tuple(row) for row in connection.execute(terminal_query))
        require_runtime_parity("China terminal station mappings", expected_terminals, actual_terminals)
        source_identifier_rows = source.execute(
            "SELECT station_key, city_id, source_code FROM tunion_stations "
            "ORDER BY station_key"
        ).fetchall()
        for row in source_identifier_rows:
            validate_chinese_station_identifier(row)
        expected_china_keys = Counter(
            (str(row["station_key"]), str(row["station_name"]))
            for row in source.execute("SELECT station_key, station_name FROM tunion_stations")
        )
        registry_path = resources / "TUnionLineStations.json"
        if registry_path.is_file():
            require_runtime_parity(
                "China decoder station registry", expected_china_keys,
                Counter(load_json(registry_path).items()),
            )
        expected_china = Counter(
            (
                str(row["station_key"]),
                str(row["station_name"]),
                float(row["latitude"]),
                float(row["longitude"]),
            )
            for row in source.execute(
                "SELECT station_key, station_name, latitude, longitude FROM tunion_stations "
                "WHERE latitude IS NOT NULL AND longitude IS NOT NULL"
            )
        )
        expected_china_edges = Counter(
            (
                "CN",
                str(row["line_code"]),
                str(row["from_station_code"]),
                str(row["to_station_code"]),
                float(row["distance_km"]),
                "stations.cn",
            )
            for row in source.execute(
                "SELECT line_code, from_station_code, to_station_code, distance_km "
                "FROM station_edges"
            )
        )

    actual_china_keys = Counter(
        tuple(row)
        for row in connection.execute(
            "SELECT code, lookup_name FROM station_identifiers "
            "WHERE namespace = 'cn.tunion.station_key' AND event_kind = 'any'"
        )
    )
    require_runtime_parity("China station identifiers", expected_china_keys, actual_china_keys)
    actual_china = Counter(
        tuple(row)
        for row in connection.execute(
            """
            SELECT i.code, i.lookup_name, s.latitude, s.longitude
            FROM station_identifiers i
            JOIN stations s ON s.id = i.station_id
            WHERE i.namespace = 'cn.tunion.station_key'
                AND i.event_kind = 'any'
                AND s.latitude IS NOT NULL
                AND s.longitude IS NOT NULL
            """
        )
    )
    require_runtime_parity("China station lookup", expected_china, actual_china)

    with open_source_database(resources / "ulaanbaatar_transit.sqlite") as source:
        expected_mongolia = Counter(
            (
                str(row["station_id"]),
                str(row["station_name_mn"]),
                str(row["station_name_en"]),
                float(row["latitude"]),
                float(row["longitude"]),
            )
            for row in source.execute(
                "SELECT station_id, station_name_mn, station_name_en, latitude, longitude "
                "FROM stations"
            )
        )
    actual_mongolia = Counter(
        tuple(row)
        for row in connection.execute(
            "SELECT source_station_id, native_name, name, latitude, longitude "
            "FROM stations WHERE country_code = 'MN'"
        )
    )
    require_runtime_parity("Mongolia station lookup", expected_mongolia, actual_mongolia)

    actual_graph_edges = Counter(
        tuple(row)
        for row in connection.execute(
            "SELECT country_code, line_code, from_station_code, to_station_code, "
            "distance_km, source_id FROM station_graph_edges"
        )
    )
    require_runtime_parity(
        "Station graph edges",
        expected_japan_edges + expected_china_edges,
        actual_graph_edges,
    )


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


def update_catalog_counts(connection: sqlite3.Connection) -> None:
    connection.execute(
        """
        UPDATE cities
        SET station_count = (
                SELECT COUNT(*) FROM stations
                WHERE stations.city_id = cities.id AND stations.is_pseudo = 0
            ),
            support_basis = CASE
                WHEN EXISTS (
                    SELECT 1 FROM stations
                    WHERE stations.city_id = cities.id AND stations.is_pseudo = 0
                ) THEN 'station'
                ELSE 'network_or_mode'
            END
        """
    )
    connection.execute(
        """
        UPDATE provinces
        SET city_count = (
                SELECT COUNT(*) FROM cities WHERE cities.province_id = provinces.id
            ),
            station_count = (
                SELECT COUNT(*) FROM stations
                WHERE stations.province_id = provinces.id AND stations.is_pseudo = 0
            )
        """
    )


def generate(
    resources: Path,
    output_directory: Path,
    generated_at: str | None = None,
) -> Path:
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
    refresh_mongolian_station_mappings(resources, city_catalog, province_catalog, city_parents)

    output_directory.mkdir(parents=True, exist_ok=True)
    final_path = output_directory / OUTPUT_FILENAME
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{final_path.stem}-", suffix=".sqlite", dir=final_path.parent
    )
    os.close(descriptor)
    temporary_path = Path(temporary_name)
    temporary_path.unlink()
    try:
        with closing(sqlite3.connect(temporary_path)) as connection, connection:
            configure_database(connection, 0x43425452)  # CBTR
            connection.executescript(TRANSIT_SCHEMA)
            insert_sources(connection, sources)
            build_provinces(
                connection,
                province_catalog,
                china_coverage,
                city_parents,
            )
            build_cities(connection, city_catalog, china_coverage, city_parents)
            station_counts = build_stations(
                connection,
                resources,
                city_catalog,
                province_catalog,
                city_parents,
            )
            update_catalog_counts(connection)
            import_edge_paths(connection, resources)
            validate_runtime_source_parity(connection, resources)
            korean_alias_count, korean_map_group_count = validate_korean_source_parity(
                connection, resources / "korean_stations.tsv"
            )
            china_city_code_display_name_count = validate_china_display_name_parity(
                connection, china_coverage
            )
            city_boundary_counts = Counter(
                boundary["countryCode"] for boundary in city_catalog["boundaries"]
            )
            province_boundary_counts = Counter(
                boundary["countryCode"] for boundary in province_catalog["boundaries"]
            )
            graph_edge_counts = Counter(
                {
                    country: count
                    for country, count in connection.execute(
                        "SELECT country_code, COUNT(*) FROM station_graph_edges "
                        "GROUP BY country_code"
                    )
                }
            )
            write_metadata(
                connection,
                {
                    "format": "cardbal-unified-transit-v1",
                    "generated_at": generated_at,
                    "schema_version": str(SCHEMA_VERSION),
                    "component_formats": {
                        "stations": "cardbal-unified-stations-v1",
                        "cities": "cardbal-unified-cities-v1",
                        "provinces": "cardbal-unified-provinces-v1",
                    },
                    "station_counts": dict(sorted(station_counts.items())),
                    "graph_edge_counts": dict(sorted(graph_edge_counts.items())),
                    "korean_alias_count": korean_alias_count,
                    "korean_map_group_count": korean_map_group_count,
                    "china_city_code_display_name_count": china_city_code_display_name_count,
                    "city_boundary_counts": dict(sorted(city_boundary_counts.items())),
                    "province_boundary_counts": dict(
                        sorted(province_boundary_counts.items())
                    ),
                    "city_attribution": city_catalog.get("attribution") or [],
                    "city_generation": city_catalog.get("generation") or {},
                    "city_sources": city_catalog.get("sources") or {},
                    "province_attribution": province_catalog.get("attribution") or [],
                    "province_generation": province_catalog.get("generation") or {},
                    "province_sources": province_catalog.get("sources") or {},
                },
            )
            validate_database(connection)
            finalize_database(connection)

        with closing(
            sqlite3.connect(
                f"file:{temporary_path.resolve().as_posix()}?mode=ro&immutable=1",
                uri=True,
            )
        ) as connection:
            validate_database(connection)
        os.replace(temporary_path, final_path)
        return final_path
    finally:
        temporary_path.unlink(missing_ok=True)


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
    output = generate(args.resources, args.output_directory, args.generated_at)
    print(
        canonical_json(
            {
                "path": str(output),
                "bytes": output.stat().st_size,
                "sha256": sha256_file(output),
            }
        )
    )


if __name__ == "__main__":
    main()
