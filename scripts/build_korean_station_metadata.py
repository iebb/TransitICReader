#!/usr/bin/env python3

"""Build audited coordinates and official multilingual names for Korean aliases.

The output is an enrichment layer consumed by ``build_korean_station_aliases.py``.
Identity mappings remain in that existing builder.  This script only adds a
coordinate or translated label after an exact, source-scoped join; it never
uses fuzzy station-name or nearest-coordinate matching.
"""

from __future__ import annotations

import argparse
import collections
import csv
import datetime as dt
import hashlib
import html
import json
import re
import tempfile
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path
from typing import Any
from xml.etree import ElementTree


REPO_ROOT = Path(__file__).resolve().parents[1]
VISUALIZER_ROOT = REPO_ROOT / "cloudflare" / "korean-trip-visualizer"
SOURCE_ROOT = VISUALIZER_ROOT / "scripts" / "sources"
DEFAULT_ALIASES = REPO_ROOT / "CardBal" / "Resources" / "KoreanStationAliases.json"
DEFAULT_CORPUS = REPO_ROOT / "datasets" / "korean-transit" / "korean-trips.json"
DEFAULT_ANNUAL = SOURCE_ROOT / "molit_settlement_stations_20250613.csv"
DEFAULT_SEOUL_BRIDGE = SOURCE_ROOT / "seoul_bigdata_subway_stations_cp949.csv"
DEFAULT_BUSAN_METRO = SOURCE_ROOT / "busan_metro_station_coordinates_20210319.csv"
DEFAULT_OUTPUT = SOURCE_ROOT / "korean_station_metadata_20260727.json"

TOPIS_URL = (
    "https://data.seoul.go.kr/dataList/dataView.do?onepagerow=1000&srvType=S&"
    "infId=OA-21232&serviceKind=0&pageNo=1&ssUserId=SAMPLE_VIEW&strWhere=&"
    "strOrderby=BLDN_ID%20DESC&filterCol=&txtFilter=&browser1=chrome&version=120"
)

DOWNLOADS = {
    "national_bus": {
        "url": "https://www.data.go.kr/cmm/cmm/fileDownload.do?atchFileId=FILE_000000003558143&fileDetailSn=1&insertDataPrcus=N",
        "sha256": "1db7e5d0cdc541e86a957b7584f2ddf8e4b1d29b02594984a01c5752ac13af06",
        "filename": "molit_national_bus_stops_20251031.csv",
    },
    "kric_all": {
        "url": "https://data.kric.go.kr/rips/dataset/download.file?type=filedata&id=32&operation=1",
        "sha256": "cdf1d84a7e5c898b2aacd622783ba8ba9af35c40bee0561dc97d55ce8e063f94",
        "filename": "kric_all_metro_stations_20260630.xlsx",
    },
    "seoul_names": {
        "url": "https://www.data.go.kr/cmm/cmm/fileDownload.do?atchFileId=FILE_000000003624961&fileDetailSn=1&insertDataPrcus=N",
        "sha256": "c9ef4c9a9dbeb3ca16b2a1ec03f7fa70a270494e47458dc65093b48be790de5f",
        "filename": "seoul_station_multilingual_20260326.csv",
    },
    "daegu_names": {
        "url": "https://www.data.go.kr/cmm/cmm/fileDownload.do?atchFileId=FILE_000000003515438&fileDetailSn=1&insertDataPrcus=N",
        "sha256": "95469603e26bc2d614fb9151ccf6481e6592859027039d31249fe6b23f445657",
        "filename": "kric_daegu2_multilingual_20250630.xlsx",
    },
    "seoul9_names": {
        "url": "https://www.data.go.kr/cmm/cmm/fileDownload.do?atchFileId=FILE_000000003539175&fileDetailSn=1&insertDataPrcus=N",
        "sha256": "d78f8a829520d888905ddeffae8668d07fc399e08804a1104d5f9082cc66b88d",
        "filename": "kric_seoul9_multilingual_20250630.xlsx",
    },
    "arex_names": {
        "url": "https://www.data.go.kr/cmm/cmm/fileDownload.do?atchFileId=FILE_000000003539186&fileDetailSn=1&insertDataPrcus=N",
        "sha256": "77829cf0988532328e3402a9422d7f6ac0bd05390030c82ef8e31e47572c2e89",
        "filename": "kric_arex_multilingual_20250630.xlsx",
    },
    "shinbundang_names": {
        "url": "https://www.data.go.kr/cmm/cmm/fileDownload.do?atchFileId=FILE_000000003525859&fileDetailSn=1&insertDataPrcus=N",
        "sha256": "29ed823001ee0a3ee502b026039ebf422e7676dc909eb126ed9b81c6dfeefebc",
        "filename": "kric_shinbundang_multilingual_20250630.xlsx",
    },
}

