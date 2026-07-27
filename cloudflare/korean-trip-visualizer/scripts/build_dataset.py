#!/usr/bin/env python3

from __future__ import annotations

import argparse
import csv
import datetime as dt
import json
import math
import os
import sqlite3
import statistics
import subprocess
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any, Iterable


SITE_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = Path(__file__).resolve().parents[3]
WORKER_ROOT = REPO_ROOT / "cloudflare" / "korean-trip-crowdsourcing"
DEFAULT_KNOWN = REPO_ROOT / "transit_record_comparison.tsv"
DEFAULT_SYSTEM_CODES = SITE_ROOT / "scripts/sources/kotris_transport_modes.csv"
DEFAULT_STATION_ALIASES = REPO_ROOT / "CardBal/Resources/KoreanStationAliases.json"
DEFAULT_ACCOUNT_ID = "599ee1cd6c4d3dc453d290c4c0477e76"
DEFAULT_DATABASE = "cardbal-korean-trip-crowdsourcing"
RECORD_BYTES = 52


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Build the public Korean trip visualizer snapshot.")
    parser.add_argument("--output", type=Path, default=SITE_ROOT / "public/data/korean-trips.json")
    parser.add_argument("--known", type=Path, default=DEFAULT_KNOWN)
    parser.add_argument("--system-codes", type=Path, default=DEFAULT_SYSTEM_CODES)
    parser.add_argument("--station-aliases", type=Path, default=DEFAULT_STATION_ALIASES)
    parser.add_argument("--sqlite", type=Path, help="Read a local SQLite export instead of querying D1.")
    parser.add_argument("--database", default=DEFAULT_DATABASE)
    parser.add_argument("--account-id", default=os.environ.get("CLOUDFLARE_ACCOUNT_ID", DEFAULT_ACCOUNT_ID))
    parser.add_argument("--worker-root", type=Path, default=WORKER_ROOT)
    return parser.parse_args()


SYSTEM_CLASS_NAMES = {
    "B": "Bus",
    "R": "Rail",
    "T": "Taxi",
}
OFFICIAL_SYSTEM_STATUSES = {"official_kotris", "official_seoul"}
OFFICIAL_STATION_PROVENANCES = {
    "official_dataset_exact_match",
    "official_dataset_transformed_exact_match",
}

SYSTEM_CODE_SUPPLEMENTS: dict[int, dict[str, Any]] = {
    142: {
        "officialNameKo": "도심순환(142)",
        "transportClass": "B",
        "transportClassName": "Bus",
        "area": "Seoul",
        "matchStatus": "official_seoul",
        "sourceTitle": "Seoul Smart Card transport-code table",
        "sourceURL": "https://bigdata.seoul.go.kr/data/selectSampleData.do?r_id=P213&sample_data_seq=13",
    },
    209: {
        "officialNameKo": "경기철도",
        "transportClass": "R",
        "transportClassName": "Rail",
        "area": "Capital region",
        "matchStatus": "official_seoul",
        "sourceTitle": "Seoul Smart Card transport-code table",
        "sourceURL": "https://bigdata.seoul.go.kr/data/selectSampleData.do?r_id=P213&sample_data_seq=13",
    },
    235: {
        "officialNameKo": "우이신설경전철",
        "transportClass": "R",
        "transportClassName": "Rail",
        "area": "Seoul",
        "matchStatus": "official_seoul",
        "sourceTitle": "Seoul Smart Card transport-code table",
        "sourceURL": "https://bigdata.seoul.go.kr/data/selectSampleData.do?r_id=P213&sample_data_seq=13",
    },
    210: {
        "officialNameKo": "새서울철도㈜",
        "transportClass": "R",
        "transportClassName": "Rail",
        "area": "Capital region",
        "matchStatus": "institutional_reference",
        "sourceTitle": "Incheon Institute, 도시와 대중교통, Table 3",
        "sourceURL": "https://www.ii.re.kr/storage/data/2024/04/30/DATA_ATTACH_1714437784942.pdf",
    },
    237: {
        "officialNameKo": "신림경전철㈜",
        "transportClass": "R",
        "transportClassName": "Rail",
        "area": "Seoul",
        "matchStatus": "institutional_reference",
        "sourceTitle": "Incheon Institute, 도시와 대중교통, Table 3",
        "sourceURL": "https://www.ii.re.kr/storage/data/2024/04/30/DATA_ATTACH_1714437784942.pdf",
    },
    290: {
        "officialNameKo": "GTX-A candidate",
        "transportClass": "R",
        "transportClassName": "Rail",
        "area": "Capital region",
        "matchStatus": "corpus_geometry_inference",
        "sourceTitle": "KOTI GTX-A line reference and CardBal distance geometry",
        "sourceURL": "https://cppr.koti.re.kr/site.do?command=railwyDetail&railwyId=RID241201000022",
    },
}

SYSTEM_ASSOCIATIONS: dict[int, dict[str, str]] = {
    696: {
        "status": "corpus_association",
        "note": "Regional/reserve-family association; both cards also use official code 695.",
    },
    877: {
        "status": "corpus_association",
        "note": "Strong Busan-area association from station-token layout and shared cards with Busan rail and buses.",
    },
    901: {
        "status": "layout_warning",
        "note": "Shares the 00130000 sentinel token with codes 905, 909, and 928; do not treat it as a place label.",
    },
    905: {
        "status": "layout_warning",
        "note": "Shares the 00130000 sentinel token with codes 901, 909, and 928; do not treat it as a place label.",
    },
    909: {
        "status": "layout_warning",
        "note": "Shares the 00130000 sentinel token with codes 901, 905, and 928; do not treat it as a place label.",
    },
    928: {
        "status": "layout_warning",
        "note": "Shares the 00130000 sentinel token with codes 901, 905, and 909; do not treat it as a place label.",
    },
}

for control_code in (0x0000, 0x1000, 0x4000, 0x5000, 0x6000, 0x7000, 0x8000):
    SYSTEM_ASSOCIATIONS[control_code] = {
        "status": "layout_warning",
        "note": "Synthetic-looking control/non-journey layout candidate; transit field slicing is not reliable for this row family.",
    }


def system_area(code: int, name: str) -> str | None:
    """Return a readable area hint without pretending it is a company identifier."""
    explicit = {
        105: "Seoul",
        115: "Seoul",
        120: "Seoul",
        121: "Seoul",
        131: "Seoul",
        201: "Seoul",
        202: "National / KORAIL",
        203: "Seoul",
        204: "Incheon",
        205: "Seoul",
        206: "Airport Railroad",
        207: "Airport Railroad",
        208: "Capital region",
        231: "Yongin",
        232: "Uijeongbu",
        699: "Airport Railroad",
        811: "Airport limousine",
        812: "Airport limousine",
        816: "Airport limousine",
        818: "Airport limousine",
        820: "Airport limousine",
        850: "Light rail",
        851: "Yongin",
        853: "Daejeon",
        870: "Busan",
        871: "Gwangju",
        872: "Daegu",
    }
    if code in explicit:
        return explicit[code]
    markers = (
        ("인천", "Incheon"),
        ("경기", "Gyeonggi"),
        ("부산", "Busan"),
        ("울산", "Ulsan"),
        ("마산/창원/진해", "Changwon / Masan / Jinhae"),
        ("양산", "Yangsan"),
        ("진주", "Jinju"),
        ("김해", "Gimhae"),
        ("밀양", "Miryang"),
        ("함안", "Haman"),
        ("천안", "Cheonan"),
        ("아산", "Asan"),
        ("충남", "Chungnam"),
        ("대전", "Daejeon"),
        ("포항", "Pohang"),
        ("통영", "Tongyeong"),
        ("안동", "Andong"),
        ("거제", "Geoje"),
        ("원주", "Wonju"),
        ("횡성", "Hoengseong"),
        ("춘천", "Chuncheon"),
        ("강릉", "Gangneung"),
        ("강원", "Gangwon"),
        ("광주", "Gwangju"),
        ("순천", "Suncheon"),
        ("목포", "Mokpo"),
        ("광양", "Gwangyang"),
        ("여수", "Yeosu"),
        ("나주", "Naju"),
        ("사천", "Sacheon"),
        ("제주", "Jeju"),
        ("서귀포", "Seogwipo"),
    )
    return next((area for marker, area in markers if marker in name), None)


