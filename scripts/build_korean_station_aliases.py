#!/usr/bin/env python3

"""Build CardBal's exact Korean station alias catalog from cited evidence.

The MOLIT join is deliberately narrow: only records whose KOTRIS mode is
officially classed as bus, whose four-byte token is decimal BCD ending in zero,
and whose seven-digit candidate exactly occurs in the dated settlement-stop
snapshot are accepted.  Aliases remain keyed by all six bytes (05-10).
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import re
import shutil
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[1]
VISUALIZER_ROOT = REPO_ROOT / "cloudflare" / "korean-trip-visualizer"
DEFAULT_SNAPSHOT = (
    VISUALIZER_ROOT
    / "scripts"
    / "sources"
    / "molit_seoul_settlement_stops_20250801.json"
)
DEFAULT_NATIONAL = (
    VISUALIZER_ROOT
    / "scripts"
    / "sources"
    / "molit_settlement_stations_20250613.csv"
)
DEFAULT_CORPUS = VISUALIZER_ROOT / "public" / "data" / "korean-trips.json"
DEFAULT_MODES = VISUALIZER_ROOT / "scripts" / "sources" / "kotris_transport_modes.csv"
DEFAULT_DAEGU_LINE2 = (
    VISUALIZER_ROOT
    / "scripts"
    / "sources"
    / "daegu_metro_line2_sections_20251231.csv"
)
DEFAULT_BUSAN_BIMS_STOPS = (
    VISUALIZER_ROOT
    / "scripts"
    / "sources"
    / "busan_bims_stops_20260727.json"
)
DEFAULT_BUSAN_BIMS_RAW = (
    VISUALIZER_ROOT
    / "scripts"
    / "sources"
    / "busan_bims_stationinfo_20260727.xls"
)
DEFAULT_CAPITAL_RAIL_CROSSWALK = (
    VISUALIZER_ROOT
    / "scripts"
    / "sources"
    / "cardbal_capital_rail_crosswalk_stable_v1.json"
)
DEFAULT_ADDITIONAL_CAPITAL_RAIL_CROSSWALK = (
    VISUALIZER_ROOT
    / "scripts"
    / "sources"
    / "cardbal_additional_capital_rail_crosswalk_high_v1.json"
)
DEFAULT_SEOUL_SUBWAY_SOURCE = (
    VISUALIZER_ROOT
    / "scripts"
    / "sources"
    / "seoul_bigdata_subway_stations_cp949.csv"
)
DEFAULT_GYEONGGI_DELTA = (
    VISUALIZER_ROOT
    / "scripts"
    / "sources"
    / "molit_gyeonggi_20250801_delta_mappings.json"
)
DEFAULT_JEJU_MAPPINGS = (
    VISUALIZER_ROOT
    / "scripts"
    / "sources"
    / "molit_jeju_20250801_mappings.json"
)
DEFAULT_JEJU_CITY_SOURCE = (
    VISUALIZER_ROOT
    / "scripts"
    / "sources"
    / "molit_jeju_50110_stops_20250801.json"
)
DEFAULT_SEOGWIPO_SOURCE = (
    VISUALIZER_ROOT
    / "scripts"
    / "sources"
    / "molit_jeju_50130_stops_20250801.json"
)
DEFAULT_SEOUL_CODE190_MAPPINGS = (
    VISUALIZER_ROOT / "scripts" / "sources" / "molit_seoul_code190_20251107_mappings.json"
)
DEFAULT_SEOUL_20251107_SNAPSHOT = (
    VISUALIZER_ROOT / "scripts" / "sources" / "molit_seoul_settlement_stops_20251107.json"
)
DEFAULT_SEOUL_11200_SOURCE = (
    VISUALIZER_ROOT / "scripts" / "sources" / "molit_seoul_11200_stops_20251107.json"
)
DEFAULT_SEOUL_11710_SOURCE = (
    VISUALIZER_ROOT / "scripts" / "sources" / "molit_seoul_11710_stops_20251107.json"
)
DEFAULT_STATION_METADATA = (
    VISUALIZER_ROOT
    / "scripts"
    / "sources"
    / "korean_station_metadata_20260727.json"
)
DEFAULT_SAMPLES = REPO_ROOT / "transit_record_comparison.tsv"
DEFAULT_OUTPUT = REPO_ROOT / "CardBal" / "Resources" / "KoreanStationAliases.json"
BUS_TOKEN = re.compile(r"^[0-9]{7}0$")
BUSAN_MYBI_RAIL_TOKEN = re.compile(r"^(?:00|01)13([0-9A-F]{2})00$")
BUSAN_BUS_MODE_CODES = {601, 603, 605, 606, 609, 618}
JEJU_BUS_MODE_CODES = {990, 994, 995}

# These three ARS IDs were checked individually through the same official MOLIT
# BusStop sample API.  The complete selector snapshot does not contain ARS IDs.
VERIFIED_ARS_IDS = {
    "8502230": "01016",
    "0073773": "03151",
    "9003596": "19107",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--snapshot", type=Path, default=DEFAULT_SNAPSHOT)
    parser.add_argument("--national", type=Path, default=DEFAULT_NATIONAL)
    parser.add_argument("--vendor-snapshot", type=Path)
    parser.add_argument("--corpus", type=Path, default=DEFAULT_CORPUS)
    parser.add_argument("--modes", type=Path, default=DEFAULT_MODES)
    parser.add_argument("--daegu-line2", type=Path, default=DEFAULT_DAEGU_LINE2)
    parser.add_argument("--busan-bims-stops", type=Path, default=DEFAULT_BUSAN_BIMS_STOPS)
    parser.add_argument("--busan-bims-raw", type=Path, default=DEFAULT_BUSAN_BIMS_RAW)
    parser.add_argument("--capital-rail-crosswalk", type=Path, default=DEFAULT_CAPITAL_RAIL_CROSSWALK)
    parser.add_argument(
        "--additional-capital-rail-crosswalk",
        type=Path,
        default=DEFAULT_ADDITIONAL_CAPITAL_RAIL_CROSSWALK,
    )
    parser.add_argument("--seoul-subway-source", type=Path, default=DEFAULT_SEOUL_SUBWAY_SOURCE)
    parser.add_argument("--gyeonggi-delta", type=Path, default=DEFAULT_GYEONGGI_DELTA)
    parser.add_argument("--jeju-mappings", type=Path, default=DEFAULT_JEJU_MAPPINGS)
    parser.add_argument("--jeju-city-source", type=Path, default=DEFAULT_JEJU_CITY_SOURCE)
    parser.add_argument("--seogwipo-source", type=Path, default=DEFAULT_SEOGWIPO_SOURCE)
    parser.add_argument("--seoul-code190-mappings", type=Path, default=DEFAULT_SEOUL_CODE190_MAPPINGS)
    parser.add_argument("--seoul-20251107-snapshot", type=Path, default=DEFAULT_SEOUL_20251107_SNAPSHOT)
    parser.add_argument("--seoul-11200-source", type=Path, default=DEFAULT_SEOUL_11200_SOURCE)
    parser.add_argument("--seoul-11710-source", type=Path, default=DEFAULT_SEOUL_11710_SOURCE)
    parser.add_argument("--station-metadata", type=Path, default=DEFAULT_STATION_METADATA)
    parser.add_argument("--samples", type=Path, default=DEFAULT_SAMPLES)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    return parser.parse_args()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def relative_path(path: Path) -> str:
    try:
        return str(path.resolve().relative_to(REPO_ROOT))
    except ValueError:
        return str(path.resolve())


def read_station_metadata(path: Path) -> dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if payload.get("schemaVersion") != 1:
        raise ValueError("Unsupported Korean station metadata schema")
    source_ids = {source["id"] for source in payload.get("sources", [])}
    if len(source_ids) != len(payload.get("sources", [])):
        raise ValueError("Duplicate Korean station metadata source ID")
    enrichments = payload.get("enrichments", [])
    seen: set[tuple[str, int | None]] = set()
    for item in enrichments:
        key = (str(item["locationCode"]).upper(), item.get("eventRaw"))
        if key in seen:
            raise ValueError(f"Duplicate Korean station metadata key: {key}")
        seen.add(key)
        latitude = item.get("latitude")
        longitude = item.get("longitude")
        if (latitude is None) != (longitude is None):
            raise ValueError(f"Incomplete coordinates for {key}")
        if latitude is not None:
            if not (32.0 <= float(latitude) <= 40.0 and 123.0 <= float(longitude) <= 133.0):
                raise ValueError(f"Out-of-range Korean coordinates for {key}")
            if item.get("coordinateSourceID") not in source_ids:
                raise ValueError(f"Unknown coordinate source for {key}")
        for field in ("nameSourceID", "nameHanjaSourceID"):
            if item.get(field) is not None and item[field] not in source_ids:
                raise ValueError(f"Unknown multilingual-name source for {key}")
    return payload


def read_modes(path: Path) -> dict[int, dict[str, str]]:
    modes: dict[int, dict[str, str]] = {}
    with path.open(encoding="utf-8-sig", newline="") as handle:
        for row in csv.DictReader(handle):
            code = int(row["교통수단코드"])
            modes[code] = {
                "name": row["내용"].strip(),
                "class": row["구분R철도B버스T택시"].strip(),
            }
    return modes


def read_samples(path: Path) -> dict[str, dict[str, Any]]:
    grouped: dict[str, dict[str, Any]] = {}
    with path.open(encoding="utf-8", newline="") as handle:
        for row in csv.DictReader(handle, delimiter="\t"):
            raw = row["record_hex"].upper()
            location_code = raw[10:22]
            item = grouped.setdefault(
                location_code,
                {
                    "name": row["location_label"],
                    "sampleIDs": [],
                    "stationToken": location_code[:8],
                    "transportModeCode": int(location_code[8:], 16),
                },
            )
            if item["name"] != row["location_label"]:
                raise ValueError(f"Conflicting user labels for {location_code}")
            item["sampleIDs"].append(row["sample_id"])
    return grouped


def read_national_stops(path: Path) -> tuple[dict[str, dict[str, Any]], int, int]:
    grouped: defaultdict[str, list[dict[str, str]]] = defaultdict(list)
    rows = 0
    with path.open(encoding="cp949", newline="") as handle:
        for row in csv.DictReader(handle):
            rows += 1
            station_id = row["정류장아이디"].strip()
            grouped[station_id].append(
                {
                    "name": row["정류장명"].strip(),
                    "operator": row["정산사업자"].strip(),
                    "sourceMode": row["교통수단구분"].strip(),
                    "ctpvCode": row["시도코드(법정동)"].strip(),
                    "ctpvName": row["시도명(법정동)"].strip(),
                    "sggCode": row["시군구코드(법정동)"].strip(),
                    "sggName": row["시군구명(법정동)"].strip(),
                    "emdCode": row["읍면동코드(법정동)"].strip(),
                    "emdName": row["읍면동명(법정동)"].strip(),
                    "mobileID": row["모바일아이디"].strip(),
                }
            )

    result: dict[str, dict[str, Any]] = {}
    ambiguous = 0
    for station_id, entries in grouped.items():
        names = {entry["name"] for entry in entries}
        if len(names) != 1:
            ambiguous += 1
            continue
        first = entries[0]
        result[station_id] = {
            "sttnId": station_id,
            "name": first["name"],
            "sourceID": "molit-settlement-stations-20250613",
            "ctpvCode": first["ctpvCode"],
            "ctpvName": first["ctpvName"],
            "sggCode": first["sggCode"],
            "sggName": first["sggName"],
            "emdCode": first["emdCode"],
            "emdName": first["emdName"],
            "mobileID": None if first["mobileID"] == "정보없음" else first["mobileID"],
            "settlementOperator": first["operator"],
            "sourceMode": first["sourceMode"],
        }
    return result, rows, ambiguous


def read_busan_metro_stops(path: Path) -> dict[int, dict[str, Any]]:
    """Return the unambiguous one-byte station namespace used by mode 870.

    The annual MOLIT file mixes Busan Metro and Busan-Gimhae Light Rail under
    the Mybi settlement operator, and both reuse station IDs 101-121.  Mode
    870 is KOTRIS's 부산교통공단 rail code.  Restricting the join to Mybi subway
    rows in Busan whose official label ends in 역 excludes the light-rail rows
    (whose labels omit that suffix) and leaves one consistent Busan Metro row
    per numeric ID.  Duplicate annual rows are accepted only when identical.
    """
    grouped: defaultdict[int, list[dict[str, Any]]] = defaultdict(list)
    with path.open(encoding="cp949", newline="") as handle:
        for row in csv.DictReader(handle):
            if (
                row["정산사업자"].strip() != "마이비"
                or row["교통수단구분"].strip() != "지하철"
                or row["시도명(법정동)"].strip() != "부산광역시"
                or not row["정류장명"].strip().endswith("역")
            ):
                continue
            try:
                station_id = int(row["정류장아이디"].strip())
            except ValueError:
                continue
            if not 0 <= station_id <= 0xFF:
                continue
            grouped[station_id].append(
                {
                    "sttnId": str(station_id),
                    "name": row["정류장명"].strip(),
                    "sourceID": "molit-settlement-stations-20250613",
                    "ctpvCode": row["시도코드(법정동)"].strip(),
                    "ctpvName": row["시도명(법정동)"].strip(),
                    "sggCode": row["시군구코드(법정동)"].strip(),
                    "sggName": row["시군구명(법정동)"].strip(),
                    "mobileID": None,
                }
            )

    result: dict[int, dict[str, Any]] = {}
    for station_id, entries in grouped.items():
        canonical = entries[0]
        if any(entry != canonical for entry in entries[1:]):
            raise ValueError(f"Conflicting Busan Metro source rows for station ID {station_id}")
        result[station_id] = canonical
    return result


def read_daegu_line2_stops(path: Path) -> dict[str, dict[str, str]]:
    result: dict[str, dict[str, str]] = {}
    with path.open(encoding="utf-8-sig", newline="") as handle:
        for row in csv.DictReader(handle):
            station_id = row["역코드"].strip()
            name = row["역명"].strip()
            if not station_id.isdecimal() or not name:
                continue
            item = {
                "sttnId": station_id,
                "name": name,
                "sourceID": "daegu-transit-line2-section-20251231",
                "ctpvCode": "27",
                "ctpvName": "대구광역시",
            }
            previous = result.setdefault(station_id, item)
            if previous != item:
                raise ValueError(f"Conflicting Daegu Line 2 source rows for station ID {station_id}")
    return result


def read_busan_bims_stops(path: Path) -> tuple[dict[str, dict[str, Any]], dict[str, Any]]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if payload.get("schemaVersion") != 1:
        raise ValueError("Unsupported Busan BIMS stop schema")
    by_ars: defaultdict[str, list[dict[str, Any]]] = defaultdict(list)
    for stop in payload["stops"]:
        ars_id = stop.get("arsID")
        if isinstance(ars_id, str) and re.fullmatch(r"[0-9]{5}", ars_id):
            by_ars[ars_id].append(stop)
    collisions = {ars_id: stops for ars_id, stops in by_ars.items() if len(stops) != 1}
    if collisions:
        raise ValueError(f"Busan BIMS canonical table has ARS collisions: {sorted(collisions)}")
    return {ars_id: stops[0] for ars_id, stops in by_ars.items()}, payload


def read_capital_rail_aliases(path: Path) -> tuple[dict[str, dict[str, Any]], dict[str, Any]]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if payload.get("schemaVersion") != "cardbal-capital-rail-location-crosswalk-stable-v1":
        raise ValueError("Unsupported capital rail crosswalk schema")
    result: dict[str, dict[str, Any]] = {}
    for location_code, item in payload["mappingsByLocationCode"].items():
        station_token = item["stationToken"]
        mode_hex = item["transportModeHex"]
        mapping = item["mapping"]
        if (
            location_code != station_token + mode_hex
            or not BUS_TOKEN.fullmatch(station_token)
            or item["legacyRawId"] != int(station_token) // 10
            or mapping["confidence"] != "high"
            or not mapping["safeToKeyByExactLocationCodeAlone"]
        ):
            raise ValueError(f"Unsafe capital rail mapping: {location_code}")
        official_rows = item["officialSourceRows"]
        seoul_row = next(
            row for row in official_rows if row["sourceId"] == "seoul-bigdata-subway-stations"
        )
        molit_row = next(
            (row for row in official_rows if row["sourceId"] == "molit-settlement-stations-20250613"),
            None,
        )
        alias = {
            "locationCode": location_code,
            "stationToken": station_token,
            "transportModeCode": item["transportModeDecimal"],
            "name": item["station"]["displayNameKo"],
            "provenance": "official_dataset_transformed_exact_match",
            "sourceID": "seoul-bigdata-subway-stations",
            "sourceStationID": item["station"]["currentPublicStationId"],
            "sourceStopID": seoul_row.get("operatorId"),
            "arsID": None,
            "ctpvCode": molit_row.get("provinceCode") if molit_row else None,
            "ctpvName": molit_row.get("provinceName") if molit_row else None,
            "sggCode": molit_row.get("districtCode") if molit_row else None,
            "sggName": molit_row.get("districtName") if molit_row else None,
            "latitude": None,
            "longitude": None,
            "eventRaw": None,
            "matchingMethod": f"capital_rail_legacy:{mapping['ruleId']}",
            "mappingConfidence": "high",
            "lineName": item["station"].get("lineName"),
            "operatorName": item["station"].get("operatorName"),
        }
        previous = result.setdefault(location_code, alias)
        if previous != alias:
            raise ValueError(f"Conflicting capital rail aliases for {location_code}")
    return result, payload


def read_additional_capital_rail_aliases(
    path: Path,
    national_source: Path,
    seoul_source: Path,
) -> tuple[dict[str, dict[str, Any]], dict[str, Any]]:
    """Load only the artifact's high tier and recheck every cited official row."""
    payload = json.loads(path.read_text(encoding="utf-8"))
    if payload.get("schemaVersion") != "cardbal-additional-capital-rail-crosswalk-high-v1":
        raise ValueError("Unsupported additional capital rail crosswalk schema")
    mappings = payload["mappingsByLocationCode"]
    if (
        len(mappings) != payload["coverage"]["locations"]
        or len(payload.get("excludedHypotheses", [])) != 9
        or set(mappings) & {item["locationCode"] for item in payload["excludedHypotheses"]}
    ):
        raise ValueError("Additional capital rail integration policy is inconsistent")
    source_metadata = {item["id"]: item for item in payload["sources"]}
    if (
        source_metadata["seoul-bigdata-subway"]["sha256"] != sha256(seoul_source)
        or source_metadata["molit-settlement-stations-20250613"]["sha256"]
        != sha256(national_source)
    ):
        raise ValueError("Additional capital rail official source hash mismatch")

    def rows_by_number(source: Path) -> dict[int, dict[str, str]]:
        with source.open(encoding="cp949", newline="") as handle:
            return {number: row for number, row in enumerate(csv.DictReader(handle), start=2)}

    national_rows = rows_by_number(national_source)
    seoul_rows = rows_by_number(seoul_source)
    result: dict[str, dict[str, Any]] = {}
    for location_code, item in mappings.items():
        if (
            location_code != item["locationCode"]
            or location_code != item["stationToken"] + item["transportModeHex"]
            or not BUS_TOKEN.fullmatch(item["stationToken"])
            or item["legacyRawId"] != int(item["stationToken"]) // 10
            or int(item["transportModeHex"], 16) != item["transportModeDecimal"]
            or item["confidenceTier"] != "high"
            or item["eventRequiredForLookup"]
        ):
            raise ValueError(f"Unsafe additional capital rail mapping: {location_code}")
        official_rows = item["officialSourceRows"]
        molit_evidence = next(
            row
            for row in official_rows
            if row["sourceId"] == "molit-settlement-stations-20250613"
        )
        source_row = national_rows[molit_evidence["csvRowNumber"]]
        if (
            source_row["정류장아이디"].strip() != molit_evidence["stationId"]
            or source_row["정류장명"].strip() != molit_evidence["stationName"]
            or source_row["정류장아이디"].strip()
            != item["station"]["currentPublicStationId"]
        ):
            raise ValueError(f"Additional rail MOLIT row mismatch: {location_code}")
        seoul_evidence = next(
            (row for row in official_rows if row["sourceId"] == "seoul-bigdata-subway"),
            None,
        )
        if seoul_evidence:
            seoul_row = seoul_rows[seoul_evidence["csvRowNumber"]]
            if (
                seoul_row["역ID(STATION_ID)"].strip() != seoul_evidence["stationId"]
                or seoul_row["역명(STATION_NM)"].strip() != seoul_evidence["stationName"]
                or seoul_row["호선명(LINE_NM)"].strip() != seoul_evidence["lineName"]
                or seoul_row["교통운영기관명(CORP_NM)"].strip()
                != seoul_evidence["operatorName"]
            ):
                raise ValueError(f"Additional rail Seoul row mismatch: {location_code}")
        else:
            seoul_row = None
        result[location_code] = {
            "locationCode": location_code,
            "stationToken": item["stationToken"],
            "transportModeCode": item["transportModeDecimal"],
            "name": source_row["정류장명"].strip(),
            "provenance": "official_dataset_transformed_exact_match",
            "sourceID": "cardbal-additional-capital-rail-high-v1",
            "sourceStationID": item["station"]["currentPublicStationId"],
            "sourceStopID": None,
            "arsID": None,
            "ctpvCode": source_row["시도코드(법정동)"].strip(),
            "ctpvName": source_row["시도명(법정동)"].strip(),
            "sggCode": source_row["시군구코드(법정동)"].strip(),
            "sggName": source_row["시군구명(법정동)"].strip(),
            "latitude": None,
            "longitude": None,
            "eventRaw": None,
            "matchingMethod": "capital_rail_additional_high_exact_location",
            "mappingConfidence": "high",
            "mappingReason": item["reason"],
            "lineName": seoul_row["호선명(LINE_NM)"].strip() if seoul_row else None,
            "operatorName": (
                seoul_row["교통운영기관명(CORP_NM)"].strip() if seoul_row else None
            ),
        }
    if sum(item["records"] for item in mappings.values()) != payload["coverage"]["records"]:
        raise ValueError("Additional capital rail artifact record coverage mismatch")
    return result, payload