SEOUL_REVIEWED_RENAMES = {
    "0240": "신촌(지하)",
    "0427": "숙대입구(서울시교육청)",
    "0428": "삼각지(전쟁기념관)",
    "2535": "종로3가(탑골공원)",
    "2629": "삼각지(전쟁기념관)",
    "2722": "상봉",
    "2730": "자양(뚝섬한강공원)",
}

BUS_MATCHING_METHODS = {
    "bus_settlement_id_exact",
    "jeju_station_variant_digit_exact",
    "busan_bims_low16le_ars_exact",
    "seoul_code190_settlement_exact_unresolved_system",
}

PROVINCES = (
    "서울특별시", "부산광역시", "대구광역시", "인천광역시", "광주광역시",
    "대전광역시", "울산광역시", "세종특별자치시", "경기도", "강원특별자치도",
    "충청북도", "충청남도", "전북특별자치도", "전라남도", "경상북도",
    "경상남도", "제주특별자치도",
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--aliases", type=Path, default=DEFAULT_ALIASES)
    parser.add_argument("--corpus", type=Path, default=DEFAULT_CORPUS)
    parser.add_argument("--annual", type=Path, default=DEFAULT_ANNUAL)
    parser.add_argument("--seoul-bridge", type=Path, default=DEFAULT_SEOUL_BRIDGE)
    parser.add_argument("--busan-metro", type=Path, default=DEFAULT_BUSAN_METRO)
    parser.add_argument("--source-cache", type=Path, default=Path(tempfile.gettempdir()) / "cardbal-korean-station-sources")
    parser.add_argument("--topis", type=Path)
    parser.add_argument("--national-bus", type=Path)
    parser.add_argument("--kric-all", type=Path)
    parser.add_argument("--seoul-names", type=Path)
    parser.add_argument("--daegu-names", type=Path)
    parser.add_argument("--seoul9-names", type=Path)
    parser.add_argument("--arex-names", type=Path)
    parser.add_argument("--shinbundang-names", type=Path)
    parser.add_argument("--busan-operator-json", type=Path)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    return parser.parse_args()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def checked_source(path: Path | None, key: str, cache: Path) -> Path:
    item = DOWNLOADS[key]
    target = path or cache / item["filename"]
    if not target.exists():
        target.parent.mkdir(parents=True, exist_ok=True)
        request = urllib.request.Request(item["url"], headers={"User-Agent": "CardBal station metadata builder/1"})
        with urllib.request.urlopen(request, timeout=90) as response, target.open("wb") as handle:
            while chunk := response.read(1024 * 1024):
                handle.write(chunk)
    actual = sha256(target)
    if actual != item["sha256"]:
        raise ValueError(f"{key} source hash mismatch: {actual}")
    return target


def topis_source(path: Path | None, cache: Path) -> Path:
    if path:
        target = path
    else:
        target = cache / "seoul_station_master_20260722.json"
        if not target.exists():
            target.parent.mkdir(parents=True, exist_ok=True)
            request = urllib.request.Request(TOPIS_URL, headers={"User-Agent": "Mozilla/5.0"})
            raw = urllib.request.urlopen(request, timeout=60).read().decode("utf-8-sig").strip()
            # Seoul's anonymous sample endpoint returns JavaScript object syntax.
            normalized = re.sub(r"([{,])\s*([A-Za-z0-9_]+)\s*:", r'\1"\2":', raw)
            normalized = re.sub(r",\s*([}\]])", r"\1", normalized)
            payload = json.loads(normalized)
            target.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    actual = sha256(target)
    expected = "eb4301f343263f764328f8405b3c27a917f071779b504714f8a2d28d2ea7a767"
    if actual != expected:
        raise ValueError(f"TOPIS canonical source hash mismatch: {actual}")
    return target


def column_number(reference: str) -> int:
    result = 0
    for char in re.match(r"[A-Z]+", reference).group(0):
        result = result * 26 + ord(char) - ord("A") + 1
    return result - 1


def read_xlsx(path: Path) -> list[dict[str, str]]:
    namespace = "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}"
    with zipfile.ZipFile(path) as archive:
        shared: list[str] = []
        if "xl/sharedStrings.xml" in archive.namelist():
            root = ElementTree.fromstring(archive.read("xl/sharedStrings.xml"))
            for item in root.findall(f"{namespace}si"):
                shared.append("".join(node.text or "" for node in item.iter(f"{namespace}t")))
        sheet = ElementTree.fromstring(archive.read("xl/worksheets/sheet1.xml"))
    matrix: list[list[str]] = []
    for row in sheet.iter(f"{namespace}row"):
        values: dict[int, str] = {}
        for cell in row.findall(f"{namespace}c"):
            reference = cell.attrib["r"]
            value_node = cell.find(f"{namespace}v")
            value = value_node.text if value_node is not None and value_node.text is not None else ""
            if cell.attrib.get("t") == "s" and value:
                value = shared[int(value)]
            elif cell.attrib.get("t") == "inlineStr":
                value = "".join(node.text or "" for node in cell.iter(f"{namespace}t"))
            values[column_number(reference)] = value
        if values:
            matrix.append([values.get(index, "") for index in range(max(values) + 1)])
    headers = matrix[0]
    return [
        {header: row[index] if index < len(row) else "" for index, header in enumerate(headers)}
        for row in matrix[1:]
    ]


def clean(value: Any) -> str | None:
    result = re.sub(r"\s+", " ", str(value or "")).strip()
    return None if result in ("", "-") else result


def normalized_name(value: Any) -> str:
    return re.sub(r"[\W_]+", "", str(value or ""), flags=re.UNICODE)


def normalized_mobile(value: Any) -> str:
    return str(value or "").strip().lstrip("0")


def valid_coordinate(latitude: Any, longitude: Any) -> bool:
    try:
        return 32.0 <= float(latitude) <= 40.0 and 123.0 <= float(longitude) <= 133.0
    except (TypeError, ValueError):
        return False


def read_csv(path: Path, encoding: str, delimiter: str = ",") -> list[dict[str, str]]:
    with path.open(encoding=encoding, newline="") as handle:
        return list(csv.DictReader(handle, delimiter=delimiter))


def unique_by(rows: list[dict[str, Any]], fields: tuple[str, ...]) -> list[dict[str, Any]]:
    return list({tuple(str(row.get(field, "")) for field in fields): row for row in rows}.values())


def busan_operator_source(path: Path | None, aliases: list[dict[str, Any]], cache: Path) -> tuple[Path, dict[str, Any]]:
    target = path or cache / "busan_humetro_multilingual_aliases.json"
    if target.exists():
        return target, json.loads(target.read_text(encoding="utf-8"))
    endpoint = "https://work.humetro.busan.kr/homepage/default/stationinfo/page/list01.do?menu_no=1001010201"
    rows = []
    for station_id in sorted({alias["sourceStationID"] for alias in aliases}):
        body = urllib.parse.urlencode({"s_line": station_id[0], "s_station": station_id}).encode()
        request = urllib.request.Request(
            endpoint,
            data=body,
            headers={"User-Agent": "Mozilla/5.0", "Content-Type": "application/x-www-form-urlencoded"},
        )
        response = urllib.request.urlopen(request, timeout=60).read()
        page = response.decode("utf-8", errors="replace")

        def extract(pattern: str) -> str:
            match = re.search(pattern, page, flags=re.DOTALL)
            if not match:
                raise ValueError(f"Missing Busan label for station {station_id}: {pattern}")
            return re.sub(r"<[^>]+>", "", html.unescape(match.group(1))).strip()

        rows.append({
            "sourceStationID": station_id,
            "line": f"{station_id[0]}호선",
            "korean": extract(r'station-info-1-1.*?<b>(.*?)</b>'),
            "english": extract(r'<li>\s*<b>영어</b>(.*?)</li>'),
            "chineseSimplified": extract(r'<li>\s*<b>중국어\(간체\)</b>(.*?)</li>'),
            "chineseTraditional": extract(r'<li>\s*<b>중국어\(번체\)</b>(.*?)</li>'),
            "japanese": extract(r'<li>\s*<b>일본어</b>(.*?)</li>'),
            "requestBody": body.decode(),
            "responseSHA256": hashlib.sha256(response).hexdigest(),
        })
    payload = {
        "source": endpoint,
        "retrievedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "rows": rows,
    }
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return target, payload


def source_record(
    identifier: str,
    title: str,
    publisher: str,
    catalog_url: str,
    dataset_date: str,
    license_name: str,
    note: str,
    path: Path,
    row_count: int,
    matching_method: str,
) -> dict[str, Any]:
    return {
        "id": identifier,
        "title": title,
        "publisher": publisher,
        "catalogURL": catalog_url,
        "localPath": None,
        "datasetDate": dataset_date,
        "portalModifiedDate": None,
        "retrievedAt": "2026-07-27",
        "license": license_name,
        "note": note,
        "sourceSHA256": sha256(path),
        "rowCount": row_count,
        "matchingMethod": matching_method,
    }


def main() -> None:
    args = parse_args()
    args.source_cache.mkdir(parents=True, exist_ok=True)
    topis_path = topis_source(args.topis, args.source_cache)
    national_bus_path = checked_source(args.national_bus, "national_bus", args.source_cache)
    kric_all_path = checked_source(args.kric_all, "kric_all", args.source_cache)
    seoul_names_path = checked_source(args.seoul_names, "seoul_names", args.source_cache)
    daegu_names_path = checked_source(args.daegu_names, "daegu_names", args.source_cache)
    seoul9_names_path = checked_source(args.seoul9_names, "seoul9_names", args.source_cache)
    arex_names_path = checked_source(args.arex_names, "arex_names", args.source_cache)
    shinbundang_names_path = checked_source(args.shinbundang_names, "shinbundang_names", args.source_cache)

    alias_payload = json.loads(args.aliases.read_text(encoding="utf-8"))
    aliases = alias_payload["locations"]
    corpus = json.loads(args.corpus.read_text(encoding="utf-8"))
    record_counts = {row["code"]: int(row["records"]) for row in corpus["locations"]}
    aliases_by_code = collections.defaultdict(list)
    for alias in aliases:
        aliases_by_code[alias["locationCode"]].append(alias)

    enrichments: dict[tuple[str, int | None], dict[str, Any]] = {}
    evidence: dict[str, Any] = {}

    def enrichment(alias: dict[str, Any]) -> dict[str, Any]:
        key = (alias["locationCode"], alias.get("eventRaw"))
        return enrichments.setdefault(key, {
            "locationCode": alias["locationCode"],
            "eventRaw": alias.get("eventRaw"),
            "identityName": alias["name"],
        })

    def add_coordinates(alias: dict[str, Any], latitude: Any, longitude: Any, source_id: str, source_station_id: Any, method: str) -> None:
        if not valid_coordinate(latitude, longitude):
            raise ValueError(f"Invalid coordinate for {alias['locationCode']}")
        item = enrichment(alias)
        values = {
            "latitude": float(latitude),
            "longitude": float(longitude),
            "coordinateSourceID": source_id,
            "coordinateSourceStationID": str(source_station_id),
            "coordinateMatchingMethod": method,
        }
        for field, value in values.items():
            if field in item and item[field] != value:
                raise ValueError(f"Coordinate conflict for {alias['locationCode']}: {field}")
            item[field] = value

    def add_names(alias: dict[str, Any], row: dict[str, Any], source_id: str, source_station_id: Any, method: str, hanja_source_id: str | None = None) -> None:
        item = enrichment(alias)
        values = {
            "nameCanonicalKo": clean(row.get("korean")),
            "nameEnglish": clean(row.get("english")),
            "nameHanja": clean(row.get("hanja")),
            "nameChineseSimplified": clean(row.get("chineseSimplified")),
            "nameChineseTraditional": clean(row.get("chineseTraditional")),
            "nameJapanese": clean(row.get("japanese")),
            "nameSourceID": source_id,
            "nameSourceStationID": str(source_station_id),
            "nameMatchingMethod": method,
            "nameHanjaSourceID": hanja_source_id,
        }
        for field, value in values.items():
            if value is None:
                continue
            if field in item and item[field] != value:
                raise ValueError(f"Name conflict for {alias['locationCode']}: {field}")
            item[field] = value

    annual_rows = read_csv(args.annual, "cp949")
    national_bus_rows = read_csv(national_bus_path, "cp949")
    topis_rows = json.loads(topis_path.read_text(encoding="utf-8"))["list"]
    busan_metro_rows = read_csv(args.busan_metro, "utf-16", delimiter="\t")
    kric_all_rows = read_xlsx(kric_all_path)

    annual_by_id: dict[str, list[dict[str, str]]] = collections.defaultdict(list)
    for row in annual_rows:
        annual_by_id[row["정류장아이디"]].append(row)
    national_by_mobile_province: dict[tuple[str, str], list[dict[str, str]]] = collections.defaultdict(list)
    for row in national_bus_rows:
        province = next((item for item in PROVINCES if item in row["도시명"]), None)
        if province:
            national_by_mobile_province[(normalized_mobile(row["모바일단축번호"]), province)].append(row)

    annual_exact_by_alias = {}
    for alias in aliases:
        if alias.get("matchingMethod") not in BUS_MATCHING_METHODS:
            continue
        rows = [
            row for row in annual_by_id[alias["sourceStationID"]]
            if row["교통수단구분"] == "버스"
            and row["정류장명"].strip() == alias["name"].strip()
            and row["시도명(법정동)"] == alias.get("ctpvName")
            and row["시군구명(법정동)"] == alias.get("sggName")
        ]
        rows = unique_by(rows, ("정류장명", "시도명(법정동)", "시군구명(법정동)", "모바일아이디"))
        if len(rows) == 1:
            annual_exact_by_alias[alias["locationCode"]] = rows[0]

    rejected_bus_names = []
    ambiguous_bus_mobile = []
    direct_bus = bridge_bus = 0
    for alias in aliases:
        if alias.get("matchingMethod") not in BUS_MATCHING_METHODS or alias["sourceID"] == "busan-bims-route-stops-20260727":
            continue
        mobile = alias.get("arsID")
        used_bridge = False
        if not mobile:
            bridge = annual_exact_by_alias.get(alias["locationCode"])
            if bridge and bridge["모바일아이디"] not in ("", "정보없음"):
                mobile = bridge["모바일아이디"]
                used_bridge = True
        if not mobile:
            continue
        rows = [row for row in national_by_mobile_province[(normalized_mobile(mobile), alias.get("ctpvName"))] if valid_coordinate(row["위도"], row["경도"])]
        rows = unique_by(rows, ("정류장번호", "정류장명", "위도", "경도", "도시명"))
        if len(rows) > 1:
            ambiguous_bus_mobile.append({"locationCode": alias["locationCode"], "mobileID": str(mobile), "candidateCount": len(rows)})
            continue
        if len(rows) != 1:
            continue
        row = rows[0]
        if normalized_name(alias["name"]) != normalized_name(row["정류장명"]):
            rejected_bus_names.append({"locationCode": alias["locationCode"], "aliasName": alias["name"], "sourceName": row["정류장명"]})
            continue
        method = (
            "exact settlement ID/name/province/district to annual mobile ID, then exact province/mobile ID, unique national row, and punctuation-insensitive exact name"
            if used_bridge else
            "exact alias ARS/mobile ID plus province, unique national row, and punctuation-insensitive exact name"
        )
        add_coordinates(alias, row["위도"], row["경도"], "molit-national-bus-stop-locations-20251031", row["정류장번호"], method)
        bridge_bus += int(used_bridge)
        direct_bus += int(not used_bridge)

    topis_by_id: dict[str, list[dict[str, str]]] = collections.defaultdict(list)
    for row in topis_rows:
        topis_by_id[row["BLDN_ID"]].append(row)
    for alias in aliases:
        if alias["sourceID"] not in {"seoul-bigdata-subway-stations", "cardbal-additional-capital-rail-high-v1"}:
            continue
        rows = topis_by_id[alias["sourceStationID"]]
        if len(rows) != 1:
            raise ValueError(f"TOPIS ID is not unique: {alias['sourceStationID']}")
        row = rows[0]
        add_coordinates(alias, row["LAT"], row["LOT"], "seoul-topis-station-master-20260722", row["BLDN_ID"], "exact unique TOPIS BLDN_ID equal to the alias sourceStationID; no name fallback")

    busan_by_id: dict[str, list[dict[str, str]]] = collections.defaultdict(list)
    for row in busan_metro_rows:
        busan_by_id[row["역번호"]].append(row)
    busan_aliases = [alias for alias in aliases if alias.get("matchingMethod") == "busan_mybi_station_byte"]
    for alias in busan_aliases:
        rows = busan_by_id[alias["sourceStationID"]]
        if len(rows) != 1:
            raise ValueError(f"Busan Metro ID is not unique: {alias['sourceStationID']}")
        row = rows[0]
        add_coordinates(alias, row["역위도"], row["역경도"], "busan-metro-station-coordinates-20210319", row["역번호"], "exact unique operator 역번호 equal to alias sourceStationID, scoped to Busan mode 870")

    kric_daegu_by_id: dict[str, list[dict[str, str]]] = collections.defaultdict(list)
    for row in kric_all_rows:
        if row.get("운영기관명") == "대구교통공사" and row.get("노선명") == "대구 도시철도 2호선":
            kric_daegu_by_id[row["역번호"].lstrip("0")].append(row)
    for alias in aliases:
        if alias["sourceID"] != "daegu-transit-line2-section-20251231":
            continue
        rows = kric_daegu_by_id[alias["sourceStationID"].lstrip("0")]
        if len(rows) != 1:
            raise ValueError(f"Daegu KRIC ID is not unique: {alias['sourceStationID']}")
        row = rows[0]
        add_coordinates(alias, row["역위도"], row["역경도"], "kric-all-metro-stations-20260630", row["역번호"], "exact station code after leading-zero normalization, scoped to Daegu Transit Line 2")

    seoul_bridge_rows = read_csv(args.seoul_bridge, "cp949")
    bridge_by_id: dict[str, list[dict[str, str]]] = collections.defaultdict(list)
    for row in seoul_bridge_rows:
        bridge_by_id[row["역ID(STATION_ID)"]].append(row)
    seoul_multilingual_rows = read_csv(seoul_names_path, "utf-8-sig")
    seoul_names_by_key: dict[tuple[str, str], list[dict[str, str]]] = collections.defaultdict(list)
    for row in seoul_multilingual_rows:
        seoul_names_by_key[(row["호선"], row["한글"])].append(row)
    seoul_name_counts = collections.Counter()
    unresolved_seoul = []
    for alias in [item for item in aliases if item["sourceID"] == "seoul-bigdata-subway-stations"]:
        bridge_rows = bridge_by_id[alias["sourceStationID"]]
        if len(bridge_rows) != 1:
            raise ValueError(f"Seoul bridge ID is not unique: {alias['sourceStationID']}")
        bridge = bridge_rows[0]
        line = "9호선" if bridge["호선명(LINE_NM)"] == "9호선2~3단계" else bridge["호선명(LINE_NM)"]
        station_name = SEOUL_REVIEWED_RENAMES.get(alias["sourceStationID"], bridge["역명(STATION_NM)"])
        rows = seoul_names_by_key[(line, station_name)]
        if len(rows) != 1:
            unresolved_seoul.append((alias, bridge))
            continue
        row = rows[0]
        method_kind = "reviewed explicit rename" if alias["sourceStationID"] in SEOUL_REVIEWED_RENAMES else "normalized official line label" if bridge["호선명(LINE_NM)"] != line else "exact line and Korean name"
        add_names(alias, {
            "korean": row["한글"], "english": row["영문"], "hanja": row["한자"],
            "chineseSimplified": row["중국어"], "japanese": row["일본어"],
        }, "seoul-metro-multilingual-20260326", alias["sourceStationID"], f"exact alias station ID to official Seoul bridge, then {method_kind} in multilingual table")
        seoul_name_counts[method_kind] += 1

    def route_names(row: dict[str, str]) -> dict[str, Any]:
        return {
            "korean": row.get("역명"), "english": row.get("영어명"),
            "chineseSimplified": row.get("중국어간체"),
            "chineseTraditional": row.get("중국어번체"), "japanese": row.get("일본어"),
        }

    def apply_route_file(
        unresolved: list[tuple[dict[str, Any], dict[str, str]]],
        rows: list[dict[str, str]],
        source_id: str,
        operator: str,
        line: str,
        bridge_id_prefix: str,
    ) -> set[str]:
        matched = set()
        scoped = [row for row in rows if row.get("철도운영기관명") == operator and row.get("선명") == line]
        for alias, bridge in unresolved:
            if not alias["sourceStationID"].startswith(bridge_id_prefix):
                continue
            candidates = [row for row in scoped if row.get("역명") == bridge["역명(STATION_NM)"]]
            if len(candidates) != 1:
                continue
            row = candidates[0]
            add_names(alias, route_names(row), source_id, row["역번호"], "exact alias station ID to official Seoul bridge, then exact operator, line, and Korean name in KRIC route table")
            matched.add(alias["locationCode"])
        return matched

    matched_line9 = apply_route_file(unresolved_seoul, read_xlsx(seoul9_names_path), "kric-seoul-line9-multilingual-20250630", "서울시메트로9호선주식회사", "9호선", "41")
    matched_arex = apply_route_file(unresolved_seoul, read_xlsx(arex_names_path), "kric-arex-multilingual-20250630", "공항철도주식회사", "공항", "42")
    unresolved_after_routes = [alias["locationCode"] for alias, _ in unresolved_seoul if alias["locationCode"] not in matched_line9 | matched_arex]
    if unresolved_after_routes:
        raise ValueError(f"Unresolved Seoul multilingual aliases: {unresolved_after_routes}")

    busan_operator_path, busan_operator = busan_operator_source(args.busan_operator_json, busan_aliases, args.source_cache)
    operator_by_id = {row["sourceStationID"]: row for row in busan_operator["rows"]}
    if len(operator_by_id) != 23:
        raise ValueError("Expected 23 unique Busan operator stations")
    for alias in busan_aliases:
        row = operator_by_id[alias["sourceStationID"]]
        coordinate_row = busan_by_id[alias["sourceStationID"]][0]
        add_names(alias, {
            "korean": row["korean"], "english": row["english"],
            "chineseSimplified": row["chineseSimplified"],
            "chineseTraditional": row["chineseTraditional"], "japanese": row["japanese"],
            "hanja": coordinate_row.get("한자역사명"),
        }, "busan-humetro-station-pages-20260727", alias["sourceStationID"], "exact operator line and station ID", hanja_source_id="busan-metro-station-coordinates-20210319")

    daegu_route_rows = read_xlsx(daegu_names_path)
    daegu_route_by_id: dict[str, list[dict[str, str]]] = collections.defaultdict(list)
    for row in daegu_route_rows:
        if row.get("철도운영기관명") == "대구교통공사" and row.get("선명") == "2호선":
            daegu_route_by_id[row["역번호"].lstrip("0")].append(row)
    for alias in [item for item in aliases if item["sourceID"] == "daegu-transit-line2-section-20251231"]:
        rows = daegu_route_by_id[alias["sourceStationID"].lstrip("0")]
        if len(rows) != 1:
            raise ValueError(f"Daegu multilingual ID is not unique: {alias['sourceStationID']}")
        add_names(alias, route_names(rows[0]), "kric-daegu-line2-multilingual-20250630", rows[0]["역번호"], "exact station ID after leading-zero normalization, operator, and line")

    shinbundang_ids = {"4304", "4305", "4306", "4315"}
    shinbundang_rows = [
        row for row in read_xlsx(shinbundang_names_path)
        if row.get("철도운영기관명") == "네오트랜스주식회사" and row.get("선명") == "신분당"
    ]
    for alias in [item for item in aliases if item.get("sourceStationID") in shinbundang_ids and item["sourceID"] == "cardbal-additional-capital-rail-high-v1"]:
        rows = [row for row in shinbundang_rows if row.get("역명") == alias["name"]]
        if len(rows) != 1:
            raise ValueError(f"Shinbundang name is not unique: {alias['name']}")
        add_names(alias, route_names(rows[0]), "kric-shinbundang-multilingual-20250630", rows[0]["역번호"], "exact scoped alias set, operator, line, and Korean name; retain differing public station ID")

    # KRIC's nationwide table supplies official English and Hanja for nine
    # additional KORAIL aliases where ID, operator, and line are all exact.
    korail_name_count = 0
    for alias in [item for item in aliases if item["sourceID"] == "cardbal-additional-capital-rail-high-v1"]:
        if enrichment(alias).get("nameEnglish") or not alias.get("lineName") or not alias.get("operatorName"):
            continue
        rows = [
            row for row in kric_all_rows
            if row.get("역번호", "").lstrip("0") == alias["sourceStationID"].lstrip("0")
            and row.get("노선명") == alias["lineName"]
            and row.get("운영기관명") == alias["operatorName"]
        ]
        if len(rows) != 1:
            continue
        row = rows[0]
        add_names(alias, {
            "korean": row.get("역사명"), "english": row.get("영문역사명"), "hanja": row.get("한자역사명"),
        }, "kric-all-metro-stations-20260630", row["역번호"], "exact station ID, operator, and line in nationwide KRIC station table")
        korail_name_count += 1

    coordinate_items = [item for item in enrichments.values() if item.get("latitude") is not None]
    new_coordinate_items = [
        item for item in coordinate_items
        if not any(alias.get("latitude") is not None for alias in aliases_by_code[item["locationCode"]])
    ]
    existing_coordinate_aliases = sum(alias.get("latitude") is not None for alias in aliases)
    coordinate_aliases = existing_coordinate_aliases + len(new_coordinate_items)
    coordinate_records = sum(
        record_counts.get(alias["locationCode"], 0)
        for alias in aliases
        if alias.get("latitude") is not None or any(item["locationCode"] == alias["locationCode"] for item in new_coordinate_items)
    )
    name_items = [item for item in enrichments.values() if item.get("nameEnglish") or item.get("nameJapanese") or item.get("nameChineseSimplified")]

    # Alias/source cardinalities are evidence invariants. The number of corpus
    # rows covered by those aliases is expected to grow as D1 receives records.
    coordinate_baseline = (72, 48, 311, 354)
    coordinate_actual = (direct_bus, bridge_bus, len(coordinate_items), coordinate_aliases)
    if any(actual < baseline for actual, baseline in zip(coordinate_actual, coordinate_baseline)):
        raise ValueError(f"Coordinate alias coverage regressed: {coordinate_actual} < {coordinate_baseline}")
    english_name_count = len([item for item in name_items if item.get("nameEnglish")])
    if english_name_count != 186:
        raise ValueError(f"Expected 186 aliases with official English labels, got {english_name_count}")

    sources = [
        source_record("seoul-topis-station-master-20260722", "서울시 역사마스터 정보", "서울특별시", "https://data.seoul.go.kr/dataList/OA-21232/S/1/datasetView.do?tab=A", "2026-07-22", "공공누리 제1유형", "Coordinates for capital-region rail aliases.", topis_path, len(topis_rows), "Exact unique BLDN_ID; no name fallback."),
        source_record("molit-national-bus-stop-locations-20251031", "국토교통부_전국 버스정류장 위치정보_20251031", "국토교통부", "https://www.data.go.kr/data/15067528/fileData.do", "2025-10-31", "이용허락범위 제한 없음", "National TAGO stop coordinates; KOTRIS settlement IDs are never joined directly to NODE_ID.", national_bus_path, len(national_bus_rows), "Province-scoped exact mobile ID, one distinct coordinate row, and punctuation-insensitive exact name."),
        source_record("busan-metro-station-coordinates-20210319", "전국도시철도역사정보표준데이터 (Busan operator extract)", "부산교통공사", "https://www.data.go.kr/data/15043686/fileData.do", "2021-03-19", "공공데이터포털 이용조건", "Official Busan station coordinates, English, and Hanja.", args.busan_metro, len(busan_metro_rows), "Exact unique Busan operator station number."),
        source_record("kric-all-metro-stations-20260630", "전체 도시철도역사정보", "한국철도산업정보센터 (KRIC)", "https://data.kric.go.kr/rips/M_01_01/detail.do?id=32", "2026-06-30", "공공데이터포털 이용조건", "Nationwide urban-rail coordinates plus official English and Hanja fields.", kric_all_path, len(kric_all_rows), "Station ID is accepted only with an exact operator and line scope."),
        source_record("seoul-metro-multilingual-20260326", "서울교통공사_역명다국어표기_20260326", "서울교통공사", "https://www.data.go.kr/data/15044232/fileData.do", "2026-03-26", "공공누리 제1유형", "Official English, Hanja, simplified Chinese, and Japanese station labels.", seoul_names_path, len(seoul_multilingual_rows), "Alias station ID first resolves through the official Seoul bridge; multilingual rows then require line and Korean name."),
        source_record("busan-humetro-station-pages-20260727", "부산교통공사 역정보", "부산교통공사", "https://work.humetro.busan.kr/homepage/default/stationinfo/page/list01.do?menu_no=1001010201", "2026-07-27", "Official operator website", "Official English, simplified/traditional Chinese, and Japanese labels fetched for the exact station IDs.", busan_operator_path, len(busan_operator["rows"]), "Exact operator line and station ID."),
        source_record("kric-daegu-line2-multilingual-20250630", "국가철도공단_대구2호선_역정보", "국가철도공단", "https://www.data.go.kr/data/15041045/fileData.do", "2025-06-30", "공공데이터포털 이용조건", "Official multilingual route labels.", daegu_names_path, len(daegu_route_rows), "Exact station ID after leading-zero normalization, operator, and line."),
        source_record("kric-seoul-line9-multilingual-20250630", "국가철도공단_수도권9호선_역정보", "국가철도공단", "https://www.data.go.kr/data/15041811/fileData.do", "2025-06-30", "공공데이터포털 이용조건", "Official multilingual route labels for the private Line 9 section.", seoul9_names_path, len(read_xlsx(seoul9_names_path)), "Exact Seoul bridge name, operator, and line; both station-ID namespaces are retained."),
        source_record("kric-arex-multilingual-20250630", "국가철도공단_공항철도_역정보", "국가철도공단", "https://www.data.go.kr/data/15041034/fileData.do", "2025-06-30", "공공데이터포털 이용조건", "Official multilingual Airport Railroad route labels.", arex_names_path, len(read_xlsx(arex_names_path)), "Exact Seoul bridge name, operator, and line; both station-ID namespaces are retained."),
        source_record("kric-shinbundang-multilingual-20250630", "국가철도공단_신분당선_역정보", "국가철도공단", "https://www.data.go.kr/data/15041033/fileData.do", "2025-06-30", "공공데이터포털 이용조건", "Official multilingual Shinbundang route labels.", shinbundang_names_path, len(shinbundang_rows), "Exact reviewed alias set, operator, line, and Korean name; both station-ID namespaces are retained."),
    ]

    output = {
        "schemaVersion": 1,
        "sources": sources,
        "statistics": {
            "aliases": len(aliases),
            "coordinateAliases": coordinate_aliases,
            "coordinateAliasCoveragePercent": round(100 * coordinate_aliases / len(aliases), 1),
            "coordinateRecords": coordinate_records,
            "coordinateRecordCoveragePercent": round(100 * coordinate_records / len(corpus["records"]), 1),
            "newCoordinateAliases": len(new_coordinate_items),
            "nationalBusDirectMobileAliases": direct_bus,
            "nationalBusAnnualBridgeAliases": bridge_bus,
            "nameEnglishAliases": sum(item.get("nameEnglish") is not None for item in enrichments.values()),
            "nameHanjaAliases": sum(item.get("nameHanja") is not None for item in enrichments.values()),
            "nameChineseSimplifiedAliases": sum(item.get("nameChineseSimplified") is not None for item in enrichments.values()),
            "nameChineseTraditionalAliases": sum(item.get("nameChineseTraditional") is not None for item in enrichments.values()),
            "nameJapaneseAliases": sum(item.get("nameJapanese") is not None for item in enrichments.values()),
            "seoulMultilingualMethods": dict(seoul_name_counts),
            "additionalKORAILNameAliases": korail_name_count,
        },
        "enrichments": sorted(enrichments.values(), key=lambda item: (item["locationCode"], item.get("eventRaw") if item.get("eventRaw") is not None else -1)),
        "audit": {
            "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
            "coordinatePolicy": "Exact source-scoped joins only; no fuzzy name or nearest-coordinate matching.",
            "languagePolicy": "Values are published labels. Hanja is separate from Chinese; blanks stay null; no machine translation.",
            "nationalBusRejectedNameConflicts": rejected_bus_names,
            "nationalBusAmbiguousProvinceMobileMatches": ambiguous_bus_mobile,
            "busanOperatorSourceRows": busan_operator["rows"],
            "unmappedCoordinateNote": "Jeju settlement IDs and local BIS coordinate IDs lack a verified exact bridge; name-only matches are intentionally excluded.",
        },
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(output, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(output["statistics"], ensure_ascii=False, indent=2))
    print(args.output)


if __name__ == "__main__":
    main()