def read_system_codes(path: Path) -> dict[int, dict[str, Any]]:
    result: dict[int, dict[str, Any]] = {}
    with path.open(encoding="utf-8-sig", newline="") as handle:
        for row in csv.DictReader(handle):
            code = int(row["교통수단코드"])
            name = row["내용"].strip()
            kind = row["구분R철도B버스T택시"].strip()
            result[code] = {
                "decimalCode": code,
                "officialNameKo": name,
                "transportClass": kind,
                "transportClassName": SYSTEM_CLASS_NAMES.get(kind, "Unknown"),
                "area": system_area(code, name),
                "matchStatus": "official_kotris",
                "sourceTitle": "KORAIL KOTRIS public-transport code table",
                "sourceURL": "https://www.data.go.kr/data/15121099/fileData.do",
            }
    for code, supplement in SYSTEM_CODE_SUPPLEMENTS.items():
        if code in result:
            raise ValueError(f"Supplemental transport code {code} conflicts with KOTRIS")
        result[code] = {"decimalCode": code, **supplement}
    return result


def read_rows_from_sqlite(path: Path) -> list[dict[str, Any]]:
    connection = sqlite3.connect(path)
    connection.row_factory = sqlite3.Row
    try:
        result = connection.execute(
            """
            SELECT dedup_hash, hashed_card_id, bytes_05_08,
                   bytes_09_0a, all_bytes, card_family, created_at
            FROM korean_trip_records
            ORDER BY created_at, dedup_hash
            """
        ).fetchall()
        return [dict(row) for row in result]
    finally:
        connection.close()


def read_rows_from_d1(database: str, account_id: str, worker_root: Path) -> list[dict[str, Any]]:
    query = """
        SELECT dedup_hash, hashed_card_id, bytes_05_08,
               bytes_09_0a, all_bytes, card_family, created_at
        FROM korean_trip_records
        ORDER BY created_at, dedup_hash
    """.strip()
    environment = os.environ.copy()
    environment["CLOUDFLARE_ACCOUNT_ID"] = account_id
    command = [
        "wrangler",
        "d1",
        "execute",
        database,
        "--remote",
        "--json",
        "--command",
        query,
    ]
    result = subprocess.run(
        command,
        cwd=worker_root,
        env=environment,
        check=True,
        capture_output=True,
        text=True,
    )
    payload = json.loads(result.stdout)
    if not payload or not payload[0].get("success"):
        raise RuntimeError("D1 query did not return a successful result")
    return payload[0]["results"]


def uint16(data: bytes, offset: int) -> int:
    return int.from_bytes(data[offset : offset + 2], "big")


def operator_field_profile(code: int) -> str:
    if code == 870:
        return "mybi_busan_subway"
    if (
        600 <= code < 619
        or 632 <= code < 637
        or 641 <= code < 661
        or 711 <= code < 714
        or 776 <= code < 800
        or code in (887, 936, 940)
        or 901 <= code < 905
        or 913 <= code < 917
        or 925 <= code < 928
    ):
        return "mybi_busan"
    if (
        621 <= code < 632
        or 637 <= code < 641
        or 684 <= code < 686
        or code in (729, 888)
        or 928 <= code < 932
    ):
        return "mybi_total"
    if code == 691 or 770 <= code < 776 or code == 871:
        return "mybi_gwangju"
    if (
        672 <= code < 684
        or 828 <= code < 831
        or 701 <= code < 704
        or 752 <= code < 756
        or 759 <= code < 763
        or 824 <= code < 826
        or 810 <= code < 821
        or 990 <= code < 1000
        or code == 853
    ):
        return "bcd14_regional"
    return "standard_packed33"


def decode_timestamp(
    data: bytes, created_at: str, system_decimal: int
) -> tuple[str | None, int, str, bool]:
    bcd_hex = data[11:18].hex().upper()
    if bcd_hex.isdecimal():
        try:
            parsed_bcd = dt.datetime.strptime(bcd_hex, "%Y%m%d%H%M%S")
            collected_local = dt.datetime.fromisoformat(created_at) + dt.timedelta(hours=9)
            return (
                parsed_bcd.isoformat(timespec="seconds"),
                0,
                "bcd14",
                parsed_bcd <= collected_local,
            )
        except ValueError:
            pass

    profile = operator_field_profile(system_decimal)
    if profile in ("mybi_busan", "mybi_busan_subway", "mybi_total", "mybi_gwangju"):
        return None, 0, "operator_opaque", False

    raw_date = uint16(data, 11)
    time_word = uint16(data, 13)
    year = 2000 + (raw_date >> 9)
    month = (raw_date >> 5) & 0x0F
    day = raw_date & 0x1F
    hour = time_word >> 11
    minute = (time_word >> 5) & 0x3F
    second = ((time_word & 0x1F) << 1) | (data[15] >> 7)
    try:
        parsed = dt.datetime(year, month, day, hour, minute, second)
    except ValueError:
        return None, 0, "alternate_unknown", False
    collected_local = dt.datetime.fromisoformat(created_at) + dt.timedelta(hours=9)
    plausible = parsed <= collected_local
    return parsed.isoformat(timespec="seconds"), 0, "packed33", plausible