def read_gyeonggi_delta_stops(path: Path) -> tuple[dict[str, dict[str, Any]], dict[str, Any]]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if payload.get("schemaVersion") != 1:
        raise ValueError("Unsupported Gyeonggi selector-delta schema")
    result: dict[str, dict[str, Any]] = {}
    for item in payload["knownLocations"]:
        station_id = item["sourceStationID"]
        if (
            item["locationCode"] != item["stationToken"] + item["transportModeCode"]
            or not BUS_TOKEN.fullmatch(item["stationToken"])
            or item["stationToken"][:-1] != station_id
            or item["sourceRow"]["value"] != station_id
        ):
            raise ValueError(f"Unsafe Gyeonggi delta mapping: {item['locationCode']}")
        stop = {
            "sttnId": station_id,
            "name": item["name"],
            "sourceID": "molit-settlement-stops-gyeonggi-20250801",
            "ctpvCode": "41",
            "ctpvName": item["ctpvName"],
            "sggCode": item["sourceRequest"]["form"]["sgg"],
            "sggName": item["sggName"],
            "mobileID": item.get("arsID"),
            "settlementOperator": None,
            "sourceMode": "버스",
        }
        previous = result.setdefault(station_id, stop)
        if previous != stop:
            raise ValueError(f"Conflicting Gyeonggi delta station ID: {station_id}")
    return result, payload


def read_jeju_aliases(
    path: Path,
    jeju_city_source: Path,
    seogwipo_source: Path,
) -> tuple[dict[str, dict[str, Any]], dict[str, Any]]:
    """Validate the scoped Jeju transform against the vendored official rows."""
    payload = json.loads(path.read_text(encoding="utf-8"))
    if payload.get("schemaVersion") != 1:
        raise ValueError("Unsupported Jeju selector mapping schema")
    validation = payload.get("validation", {})
    if not all(
        validation.get(field)
        for field in (
            "allLocationCodesExact",
            "allTokensEightDecimalDigits",
            "allExactUniqueOfficialJoins",
        )
    ):
        raise ValueError("Jeju selector artifact did not pass its invariants")

    source_paths = {"50110": jeju_city_source, "50130": seogwipo_source}
    official_index: defaultdict[str, list[tuple[str, int, dict[str, str]]]] = defaultdict(list)
    source_metadata = {
        item["sggCode"]: item for item in payload["generatedFrom"]["sourceFiles"]
    }
    for district, source_path in source_paths.items():
        rows = json.loads(source_path.read_text(encoding="utf-8"))
        if not isinstance(rows, list) or any(set(row) != {"value", "text"} for row in rows):
            raise ValueError(f"Unexpected Jeju selector schema: {source_path}")
        metadata = source_metadata.get(district)
        if (
            metadata is None
            or metadata["sha256"] != sha256(source_path)
            or metadata["selectorRows"] != len(rows)
        ):
            raise ValueError(f"Jeju source metadata mismatch: {source_path}")
        for index, row in enumerate(rows):
            official_index[row["value"]].append((district, index, row))

    result: dict[str, dict[str, Any]] = {}
    for item in payload["knownLocations"]:
        location_code = item["locationCode"]
        station_token = item["stationToken"]
        station_id = item["sourceStationID"]
        district = item["sourceRequest"]["form"]["sgg"]
        source_path = source_paths.get(district)
        matches = official_index.get(station_id, [])
        if (
            source_path is None
            or location_code != station_token + item["transportModeCode"]
            or len(station_token) != 8
            or not station_token.isdecimal()
            or station_token[:7] != station_id
            or item["transform"]["discardedFinalDigit"] != station_token[7]
            or item["transform"]["derivedStationID"] != station_id
            or item["systemDecimal"] not in JEJU_BUS_MODE_CODES
            or int(item["transportModeCode"], 16) != item["systemDecimal"]
            or len(matches) != 1
            or matches[0][0] != district
            or matches[0][1] != item["sourceSelectorIndex"]
            or matches[0][2] != item["sourceRow"]
            or item["sourceRow"]["value"] != station_id
            or item["sourceFileSha256"] != sha256(source_path)
        ):
            raise ValueError(f"Unsafe Jeju selector mapping: {location_code}")
        alias = {
            "locationCode": location_code,
            "stationToken": station_token,
            "transportModeCode": item["systemDecimal"],
            "name": item["name"],
            "provenance": "official_dataset_transformed_exact_match",
            "sourceID": "molit-settlement-stops-jeju-20250801",
            "sourceStationID": station_id,
            "sourceStopID": None,
            "arsID": None,
            "ctpvCode": "50",
            "ctpvName": item["ctpvName"],
            "sggCode": district,
            "sggName": item["sggName"],
            "latitude": None,
            "longitude": None,
            "eventRaw": None,
            "matchingMethod": "jeju_station_variant_digit_exact",
        }
        previous = result.setdefault(location_code, alias)
        if previous != alias:
            raise ValueError(f"Conflicting Jeju aliases for {location_code}")
    if len(result) != validation["mappedLocations"]:
        raise ValueError("Jeju mapping location count differs from its validation summary")
    return result, payload