def decode_record(
    row: dict[str, Any],
    known: dict[str, dict[str, Any]],
    system_codes: dict[int, dict[str, Any]],
) -> dict[str, Any]:
    raw = row["all_bytes"].upper()
    data = bytes.fromhex(raw)
    if len(data) != RECORD_BYTES:
        raise ValueError(f"{row['dedup_hash']}: expected {RECORD_BYTES} bytes, got {len(data)}")

    station_code = data[5:9].hex().upper()
    network_code = data[9:11].hex().upper()
    system_decimal = int.from_bytes(data[9:11], "big")
    system = system_codes.get(system_decimal)
    association = SYSTEM_ASSOCIATIONS.get(system_decimal)
    location_code = station_code + network_code
    if station_code != row["bytes_05_08"].upper() or network_code != row["bytes_09_0a"].upper():
        raise ValueError(f"{row['dedup_hash']}: indexed location bytes differ from raw data")

    event_raw = data[2]
    event = "boarding" if event_raw == 0 else "alighting" if event_raw == 1 else "flagged"
    profile = operator_field_profile(system_decimal)
    timestamp, date_flags, timestamp_layout, timestamp_plausible = decode_timestamp(
        data, row["created_at"], system_decimal
    )
    fare22 = uint16(data, 22)
    fare36 = uint16(data, 36)
    fare40 = uint16(data, 40)
    fare50 = uint16(data, 50)
    fare_candidates = (
        (("base40", fare40), ("regional36", fare36), ("primary22", fare22))
        if profile.startswith("mybi_")
        else (("primary22", fare22), ("base40", fare40), ("regional36", fare36))
    )
    selected_fare_item = next(
        ((layout, value) for layout, value in fare_candidates if 0 < value <= 10_000),
        None,
    )
    selected_fare = selected_fare_item[1] if selected_fare_item else None
    known_location = known.get(f"{location_code}:{event_raw}") or known.get(location_code)
    station_id_candidate = (
        station_code[:-1]
        if system
        and system["transportClass"] == "B"
        and station_code.isdecimal()
        and station_code.endswith("0")
        else None
    )

    return {
        "id": row["dedup_hash"],
        "dedupHash": row["dedup_hash"],
        "cardHash": row["hashed_card_id"],
        "family": row["card_family"],
        "createdAt": row["created_at"].replace(" ", "T") + "Z",
        "raw": raw,
        "event": event,
        "eventRaw": event_raw,
        "eventFlags": event_raw & 0xFE,
        "byte03": data[3],
        "tripCounter": data[4],
        "stationToken": station_code,
        "transportModeCode": network_code,
        "systemDecimal": system_decimal,
        "systemOfficialNameKo": system["officialNameKo"] if system else None,
        "systemClass": system["transportClass"] if system else None,
        "systemClassName": system["transportClassName"] if system else None,
        "systemArea": system["area"] if system else None,
        "systemMatchStatus": system["matchStatus"] if system else association["status"] if association else "unmapped",
        "systemSourceTitle": system["sourceTitle"] if system else None,
        "systemSourceURL": system["sourceURL"] if system else None,
        "systemAssociationStatus": association["status"] if association else None,
        "systemAssociationNote": association["note"] if association else None,
        "stationIdCandidate": station_id_candidate,
        "locationCode": location_code,
        "knownEventRaw": known_location["eventRaw"] if known_location else None,
        "knownName": known_location["name"] if known_location else None,
        "knownIdentityName": known_location["identityName"] if known_location else None,
        "knownDisplayNames": known_location["displayNames"] if known_location else None,
        "knownNameEnglish": known_location["nameEnglish"] if known_location else None,
        "knownNameHanja": known_location["nameHanja"] if known_location else None,
        "knownNameChineseSimplified": known_location["nameChineseSimplified"] if known_location else None,
        "knownNameChineseTraditional": known_location["nameChineseTraditional"] if known_location else None,
        "knownNameJapanese": known_location["nameJapanese"] if known_location else None,
        "knownMode": known_location["mode"] if known_location else None,
        "knownProvenance": known_location["provenance"] if known_location else None,
        "knownSourceID": known_location["sourceID"] if known_location else None,
        "knownSourceTitle": known_location["sourceTitle"] if known_location else None,
        "knownSourceURL": known_location["sourceURL"] if known_location else None,
        "knownSourceStationID": known_location["sourceStationID"] if known_location else None,
        "knownMatchingMethod": known_location["matchingMethod"] if known_location else None,
        "knownNameSourceID": known_location["nameSourceID"] if known_location else None,
        "knownNameSourceTitle": known_location["nameSourceTitle"] if known_location else None,
        "knownNameSourceURL": known_location["nameSourceURL"] if known_location else None,
        "knownNameSourceStationID": known_location["nameSourceStationID"] if known_location else None,
        "knownNameMatchingMethod": known_location["nameMatchingMethod"] if known_location else None,
        "knownHanjaSourceID": known_location["hanjaSourceID"] if known_location else None,
        "knownHanjaSourceTitle": known_location["hanjaSourceTitle"] if known_location else None,
        "knownHanjaSourceURL": known_location["hanjaSourceURL"] if known_location else None,
        "knownCoordinateSourceID": known_location["coordinateSourceID"] if known_location else None,
        "knownCoordinateSourceTitle": known_location["coordinateSourceTitle"] if known_location else None,
        "knownCoordinateSourceURL": known_location["coordinateSourceURL"] if known_location else None,
        "knownCoordinateSourceStationID": known_location["coordinateSourceStationID"] if known_location else None,
        "knownCoordinateMatchingMethod": known_location["coordinateMatchingMethod"] if known_location else None,
        "knownSourceStopID": known_location["sourceStopID"] if known_location else None,
        "knownARSID": known_location["arsID"] if known_location else None,
        "knownCtpvName": known_location["ctpvName"] if known_location else None,
        "knownSggName": known_location["sggName"] if known_location else None,
        "knownLatitude": known_location["latitude"] if known_location else None,
        "knownLongitude": known_location["longitude"] if known_location else None,
        "timestamp": timestamp,
        "timestampHex": data[11:18].hex().upper(),
        "dateFlags": date_flags,
        "timestampLayout": timestamp_layout,
        "timestampPlausible": timestamp_plausible,
        "operatorFieldProfile": profile,
        "operatorClockA": int.from_bytes(data[11:14], "big") if profile.startswith("mybi_") else None,
        "operatorClockB": int.from_bytes(data[14:17], "big") if profile.startswith("mybi_") else None,
        "operatorClockFlag": data[17] if profile.startswith("mybi_") else None,
        "distanceMeters": uint16(data, 19),
        "legacyDistanceMeters": int.from_bytes(data[18:21], "big"),
        "fare22": fare22,
        "fare36": fare36,
        "fare40": fare40,
        "fare50": fare50,
        "selectedFare": selected_fare,
        "fareLayout": selected_fare_item[0] if selected_fare_item else "unresolved",
        "terminalReference": data[24:28].hex().upper(),
    }