def read_seoul_code190_aliases(
    path: Path,
    snapshot_path: Path,
    source_11200: Path,
    source_11710: Path,
) -> tuple[dict[str, dict[str, Any]], dict[str, Any]]:
    """Map two places while preserving code 190's unresolved system identity."""
    payload = json.loads(path.read_text(encoding="utf-8"))
    validation = payload.get("validation", {})
    if (
        payload.get("schemaVersion") != 1
        or validation.get("mappedLocations") != 2
        or validation.get("mappedRecords") != 2
        or not validation.get("allLocationCodesExact")
        or not validation.get("allDerivedIDsExact")
        or not validation.get("allOfficialRowsUnique")
        or validation.get("operatorClaimPresent")
    ):
        raise ValueError("Unsafe Seoul code-190 mapping artifact")
    snapshot = json.loads(snapshot_path.read_text(encoding="utf-8"))
    if (
        snapshot.get("schemaVersion") != 2
        or snapshot.get("snapshotDate") != "20251107"
        or snapshot.get("recordCount") != 15470
        or snapshot.get("ambiguousIds")
        or payload["generatedFrom"]["officialFullSnapshotSha256"] != sha256(snapshot_path)
    ):
        raise ValueError("Seoul 2025-11-07 official snapshot mismatch")
    snapshot_index = {row["sttnId"]: row for row in snapshot["records"]}
    source_paths = {"11200": source_11200, "11710": source_11710}
    result: dict[str, dict[str, Any]] = {}
    for item in payload["knownLocations"]:
        code = item["locationCode"]
        token = item["stationToken"]
        station_id = item["sourceStationID"]
        district = item["sourceRequest"]["form"]["sgg"]
        source_path = source_paths.get(district)
        raw_rows = json.loads(source_path.read_text(encoding="utf-8")) if source_path else []
        official = snapshot_index.get(station_id)
        if (
            code != token + "00BE"
            or item["transportModeCode"] != "00BE"
            or item["systemDecimal"] != 190
            or item.get("systemOfficialNameKo") is not None
            or item.get("systemIdentityStatus") != "unresolved"
            or not BUS_TOKEN.fullmatch(token)
            or token[:7] != station_id
            or source_path is None
            or item["sourceFileSha256"] != sha256(source_path)
            or item["sourceSelectorIndex"] >= len(raw_rows)
            or raw_rows[item["sourceSelectorIndex"]] != item["sourceRow"]
            or item["sourceRow"] != {"value": station_id, "text": item["name"]}
            or official is None
            or official["name"] != item["name"]
            or len(official.get("districts", [])) != 1
            or official["districts"][0]["sggCode"] != district
        ):
            raise ValueError(f"Unsafe Seoul code-190 place mapping: {code}")
        result[code] = {
            "locationCode": code,
            "stationToken": token,
            "transportModeCode": 190,
            "name": item["name"],
            "provenance": "official_dataset_transformed_exact_match",
            "sourceID": "molit-settlement-stops-seoul-20251107",
            "sourceStationID": station_id,
            "sourceStopID": None,
            "arsID": None,
            "ctpvCode": "11",
            "ctpvName": "서울특별시",
            "sggCode": district,
            "sggName": item["sggName"],
            "latitude": None,
            "longitude": None,
            "eventRaw": None,
            "matchingMethod": "seoul_code190_settlement_exact_unresolved_system",
            "systemIdentityStatus": "unresolved",
        }
    return result, payload


def main() -> None:
    args = parse_args()
    station_metadata = read_station_metadata(args.station_metadata)
    snapshot_path = args.snapshot
    if args.vendor_snapshot:
        args.vendor_snapshot.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(args.snapshot, args.vendor_snapshot)
        snapshot_path = args.vendor_snapshot

    snapshot = json.loads(snapshot_path.read_text(encoding="utf-8"))
    if snapshot.get("schemaVersion") != 1:
        raise ValueError("Unsupported MOLIT snapshot schema")
    if snapshot.get("ambiguousIds"):
        raise ValueError("MOLIT snapshot contains ambiguous station IDs")
    snapshot_records = snapshot["records"]
    delta_stops = {record["sttnId"]: record for record in snapshot_records}
    if len(delta_stops) != len(snapshot_records):
        raise ValueError("MOLIT snapshot contains duplicate station IDs")
    stops, national_rows, national_ambiguous = read_national_stops(args.national)
    busan_metro_stops = read_busan_metro_stops(args.national)
    daegu_line2_stops = read_daegu_line2_stops(args.daegu_line2)
    busan_bims_stops, busan_bims_payload = read_busan_bims_stops(args.busan_bims_stops)
    capital_rail_aliases, capital_rail_payload = read_capital_rail_aliases(
        args.capital_rail_crosswalk
    )
    additional_capital_rail_aliases, additional_capital_rail_payload = (
        read_additional_capital_rail_aliases(
            args.additional_capital_rail_crosswalk,
            args.national,
            args.seoul_subway_source,
        )
    )
    gyeonggi_delta_stops, gyeonggi_delta_payload = read_gyeonggi_delta_stops(
        args.gyeonggi_delta
    )
    jeju_aliases, jeju_payload = read_jeju_aliases(
        args.jeju_mappings,
        args.jeju_city_source,
        args.seogwipo_source,
    )
    seoul_code190_aliases, seoul_code190_payload = read_seoul_code190_aliases(
        args.seoul_code190_mappings,
        args.seoul_20251107_snapshot,
        args.seoul_11200_source,
        args.seoul_11710_source,
    )
    for station_id, record in delta_stops.items():
        districts = record.get("districts", [])
        if len(districts) != 1:
            continue
        district = districts[0]
        stops[station_id] = {
            "sttnId": station_id,
            "name": record["name"],
            "sourceID": "molit-settlement-stops-20250801",
            "ctpvCode": snapshot["city"]["ctpvCode"],
            "ctpvName": snapshot["city"]["ctpvName"],
            "sggCode": district["sggCode"],
            "sggName": district["sggName"],
            "emdCode": None,
            "emdName": None,
            "mobileID": VERIFIED_ARS_IDS.get(station_id),
            "settlementOperator": None,
            "sourceMode": "버스",
        }
    for station_id, record in gyeonggi_delta_stops.items():
        if station_id in stops:
            raise ValueError(f"Gyeonggi delta is not a true annual-source delta: {station_id}")
        stops[station_id] = record

    modes = read_modes(args.modes)
    samples = read_samples(args.samples)
    corpus = json.loads(args.corpus.read_text(encoding="utf-8"))
    corpus_records = corpus["records"]

    location_row_counts: defaultdict[str, int] = defaultdict(int)
    official_bus_rows = 0
    eligible_bus_rows = 0
    matched_rows = 0
    matched_station_ids: set[str] = set()
    matched_names: set[str] = set()
    official_aliases: dict[str, dict[str, Any]] = {}
    transformed_rail_rows = 0
    transformed_rail_station_ids: set[str] = set()
    transformed_rail_aliases: dict[str, dict[str, Any]] = {}
    daegu_rail_rows = 0
    daegu_rail_aliases: dict[str, dict[str, Any]] = {}
    busan_bims_rows = 0
    busan_bims_aliases: dict[str, dict[str, Any]] = {}
    capital_rail_rows = 0
    additional_capital_rail_rows = 0
    jeju_rows = 0
    seoul_code190_rows = 0

    for record in corpus_records:
        raw = bytes.fromhex(record["raw"])
        if len(raw) != 52:
            raise ValueError(f"Expected 52 bytes for {record['id']}")
        station_token = raw[5:9].hex().upper()
        mode_code = int.from_bytes(raw[9:11], "big")
        location_code = station_token + raw[9:11].hex().upper()
        location_row_counts[location_code] += 1
        mode = modes.get(mode_code)
        if (not mode or mode["class"] != "B") and mode_code != 142:
            continue
        official_bus_rows += 1
        if not BUS_TOKEN.fullmatch(station_token):
            continue
        eligible_bus_rows += 1
        settlement_id = station_token[:-1]
        stop = stops.get(settlement_id)
        if not stop:
            continue
        matched_rows += 1
        matched_station_ids.add(settlement_id)
        matched_names.add(stop["name"])
        alias = {
            "locationCode": location_code,
            "stationToken": station_token,
            "transportModeCode": mode_code,
            "name": stop["name"],
            "provenance": "official_dataset_exact_match",
            "sourceID": stop["sourceID"],
            "sourceStationID": settlement_id,
            "arsID": stop.get("mobileID") or VERIFIED_ARS_IDS.get(settlement_id),
            "ctpvCode": stop.get("ctpvCode"),
            "ctpvName": stop.get("ctpvName"),
            "sggCode": stop.get("sggCode"),
            "sggName": stop.get("sggName"),
            "userConfirmedSampleIDs": sorted(samples.get(location_code, {}).get("sampleIDs", [])),
            "matchingMethod": "bus_settlement_id_exact",
        }
        previous = official_aliases.setdefault(location_code, alias)
        if previous != alias:
            raise ValueError(f"Conflicting official aliases for {location_code}")

    for record in corpus_records:
        raw = bytes.fromhex(record["raw"])
        mode_code = int.from_bytes(raw[9:11], "big")
        if mode_code not in BUSAN_BUS_MODE_CODES:
            continue
        station_token = raw[5:9].hex().upper()
        candidate_ars = f"{int.from_bytes(raw[7:9], 'little'):05d}"
        stop = busan_bims_stops.get(candidate_ars)
        if not stop:
            continue
        location_code = station_token + raw[9:11].hex().upper()
        busan_bims_rows += 1
        alias = {
            "locationCode": location_code,
            "stationToken": station_token,
            "transportModeCode": mode_code,
            "name": stop["nameKo"],
            "provenance": "official_dataset_transformed_exact_match",
            "sourceID": "busan-bims-route-stops-20260727",
            "sourceStationID": candidate_ars,
            "sourceStopID": stop["stopID"],
            "arsID": candidate_ars,
            "ctpvCode": "26",
            "ctpvName": stop["city"],
            "sggCode": None,
            "sggName": stop["district"],
            "latitude": stop["latitude"],
            "longitude": stop["longitude"],
            "eventRaw": None,
            "userConfirmedSampleIDs": sorted(samples.get(location_code, {}).get("sampleIDs", [])),
            "matchingMethod": "busan_bims_low16le_ars_exact",
        }
        previous = busan_bims_aliases.setdefault(location_code, alias)
        if previous != alias:
            raise ValueError(f"Conflicting Busan BIMS aliases for {location_code}")

    corpus_location_codes = Counter(
        bytes.fromhex(record["raw"])[5:11].hex().upper() for record in corpus_records
    )
    for location_code, alias in capital_rail_aliases.items():
        observed_rows = corpus_location_codes.get(location_code, 0)
        if observed_rows <= 0:
            raise ValueError(f"Capital rail alias is absent from corpus: {location_code}")
        alias["userConfirmedSampleIDs"] = sorted(
            samples.get(location_code, {}).get("sampleIDs", [])
        )
        capital_rail_rows += observed_rows
    # The crosswalk records the minimum corpus coverage at review time. D1 is
    # append-only, so later records may legitimately reuse an accepted alias.
    if capital_rail_rows < capital_rail_payload["coverage"]["stableMappedRecords"]:
        raise ValueError(
            f"Capital rail coverage regressed: {capital_rail_rows} < "
            f"{capital_rail_payload['coverage']['stableMappedRecords']}"
        )

    additional_expected_rows = {
        location_code: item["records"]
        for location_code, item in additional_capital_rail_payload[
            "mappingsByLocationCode"
        ].items()
    }
    for location_code, alias in additional_capital_rail_aliases.items():
        observed_rows = corpus_location_codes.get(location_code, 0)
        if observed_rows < additional_expected_rows[location_code]:
            raise ValueError(
                f"Additional capital rail corpus coverage regressed for {location_code}: "
                f"{observed_rows} < {additional_expected_rows[location_code]}"
            )
        alias["userConfirmedSampleIDs"] = sorted(
            samples.get(location_code, {}).get("sampleIDs", [])
        )
        additional_capital_rail_rows += observed_rows
    if additional_capital_rail_rows < additional_capital_rail_payload["coverage"]["records"]:
        raise ValueError("Additional capital rail aggregate coverage regressed")

    jeju_expected_rows = {
        item["locationCode"]: item["records"] for item in jeju_payload["knownLocations"]
    }
    for location_code, alias in jeju_aliases.items():
        observed_rows = corpus_location_codes.get(location_code, 0)
        if observed_rows < jeju_expected_rows[location_code]:
            raise ValueError(
                f"Jeju corpus coverage regressed for {location_code}: "
                f"{observed_rows} < {jeju_expected_rows[location_code]}"
            )
        alias["userConfirmedSampleIDs"] = sorted(
            samples.get(location_code, {}).get("sampleIDs", [])
        )
        jeju_rows += observed_rows
    if jeju_rows < jeju_payload["validation"]["mappedRecords"]:
        raise ValueError(
            f"Jeju record coverage regressed: {jeju_rows} < "
            f"{jeju_payload['validation']['mappedRecords']}"
        )

    code190_expected_rows = {
        item["locationCode"]: item["records"]
        for item in seoul_code190_payload["knownLocations"]
    }
    for location_code, alias in seoul_code190_aliases.items():
        observed_rows = corpus_location_codes.get(location_code, 0)
        if observed_rows < code190_expected_rows[location_code]:
            raise ValueError(f"Seoul code-190 corpus coverage regressed: {location_code}")
        alias["userConfirmedSampleIDs"] = sorted(
            samples.get(location_code, {}).get("sampleIDs", [])
        )
        seoul_code190_rows += observed_rows

    for record in corpus_records:
        raw = bytes.fromhex(record["raw"])
        station_token = raw[5:9].hex().upper()
        mode_code = int.from_bytes(raw[9:11], "big")
        if mode_code != 870:
            continue
        token_match = BUSAN_MYBI_RAIL_TOKEN.fullmatch(station_token)
        if not token_match:
            continue
        station_id = int(token_match.group(1), 16)
        stop = busan_metro_stops.get(station_id)
        if not stop:
            continue
        location_code = station_token + raw[9:11].hex().upper()
        transformed_rail_rows += 1
        transformed_rail_station_ids.add(stop["sttnId"])
        alias = {
            "locationCode": location_code,
            "stationToken": station_token,
            "transportModeCode": mode_code,
            "name": stop["name"],
            "provenance": "official_dataset_transformed_exact_match",
            "sourceID": stop["sourceID"],
            "sourceStationID": stop["sttnId"],
            "arsID": None,
            "ctpvCode": stop["ctpvCode"],
            "ctpvName": stop["ctpvName"],
            "sggCode": stop["sggCode"],
            "sggName": stop["sggName"],
            "userConfirmedSampleIDs": sorted(samples.get(location_code, {}).get("sampleIDs", [])),
            "matchingMethod": "busan_mybi_station_byte",
        }
        previous = transformed_rail_aliases.setdefault(location_code, alias)
        if previous != alias:
            raise ValueError(f"Conflicting Busan Metro aliases for {location_code}")

    # Daegu mode 872 stores a four-digit origin settlement ID followed by a
    # four-digit destination settlement ID.  The active half depends on the
    # event byte, and is ten times the operator's three-digit station code.
    # Keep eventRaw in the alias so the app never applies this event-dependent
    # transform to the opposite side of a future record.
    for record in corpus_records:
        raw = bytes.fromhex(record["raw"])
        station_token = raw[5:9].hex().upper()
        mode_code = int.from_bytes(raw[9:11], "big")
        event_raw = raw[2]
        if mode_code != 872 or event_raw not in (0, 1) or not station_token.isdecimal():
            continue
        active_half = station_token[:4] if event_raw == 0 else station_token[4:]
        if not active_half.endswith("0"):
            continue
        operator_station_id = str(int(active_half) // 10)
        if f"{int(operator_station_id) * 10:04d}" != active_half:
            continue
        stop = daegu_line2_stops.get(operator_station_id)
        if not stop:
            continue
        location_code = station_token + raw[9:11].hex().upper()
        daegu_rail_rows += 1
        alias = {
            "locationCode": location_code,
            "stationToken": station_token,
            "transportModeCode": mode_code,
            "name": stop["name"],
            "provenance": "official_dataset_transformed_exact_match",
            "sourceID": stop["sourceID"],
            "sourceStationID": stop["sttnId"],
            "arsID": None,
            "ctpvCode": stop["ctpvCode"],
            "ctpvName": stop["ctpvName"],
            "sggCode": None,
            "sggName": None,
            "eventRaw": event_raw,
            "userConfirmedSampleIDs": sorted(samples.get(location_code, {}).get("sampleIDs", [])),
            "matchingMethod": "daegu_event_split_station_id_v1",
        }
        previous = daegu_rail_aliases.setdefault(location_code, alias)
        if previous != alias:
            raise ValueError(f"Conflicting Daegu rail aliases for {location_code}")

    sourced_groups = [
        official_aliases,
        capital_rail_aliases,
        additional_capital_rail_aliases,
        busan_bims_aliases,
        transformed_rail_aliases,
        daegu_rail_aliases,
        jeju_aliases,
        seoul_code190_aliases,
    ]
    overlap: set[str] = set()
    seen: set[str] = set()
    for group in sourced_groups:
        overlap |= seen & set(group)
        seen |= set(group)
    if overlap:
        raise ValueError(f"Sourced station alias keys overlap: {sorted(overlap)}")
    aliases = [
        *official_aliases.values(),
        *capital_rail_aliases.values(),
        *additional_capital_rail_aliases.values(),
        *busan_bims_aliases.values(),
        *transformed_rail_aliases.values(),
        *daegu_rail_aliases.values(),
        *jeju_aliases.values(),
        *seoul_code190_aliases.values(),
    ]
    sourced_alias_codes = {
        *official_aliases.keys(),
        *capital_rail_aliases.keys(),
        *additional_capital_rail_aliases.keys(),
        *busan_bims_aliases.keys(),
        *transformed_rail_aliases.keys(),
        *daegu_rail_aliases.keys(),
        *jeju_aliases.keys(),
        *seoul_code190_aliases.keys(),
    }
    for location_code, sample in samples.items():
        if location_code in sourced_alias_codes:
            continue
        aliases.append(
            {
                "locationCode": location_code,
                "stationToken": sample["stationToken"],
                "transportModeCode": sample["transportModeCode"],
                "name": sample["name"],
                "provenance": "user_confirmed",
                "sourceID": "cardbal-user-confirmed-samples",
                "sourceStationID": None,
                "arsID": None,
                "ctpvCode": None,
                "ctpvName": None,
                "sggCode": None,
                "sggName": None,
                "userConfirmedSampleIDs": sorted(sample["sampleIDs"]),
                "matchingMethod": "user_confirmed_full_fingerprint",
                "eventRaw": None,
            }
        )

    aliases_by_key = {
        (alias["locationCode"].upper(), alias.get("eventRaw")): alias
        for alias in aliases
    }
    if len(aliases_by_key) != len(aliases):
        raise ValueError("Korean alias list contains duplicate event-aware keys")
    metadata_fields = {
        "latitude",
        "longitude",
        "coordinateSourceID",
        "coordinateSourceStationID",
        "coordinateMatchingMethod",
        "nameCanonicalKo",
        "nameEnglish",
        "nameHanja",
        "nameChineseSimplified",
        "nameChineseTraditional",
        "nameJapanese",
        "nameSourceID",
        "nameSourceStationID",
        "nameHanjaSourceID",
        "nameMatchingMethod",
    }
    for enrichment in station_metadata["enrichments"]:
        key = (enrichment["locationCode"].upper(), enrichment.get("eventRaw"))
        alias = aliases_by_key.get(key)
        if alias is None:
            raise ValueError(f"Station metadata references an unknown alias: {key}")
        if enrichment.get("identityName") != alias["name"]:
            raise ValueError(f"Station metadata identity-name mismatch: {key}")
        for field in metadata_fields:
            value = enrichment.get(field)
            if value is None:
                continue
            existing = alias.get(field)
            if existing is not None and existing != value:
                raise ValueError(f"Station metadata conflicts on {field}: {key}")
            alias[field] = value

    # Coordinate identity and coordinate provenance are separate concepts. For
    # BIMS aliases the same official row supplies both, so make that explicit.
    for alias in aliases:
        latitude = alias.get("latitude")
        longitude = alias.get("longitude")
        if (latitude is None) != (longitude is None):
            raise ValueError(f"Incomplete alias coordinates: {alias['locationCode']}")
        if latitude is not None:
            alias.setdefault("coordinateSourceID", alias["sourceID"])
            alias.setdefault(
                "coordinateSourceStationID",
                alias.get("sourceStopID")
                or alias.get("arsID")
                or alias.get("sourceStationID"),
            )
            alias.setdefault("coordinateMatchingMethod", alias.get("matchingMethod"))
    provenance_order = {
        "official_dataset_exact_match": 0,
        "official_dataset_transformed_exact_match": 1,
        "user_confirmed": 2,
    }
    aliases.sort(key=lambda item: (provenance_order[item["provenance"]], item["locationCode"]))

    payload = {
        "schemaVersion": 1,
        "sources": [
            {
                "id": "molit-settlement-stations-20250613",
                "title": "국토교통부_정류장 현황_20250613",
                "publisher": "국토교통부",
                "catalogURL": "https://www.data.go.kr/data/15128614/fileData.do",
                "localPath": relative_path(args.national),
                "datasetDate": "2025-06-13",
                "portalModifiedDate": "2025-07-01",
                "retrievedAt": "2026-07-27",
                "license": "이용허락범위 제한 없음",
                "note": "Annual nationwide station inventory collected from fare-settlement operators under the Public Transportation Act. Bus rows require an exact settlement-ID match. For KOTRIS mode 870 only, CardBal also applies the separately identified Mybi Busan Metro station-byte transform and retains that distinct provenance.",
                "sourceSHA256": sha256(args.national),
                "rowCount": national_rows,
                "matchingMethod": "Bus: require an eight-digit decimal BCD station token ending in zero, drop only that final nibble, and require an exact unambiguous 정류장아이디 match. Busan Metro mode 870: require token bytes [00|01] 13 [station byte] 00, convert only the station byte from hexadecimal to decimal, and join a uniquely filtered Mybi Busan subway row. No name or geographic fuzzy matching is used.",
            },
            {
                "id": "molit-settlement-stops-20250801",
                "title": "국토교통부_버스정류장",
                "publisher": "국토교통부",
                "catalogURL": "https://www.data.go.kr/data/15142032/openapi.do",
                "localPath": relative_path(snapshot_path),
                "datasetDate": snapshot["snapshotDate"],
                "portalModifiedDate": "2026-04-10",
                "retrievedAt": snapshot["source"]["retrievedAtUTC"],
                "license": "이용허락범위 제한 없음",
                "note": "The source covers stops managed by fare-settlement operators. CardBal's removal of the final zero nibble from qualifying bus tokens is an interpretation; a name is included only after an exact source sttn_id match.",
                "sourceSHA256": sha256(snapshot_path),
                "rowCount": len(snapshot_records),
                "matchingMethod": "For official KOTRIS class B only: require an eight-digit decimal BCD station token ending in zero, drop only that final nibble, then require an exact seven-digit sttn_id match. The resulting alias remains keyed by bytes 05-10.",
            },
            {
                "id": "molit-settlement-stops-gyeonggi-20250801",
                "title": "국토교통부_버스정류장 경기도 2025-08-01 delta",
                "publisher": "국토교통부",
                "catalogURL": "https://www.data.go.kr/data/15142032/openapi.do",
                "localPath": relative_path(args.gyeonggi_delta),
                "datasetDate": "2025-08-01",
                "portalModifiedDate": "2026-04-10",
                "retrievedAt": "2026-07-27",
                "license": "이용허락범위 제한 없음",
                "note": "Exact rows from all 47 official Gyeonggi selector files. These five station IDs are absent from the 2025-06-13 annual inventory; request bodies, district source-row indexes, and hashes are retained in the artifact.",
                "sourceSHA256": sha256(args.gyeonggi_delta),
                "rowCount": gyeonggi_delta_payload["generatedFrom"]["selectorRows"],
                "matchingMethod": "Use the same exact bus settlement-ID transform, then require the derived ID to equal a unique official 2025-08-01 selector row. No fuzzy or geographic matching.",
            },
            {
                "id": "molit-settlement-stops-jeju-20250801",
                "title": "국토교통부_버스정류장 제주특별자치도 2025-08-01 selector",
                "publisher": "국토교통부",
                "catalogURL": "https://www.data.go.kr/data/15142032/openapi.do",
                "localPath": relative_path(args.jeju_mappings),
                "sourceFiles": [
                    {
                        "sggCode": "50110",
                        "localPath": relative_path(args.jeju_city_source),
                        "sha256": sha256(args.jeju_city_source),
                    },
                    {
                        "sggCode": "50130",
                        "localPath": relative_path(args.seogwipo_source),
                        "sha256": sha256(args.seogwipo_source),
                    },
                ],
                "datasetDate": "2025-08-01",
                "portalModifiedDate": "2026-04-10",
                "retrievedAt": "2026-07-27",
                "license": "이용허락범위 제한 없음",
                "note": "All 59 observed Jeju fingerprints join uniquely to one of 3,400 official Jeju selector rows. Dropping token digit eight is a CardBal corpus inference scoped only to KOTRIS modes 990, 994, and 995; the official source does not publish the card wire format.",
                "sourceSHA256": sha256(args.jeju_mappings),
                "rowCount": jeju_payload["generatedFrom"]["selectorRows"],
                "matchingMethod": "For KOTRIS Jeju modes 990/994/995 only, require an eight-digit decimal token, drop exactly the final variant digit, and require the seven-digit result to occur exactly once across the Jeju City and Seogwipo official selector rows. No fuzzy or geographic matching.",
            },
            {
                "id": "molit-settlement-stops-seoul-20251107",
                "title": "국토교통부_버스정류장 서울특별시 2025-11-07 selector",
                "publisher": "국토교통부",
                "catalogURL": "https://www.data.go.kr/data/15142032/openapi.do",
                "localPath": relative_path(args.seoul_20251107_snapshot),
                "mappingLocalPath": relative_path(args.seoul_code190_mappings),
                "districtSourceFiles": [
                    {
                        "sggCode": "11200",
                        "localPath": relative_path(args.seoul_11200_source),
                        "sha256": sha256(args.seoul_11200_source),
                    },
                    {
                        "sggCode": "11710",
                        "localPath": relative_path(args.seoul_11710_source),
                        "sha256": sha256(args.seoul_11710_source),
                    },
                ],
                "datasetDate": "2025-11-07",
                "portalModifiedDate": "2026-04-10",
                "retrievedAt": "2026-07-27",
                "license": "이용허락범위 제한 없음",
                "note": "Two code-190 fingerprints exactly match official selector IDs on the trip date and form one coherent ride. Only the places are attributed: no source identifies transport-mode code 190 or its operator, so the system identity deliberately remains unresolved.",
                "sourceSHA256": sha256(args.seoul_20251107_snapshot),
                "mappingSHA256": sha256(args.seoul_code190_mappings),
                "rowCount": seoul_code190_payload["generatedFrom"]["officialFullSnapshotRows"],
                "matchingMethod": "For the two explicitly listed code-190 fingerprints only, drop the final zero from an eight-digit decimal token and require an exact unique official row in both the dated district response and canonical Seoul snapshot. Do not infer a mode operator.",
            },
            {
                "id": "seoul-bigdata-subway-stations",
                "title": "서울시 대중교통 및 지하철 1회권 승하차 데이터 - 지하철정보.csv",
                "publisher": "서울특별시 빅데이터캠퍼스",
                "catalogURL": "https://bigdata.seoul.go.kr/data/selectSampleData.do?r_id=P213&sample_data_seq=13",
                "localPath": relative_path(args.seoul_subway_source),
                "datasetDate": "2017-01 to 2026-05",
                "portalModifiedDate": "2026-06-30",
                "retrievedAt": "2026-07-27",
                "license": "Official Seoul Big Data Campus sample data",
                "note": "Official current station IDs, names, operators, and lines. CardBal's versioned relation from the legacy packed-decimal card serial is inferred and stored in a stable-only exact-location crosswalk; three medium-high extension candidates are deliberately excluded.",
                "sourceSHA256": sha256(args.seoul_subway_source),
                "rowCount": 736,
                "matchingMethod": "Require an exact observed 12-character locationCode in the stable crosswalk. Each entry must have high confidence, an official current station row, a validated legacy range/offset rule, and no event dependence. Never direct-join the legacy raw serial to a current public station ID.",
                "crosswalkLocalPath": relative_path(args.capital_rail_crosswalk),
                "crosswalkSHA256": sha256(args.capital_rail_crosswalk),
            },
            {
                "id": "cardbal-additional-capital-rail-high-v1",
                "title": "CardBal additional capital-rail high-confidence crosswalk",
                "publisher": "CardBal research using official station rows",
                "catalogURL": "https://bigdata.seoul.go.kr/data/selectSampleData.do?r_id=P213&sample_data_seq=13",
                "localPath": relative_path(args.additional_capital_rail_crosswalk),
                "datasetDate": "2025-06-13 to 2026-06-30",
                "portalModifiedDate": None,
                "retrievedAt": "2026-07-27",
                "license": "Project research evidence; underlying official datasets retain their published terms",
                "note": "Eighteen exact observed fingerprints are high-confidence legacy-to-current mappings backed by exact cited MOLIT rows; twelve also have exact Seoul table rows. Legacy relations remain CardBal inferences because public MT12/RSI documentation proves internal and external station-number namespaces exist but does not publish the row-level crosswalk. Mode 210 retains institutional operator-code provenance and mode 290 retains corpus/KOTI association provenance. Nine strong hypotheses are stored only as exclusions and are never emitted as aliases.",
                "sourceSHA256": sha256(args.additional_capital_rail_crosswalk),
                "rowCount": additional_capital_rail_payload["coverage"]["locations"],
                "officialSources": additional_capital_rail_payload["sources"],
                "matchingMethod": "Require an exact observed locationCode listed in the high-only artifact, high confidence, no event dependence, an exact cited MOLIT CSV row number/ID/name, and—when present—an exact cited Seoul CSV row. Revalidate both source hashes during every build.",
            },
            {
                "id": "busan-bims-route-stops-20260727",
                "title": "부산광역시 버스정보관리시스템 노선별 정류소 정보",
                "publisher": "부산광역시",
                "catalogURL": "https://www.data.go.kr/data/15092750/openapi.do",
                "localPath": relative_path(args.busan_bims_raw),
                "canonicalLocalPath": relative_path(args.busan_bims_stops),
                "canonicalSHA256": sha256(args.busan_bims_stops),
                "datasetDate": "2026-07-27",
                "portalModifiedDate": None,
                "retrievedAt": busan_bims_payload["source"]["retrievedAt"],
                "license": "Official Busan BIMS public data",
                "note": "The vendored official route-stop download contains 24,756 rows. Its canonical stop export has 4,116 unique valid five-digit ARS IDs with zero collisions. Low16 little-endian decoding of the card token remains a CardBal corpus inference.",
                "sourceSHA256": sha256(args.busan_bims_raw),
                "rowCount": busan_bims_payload["summary"]["routeStopRows"],
                "matchingMethod": "For KOTRIS Busan bus modes only, decode token bytes 07-08 as UInt16 little-endian, zero-pad to five digits, and require one exact collision-free official BIMS ARS match. Never suffix-join BIMS stop IDs or prefix 26.",
            },
            {
                "id": "daegu-transit-line2-section-20251231",
                "title": "대구교통공사_2호선 역 구간정보_20251231",
                "publisher": "대구교통공사",
                "catalogURL": "https://www.data.go.kr/data/15061835/fileData.do",
                "localPath": relative_path(args.daegu_line2),
                "datasetDate": "2025-12-31",
                "portalModifiedDate": None,
                "retrievedAt": "2026-07-27",
                "license": "이용허락범위 제한 없음",
                "note": "Official operator Line 2 station codes and names. CardBal's event-dependent split of the card token and the 10x settlement-ID relation are a high-confidence corpus inference over two observed journeys, not a published operator format.",
                "sourceSHA256": sha256(args.daegu_line2),
                "rowCount": len(daegu_line2_stops),
                "matchingMethod": "For mode 872 only, choose token[0:4] on event 00 or token[4:8] on event 01, require four decimal digits ending in zero, divide by ten, and require an exact operator 역코드 match. Store eventRaw with the alias.",
            },
            {
                "id": "cardbal-user-confirmed-samples",
                "title": "CardBal user-confirmed Korean station samples",
                "publisher": "CardBal contributors",
                "catalogURL": None,
                "localPath": relative_path(args.samples),
                "datasetDate": None,
                "portalModifiedDate": None,
                "retrievedAt": "2026-07-27",
                "license": "Project research evidence",
                "note": "Exact labels supplied for sample records. These aliases are keyed by all six location bytes and are not presented as an official rail station-code crosswalk.",
                "sourceSHA256": sha256(args.samples),
                "rowCount": sum(len(item["sampleIDs"]) for item in samples.values()),
                "matchingMethod": "Exact full bytes 05-10 fingerprint from the supplied raw record.",
            },
            *station_metadata["sources"],
        ],
        "statistics": {
            "corpusRows": len(corpus_records),
            "officialBusRows": official_bus_rows,
            "eligibleBusRows": eligible_bus_rows,
            "exactMatchedRows": matched_rows,
            "exactMatchedLocationCodes": len(official_aliases),
            "exactMatchedSettlementStationIDs": len(matched_station_ids),
            "exactMatchedNames": len(matched_names),
            "transformedRailMatchedRows": transformed_rail_rows + daegu_rail_rows,
            "transformedRailMatchedLocationCodes": len(transformed_rail_aliases) + len(daegu_rail_aliases),
            "transformedRailMatchedStationIDs": len(transformed_rail_station_ids),
            "busanMetroSourceStationIDs": len(busan_metro_stops),
            "busanTransformedRailMatchedRows": transformed_rail_rows,
            "busanTransformedRailMatchedLocationCodes": len(transformed_rail_aliases),
            "daeguTransformedRailMatchedRows": daegu_rail_rows,
            "daeguTransformedRailMatchedLocationCodes": len(daegu_rail_aliases),
            "daeguLine2SourceStationIDs": len(daegu_line2_stops),
            "busanBIMSMatchedRows": busan_bims_rows,
            "busanBIMSMatchedLocationCodes": len(busan_bims_aliases),
            "capitalRailMatchedRows": capital_rail_rows,
            "capitalRailMatchedLocationCodes": len(capital_rail_aliases),
            "capitalRailExcludedReviewRows": (
                capital_rail_payload["coverage"]["records"] - capital_rail_rows
            ),
            "additionalCapitalRailMatchedRows": additional_capital_rail_rows,
            "additionalCapitalRailMatchedLocationCodes": len(
                additional_capital_rail_aliases
            ),
            "additionalCapitalRailHypothesesExcluded": len(
                additional_capital_rail_payload["excludedHypotheses"]
            ),
            "jejuTransformedBusMatchedRows": jeju_rows,
            "jejuTransformedBusMatchedLocationCodes": len(jeju_aliases),
            "jejuSelectorSourceRows": jeju_payload["generatedFrom"]["selectorRows"],
            "seoulCode190PlaceMatchedRows": seoul_code190_rows,
            "seoulCode190PlaceMatchedLocationCodes": len(seoul_code190_aliases),
            "seoulCode190SystemIdentity": "unresolved",
            "userConfirmedLocationCodes": sum(
                alias["provenance"] == "user_confirmed" for alias in aliases
            ),
            "nationalSourceRows": national_rows,
            "nationalAmbiguousStationIDsExcluded": national_ambiguous,
            "coordinateMatchedAliases": sum(
                alias.get("latitude") is not None and alias.get("longitude") is not None
                for alias in aliases
            ),
            "officialEnglishNameAliases": sum(bool(alias.get("nameEnglish")) for alias in aliases),
            "officialHanjaNameAliases": sum(bool(alias.get("nameHanja")) for alias in aliases),
            "officialChineseNameAliases": sum(
                bool(alias.get("nameChineseSimplified") or alias.get("nameChineseTraditional"))
                for alias in aliases
            ),
            "officialTraditionalChineseNameAliases": sum(
                bool(alias.get("nameChineseTraditional")) for alias in aliases
            ),
            "officialJapaneseNameAliases": sum(bool(alias.get("nameJapanese")) for alias in aliases),
            "stationMetadataLocalPath": relative_path(args.station_metadata),
            "stationMetadataSHA256": sha256(args.station_metadata),
        },
        "locations": aliases,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(
        json.dumps(
            {
                "output": relative_path(args.output),
                "snapshot": relative_path(snapshot_path),
                **payload["statistics"],
                "totalAliases": len(aliases),
            },
            ensure_ascii=False,
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