def read_known_locations(
    path: Path,
    station_aliases_path: Path,
    system_codes: dict[int, dict[str, Any]],
) -> tuple[dict[str, dict[str, Any]], list[dict[str, Any]]]:
    grouped: dict[str, dict[str, Any]] = {}
    evidence: list[dict[str, Any]] = []

    alias_payload = json.loads(station_aliases_path.read_text(encoding="utf-8"))
    alias_sources = {source["id"]: source for source in alias_payload["sources"]}

    def source_url(source: dict[str, Any]) -> str | None:
        return source.get("catalogURL") or source.get("sourceURL") or source.get("url")

    for alias in alias_payload["locations"]:
        mode = system_codes.get(alias["transportModeCode"])
        mode_label = {
            "B": "bus",
            "R": "subway / rail",
            "T": "taxi",
        }.get(mode["transportClass"] if mode else "", "unknown")
        source = alias_sources[alias["sourceID"]]
        has_multilingual_name = any(
            alias.get(field)
            for field in (
                "nameEnglish",
                "nameHanja",
                "nameChineseSimplified",
                "nameChineseTraditional",
                "nameJapanese",
            )
        )
        name_source_id = alias.get("nameSourceID") or (alias["sourceID"] if has_multilingual_name else None)
        name_source = alias_sources.get(name_source_id) if name_source_id else None
        if name_source_id and name_source is None:
            raise ValueError(f"{alias['locationCode']}: missing name source {name_source_id}")
        hanja_source_id = alias.get("nameHanjaSourceID") or (
            name_source_id if alias.get("nameHanja") else None
        )
        hanja_source = alias_sources.get(hanja_source_id) if hanja_source_id else None
        if hanja_source_id and hanja_source is None:
            raise ValueError(f"{alias['locationCode']}: missing Hanja source {hanja_source_id}")
        latitude = alias.get("latitude")
        longitude = alias.get("longitude")
        if (latitude is None) != (longitude is None):
            raise ValueError(f"{alias['locationCode']}: incomplete coordinate pair")
        has_coordinates = latitude is not None and longitude is not None
        if has_coordinates and (
            not isinstance(latitude, (int, float))
            or not isinstance(longitude, (int, float))
            or not math.isfinite(latitude)
            or not math.isfinite(longitude)
            or not 32 <= latitude <= 40
            or not 123 <= longitude <= 133
        ):
            raise ValueError(f"{alias['locationCode']}: invalid South Korea coordinates")
        coordinate_source_id = alias.get("coordinateSourceID") or (
            alias["sourceID"] if has_coordinates else None
        )
        coordinate_source = alias_sources.get(coordinate_source_id) if coordinate_source_id else None
        if coordinate_source_id and coordinate_source is None:
            raise ValueError(
                f"{alias['locationCode']}: missing coordinate source {coordinate_source_id}"
            )
        if not has_coordinates and any(
            alias.get(field)
            for field in (
                "coordinateSourceID",
                "coordinateSourceStationID",
                "coordinateMatchingMethod",
            )
        ):
            raise ValueError(
                f"{alias['locationCode']}: coordinate provenance without coordinates"
            )
        event_raw = alias.get("eventRaw")
        alias_key = alias["locationCode"] if event_raw is None else f"{alias['locationCode']}:{event_raw}"
        grouped[alias_key] = {
            "code": alias["locationCode"],
            "name": alias.get("nameCanonicalKo") or alias["name"],
            "identityName": alias["name"],
            "displayNames": {
                "ko": alias.get("nameCanonicalKo") or alias["name"],
                "en": alias.get("nameEnglish"),
                "hanja": alias.get("nameHanja"),
                "zhHans": alias.get("nameChineseSimplified"),
                "zhHant": alias.get("nameChineseTraditional"),
                "ja": alias.get("nameJapanese"),
            },
            "nameEnglish": alias.get("nameEnglish"),
            "nameHanja": alias.get("nameHanja"),
            "nameChineseSimplified": alias.get("nameChineseSimplified"),
            "nameChineseTraditional": alias.get("nameChineseTraditional"),
            "nameJapanese": alias.get("nameJapanese"),
            "mode": mode_label,
            "sampleIds": list(alias.get("userConfirmedSampleIDs") or []),
            "provenance": alias["provenance"],
            "sourceID": alias["sourceID"],
            "sourceTitle": source["title"],
            "sourceURL": source_url(source),
            "sourceNote": source.get("note"),
            "sourceStationID": alias.get("sourceStationID"),
            "matchingMethod": alias.get("matchingMethod"),
            "nameSourceID": name_source_id,
            "nameSourceTitle": name_source.get("title") if name_source else None,
            "nameSourceURL": source_url(name_source) if name_source else None,
            "nameSourceNote": name_source.get("note") if name_source else None,
            "nameSourceStationID": alias.get("nameSourceStationID"),
            "nameMatchingMethod": alias.get("nameMatchingMethod"),
            "hanjaSourceID": hanja_source_id,
            "hanjaSourceTitle": hanja_source.get("title") if hanja_source else None,
            "hanjaSourceURL": source_url(hanja_source) if hanja_source else None,
            "hanjaSourceNote": hanja_source.get("note") if hanja_source else None,
            "coordinateSourceID": coordinate_source_id,
            "coordinateSourceTitle": coordinate_source.get("title") if coordinate_source else None,
            "coordinateSourceURL": source_url(coordinate_source) if coordinate_source else None,
            "coordinateSourceNote": coordinate_source.get("note") if coordinate_source else None,
            "coordinateSourceStationID": alias.get("coordinateSourceStationID")
            or (alias.get("sourceStationID") if has_coordinates else None),
            "coordinateMatchingMethod": alias.get("coordinateMatchingMethod")
            or (alias.get("matchingMethod") if has_coordinates else None),
            "sourceStopID": alias.get("sourceStopID"),
            "arsID": alias.get("arsID"),
            "ctpvName": alias.get("ctpvName"),
            "sggName": alias.get("sggName"),
            "latitude": latitude,
            "longitude": longitude,
            "eventRaw": event_raw,
        }

    with path.open(encoding="utf-8", newline="") as handle:
        for row in csv.DictReader(handle, delimiter="\t"):
            raw = row["record_hex"].upper()
            location_code = raw[5 * 2 : 11 * 2]
            grouped_item = next(
                (item for item in grouped.values() if item["code"] == location_code),
                None,
            )
            if grouped_item is None:
                grouped[location_code] = {
                    "code": location_code,
                    "name": row["location_label"],
                    "identityName": row["location_label"],
                    "displayNames": {
                        "ko": row["location_label"],
                        "en": None,
                        "hanja": None,
                        "zhHans": None,
                        "zhHant": None,
                        "ja": None,
                    },
                    "nameEnglish": None,
                    "nameHanja": None,
                    "nameChineseSimplified": None,
                    "nameChineseTraditional": None,
                    "nameJapanese": None,
                    "mode": row["mode"],
                    "sampleIds": [],
                    "provenance": "user_confirmed",
                    "sourceID": "cardbal-user-confirmed-samples",
                    "sourceTitle": "CardBal user-confirmed Korean station samples",
                    "sourceURL": None,
                    "sourceNote": "User-confirmed CardBal samples; no official translated names or coordinates are inferred.",
                    "sourceStationID": None,
                    "matchingMethod": "user_confirmed_full_fingerprint",
                    "nameSourceID": None,
                    "nameSourceTitle": None,
                    "nameSourceURL": None,
                    "nameSourceNote": None,
                    "nameSourceStationID": None,
                    "nameMatchingMethod": None,
                    "hanjaSourceID": None,
                    "hanjaSourceTitle": None,
                    "hanjaSourceURL": None,
                    "hanjaSourceNote": None,
                    "coordinateSourceID": None,
                    "coordinateSourceTitle": None,
                    "coordinateSourceURL": None,
                    "coordinateSourceNote": None,
                    "coordinateSourceStationID": None,
                    "coordinateMatchingMethod": None,
                    "sourceStopID": None,
                    "arsID": None,
                    "ctpvName": None,
                    "sggName": None,
                    "latitude": None,
                    "longitude": None,
                    "eventRaw": None,
                }
                grouped_item = grouped[location_code]
            if row["sample_id"] not in grouped_item["sampleIds"]:
                grouped_item["sampleIds"].append(row["sample_id"])
            evidence.append(
                {
                    "sampleId": row["sample_id"],
                    "locationCode": location_code,
                    "name": row["location_label"],
                    "mode": row["mode"],
                    "event": row["event"],
                    "trip": row["trip_label"],
                    "notes": row["notes"],
                    "duplicateOf": row["duplicate_of"] or None,
                    "raw": raw,
                }
            )
    return grouped, evidence


def entropy(values: Iterable[int]) -> float:
    counts = Counter(values)
    total = sum(counts.values())
    return -sum((count / total) * math.log2(count / total) for count in counts.values())


def percentile(values: list[float], fraction: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    return ordered[round((len(ordered) - 1) * fraction)]


def aggregate_locations(records: list[dict[str, Any]], known: dict[str, dict[str, Any]]) -> list[dict[str, Any]]:
    groups: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for record in records:
        groups[record["locationCode"]].append(record)

    result = []
    for code, items in groups.items():
        known_record = next((item for item in items if item["knownName"]), None)
        result.append(
            {
                "code": code,
                "stationToken": items[0]["stationToken"],
                "transportModeCode": items[0]["transportModeCode"],
                "systemDecimal": items[0]["systemDecimal"],
                "systemOfficialNameKo": items[0]["systemOfficialNameKo"],
                "systemClass": items[0]["systemClass"],
                "systemClassName": items[0]["systemClassName"],
                "systemArea": items[0]["systemArea"],
                "systemMatchStatus": items[0]["systemMatchStatus"],
                "systemSourceTitle": items[0]["systemSourceTitle"],
                "systemSourceURL": items[0]["systemSourceURL"],
                "systemAssociationStatus": items[0]["systemAssociationStatus"],
                "systemAssociationNote": items[0]["systemAssociationNote"],
                "stationIdCandidate": items[0]["stationIdCandidate"],
                "name": known_record["knownName"] if known_record else None,
                "identityName": known_record["knownIdentityName"] if known_record else None,
                "displayNames": known_record["knownDisplayNames"] if known_record else None,
                "nameEnglish": known_record["knownNameEnglish"] if known_record else None,
                "nameHanja": known_record["knownNameHanja"] if known_record else None,
                "nameChineseSimplified": known_record["knownNameChineseSimplified"] if known_record else None,
                "nameChineseTraditional": known_record["knownNameChineseTraditional"] if known_record else None,
                "nameJapanese": known_record["knownNameJapanese"] if known_record else None,
                "mode": known_record["knownMode"] if known_record else None,
                "provenance": known_record["knownProvenance"] if known_record else None,
                "sourceID": known_record["knownSourceID"] if known_record else None,
                "sourceTitle": known_record["knownSourceTitle"] if known_record else None,
                "sourceURL": known_record["knownSourceURL"] if known_record else None,
                "sourceStationID": known_record["knownSourceStationID"] if known_record else None,
                "matchingMethod": known_record["knownMatchingMethod"] if known_record else None,
                "nameSourceID": known_record["knownNameSourceID"] if known_record else None,
                "nameSourceTitle": known_record["knownNameSourceTitle"] if known_record else None,
                "nameSourceURL": known_record["knownNameSourceURL"] if known_record else None,
                "nameSourceStationID": known_record["knownNameSourceStationID"] if known_record else None,
                "nameMatchingMethod": known_record["knownNameMatchingMethod"] if known_record else None,
                "hanjaSourceID": known_record["knownHanjaSourceID"] if known_record else None,
                "hanjaSourceTitle": known_record["knownHanjaSourceTitle"] if known_record else None,
                "hanjaSourceURL": known_record["knownHanjaSourceURL"] if known_record else None,
                "coordinateSourceID": known_record["knownCoordinateSourceID"] if known_record else None,
                "coordinateSourceTitle": known_record["knownCoordinateSourceTitle"] if known_record else None,
                "coordinateSourceURL": known_record["knownCoordinateSourceURL"] if known_record else None,
                "coordinateSourceStationID": known_record["knownCoordinateSourceStationID"] if known_record else None,
                "coordinateMatchingMethod": known_record["knownCoordinateMatchingMethod"] if known_record else None,
                "sourceStopID": known_record["knownSourceStopID"] if known_record else None,
                "arsID": known_record["knownARSID"] if known_record else None,
                "ctpvName": known_record["knownCtpvName"] if known_record else None,
                "sggName": known_record["knownSggName"] if known_record else None,
                "latitude": known_record["knownLatitude"] if known_record else None,
                "longitude": known_record["knownLongitude"] if known_record else None,
                "records": len(items),
                "cards": len({item["cardHash"] for item in items}),
                "boarding": sum(item["event"] == "boarding" for item in items),
                "alighting": sum(item["event"] == "alighting" for item in items),
                "flagged": sum(item["event"] == "flagged" for item in items),
                "families": dict(Counter(item["family"] for item in items)),
                "firstCollected": min(item["createdAt"] for item in items),
                "lastCollected": max(item["createdAt"] for item in items),
                "firstTrip": min(
                    (
                        item["timestamp"]
                        for item in items
                        if item["timestamp"] and item["timestampPlausible"]
                    ),
                    default=None,
                ),
                "lastTrip": max(
                    (
                        item["timestamp"]
                        for item in items
                        if item["timestamp"] and item["timestampPlausible"]
                    ),
                    default=None,
                ),
            }
        )
    return sorted(result, key=lambda item: (-item["records"], item["code"]))


def aggregate_networks(records: list[dict[str, Any]], known: dict[str, dict[str, Any]]) -> list[dict[str, Any]]:
    groups: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for record in records:
        groups[record["transportModeCode"]].append(record)
    result = []
    for code, items in groups.items():
        known_names = sorted(
            {
                item["knownName"]
                for item in items
                if item["knownName"]
            }
        )
        result.append(
            {
                "code": code,
                "decimalCode": items[0]["systemDecimal"],
                "officialNameKo": items[0]["systemOfficialNameKo"],
                "transportClass": items[0]["systemClass"],
                "transportClassName": items[0]["systemClassName"],
                "area": items[0]["systemArea"],
                "matchStatus": items[0]["systemMatchStatus"],
                "sourceTitle": items[0]["systemSourceTitle"],
                "sourceURL": items[0]["systemSourceURL"],
                "associationNote": items[0]["systemAssociationNote"],
                "records": len(items),
                "cards": len({item["cardHash"] for item in items}),
                "locations": len({item["locationCode"] for item in items}),
                "knownLocations": known_names,
                "families": dict(Counter(item["family"] for item in items)),
                "timestampLayouts": dict(Counter(item["timestampLayout"] for item in items)),
            }
        )
    return sorted(result, key=lambda item: (-item["records"], item["code"]))


def aggregate_cards(records: list[dict[str, Any]]) -> list[dict[str, Any]]:
    groups: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for record in records:
        groups[record["cardHash"]].append(record)
    cards = []
    for card_hash, items in groups.items():
        cards.append(
            {
                "hash": card_hash,
                "records": len(items),
                "families": dict(Counter(item["family"] for item in items)),
                "locations": len({item["locationCode"] for item in items}),
                "knownLocations": len({item["locationCode"] for item in items if item["knownName"]}),
                "firstCollected": min(item["createdAt"] for item in items),
                "lastCollected": max(item["createdAt"] for item in items),
                "firstTrip": min(
                    (
                        item["timestamp"]
                        for item in items
                        if item["timestamp"] and item["timestampPlausible"]
                    ),
                    default=None,
                ),
                "lastTrip": max(
                    (
                        item["timestamp"]
                        for item in items
                        if item["timestamp"] and item["timestampPlausible"]
                    ),
                    default=None,
                ),
            }
        )
    return sorted(cards, key=lambda item: (-item["records"], item["hash"]))


def build_journeys(records: list[dict[str, Any]]) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    by_card: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for record in records:
        if (
            record["timestamp"]
            and record["timestampPlausible"]
            and record["event"] in ("boarding", "alighting")
        ):
            by_card[record["cardHash"]].append(record)

    journeys: list[dict[str, Any]] = []
    for card_hash, items in by_card.items():
        items.sort(key=lambda item: (item["timestamp"], item["dedupHash"]))
        used_alightings: set[int] = set()
        for index, boarding in enumerate(items):
            if boarding["event"] != "boarding":
                continue
            boarded_at = dt.datetime.fromisoformat(boarding["timestamp"])
            match: tuple[int, dict[str, Any], float] | None = None
            for candidate_index in range(index + 1, len(items)):
                if candidate_index in used_alightings:
                    continue
                alighting = items[candidate_index]
                if alighting["event"] != "alighting":
                    continue
                alighted_at = dt.datetime.fromisoformat(alighting["timestamp"])
                seconds = (alighted_at - boarded_at).total_seconds()
                if seconds < 0:
                    continue
                if seconds > 8 * 60 * 60:
                    break
                if alighting["tripCounter"] == boarding["tripCounter"]:
                    match = (candidate_index, alighting, seconds)
                    break
            if not match:
                continue
            candidate_index, alighting, seconds = match
            used_alightings.add(candidate_index)
            journeys.append(
                {
                    "id": f"{boarding['dedupHash'][:12]}-{alighting['dedupHash'][:12]}",
                    "cardHash": card_hash,
                    "family": boarding["family"],
                    "tripCounter": boarding["tripCounter"],
                    "fromCode": boarding["locationCode"],
                    "fromName": boarding["knownName"],
                    "toCode": alighting["locationCode"],
                    "toName": alighting["knownName"],
                    "boardedAt": boarding["timestamp"],
                    "alightedAt": alighting["timestamp"],
                    "durationMinutes": round(seconds / 60, 1),
                    "distanceMeters": alighting["distanceMeters"],
                    "fare": alighting["selectedFare"],
                    "boardingRecord": boarding["dedupHash"],
                    "alightingRecord": alighting["dedupHash"],
                }
            )

    flow_groups: dict[tuple[str, str], list[dict[str, Any]]] = defaultdict(list)
    for journey in journeys:
        flow_groups[(journey["fromCode"], journey["toCode"])].append(journey)
    flows = []
    for (from_code, to_code), items in flow_groups.items():
        durations = [item["durationMinutes"] for item in items]
        distances = [item["distanceMeters"] for item in items if item["distanceMeters"] > 0]
        flows.append(
            {
                "fromCode": from_code,
                "fromName": items[0]["fromName"],
                "toCode": to_code,
                "toName": items[0]["toName"],
                "journeys": len(items),
                "cards": len({item["cardHash"] for item in items}),
                "medianMinutes": round(statistics.median(durations), 1),
                "medianDistanceMeters": round(statistics.median(distances)) if distances else None,
                "families": dict(Counter(item["family"] for item in items)),
            }
        )
    journeys.sort(key=lambda item: item["boardedAt"], reverse=True)
    flows.sort(key=lambda item: (-item["journeys"], item["fromCode"], item["toCode"]))
    return journeys, flows


def timestamp_evidence(records: list[dict[str, Any]]) -> dict[str, int]:
    by_card: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for record in records:
        by_card[record["cardHash"]].append(record)

    bitfield_exact = 0
    bitfield_near = 0
    day_counter_exact = 0
    epoch = dt.date(1989, 6, 14)
    for items in by_card.values():
        collected = max(dt.datetime.fromisoformat(item["createdAt"].removesuffix("Z")).date() for item in items)
        decoded_dates = [
            dt.datetime.fromisoformat(item["timestamp"]).date()
            for item in items
            if item["timestamp"]
            and item["timestampLayout"] == "packed33"
            and item["timestampPlausible"]
            and dt.datetime.fromisoformat(item["timestamp"]).date() <= collected + dt.timedelta(days=2)
        ]
        if decoded_dates:
            difference = (collected - max(decoded_dates)).days
            bitfield_exact += difference == 0
            bitfield_near += abs(difference) <= 2

        day_dates = []
        for item in items:
            data = bytes.fromhex(item["raw"])
            day_dates.append(epoch + dt.timedelta(days=uint16(data, 11) & 0x3FFF))
        plausible_days = [value for value in day_dates if value <= collected + dt.timedelta(days=2)]
        if plausible_days:
            day_counter_exact += (collected - max(plausible_days)).days == 0
    return {
        "bitfieldExactCardScans": bitfield_exact,
        "bitfieldWithinTwoDaysCardScans": bitfield_near,
        "dayCounterExactCardScans": day_counter_exact,
    }


def build_payload(
    rows: list[dict[str, Any]],
    known: dict[str, dict[str, Any]],
    evidence: list[dict[str, Any]],
    system_codes: dict[int, dict[str, Any]],
) -> dict[str, Any]:
    records = [decode_record(row, known, system_codes) for row in rows]
    locations = aggregate_locations(records, known)
    networks = aggregate_networks(records, known)
    cards = aggregate_cards(records)
    journeys, flows = build_journeys(records)
    raw_record_counts = Counter(record["raw"] for record in records)
    field_stats = []
    for offset in range(RECORD_BYTES):
        values = [bytes.fromhex(record["raw"])[offset] for record in records]
        counts = Counter(values)
        field_stats.append(
            {
                "offset": offset,
                "distinct": len(counts),
                "entropy": round(entropy(values), 3),
                "top": [
                    {"hex": f"{value:02X}", "count": count}
                    for value, count in counts.most_common(6)
                ],
            }
        )

    confirmed_rows = sum(record["knownName"] is not None for record in records)
    official_station_rows = sum(
        record["knownProvenance"] in OFFICIAL_STATION_PROVENANCES for record in records
    )
    official_exact_station_rows = sum(
        record["knownProvenance"] == "official_dataset_exact_match" for record in records
    )
    official_transformed_station_rows = sum(
        record["knownProvenance"] == "official_dataset_transformed_exact_match"
        for record in records
    )
    busan_bims_station_rows = sum(
        record["knownMatchingMethod"] == "busan_bims_low16le_ars_exact"
        for record in records
    )
    busan_metro_station_rows = sum(
        record["knownMatchingMethod"] == "busan_mybi_station_byte"
        for record in records
    )
    daegu_station_rows = sum(
        record["knownMatchingMethod"] == "daegu_event_split_station_id_v1"
        for record in records
    )
    capital_rail_station_rows = sum(
        (record["knownMatchingMethod"] or "").startswith("capital_rail_")
        for record in records
    )
    additional_capital_rail_station_rows = sum(
        record["knownMatchingMethod"] == "capital_rail_additional_high_exact_location"
        for record in records
    )
    jeju_station_rows = sum(
        record["knownMatchingMethod"] == "jeju_station_variant_digit_exact"
        for record in records
    )
    unresolved_system_place_rows = sum(
        record["knownMatchingMethod"]
        == "seoul_code190_settlement_exact_unresolved_system"
        for record in records
    )
    user_confirmed_station_rows = sum(
        record["knownProvenance"] == "user_confirmed" for record in records
    )
    coordinate_rows = sum(
        record["knownLatitude"] is not None and record["knownLongitude"] is not None
        for record in records
    )
    english_name_rows = sum(bool(record["knownNameEnglish"]) for record in records)
    hanja_name_rows = sum(bool(record["knownNameHanja"]) for record in records)
    chinese_name_rows = sum(
        bool(record["knownNameChineseSimplified"] or record["knownNameChineseTraditional"])
        for record in records
    )
    japanese_name_rows = sum(bool(record["knownNameJapanese"]) for record in records)
    multilingual_name_rows = sum(
        bool(
            record["knownNameEnglish"]
            or record["knownNameChineseSimplified"]
            or record["knownNameChineseTraditional"]
            or record["knownNameJapanese"]
        )
        for record in records
    )

    def matched_alias_keys(predicate: Any) -> set[tuple[str, int | None]]:
        return {
            (record["locationCode"], record["knownEventRaw"])
            for record in records
            if predicate(record)
        }

    coordinate_location_keys = matched_alias_keys(
        lambda record: record["knownLatitude"] is not None
        and record["knownLongitude"] is not None
    )
    english_name_location_keys = matched_alias_keys(lambda record: bool(record["knownNameEnglish"]))
    hanja_name_location_keys = matched_alias_keys(lambda record: bool(record["knownNameHanja"]))
    chinese_name_location_keys = matched_alias_keys(
        lambda record: bool(
            record["knownNameChineseSimplified"] or record["knownNameChineseTraditional"]
        )
    )
    japanese_name_location_keys = matched_alias_keys(lambda record: bool(record["knownNameJapanese"]))
    multilingual_name_location_keys = matched_alias_keys(
        lambda record: bool(
            record["knownNameEnglish"]
            or record["knownNameChineseSimplified"]
            or record["knownNameChineseTraditional"]
            or record["knownNameJapanese"]
        )
    )
    decoded_timestamps = sum(record["timestamp"] is not None for record in records)
    plausible_timestamps = sum(record["timestampPlausible"] for record in records)
    timestamp_layouts = Counter(record["timestampLayout"] for record in records)
    exact_events = sum(record["event"] != "flagged" for record in records)
    exit_records = [record for record in records if record["event"] == "alighting"]
    entry_records = [record for record in records if record["event"] == "boarding"]
    timestamp_comparison = timestamp_evidence(records)
    official_system_rows = sum(
        record["systemMatchStatus"] in OFFICIAL_SYSTEM_STATUSES for record in records
    )
    official_system_codes = sum(
        network["matchStatus"] in OFFICIAL_SYSTEM_STATUSES for network in networks
    )
    official_system_locations = len(
        {
            record["locationCode"]
            for record in records
            if record["systemMatchStatus"] in OFFICIAL_SYSTEM_STATUSES
        }
    )
    official_system_station_codes = len(
        {
            record["stationToken"]
            for record in records
            if record["systemMatchStatus"] in OFFICIAL_SYSTEM_STATUSES
        }
    )
    official_system_cards = len(
        {
            record["cardHash"]
            for record in records
            if record["systemMatchStatus"] in OFFICIAL_SYSTEM_STATUSES
        }
    )

    known_locations = []
    for alias_key, item in known.items():
        matching_records = [
            record
            for record in records
            if record["locationCode"] == item["code"]
            and (item["eventRaw"] is None or record["eventRaw"] == item["eventRaw"])
        ]
        known_locations.append(
            {
                **item,
                "aliasKey": alias_key,
                "records": len(matching_records),
                "cards": len({record["cardHash"] for record in matching_records}),
            }
        )
    known_locations.sort(key=lambda item: (-item["records"], item["code"]))

    distances = [record["distanceMeters"] for record in exit_records if record["distanceMeters"] > 0]
    payload = {
        "meta": {
            "title": "Korean Trip Atlas",
            "format": "cardbal-korean-trip-atlas-v3",
            "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
            "sourceFirstSeen": min(record["createdAt"] for record in records),
            "sourceLastSeen": max(record["createdAt"] for record in records),
            "recordBytes": RECORD_BYTES,
            "method": "All D1 rows and raw 52-byte records retained; card identifiers are published only as full SHA-256 hashes and plaintext last-four fragments are omitted.",
        },
        "summary": {
            "records": len(records),
            "cards": len(cards),
            "families": dict(Counter(record["family"] for record in records)),
            "locations": len(locations),
            "stationTokens": len({record["stationToken"] for record in records}),
            "transportModeCodes": len(networks),
            "knownLocations": len(known_locations),
            "confirmedRows": confirmed_rows,
            "confirmedCoverage": round(confirmed_rows / len(records) * 100, 1),
            "officialStationRows": official_station_rows,
            "officialStationCoverage": round(official_station_rows / len(records) * 100, 1),
            "officialStationLocations": sum(
                location["provenance"] in OFFICIAL_STATION_PROVENANCES
                for location in locations
            ),
            "officialExactStationRows": official_exact_station_rows,
            "officialExactStationLocations": sum(
                location["provenance"] == "official_dataset_exact_match"
                for location in locations
            ),
            "officialTransformedStationRows": official_transformed_station_rows,
            "officialTransformedStationLocations": sum(
                location["provenance"] == "official_dataset_transformed_exact_match"
                for location in locations
            ),
            "busanBIMSStationRows": busan_bims_station_rows,
            "busanBIMSStationLocations": sum(
                location["matchingMethod"] == "busan_bims_low16le_ars_exact"
                for location in locations
            ),
            "busanMetroStationRows": busan_metro_station_rows,
            "busanMetroStationLocations": sum(
                location["matchingMethod"] == "busan_mybi_station_byte"
                for location in locations
            ),
            "daeguStationRows": daegu_station_rows,
            "daeguStationLocations": sum(
                location["matchingMethod"] == "daegu_event_split_station_id_v1"
                for location in locations
            ),
            "capitalRailStationRows": capital_rail_station_rows,
            "capitalRailStationLocations": sum(
                (location["matchingMethod"] or "").startswith("capital_rail_")
                for location in locations
            ),
            "additionalCapitalRailStationRows": additional_capital_rail_station_rows,
            "additionalCapitalRailStationLocations": sum(
                location["matchingMethod"]
                == "capital_rail_additional_high_exact_location"
                for location in locations
            ),
            "jejuStationRows": jeju_station_rows,
            "jejuStationLocations": sum(
                location["matchingMethod"] == "jeju_station_variant_digit_exact"
                for location in locations
            ),
            "unresolvedSystemPlaceRows": unresolved_system_place_rows,
            "unresolvedSystemPlaceLocations": sum(
                location["matchingMethod"]
                == "seoul_code190_settlement_exact_unresolved_system"
                for location in locations
            ),
            "officialStationIDs": len(
                {
                    record["knownSourceStationID"]
                    for record in records
                    if record["knownProvenance"] in OFFICIAL_STATION_PROVENANCES
                    and record["knownSourceStationID"]
                }
            ),
            "userConfirmedStationRows": user_confirmed_station_rows,
            "userConfirmedStationLocations": sum(
                location["provenance"] == "user_confirmed" for location in locations
            ),
            "coordinateRows": coordinate_rows,
            "coordinateCoverage": round(coordinate_rows / len(records) * 100, 1),
            "coordinateLocations": len(coordinate_location_keys),
            "coordinateAliases": sum(
                item["latitude"] is not None and item["longitude"] is not None
                for item in known_locations
            ),
            "multilingualNameRows": multilingual_name_rows,
            "multilingualNameCoverage": round(multilingual_name_rows / len(records) * 100, 1),
            "multilingualNameLocations": len(multilingual_name_location_keys),
            "englishNameRows": english_name_rows,
            "englishNameCoverage": round(english_name_rows / len(records) * 100, 1),
            "englishNameLocations": len(english_name_location_keys),
            "hanjaNameRows": hanja_name_rows,
            "hanjaNameCoverage": round(hanja_name_rows / len(records) * 100, 1),
            "hanjaNameLocations": len(hanja_name_location_keys),
            "chineseNameRows": chinese_name_rows,
            "chineseNameCoverage": round(chinese_name_rows / len(records) * 100, 1),
            "chineseNameLocations": len(chinese_name_location_keys),
            "japaneseNameRows": japanese_name_rows,
            "japaneseNameCoverage": round(japanese_name_rows / len(records) * 100, 1),
            "japaneseNameLocations": len(japanese_name_location_keys),
            "uniqueRawRecords": len(raw_record_counts),
            "duplicateRawRows": sum(count - 1 for count in raw_record_counts.values()),
            "decodedTimestamps": decoded_timestamps,
            "plausibleTimestamps": plausible_timestamps,
            "timestampCoverage": round(plausible_timestamps / len(records) * 100, 1),
            "timestampLayouts": dict(timestamp_layouts),
            "futureTimestampCandidates": sum(
                record["timestamp"] is not None and not record["timestampPlausible"]
                for record in records
            ),
            "exactEvents": exact_events,
            "eventCoverage": round(exact_events / len(records) * 100, 1),
            "officialSystemCodes": official_system_codes,
            "unmappedSystemCodes": sum(
                network["matchStatus"] == "unmapped" for network in networks
            ),
            "associatedSystemCodes": sum(
                network["matchStatus"] == "corpus_association" for network in networks
            ),
            "institutionalReferenceSystemCodes": sum(
                network["matchStatus"] == "institutional_reference" for network in networks
            ),
            "corpusInferenceSystemCodes": sum(
                network["matchStatus"] == "corpus_geometry_inference" for network in networks
            ),
            "attributedSystemRows": sum(
                record["systemMatchStatus"] != "unmapped" for record in records
            ),
            "layoutWarningSystemCodes": sum(
                network["matchStatus"] == "layout_warning" for network in networks
            ),
            "officialSystemRows": official_system_rows,
            "officialSystemCoverage": round(official_system_rows / len(records) * 100, 1),
            "officialSystemLocations": official_system_locations,
            "officialSystemStationTokens": official_system_station_codes,
            "officialSystemCards": official_system_cards,
            "stationIdCandidateRows": sum(record["stationIdCandidate"] is not None for record in records),
            "pairedJourneys": len(journeys),
            "journeyFlows": len(flows),
            "exitDistanceRows": sum(record["distanceMeters"] > 0 for record in exit_records),
            "entryDistanceZeroRows": sum(record["distanceMeters"] == 0 for record in entry_records),
            "medianExitDistanceMeters": round(statistics.median(distances)) if distances else None,
            "p95ExitDistanceMeters": round(percentile([float(value) for value in distances], 0.95) or 0),
            **timestamp_comparison,
        },
        "knownLocations": known_locations,
        "knownEvidence": evidence,
        "fieldStats": field_stats,
        "locations": locations,
        "networks": networks,
        "cards": cards,
        "journeys": journeys,
        "flows": flows,
        "records": records,
        "sources": [
            {
                "title": "KORAIL KOTRIS public-transport code table",
                "url": "https://www.data.go.kr/data/15121099/fileData.do",
                "note": "Official unrestricted 319-row table (source date 2023-08-25; catalog modified 2025-09-03). Applying the table to card bytes 09-10 is a CardBal corpus inference.",
            },
            {
                "title": "Seoul Smart Card transport-code table",
                "url": "https://bigdata.seoul.go.kr/data/selectSampleData.do?r_id=P213&sample_data_seq=13",
                "note": "Official Seoul/Smart Card monthly code table (updated 2026-06-30). Exact rows supply observed codes 142 (도심순환), 209 (경기철도), and 235 (우이신설경전철). The original CP949 CSV is vendored with SHA-256 f4702ebe2ef2265118b7cdc69ce0201d1824e787411409311ce4c904920b2303.",
            },
            {
                "title": "Incheon Institute metropolitan transport-code table",
                "url": "https://www.ii.re.kr/storage/data/2024/04/30/DATA_ATTACH_1714437784942.pdf",
                "note": "Institutional working-paper reference for observed codes 210 (새서울철도㈜) and 237 (신림경전철㈜). It is deliberately labeled institutional_reference, not an official KOTRIS row.",
            },
            {
                "title": "KOTI GTX-A line reference",
                "url": "https://cppr.koti.re.kr/site.do?command=railwyDetail&railwyId=RID241201000022",
                "note": "Official line/station context used with the corpus's exact 26.2 km geometry. Code 290 and its three tokens remain corpus_geometry_inference rather than an official code-table claim.",
            },
            {
                "title": "Seoul Big Data Campus subway station table",
                "url": "https://bigdata.seoul.go.kr/data/selectSampleData.do?r_id=P213&sample_data_seq=13",
                "note": "Official current station IDs, operators, and line names. Two high-only, versioned legacy-serial crosswalks resolve 1,580 rows across 159 exact six-byte fingerprints. Twelve of the 18 additional mappings also revalidate exact cited Seoul CSV rows. Twelve review candidates (54 rows) remain excluded, and direct legacy-ID joins are rejected by negative controls.",
            },
            {
                "title": "MOLIT nationwide settlement-operator station inventory",
                "url": "https://www.data.go.kr/data/15128614/fileData.do",
                "note": "Official unrestricted annual inventory (2025-06-13; 127,641 rows) for bus and subway stations reported by settlement operators. Exact bus settlement-ID joins resolve 860 rows across 517 fingerprints. It also revalidates the 18 additional capital-rail station identities and the separately labeled 250-row Busan Mybi station-byte transform; legacy transforms remain CardBal inferences.",
            },
            {
                "title": "MOLIT settlement-operator bus-stop selector",
                "url": "https://www.data.go.kr/data/15142032/openapi.do",
                "note": "Official unrestricted sample-data selector used for dated Seoul/Gyeonggi overlays, individual ARS-ID verification, and 3,400 Jeju City/Seogwipo rows. A mode-scoped seven-digit exact join resolves all 67 observed Jeju rows across 59 fingerprints. A trip-date Seoul snapshot also resolves two code-190 places while deliberately leaving that system/operator unidentified. Token transforms remain CardBal inferences; the selector is not treated as a rail crosswalk.",
            },
            {
                "title": "Busan BIMS route-stop inventory",
                "url": "https://www.data.go.kr/data/15092750/openapi.do",
                "note": "Official Busan stop data: 24,756 route-stop rows and 4,116 unique valid five-digit ARS IDs with zero collisions. A mode-scoped low16 little-endian token transform followed by an exact ARS join resolves 305 rows across 43 fingerprints; stop-ID suffix and nationwide-number fallbacks were rejected by collision tests.",
            },
            {
                "title": "Daegu Transportation Corporation Line 2 station sections",
                "url": "https://www.data.go.kr/data/15061835/fileData.do",
                "note": "Official operator station codes and names. A separately labeled event-split token transform resolves all four observed mode-872 rows; the transform is a CardBal inference from two journeys, so aliases retain the event byte.",
            },
            {
                "title": "Seoul bus-stop boarding dataset",
                "url": "https://data.seoul.go.kr/dataList/OA-12912/A/1/datasetView.do",
                "note": "Current official ridership data uses Seoul standard NODE_ID. It can enrich stops after a documented crosswalk, but NODE_ID is not the raw settlement ID found here.",
            },
            {
                "title": "Seoul Metro station ridership API",
                "url": "https://data.seoul.go.kr/dataList/OA-22723/A/1/datasetView.do",
                "note": "Official station-code/name data checked as a non-match for the four-byte raw rail token; no numerical rail crosswalk is claimed.",
            },
            {
                "title": "KRIC operator / line / station data",
                "url": "https://data.kric.go.kr/rips/M_04_02/detail.do?id=17",
                "note": "Current official operator/line/station namespace checked as a non-match for the raw rail token; it is linked for future crosswalk work and is not redistributed here.",
            },
            {
                "title": "15 user-confirmed CardBal samples",
                "url": None,
                "note": "Ten unique location codes with explicit labels retained as evidence anchors. Every labelled fingerprint now also has an official station-row attribution, so no production alias relies solely on a user label.",
            },
            {
                "title": "MOLIT / KRRI 2018 AFC standardization report (MT12 schema)",
                "url": "https://www.codil.or.kr/filebank/original/RK/OTKCRK190216/OTKCRK190216.pdf",
                "note": "Official report documenting that MT12 carries station ID and a separate internal station number. It establishes the namespace distinction but publishes no row-level crosswalk; SHA-256 c73d6193cb6bfe9ba16d9dfe1f46e626868c1a0293395a2678b2fbc7259380de.",
            },
            {
                "title": "MTC / KOTI 2021 AFC report (RSI schema)",
                "url": "https://www.codil.or.kr/filebank/original/RK/OTKCRK240571/OTKCRK240571.pdf",
                "note": "Official report documenting distinct external and internal station-number fields in RSI. It supplies schema evidence, not public crosswalk rows; SHA-256 ae77df0c4f4be40be9fd8a7a0d174a6cac5324a91cb9311c08bc513a082e9bc1.",
            },
            {
                "title": "K-Transit reverse-engineering notes",
                "url": "https://github.com/thanhdo1110/K-Transit/blob/main/ANALYSIS.md",
                "note": "Independent SFI 3 field hypotheses, checked against this larger corpus.",
            },
            {
                "title": "BucaCheck transport-card reader",
                "url": "https://play.google.com/store/apps/details?id=com.happypool.bucacheck",
                "note": "Independent reader corroborates KOTRIS-code-specific field profiles. Its current implementation treats Mybi Busan, integrated Mybi, Busan subway, and Gwangju clocks as unavailable; CardBal therefore exposes their two 24-bit counters but does not invent an epoch.",
            },
            {
                "title": "Metrodroid South Korea notes",
                "url": "https://github.com/metrodroid/metrodroid/wiki/South-Korea",
                "note": "Community protocol and issuer context; issuer ID is kept separate from the KOTRIS transport-mode field.",
            },
            {
                "title": "Proxmark3 KS X 6924 implementation",
                "url": "https://github.com/RfidResearchGroup/proxmark3/tree/master/client/src/ksx6924",
                "note": "Open implementation of the card protocol and purse metadata.",
            },
            {
                "title": "KS X 6924 compatibility research",
                "url": "https://journal.kits.or.kr/journal/article.php?code=41675",
                "note": "Academic background for the Korean interoperable transit-card standard.",
            },
        ],
    }
    cited_sources = {
        (source["title"], source.get("url"))
        for source in payload["sources"]
    }
    for item in known.values():
        for prefix in ("source", "nameSource", "hanjaSource", "coordinateSource"):
            title = item.get(f"{prefix}Title")
            url = item.get(f"{prefix}URL")
            note = item.get(f"{prefix}Note")
            source_key = (title, url)
            if not title or source_key in cited_sources:
                continue
            payload["sources"].append(
                {
                    "title": title,
                    "url": url,
                    "note": note
                    or "Official station metadata source retained with the exact alias match.",
                }
            )
            cited_sources.add(source_key)
    return payload


def main() -> None:
    args = parse_args()
    system_codes = read_system_codes(args.system_codes)
    known, evidence = read_known_locations(args.known, args.station_aliases, system_codes)
    rows = (
        read_rows_from_sqlite(args.sqlite)
        if args.sqlite
        else read_rows_from_d1(args.database, args.account_id, args.worker_root)
    )
    if not rows:
        raise RuntimeError("No Korean trip rows were returned")
    payload = build_payload(rows, known, evidence, system_codes)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )
    print(
        json.dumps(
            {
                "output": str(args.output),
                "bytes": args.output.stat().st_size,
                "records": payload["summary"]["records"],
                "cards": payload["summary"]["cards"],
                "locations": payload["summary"]["locations"],
                "journeys": payload["summary"]["pairedJourneys"],
            },
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
