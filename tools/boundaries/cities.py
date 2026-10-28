#!/usr/bin/env python3
"""Build CardBal's compact, offline East Asia city-boundary catalog.

Japan includes only ADM2 municipalities referenced by a non-pseudo station in
the bundled station database. Korea uses a non-stacked mixed city layer: metropolitan
cities use ADM1, other municipalities use ADM2, and Jeju stays whole because
the available evidence does not safely split its visits between its two cities.
Mongolia keeps Ulaanbaatar as one ADM1 city to avoid stacked district outlines,
and adds the station-backed Sergelen, Erdene, and Bayandelger ADM2 municipalities
in neighboring Töv. Exact U-Money station-token conversion remains intentionally
unasserted until a real-card crosswalk is available.
Exact Korean station locations win, with reviewed city-specific KOTRIS modes as
a fallback when a station token is unknown. China's source catalog includes
every peer-level city in the bundled T-Union registry plus a reference-only
Macau outline. The client shows
only the current participation subset, while reviewed historical aliases stay
decodable; province-wide codes never fabricate a City match.
Coordinates use GeoJSON order everywhere:

* ``center``: ``[longitude, latitude]``
* ``bbox``: ``[minLongitude, minLatitude, maxLongitude, maxLatitude]``
* ``components``: an array of polygon components. Each component stores one
  ``outer`` ring and zero or more interior ``holes``; every point is represented
  as ``[longitude, latitude]``.

The geoBoundaries and Natural Earth inputs are pinned to commits and verified
by SHA-256. Chinese administrative relations are fixed in a reviewed manifest,
resolved in rate-limited Nominatim lookup batches, intersected with Natural
Earth land, and only then simplified for the bundled catalog.
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import hashlib
import json
import math
import re
import sqlite3
import tempfile
import time
import urllib.parse
import urllib.request
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any, Iterable


from tools.paths import ROOT as REPO_ROOT, PORTABLE_OUTPUT, BOUNDARIES
DEFAULT_JAPAN_DATABASE = PORTABLE_OUTPUT / "jp_stations.sqlite"
DEFAULT_JAPAN_COVERAGE = BOUNDARIES / "JapanTransitCoverage.json"
DEFAULT_CHINA_CITY_REGISTRY = PORTABLE_OUTPUT / "TUnionCityCodes.json"
DEFAULT_CHINA_COVERAGE = BOUNDARIES / "ChinaTransitCoverage.json"
DEFAULT_CHINA_RELATION_MANIFEST = Path(__file__).parent / "data/china_tunion_osm_relations.json"
DEFAULT_KOREA_STATIONS = PORTABLE_OUTPUT / "korean_stations.tsv"
DEFAULT_KOREA_MODES = PORTABLE_OUTPUT / "KOTRISTransportModes.json"
DEFAULT_MONGOLIA_DATABASE = PORTABLE_OUTPUT / "ulaanbaatar_transit.sqlite"
DEFAULT_OUTPUT = BOUNDARIES / "EastAsiaCityBoundaries.json"

GEBOUNDARIES_COMMIT = "9469f09592ced973a3448cf66b6100b741b64c0d"
GEBOUNDARIES_COMMIT_DATE = "2023-12-13T04:03:07Z"
GEBOUNDARIES_MEDIA_ROOT = (
    "https://media.githubusercontent.com/media/wmgeolab/geoBoundaries/"
    f"{GEBOUNDARIES_COMMIT}/releaseData/gbOpen"
)
GEBOUNDARIES_ASSETS = {
    "JPN_ADM1": {
        "relativePath": "JPN/ADM1/geoBoundaries-JPN-ADM1_simplified.geojson",
        "sha256": "f18eeeb978d992a7147f636642932913731c231f298cb514bf7a3bd41a1aacc0",
    },
    "JPN_ADM2": {
        "relativePath": "JPN/ADM2/geoBoundaries-JPN-ADM2_simplified.geojson",
        "sha256": "c1c3f4d70bf7d02ef3fd2f98410597ac714c521280520fc7e85073fdee75af46",
    },
    "KOR_ADM1": {
        "relativePath": "KOR/ADM1/geoBoundaries-KOR-ADM1_simplified.geojson",
        "sha256": "7d774c8bb1ee65dde693431985423616fd059ffbe1c1bb497b5fed4f47bcac01",
    },
    "KOR_ADM2": {
        "relativePath": "KOR/ADM2/geoBoundaries-KOR-ADM2_simplified.geojson",
        "sha256": "06d1b604a843b5cc8b7adb6483ca0e2fbf4fe5cbbd8d3633ebe0c6e1df01119f",
    },
    "MNG_ADM1": {
        "relativePath": "MNG/ADM1/geoBoundaries-MNG-ADM1_simplified.geojson",
        "sha256": "4e692ea5cff967b716e59975768d1560ade8c9844fbe6831bd4d9e6a7123f7aa",
    },
    "MNG_ADM2": {
        "relativePath": "MNG/ADM2/geoBoundaries-MNG-ADM2_simplified.geojson",
        "sha256": "c1b915d68f353cd8844cb8d70120cc97d76f1620200506b6b6fe7b892bf04e47",
    },
}

USER_AGENT = (
    "CardBal-EastAsiaBoundaryGenerator/1.0 "
    "(https://github.com/iebb/TransitICReader; offline asset generation)"
)
NOMINATIM_LOOKUP_URL = "https://nominatim.openstreetmap.org/lookup"
NOMINATIM_POLYGON_THRESHOLD = 0.0025
NOMINATIM_LOOKUP_BATCH_SIZE = 50
DEFAULT_NOMINATIM_DELAY_SECONDS = 1.1

CHINA_RELATION_MANIFEST_SHA256 = "ad76dffb1cfe6119fe03be51aaf214e81826cf9c69add5e2b74feb964fad5e87"
CHINA_OVERPASS_QUERY_SNAPSHOT_SHA256 = "5bdcf91cc72321b5c3ae9091a429e30ed7b08b07ba6da1c00a42a9fbe196329b"
EXPECTED_CHINA_REGISTRY_CITY_COUNT = 368
EXPECTED_CHINA_EXACT_NAME_MATCH_COUNT = 338
EXPECTED_CHINA_REVIEWED_ABBREVIATION_MATCH_COUNT = 30
EXPECTED_CHINA_REFERENCE_ONLY_COUNT = 1
EXPECTED_CHINA_REFERENCE_BOUNDARY_COUNT = 369
EXPECTED_CHINA_DISPLAYED_CITY_COUNT = 352
EXPECTED_CHINA_REVIEWED_ALIAS_COUNT = 53
EXPECTED_CHINA_PROVINCE_ONLY_CODE_COUNT = 9
CHINA_EXCLUDED_CITY_BOUNDARY_CODES = frozenset(
    {
        "1930",
        "3917",
        "5311",
        "6427",
        "6432",
        "6434",
        "6437",
        "6440",
        "8280",
        "8540",
        "8560",
        "8570",
        "8830",
        "8960",
        "9045",
        "9046",
    }
)
CHINA_PARTICIPATION_PAGE_REVISION_ID = 93532381
CHINA_PARTICIPATION_PAGE_REVISION_TIMESTAMP = "2026-07-18T11:11:46Z"
CHINA_PARTICIPATION_PAGE_HTML_SHA256 = "fe4ba8e0fa8d7c1769b19a25a13b394a48dc5a4a0dc8f6794ac16ecec09a02fb"
CHINA_REFERENCE_ONLY_RELATIONS = frozenset({"1867188"})
CHINA_COASTAL_VALIDATION_CITY_CODES = {
    "2900": "Shanghai",
    "2220": "Dalian",
    "3930": "Xiamen",
    "4520": "Qingdao",
    "5810": "Guangzhou",
    "5840": "Shenzhen",
}

NATURAL_EARTH_COMMIT = "f1890d9f152c896d250a77557a5751a93d494776"
NATURAL_EARTH_LAND_PATH = "geojson/ne_10m_land.geojson"
NATURAL_EARTH_LAND_URL = (
    "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/"
    f"{NATURAL_EARTH_COMMIT}/{NATURAL_EARTH_LAND_PATH}"
)
NATURAL_EARTH_LAND_SHA256 = "1ac90796408bc6ad6911d69448485d3c4dbf2190370080368a09976e1c9f7416"

COORDINATE_DECIMALS = 4
CHINA_COORDINATE_DECIMALS = 5
OUTPUT_QUANTIZATION_CONTAINMENT_BUFFER_DEGREES = 0.000008
JAPAN_RDP_TOLERANCE = 0.002
CHINA_RDP_TOLERANCE = 0.001
KOREA_RDP_TOLERANCE = 0.0015
MONGOLIA_RDP_TOLERANCE = 0.002
JAPAN_GRID_SIZE = 0.5
JAPAN_NEAREST_FALLBACK_DEGREES = 0.02
MAX_OUTPUT_BYTES = 10 * 1024 * 1024

KOREA_AREA_SPECS = {
    "서울특별시": {"name": "Seoul", "level": "ADM1", "shapeName": "Seoul"},
    "인천광역시": {"name": "Incheon", "level": "ADM1", "shapeName": "Incheon"},
    "부산광역시": {"name": "Busan", "level": "ADM1", "shapeName": "Busan"},
    "대구광역시": {"name": "Daegu", "level": "ADM1", "shapeName": "Daegu"},
    "대전광역시": {"name": "Daejeon", "level": "ADM1", "shapeName": "Daejeon"},
    "광주광역시": {"name": "Gwangju", "level": "ADM1", "shapeName": "Gwangju"},
    "울산광역시": {"name": "Ulsan", "level": "ADM1", "shapeName": "Ulsan"},
    "제주특별자치도": {"name": "Jeju", "level": "ADM1", "shapeName": "Jeju"},
    "경기도|포천시": {"name": "Pocheon", "level": "ADM2", "shapeName": "Pocheon-si"},
    "경기도|안양시": {"name": "Anyang", "level": "ADM2", "shapeName": "Anyang-si"},
    "경기도|수원시": {"name": "Suwon", "level": "ADM2", "shapeName": "Suwon-si"},
    "경기도|화성시": {"name": "Hwaseong", "level": "ADM2", "shapeName": "Hwaseong-si"},
    "경기도|광명시": {"name": "Gwangmyeong", "level": "ADM2", "shapeName": "Gwangmyeong-si"},
    "경기도|평택시": {"name": "Pyeongtaek", "level": "ADM2", "shapeName": "Pyeongtaek-si"},
    "경기도|의정부시": {"name": "Uijeongbu", "level": "ADM2", "shapeName": "Uijeongbu-si"},
    "경기도|의왕시": {"name": "Uiwang", "level": "ADM2", "shapeName": "Uiwang-si"},
    "경기도|양주시": {"name": "Yangju", "level": "ADM2", "shapeName": "Yangju-si"},
    "경기도|안성시": {"name": "Anseong", "level": "ADM2", "shapeName": "Anseong-si"},
    "경기도|부천시": {"name": "Bucheon", "level": "ADM2", "shapeName": "Bucheon-si"},
    "경기도|군포시": {"name": "Gunpo", "level": "ADM2", "shapeName": "Gunpo-si"},
    "경기도|용인시": {"name": "Yongin", "level": "ADM2", "shapeName": "Yongin-si"},
    "경기도|고양시": {"name": "Goyang", "level": "ADM2", "shapeName": "Goyang-si"},
    "경기도|이천시": {"name": "Icheon", "level": "ADM2", "shapeName": "Icheon-si"},
    "경상남도|창원시": {"name": "Changwon", "level": "ADM2", "shapeName": "Changwon-si"},
    "경상남도|양산시": {"name": "Yangsan", "level": "ADM2", "shapeName": "Yangsan-si"},
    "경상남도|진주시": {"name": "Jinju", "level": "ADM2", "shapeName": "Jinju-si"},
    "경상남도|김해시": {"name": "Gimhae", "level": "ADM2", "shapeName": "Gimhae-si"},
    "경상남도|밀양시": {"name": "Miryang", "level": "ADM2", "shapeName": "Miryang-si"},
    "경상남도|함안군": {"name": "Haman", "level": "ADM2", "shapeName": "Haman-gun"},
    "경상남도|통영시": {"name": "Tongyeong", "level": "ADM2", "shapeName": "Tongyeong-si"},
    "경상남도|거제시": {"name": "Geoje", "level": "ADM2", "shapeName": "Geoje-si"},
    "경상남도|사천시": {"name": "Sacheon", "level": "ADM2", "shapeName": "Sacheon-si"},
    "경상북도|포항시": {"name": "Pohang", "level": "ADM2", "shapeName": "Pohang-si"},
    "경상북도|안동시": {"name": "Andong", "level": "ADM2", "shapeName": "Andong-si"},
    "충청남도|천안시": {"name": "Cheonan", "level": "ADM2", "shapeName": "Cheonan-si"},
    "충청남도|아산시": {"name": "Asan", "level": "ADM2", "shapeName": "Asan-si"},
    "강원특별자치도|원주시": {"name": "Wonju", "level": "ADM2", "shapeName": "Wonju-si"},
    "강원특별자치도|횡성군": {"name": "Hoengseong", "level": "ADM2", "shapeName": "Hoengseong-gun"},
    "강원특별자치도|춘천시": {"name": "Chuncheon", "level": "ADM2", "shapeName": "Chuncheon-si"},
    "강원특별자치도|강릉시": {"name": "Gangneung", "level": "ADM2", "shapeName": "Gangneung-si"},
    "전라남도|순천시": {"name": "Suncheon", "level": "ADM2", "shapeName": "Suncheon-si"},
    "전라남도|목포시": {"name": "Mokpo", "level": "ADM2", "shapeName": "Mokpo-si"},
    "전라남도|광양시": {"name": "Gwangyang", "level": "ADM2", "shapeName": "Gwangyang-si"},
    "전라남도|여수시": {"name": "Yeosu", "level": "ADM2", "shapeName": "Yeosu-si"},
    "전라남도|나주시": {"name": "Naju", "level": "ADM2", "shapeName": "Naju-si"},
}

# The pinned KOR ADM2 snapshot predates Gunwi-gun's transfer to Daegu. Its 74
# metropolitan subdivisions would stack inside the eight city-level ADM1
# outlines, so they are reference-excluded. The duplicate Sejong-si ADM2 shape
# is omitted in favor of its city-level ADM1 outline. Jeju-si and Seogwipo-si
# are also excluded until exact card evidence can distinguish their visits.
KOREA_CITY_ADM1_REFERENCE_SHAPE_NAMES = frozenset({
    "Busan",
    "Daegu",
    "Daejeon",
    "Gwangju",
    "Incheon",
    "Sejong",
    "Seoul",
    "Ulsan",
})
KOREA_METROPOLITAN_ADM2_GUN_SHAPE_NAMES = frozenset({
    "Dalseong-gun",
    "Ganghwa-gun",
    "Gijang-gun",
    "Ongjin-gun",
    "Ulju-gun",
})
KOREA_WHOLE_AREA_ADM1_REFERENCE_SHAPE_NAMES = frozenset({"Jeju"})
KOREA_CITY_REFERENCE_EXCLUDED_ADM2_SHAPE_NAMES = frozenset({
    "Jeju-si",
    "Sejong-si",
    "Seogwipo-si",
})
EXPECTED_KOREA_ADM2_FEATURE_COUNT = 228
EXPECTED_KOREA_METROPOLITAN_ADM2_FEATURE_COUNT = 74
EXPECTED_KOREA_CITY_REFERENCE_BOUNDARY_COUNT = 160
EXPECTED_KOREA_VISIT_BOUNDARY_COUNT = 45
EXPECTED_KOREA_MODE_MAPPING_COUNT = 198
EXPECTED_KOREA_MODE_AREA_COUNT = 32

EXPECTED_MONGOLIA_ADM1_FEATURE_COUNT = 22
EXPECTED_MONGOLIA_ADM2_FEATURE_COUNT = 339
EXPECTED_MONGOLIA_CITY_BOUNDARY_COUNT = 4
EXPECTED_MONGOLIA_MAPPED_STATION_COUNT = 1_499
EXPECTED_MONGOLIA_NEAREST_FALLBACK_STATION_COUNT = 12
MONGOLIA_NEAREST_FALLBACK_DEGREES = 0.02
MONGOLIA_CITY_SPECS = {
    "93677404B51496043907868": {
        "name": "Sergelen",
        "nativeName": "Сэргэлэн",
    },
    "93677404B44653121732783": {
        "name": "Erdene",
        "nativeName": "Эрдэнэ",
    },
    "93677404B81168831538061": {
        "name": "Bayandelger",
        "nativeName": "Баяндэлгэр",
    },
}

# Exact station aliases remain authoritative. These reviewed KOTRIS groups are
# used only when a 52-byte record's station token is unknown. Broad or
# multi-city modes (KORAIL, Airport Railroad/limousine, capital-area and
# province-wide services) are deliberately absent. Jeju and Seogwipo modes both
# use the whole-Jeju boundary so the city layer never stacks nested masks.
KOREA_MODE_CODES_BY_AREA: dict[str, frozenset[int]] = {
    "서울특별시": frozenset({105, 115, 120, 121, 131, 142, 201, 203, 205, 235, 237}),
    "인천광역시": frozenset(
        {204, 400, 402, 403, 404, 406, 408, 430, 431, 496}
        | set(range(450, 468))
        | {470, 471, 472, 474, 475, 476, 477}
        | set(range(480, 492))
    ),
    "부산광역시": frozenset(set(range(601, 619)) | {870}),
    "울산광역시": frozenset(range(621, 627)),
    "경상남도|창원시": frozenset(range(627, 632)),
    "경상남도|양산시": frozenset(range(632, 637)),
    "경상남도|진주시": frozenset(range(637, 641)),
    "경상남도|김해시": frozenset(range(641, 645)),
    "경상남도|밀양시": frozenset(range(645, 648)),
    "경상남도|함안군": frozenset(range(648, 651)),
    "충청남도|천안시": frozenset(range(651, 656)),
    "충청남도|아산시": frozenset(range(656, 661)),
    "대전광역시": frozenset(set(range(672, 684)) | {853}),
    "광주광역시": frozenset({691, 871} | set(range(770, 776))),
    "경상북도|포항시": frozenset(range(701, 704)),
    "경상남도|통영시": frozenset(range(704, 706)),
    "경상북도|안동시": frozenset(range(706, 709)),
    "경상남도|거제시": frozenset(range(709, 711)),
    "강원특별자치도|원주시": frozenset({321} | set(range(711, 714))),
    "강원특별자치도|횡성군": frozenset(range(714, 717)),
    "강원특별자치도|춘천시": frozenset(range(717, 720)),
    "강원특별자치도|강릉시": frozenset(range(720, 722)),
    "전라남도|순천시": frozenset(range(776, 780)),
    "전라남도|목포시": frozenset(range(780, 784)),
    "전라남도|광양시": frozenset(range(784, 788)),
    "전라남도|여수시": frozenset(range(788, 792)),
    "전라남도|나주시": frozenset(range(792, 796)),
    "경상남도|사천시": frozenset(range(796, 800)),
    "경기도|용인시": frozenset({231, 851}),
    "경기도|의정부시": frozenset({232}),
    "대구광역시": frozenset({872}),
    "제주특별자치도": frozenset(range(990, 1000)),
}
KOREA_MODE_TO_AREA = {
    str(code): area_key
    for area_key, codes in KOREA_MODE_CODES_BY_AREA.items()
    for code in codes
}
KOREA_MODE_EXPLICIT_AREA_BY_CODE: dict[int, str | None] = {
    **{code: "서울특별시" for code in (105, 115, 120, 121, 131, 142, 201, 203, 205, 235, 237)},
    202: None,
    204: "인천광역시",
    206: None,
    207: None,
    208: None,
    231: "경기도|용인시",
    232: "경기도|의정부시",
    699: None,
    811: None,
    812: None,
    816: None,
    818: None,
    820: None,
    850: None,
    851: "경기도|용인시",
    853: "대전광역시",
    870: "부산광역시",
    871: "광주광역시",
    872: "대구광역시",
}
KOREA_MODE_AREA_NAME_MARKERS: tuple[tuple[str, str | None], ...] = (
    ("인천", "인천광역시"),
    ("경기", None),
    ("부산", "부산광역시"),
    ("울산", "울산광역시"),
    ("마산/창원/진해", "경상남도|창원시"),
    ("양산", "경상남도|양산시"),
    ("진주", "경상남도|진주시"),
    ("김해", "경상남도|김해시"),
    ("밀양", "경상남도|밀양시"),
    ("함안", "경상남도|함안군"),
    ("천안", "충청남도|천안시"),
    ("아산", "충청남도|아산시"),
    ("충남", None),
    ("대전", "대전광역시"),
    ("포항", "경상북도|포항시"),
    ("통영", "경상남도|통영시"),
    ("안동", "경상북도|안동시"),
    ("거제", "경상남도|거제시"),
    ("원주", "강원특별자치도|원주시"),
    ("횡성", "강원특별자치도|횡성군"),
    ("춘천", "강원특별자치도|춘천시"),
    ("강릉", "강원특별자치도|강릉시"),
    ("강원", None),
    ("광주", "광주광역시"),
    ("순천", "전라남도|순천시"),
    ("목포", "전라남도|목포시"),
    ("광양", "전라남도|광양시"),
    ("여수", "전라남도|여수시"),
    ("나주", "전라남도|나주시"),
    ("사천", "경상남도|사천시"),
    ("제주", "제주특별자치도"),
    ("서귀포", "제주특별자치도"),
)


Point = list[float]
Ring = list[Point]
PolygonPart = tuple[Ring, list[Ring]]
BBox = tuple[float, float, float, float]


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def normalized_boundary_name(value: Any) -> str:
    if value is None:
        return ""
    text = str(value).strip()
    return "" if text.casefold() in {"none", "null"} else text


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def download_verified_json(
    url: str,
    destination: Path,
    expected_sha256: str,
    label: str,
) -> dict[str, Any]:
    destination.parent.mkdir(parents=True, exist_ok=True)
    if not destination.is_file():
        request = urllib.request.Request(
            url,
            headers={"User-Agent": USER_AGENT, "Accept": "application/geo+json, application/json"},
        )
        temporary_path = destination.with_name(f".{destination.name}.download")
        try:
            with urllib.request.urlopen(request, timeout=180) as response, temporary_path.open("wb") as output:
                while chunk := response.read(1024 * 1024):
                    output.write(chunk)
            temporary_path.replace(destination)
        finally:
            if temporary_path.exists():
                temporary_path.unlink()

    actual_sha256 = sha256_file(destination)
    if actual_sha256 != expected_sha256:
        raise RuntimeError(
            f"{label} checksum mismatch: expected {expected_sha256}, got {actual_sha256}"
        )
    payload = load_json(destination)
    if not isinstance(payload, dict):
        raise RuntimeError(f"Unexpected {label} JSON payload")
    return payload


def download_geoboundaries_asset(asset_key: str, destination: Path) -> dict[str, Any]:
    asset = GEBOUNDARIES_ASSETS[asset_key]
    url = f"{GEBOUNDARIES_MEDIA_ROOT}/{asset['relativePath']}"
    payload = download_verified_json(
        url,
        destination,
        asset["sha256"],
        f"geoBoundaries {asset_key}",
    )
    if payload.get("type") != "FeatureCollection" or not isinstance(payload.get("features"), list):
        raise RuntimeError(f"Unexpected geoBoundaries payload for {asset_key}")
    return payload


def geometry_parts(geometry: dict[str, Any]) -> list[PolygonPart]:
    geometry_type = geometry.get("type")
    coordinates = geometry.get("coordinates")
    if geometry_type == "Polygon":
        polygons = [coordinates]
    elif geometry_type == "MultiPolygon":
        polygons = coordinates
    else:
        raise ValueError(f"Unsupported geometry type: {geometry_type}")

    parts: list[PolygonPart] = []
    for polygon in polygons or []:
        if not polygon:
            continue
        outer = [[float(point[0]), float(point[1])] for point in polygon[0]]
        holes = [
            [[float(point[0]), float(point[1])] for point in ring]
            for ring in polygon[1:]
            if ring
        ]
        if len(outer) >= 4:
            parts.append((outer, holes))
    if not parts:
        raise ValueError("Polygon geometry contains no usable outer rings")
    return parts


def ring_signed_area(ring: Ring) -> float:
    if len(ring) < 3:
        return 0.0
    area_twice = 0.0
    for left, right in zip(ring, ring[1:] + ring[:1]):
        area_twice += left[0] * right[1] - right[0] * left[1]
    return area_twice / 2.0


def parts_bbox(parts: Iterable[PolygonPart]) -> BBox:
    points = [point for outer, _holes in parts for point in outer]
    return (
        min(point[0] for point in points),
        min(point[1] for point in points),
        max(point[0] for point in points),
        max(point[1] for point in points),
    )


def parts_area(parts: Iterable[PolygonPart]) -> float:
    return sum(abs(ring_signed_area(outer)) for outer, _holes in parts)


def point_on_segment(point: tuple[float, float], left: Point, right: Point) -> bool:
    px, py = point
    ax, ay = left
    bx, by = right
    cross = (px - ax) * (by - ay) - (py - ay) * (bx - ax)
    if abs(cross) > 1e-10:
        return False
    return min(ax, bx) - 1e-10 <= px <= max(ax, bx) + 1e-10 and min(ay, by) - 1e-10 <= py <= max(ay, by) + 1e-10


def point_in_ring(point: tuple[float, float], ring: Ring) -> bool:
    x, y = point
    inside = False
    previous = ring[-1]
    for current in ring:
        if point_on_segment(point, previous, current):
            return True
        x1, y1 = previous
        x2, y2 = current
        if (y1 > y) != (y2 > y):
            intersection_x = (x2 - x1) * (y - y1) / (y2 - y1) + x1
            if x < intersection_x:
                inside = not inside
        previous = current
    return inside


def point_in_parts(point: tuple[float, float], parts: list[PolygonPart]) -> bool:
    for outer, holes in parts:
        if point_in_ring(point, outer) and not any(point_in_ring(point, hole) for hole in holes):
            return True
    return False


def squared_segment_distance(point: tuple[float, float], left: Point, right: Point) -> float:
    """Return an approximate local angular distance, correcting longitude by latitude."""

    longitude_scale = math.cos(math.radians(point[1]))
    px, py = point[0] * longitude_scale, point[1]
    ax, ay = left[0] * longitude_scale, left[1]
    bx, by = right[0] * longitude_scale, right[1]
    dx, dy = bx - ax, by - ay
    if dx == 0.0 and dy == 0.0:
        return (px - ax) ** 2 + (py - ay) ** 2
    projection = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)))
    nearest_x, nearest_y = ax + projection * dx, ay + projection * dy
    return (px - nearest_x) ** 2 + (py - nearest_y) ** 2


def point_to_parts_distance(point: tuple[float, float], parts: list[PolygonPart]) -> float:
    if point_in_parts(point, parts):
        return 0.0
    minimum = math.inf
    for outer, _holes in parts:
        for left, right in zip(outer, outer[1:]):
            minimum = min(minimum, squared_segment_distance(point, left, right))
    return math.sqrt(minimum)


def perpendicular_distance_squared(point: Point, left: Point, right: Point) -> float:
    dx, dy = right[0] - left[0], right[1] - left[1]
    if dx == 0.0 and dy == 0.0:
        return (point[0] - left[0]) ** 2 + (point[1] - left[1]) ** 2
    numerator = dy * point[0] - dx * point[1] + right[0] * left[1] - right[1] * left[0]
    return numerator * numerator / (dx * dx + dy * dy)


def rdp(points: Ring, tolerance: float) -> Ring:
    if len(points) <= 2:
        return points[:]
    tolerance_squared = tolerance * tolerance
    keep = {0, len(points) - 1}
    pending = [(0, len(points) - 1)]
    while pending:
        start, end = pending.pop()
        furthest_index = -1
        furthest_distance = -1.0
        for index in range(start + 1, end):
            distance = perpendicular_distance_squared(points[index], points[start], points[end])
            if distance > furthest_distance:
                furthest_distance = distance
                furthest_index = index
        if furthest_index >= 0 and furthest_distance > tolerance_squared:
            keep.add(furthest_index)
            pending.append((start, furthest_index))
            pending.append((furthest_index, end))
    return [points[index] for index in sorted(keep)]


def simplify_ring(
    ring: Ring,
    tolerance: float,
    coordinate_decimals: int = COORDINATE_DECIMALS,
) -> Ring:
    open_ring = ring[:-1] if ring[0] == ring[-1] else ring[:]
    deduplicated: Ring = []
    for point in open_ring:
        if not deduplicated or point != deduplicated[-1]:
            deduplicated.append(point)
    if len(deduplicated) < 3:
        raise ValueError("Cannot simplify a degenerate polygon ring")

    simplified = rdp(deduplicated, tolerance)
    quantized: Ring = []
    for point in simplified:
        rounded = [round(point[0], coordinate_decimals), round(point[1], coordinate_decimals)]
        if not quantized or rounded != quantized[-1]:
            quantized.append(rounded)
    if len(quantized) < 3:
        quantized = []
        for point in deduplicated:
            rounded = [round(point[0], coordinate_decimals), round(point[1], coordinate_decimals)]
            if not quantized or rounded != quantized[-1]:
                quantized.append(rounded)
    if len(quantized) < 3:
        raise ValueError("Quantization collapsed a polygon ring")
    if quantized[0] != quantized[-1]:
        quantized.append(quantized[0])
    return quantized


def parts_centroid(parts: list[PolygonPart]) -> Point:
    weighted_x = 0.0
    weighted_y = 0.0
    total_weight = 0.0
    fallback_points: list[Point] = []
    for outer, _holes in parts:
        ring = outer[:-1] if outer[0] == outer[-1] else outer
        fallback_points.extend(ring)
        cross_sum = 0.0
        centroid_x_sum = 0.0
        centroid_y_sum = 0.0
        for left, right in zip(ring, ring[1:] + ring[:1]):
            cross = left[0] * right[1] - right[0] * left[1]
            cross_sum += cross
            centroid_x_sum += (left[0] + right[0]) * cross
            centroid_y_sum += (left[1] + right[1]) * cross
        if abs(cross_sum) < 1e-12:
            continue
        centroid_x = centroid_x_sum / (3.0 * cross_sum)
        centroid_y = centroid_y_sum / (3.0 * cross_sum)
        weight = abs(cross_sum / 2.0)
        weighted_x += centroid_x * weight
        weighted_y += centroid_y * weight
        total_weight += weight
    if total_weight:
        return [
            round(weighted_x / total_weight, COORDINATE_DECIMALS),
            round(weighted_y / total_weight, COORDINATE_DECIMALS),
        ]
    return [
        round(sum(point[0] for point in fallback_points) / len(fallback_points), COORDINATE_DECIMALS),
        round(sum(point[1] for point in fallback_points) / len(fallback_points), COORDINATE_DECIMALS),
    ]


def make_boundary(
    boundary_id: str,
    country_code: str,
    name: str,
    native_name: str,
    parts: list[PolygonPart],
    tolerance: float,
    coordinate_decimals: int = COORDINATE_DECIMALS,
) -> dict[str, Any]:
    bbox = parts_bbox(parts)
    components: list[dict[str, Any]] = []
    for outer, holes in parts:
        try:
            simplified_outer = simplify_ring(outer, tolerance, coordinate_decimals)
        except ValueError:
            # Some source multipolygons include microscopic slivers that become
            # fewer than three distinct points at the output quantization.
            # Omitting only those degenerate pieces preserves useful parts.
            continue
        simplified_holes: list[Ring] = []
        for hole in holes:
            try:
                simplified_holes.append(
                    simplify_ring(hole, tolerance, coordinate_decimals)
                )
            except ValueError:
                # A hole that collapses at the selected output precision has no
                # representable interior area and can be omitted independently.
                continue
        simplified_holes.sort(
            key=lambda ring: (
                -abs(ring_signed_area(ring)),
                tuple(tuple(point) for point in ring),
            )
        )
        components.append({"outer": simplified_outer, "holes": simplified_holes})
    if not components:
        raise ValueError(
            f"Boundary {boundary_id} contains no usable components after simplification"
        )
    components.sort(
        key=lambda component: (
            -abs(ring_signed_area(component["outer"])),
            tuple(tuple(point) for point in component["outer"]),
            tuple(
                tuple(tuple(point) for point in hole)
                for hole in component["holes"]
            ),
        )
    )
    return {
        "id": boundary_id,
        "countryCode": country_code,
        "name": normalized_boundary_name(name),
        "nativeName": normalized_boundary_name(native_name),
        "center": parts_centroid(parts),
        "bbox": [round(value, COORDINATE_DECIMALS) for value in bbox],
        "components": components,
    }


def grid_cell(longitude: float, latitude: float) -> tuple[int, int]:
    return (math.floor(longitude / JAPAN_GRID_SIZE), math.floor(latitude / JAPAN_GRID_SIZE))


def grid_cells_for_bbox(bbox: BBox) -> Iterable[tuple[int, int]]:
    min_x, min_y = grid_cell(bbox[0], bbox[1])
    max_x, max_y = grid_cell(bbox[2], bbox[3])
    for x in range(min_x, max_x + 1):
        for y in range(min_y, max_y + 1):
            yield x, y


def japanese_native_municipality(address: str) -> str | None:
    value = address.strip()
    value = re.sub(r"^(?:北海道|東京都|京都府|大阪府|[^都道府県]{2,4}県)", "", value)
    city_ward = re.match(r"^([^市区町村郡]{1,16}市[^市区町村郡]{1,16}区)", value)
    if city_ward:
        return city_ward.group(1)
    county = re.match(r"^[^市区町村郡]{1,16}郡([^市区町村郡]{1,16}[町村])", value)
    if county:
        return county.group(1)
    municipality = re.match(r"^([^市区町村郡]{1,20}[市区町村])", value)
    return municipality.group(1) if municipality else None


def prepare_japan_adm1_features(feature_collection: dict[str, Any]) -> list[dict[str, Any]]:
    features: list[dict[str, Any]] = []
    for source_feature in feature_collection["features"]:
        properties = source_feature.get("properties", {})
        subdivision_code = str(properties.get("shapeISO", "")).strip()
        shape_name = normalized_boundary_name(properties.get("shapeName"))
        if not re.fullmatch(r"JP-\d{2}", subdivision_code):
            raise RuntimeError(
                f"JPN ADM1 feature {shape_name!r} has invalid shapeISO {subdivision_code!r}"
            )
        parts = geometry_parts(source_feature["geometry"])
        features.append(
            {
                "code": subdivision_code,
                "name": shape_name,
                "parts": parts,
                "bbox": parts_bbox(parts),
                "area": parts_area(parts),
            }
        )
    if len(features) != 47 or len({feature["code"] for feature in features}) != 47:
        raise RuntimeError("Pinned JPN ADM1 source must contain all 47 unique prefectures")
    return features


def japanese_prefecture_for_parts(
    parts: list[PolygonPart],
    prefectures: list[dict[str, Any]],
) -> dict[str, Any]:
    candidate_points = [tuple(parts_centroid(parts))]
    candidate_points.extend(
        tuple(parts_centroid([part]))
        for part in sorted(parts, key=lambda part: abs(ring_signed_area(part[0])), reverse=True)
    )
    for outer, _holes in sorted(
        parts,
        key=lambda part: abs(ring_signed_area(part[0])),
        reverse=True,
    ):
        ring = outer[:-1] if outer[0] == outer[-1] else outer
        stride = max(1, len(ring) // 20)
        for index in range(0, len(ring), stride):
            left = ring[index]
            right = ring[(index + 1) % len(ring)]
            candidate_points.append(
                ((left[0] + right[0]) / 2.0, (left[1] + right[1]) / 2.0)
            )
    for point in candidate_points:
        containing = [
            prefecture
            for prefecture in prefectures
            if bbox_contains(prefecture["bbox"], point)
            and point_in_parts(point, prefecture["parts"])
        ]
        if containing:
            return min(containing, key=lambda prefecture: (prefecture["area"], prefecture["code"]))
    raise RuntimeError(
        "Could not assign a JPN ADM2 feature to an ADM1 prefecture using pinned geometry"
    )


def prepare_japan_features(
    feature_collection: dict[str, Any],
    adm1_feature_collection: dict[str, Any],
) -> tuple[list[dict[str, Any]], dict[tuple[int, int], list[int]]]:
    prefectures = prepare_japan_adm1_features(adm1_feature_collection)
    features: list[dict[str, Any]] = []
    index: dict[tuple[int, int], list[int]] = defaultdict(list)
    for source_feature in feature_collection["features"]:
        properties = source_feature.get("properties", {})
        shape_id = str(properties.get("shapeID", ""))
        shape_name = normalized_boundary_name(properties.get("shapeName"))
        if not shape_id:
            continue
        parts = geometry_parts(source_feature["geometry"])
        prefecture = japanese_prefecture_for_parts(parts, prefectures)
        feature = {
            "id": f"jp:{shape_id}",
            "name": shape_name,
            "prefectureCode": prefecture["code"],
            "prefectureName": prefecture["name"],
            "parts": parts,
            "bbox": parts_bbox(parts),
            "area": parts_area(parts),
        }
        feature_index = len(features)
        features.append(feature)
        for cell in grid_cells_for_bbox(feature["bbox"]):
            index[cell].append(feature_index)
    return features, index


def bbox_contains(bbox: BBox, point: tuple[float, float]) -> bool:
    return bbox[0] <= point[0] <= bbox[2] and bbox[1] <= point[1] <= bbox[3]


def join_japanese_stations(
    database_path: Path,
    feature_collection: dict[str, Any],
    adm1_feature_collection: dict[str, Any],
    coverage: dict[str, Any],
) -> tuple[list[dict[str, Any]], dict[str, str], dict[str, int]]:
    features, spatial_index = prepare_japan_features(
        feature_collection,
        adm1_feature_collection,
    )
    supported_prefectures = coverage.get("supportedPrefectures")
    omitted_prefectures = coverage.get("omittedPrefectures")
    if not isinstance(supported_prefectures, list) or not isinstance(omitted_prefectures, list):
        raise RuntimeError("Japan transit coverage must list supported and omitted prefectures")
    supported_codes = {str(item.get("code", "")) for item in supported_prefectures}
    omitted_codes = {str(item.get("code", "")) for item in omitted_prefectures}
    source_codes = {feature["prefectureCode"] for feature in features}
    if supported_codes & omitted_codes or supported_codes | omitted_codes != source_codes:
        raise RuntimeError(
            "Japan transit coverage must classify every pinned JPN ADM1 prefecture exactly once"
        )
    expected_names = {
        str(item.get("code", "")): normalized_boundary_name(item.get("name"))
        for item in supported_prefectures + omitted_prefectures
    }
    actual_names = {
        feature["code"]: feature["name"]
        for feature in prepare_japan_adm1_features(adm1_feature_collection)
    }
    if expected_names != actual_names:
        raise RuntimeError("Japan transit coverage names do not match pinned JPN ADM1 names")

    matches_by_hex_code: dict[str, Counter[str]] = defaultdict(Counter)
    native_names: dict[str, Counter[str]] = defaultdict(Counter)
    matched_rows = 0
    nearest_fallback_rows = 0
    excluded_rows = 0
    prefecture_mismatch_rows = 0
    input_rows = 0

    connection = sqlite3.connect(database_path)
    try:
        rows = connection.execute(
            """
            SELECT hex_code, longitude, latitude, address, prefecture
            FROM jp_stations
            WHERE is_pseudo = 0
            ORDER BY hex_code
            """
        ).fetchall()
    finally:
        connection.close()

    input_hex_codes = {str(row[0]).strip().upper() for row in rows}
    if len(input_hex_codes) != len(rows):
        raise RuntimeError("Non-pseudo jp_stations rows do not have unique hex_code values")
    invalid_hex_codes = sorted(code for code in input_hex_codes if not re.fullmatch(r"[0-9A-F]{5}", code))
    if invalid_hex_codes:
        raise RuntimeError(f"Japanese station hex_code values must be five uppercase hexadecimal characters: {invalid_hex_codes[:10]}")

    supported_input_hex_codes: set[str] = set()
    for hex_code_value, longitude_value, latitude_value, address_value, prefecture_value in rows:
        input_rows += 1
        hex_code = str(hex_code_value).strip().upper()
        prefecture_code = f"JP-{int(prefecture_value):02d}"
        if prefecture_code not in supported_codes:
            excluded_rows += 1
            continue
        supported_input_hex_codes.add(hex_code)
        point = (float(longitude_value), float(latitude_value))
        candidates = spatial_index.get(grid_cell(*point), [])
        contained = [
            feature_index
            for feature_index in candidates
            if features[feature_index]["prefectureCode"] == prefecture_code
            and bbox_contains(features[feature_index]["bbox"], point)
            and point_in_parts(point, features[feature_index]["parts"])
        ]
        selected_index: int | None = None
        if contained:
            selected_index = min(contained, key=lambda index: (features[index]["area"], features[index]["id"]))
        else:
            base_x, base_y = grid_cell(*point)
            nearby_indices = {
                feature_index
                for x in range(base_x - 1, base_x + 2)
                for y in range(base_y - 1, base_y + 2)
                for feature_index in spatial_index.get((x, y), [])
                if features[feature_index]["prefectureCode"] == prefecture_code
            }
            if nearby_indices:
                nearest_index, nearest_distance = min(
                    (
                        (feature_index, point_to_parts_distance(point, features[feature_index]["parts"]))
                        for feature_index in nearby_indices
                    ),
                    key=lambda item: (item[1], features[item[0]]["area"], features[item[0]]["id"]),
                )
                if nearest_distance <= JAPAN_NEAREST_FALLBACK_DEGREES:
                    selected_index = nearest_index
                    nearest_fallback_rows += 1

        if selected_index is None:
            continue
        if features[selected_index]["prefectureCode"] != prefecture_code:
            prefecture_mismatch_rows += 1
            continue
        matched_rows += 1
        boundary_id = features[selected_index]["id"]
        matches_by_hex_code[hex_code][boundary_id] += 1
        native_name = japanese_native_municipality(str(address_value or ""))
        if native_name:
            native_names[boundary_id][native_name] += 1

    station_mapping: dict[str, str] = {}
    ambiguous_hex_codes = 0
    for hex_code, matches in matches_by_hex_code.items():
        if len(matches) > 1:
            ambiguous_hex_codes += 1
        boundary_id = min(matches, key=lambda candidate: (-matches[candidate], candidate))
        station_mapping[hex_code] = boundary_id

    used_ids = set(station_mapping.values())
    boundary_records = []
    for feature in features:
        if feature["id"] not in used_ids:
            continue
        native_name = feature["name"]
        if native_names[feature["id"]]:
            native_name = min(
                native_names[feature["id"]],
                key=lambda candidate: (-native_names[feature["id"]][candidate], candidate),
            )
        boundary = make_boundary(
                boundary_id=feature["id"],
                country_code="JP",
                name=feature["name"],
                native_name=native_name,
                parts=feature["parts"],
                tolerance=JAPAN_RDP_TOLERANCE,
            )
        boundary["subdivisionCode"] = feature["prefectureCode"]
        boundary_records.append(boundary)

    emitted_ids = {boundary["id"] for boundary in boundary_records}
    if emitted_ids != used_ids:
        raise RuntimeError(
            "Japanese station-backed boundary mismatch: "
            f"missing={sorted(used_ids - emitted_ids)}, "
            f"unexpected={sorted(emitted_ids - used_ids)}"
        )

    station_mapping = dict(sorted(station_mapping.items()))
    expected_counts = coverage.get("expectedCounts") or {}
    actual_counts = {
        "bundledNonPseudoStationRows": input_rows,
        "supportedStationRows": len(supported_input_hex_codes),
        "excludedStationRows": excluded_rows,
        "sourceADM2Boundaries": len(features),
        "supportedADM2Boundaries": sum(
            feature["prefectureCode"] in supported_codes for feature in features
        ),
        "excludedADM2Boundaries": sum(
            feature["prefectureCode"] not in supported_codes for feature in features
        ),
    }
    for key, actual_value in actual_counts.items():
        expected_value = expected_counts.get(key)
        if expected_value != actual_value:
            raise RuntimeError(
                f"Japan coverage count {key} changed: expected {expected_value}, got {actual_value}"
            )
    if prefecture_mismatch_rows:
        raise RuntimeError(
            f"{prefecture_mismatch_rows} Japanese station rows mapped outside their bundled prefecture"
        )
    stats = {
        "inputNonPseudoRows": input_rows,
        "inputUniqueHexCodes": len(input_hex_codes),
        "supportedScopeRows": len(supported_input_hex_codes),
        "excludedByPrefectureRows": excluded_rows,
        "matchedRows": matched_rows,
        "mappedUniqueHexCodes": len(station_mapping),
        "unmappedSupportedUniqueHexCodes": len(supported_input_hex_codes - set(station_mapping)),
        "nearestBoundaryFallbackRows": nearest_fallback_rows,
        "ambiguousUniqueHexCodes": ambiguous_hex_codes,
        "usedBoundaryCount": len(used_ids),
        "referenceBoundaryCount": len(boundary_records),
        "unreferencedReferenceBoundaryCount": 0,
        "supportedPrefectureBoundaryCount": actual_counts["supportedADM2Boundaries"],
        "stationBackedBoundaryCount": len(boundary_records),
        "stationlessSupportedPrefectureBoundaryCount": (
            actual_counts["supportedADM2Boundaries"] - len(boundary_records)
        ),
    }
    return boundary_records, station_mapping, stats


class NominatimClient:
    def __init__(self, delay_seconds: float, cache_directory: Path):
        self.delay_seconds = max(delay_seconds, 1.0)
        self.last_request_started = 0.0
        self.cache_directory = cache_directory
        self.cache_directory.mkdir(parents=True, exist_ok=True)

    def _rate_limit(self) -> None:
        elapsed = time.monotonic() - self.last_request_started
        if elapsed < self.delay_seconds:
            time.sleep(self.delay_seconds - elapsed)

    def lookup_relations(self, relation_ids: list[str]) -> dict[str, dict[str, Any]]:
        if len(relation_ids) != len(set(relation_ids)):
            raise RuntimeError("Nominatim relation lookup received duplicate IDs")
        results_by_id: dict[str, dict[str, Any]] = {}
        total_batches = math.ceil(len(relation_ids) / NOMINATIM_LOOKUP_BATCH_SIZE)
        for batch_index, offset in enumerate(
            range(0, len(relation_ids), NOMINATIM_LOOKUP_BATCH_SIZE),
            start=1,
        ):
            batch_ids = relation_ids[offset : offset + NOMINATIM_LOOKUP_BATCH_SIZE]
            print(
                f"Nominatim lookup batch {batch_index}/{total_batches} "
                f"({len(batch_ids)} relations)",
                flush=True,
            )
            payload = self._lookup_batch(batch_ids)
            expected_ids = set(batch_ids)
            actual_ids: set[str] = set()
            for result in payload:
                relation_id = str(result.get("osm_id") or "")
                if result.get("osm_type") != "relation" or relation_id not in expected_ids:
                    raise RuntimeError(
                        f"Nominatim returned unexpected OSM object {result.get('osm_type')} {relation_id}"
                    )
                if relation_id in actual_ids:
                    raise RuntimeError(f"Nominatim returned relation {relation_id} more than once")
                actual_ids.add(relation_id)
                results_by_id[relation_id] = result
            if actual_ids != expected_ids:
                raise RuntimeError(
                    "Nominatim relation batch was incomplete: "
                    f"missing={sorted(expected_ids - actual_ids)}, extra={sorted(actual_ids - expected_ids)}"
                )
        return results_by_id

    def _lookup_batch(self, relation_ids: list[str]) -> list[dict[str, Any]]:
        cache_key = hashlib.sha256(
            (",".join(relation_ids) + f"|{NOMINATIM_POLYGON_THRESHOLD}").encode("ascii")
        ).hexdigest()
        cache_path = self.cache_directory / f"lookup-{cache_key}.json"
        if cache_path.is_file():
            payload = load_json(cache_path)
            if not isinstance(payload, list):
                raise RuntimeError(f"Unexpected cached Nominatim payload in {cache_path}")
            return payload

        parameters = {
            "osm_ids": ",".join(f"R{relation_id}" for relation_id in relation_ids),
            "format": "jsonv2",
            "namedetails": "1",
            "extratags": "1",
            "polygon_geojson": "1",
            "polygon_threshold": str(NOMINATIM_POLYGON_THRESHOLD),
        }
        url = f"{NOMINATIM_LOOKUP_URL}?{urllib.parse.urlencode(parameters)}"
        last_error: Exception | None = None
        for attempt in range(4):
            self._rate_limit()
            request = urllib.request.Request(
                url,
                headers={
                    "User-Agent": USER_AGENT,
                    "Accept": "application/json",
                    "Accept-Language": "en,zh",
                },
            )
            self.last_request_started = time.monotonic()
            try:
                with urllib.request.urlopen(request, timeout=180) as response:
                    response_bytes = response.read()
                payload = json.loads(response_bytes.decode("utf-8"))
                if not isinstance(payload, list):
                    raise RuntimeError("Unexpected Nominatim lookup payload")
                cache_path.write_bytes(response_bytes)
                return payload
            except Exception as error:
                last_error = error
                time.sleep((attempt + 1) * 3.0)
        raise RuntimeError(f"Nominatim relation lookup failed: {last_error}")


def load_china_relation_manifest(
    registry_path: Path,
    coverage_path: Path,
    manifest_path: Path,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], dict[str, str]]:
    if sha256_file(manifest_path) != CHINA_RELATION_MANIFEST_SHA256:
        raise RuntimeError(
            "China relation manifest changed; review the complete T-Union code-to-relation set "
            "and update its pinned checksum before regenerating"
        )
    registry = load_json(registry_path)
    coverage = load_json(coverage_path)
    manifest = load_json(manifest_path)
    if not isinstance(registry, dict) or len(registry) != EXPECTED_CHINA_REGISTRY_CITY_COUNT:
        raise RuntimeError(
            f"Expected {EXPECTED_CHINA_REGISTRY_CITY_COUNT} T-Union registry cities"
        )
    if manifest.get("schemaVersion") != 1:
        raise RuntimeError(f"Unsupported China relation manifest {manifest.get('schemaVersion')!r}")
    if (manifest.get("source") or {}).get("querySnapshotSHA256") != CHINA_OVERPASS_QUERY_SNAPSHOT_SHA256:
        raise RuntimeError("China relation manifest does not identify the reviewed Overpass snapshot")
    if ((manifest.get("source") or {}).get("additionalNominatimExactRelations") or {}) != {
        "relationCount": 16,
        "retrievedAt": "2026-07-30",
        "service": "OpenStreetMap Nominatim",
    }:
        raise RuntimeError("China relation manifest does not identify the 16 exact added peers")

    relations = manifest.get("relations")
    reference_only = manifest.get("referenceOnly")
    if not isinstance(relations, list) or not isinstance(reference_only, list):
        raise RuntimeError("China relation manifest has no usable relation lists")
    if len(relations) != EXPECTED_CHINA_REGISTRY_CITY_COUNT:
        raise RuntimeError(
            f"Expected {EXPECTED_CHINA_REGISTRY_CITY_COUNT} registry relation rows, found {len(relations)}"
        )
    if len(reference_only) != EXPECTED_CHINA_REFERENCE_ONLY_COUNT:
        raise RuntimeError(
            f"Expected {EXPECTED_CHINA_REFERENCE_ONLY_COUNT} reference-only relation row"
        )

    relation_codes = [str(row.get("cityCode") or "") for row in relations]
    relation_ids = [str(row.get("relationID") or "") for row in relations]
    if len(set(relation_codes)) != len(relation_codes):
        raise RuntimeError("China relation manifest contains duplicate T-Union city codes")
    if len(set(relation_ids)) != len(relation_ids):
        raise RuntimeError("China relation manifest contains duplicate OSM relation IDs")
    if set(relation_codes) != set(registry):
        raise RuntimeError(
            "China relation manifest and T-Union registry differ: "
            f"missing={sorted(set(registry) - set(relation_codes))}, "
            f"extra={sorted(set(relation_codes) - set(registry))}"
        )
    for row in relations:
        city_code = str(row["cityCode"])
        if str(row.get("registryName") or "") != str(registry[city_code]):
            raise RuntimeError(f"China registry name changed for city code {city_code}")
        if int(row.get("adminLevel") or 0) not in {4, 5, 6}:
            raise RuntimeError(f"Unsupported China admin level for city code {city_code}")
        if not str(row.get("englishName") or "").strip():
            raise RuntimeError(f"China relation {city_code} has no English display name")

    relations_by_city_code = {
        str(row["cityCode"]): row
        for row in relations
    }
    for city_code, expected_english_name in CHINA_COASTAL_VALIDATION_CITY_CODES.items():
        actual_english_name = str(relations_by_city_code[city_code]["englishName"])
        if actual_english_name.removesuffix(" City") != expected_english_name:
            raise RuntimeError(
                f"China coastal validation label mismatch for {city_code}: "
                f"expected {expected_english_name}, manifest has {actual_english_name}"
            )

    match_counts = Counter(str(row.get("match") or "") for row in relations)
    expected_match_counts = {
        "exact": EXPECTED_CHINA_EXACT_NAME_MATCH_COUNT,
        "reviewedAutonomousPrefectureAbbreviation": EXPECTED_CHINA_REVIEWED_ABBREVIATION_MATCH_COUNT,
    }
    if dict(match_counts) != expected_match_counts:
        raise RuntimeError(
            f"China reviewed name-match counts changed: expected {expected_match_counts}, got {dict(match_counts)}"
        )
    declared_counts = manifest.get("counts") or {}
    if declared_counts != {
        "exactNameMatches": EXPECTED_CHINA_EXACT_NAME_MATCH_COUNT,
        "registryRelations": EXPECTED_CHINA_REGISTRY_CITY_COUNT,
        "reviewedAbbreviationMatches": EXPECTED_CHINA_REVIEWED_ABBREVIATION_MATCH_COUNT,
    }:
        raise RuntimeError("China relation manifest count declaration changed")

    reference_relation_ids = {str(row.get("relationID") or "") for row in reference_only}
    if reference_relation_ids != CHINA_REFERENCE_ONLY_RELATIONS:
        raise RuntimeError(
            f"Unexpected China reference-only relations: {sorted(reference_relation_ids)}"
        )
    if set(relation_ids) & reference_relation_ids:
        raise RuntimeError("A China reference-only relation is also mapped to a T-Union city code")
    macau = reference_only[0]
    if macau.get("name") != "Macau" or macau.get("nativeName") != "澳門":
        raise RuntimeError("The reference-only Macau manifest row changed")

    if coverage.get("version") != 1:
        raise RuntimeError(f"Unsupported China transit coverage {coverage.get('version')!r}")
    t_union = coverage.get("tUnion") or {}
    city_to_province = t_union.get("cityToProvince") or {}
    aliases = t_union.get("cityToBoundaryAlias") or {}
    province_only_city_codes = set(t_union.get("provinceOnlyCityCodes") or [])
    excluded_city_boundary_codes = set(t_union.get("excludedCityBoundaryCodes") or [])
    if excluded_city_boundary_codes != CHINA_EXCLUDED_CITY_BOUNDARY_CODES:
        raise RuntimeError("China T-Union City display exclusions changed")
    if len(registry) - len(excluded_city_boundary_codes) != EXPECTED_CHINA_DISPLAYED_CITY_COUNT:
        raise RuntimeError("China T-Union displayed City count changed")
    if "9101" in excluded_city_boundary_codes:
        raise RuntimeError("Hong Kong must remain in the T-Union City layer")
    participating_city_source = (coverage.get("sources") or {}).get("participatingCityList") or {}
    if (
        participating_city_source.get("pageRevisionID")
        != CHINA_PARTICIPATION_PAGE_REVISION_ID
        or participating_city_source.get("pageRevisionTimestamp")
        != CHINA_PARTICIPATION_PAGE_REVISION_TIMESTAMP
        or participating_city_source.get("retrievedHTMLSHA256")
        != CHINA_PARTICIPATION_PAGE_HTML_SHA256
        or participating_city_source.get("exactRegistryCityCodeCount")
        != EXPECTED_CHINA_DISPLAYED_CITY_COUNT
        or set(participating_city_source.get("excludedExactRegistryCityCodes") or [])
        != CHINA_EXCLUDED_CITY_BOUNDARY_CODES
    ):
        raise RuntimeError("China T-Union participation source lock changed")
    expected_coverage_codes = set(registry) | set(aliases) | province_only_city_codes
    if set(city_to_province) != expected_coverage_codes:
        raise RuntimeError(
            "China coverage city codes do not match the registry, reviewed aliases, "
            "and province-only codes"
        )
    if len(aliases) != EXPECTED_CHINA_REVIEWED_ALIAS_COUNT:
        raise RuntimeError(
            f"Expected {EXPECTED_CHINA_REVIEWED_ALIAS_COUNT} reviewed China city aliases"
        )
    if len(province_only_city_codes) != EXPECTED_CHINA_PROVINCE_ONLY_CODE_COUNT:
        raise RuntimeError(
            f"Expected {EXPECTED_CHINA_PROVINCE_ONLY_CODE_COUNT} province-only China codes"
        )
    if province_only_city_codes & (set(registry) | set(aliases)):
        raise RuntimeError("A province-only China code also declares a City boundary")
    city_code_display_names = t_union.get("cityCodeDisplayNames") or {}
    if set(city_code_display_names) != set(aliases) | province_only_city_codes:
        raise RuntimeError(
            "Every reviewed China alias and province-only code must have a display name"
        )
    if any(not str(name).strip() for name in city_code_display_names.values()):
        raise RuntimeError("A reviewed China city-code display name is empty")
    if any(str(target) not in registry for target in aliases.values()):
        raise RuntimeError("A China boundary alias does not resolve to a registry city code")
    if aliases.get("7791") != "7790":
        raise RuntimeError("The reviewed Nagqu 7791 to 7790 boundary alias is missing")
    supported_provinces = set(coverage.get("supportedProvinceNames") or [])
    reference_boundary_to_province = coverage.get("referenceBoundaryToProvince") or {}
    expected_reference_boundary_to_province = {
        f"cn:relation:{reference_only_row['relationID']}": "Macau Special Administrative Region"
        for reference_only_row in reference_only
    }
    if reference_boundary_to_province != expected_reference_boundary_to_province:
        raise RuntimeError(
            "China reference-only city boundaries must declare their exact province"
        )
    required_provinces = set(city_to_province.values()) | set(
        reference_boundary_to_province.values()
    )
    if required_provinces != supported_provinces:
        raise RuntimeError(
            "China supported provinces must exactly match provinces reached by supported cities; "
            f"missing {sorted(required_provinces - supported_provinces)}, "
            f"unbacked {sorted(supported_provinces - required_provinces)}"
        )
    city_union = coverage.get("cityUnion") or {}
    city_union_provinces = city_union.get("cityToProvince") or {}
    city_union_aliases = city_union.get("cityToBoundaryAlias") or {}
    if city_union.get("excludedCityBoundaryCodes") != []:
        raise RuntimeError("China City Union must not declare City display exclusions")
    if city_union.get("provinceOnlyCityCodes") != []:
        raise RuntimeError("China City Union must not declare province-only codes")
    if set(city_union_provinces) != set(city_union_aliases):
        raise RuntimeError("China City Union coverage and boundary alias codes differ")
    for city_code, registry_city_code in city_union_aliases.items():
        if registry_city_code not in registry:
            raise RuntimeError(
                f"China City Union code {city_code} has an unknown boundary target"
            )
        if city_union_provinces[city_code] != city_to_province[registry_city_code]:
            raise RuntimeError(
                f"China City Union code {city_code} disagrees with its boundary province"
            )
    excluded_provinces = set((coverage.get("scope") or {}).get("excludedProvinceNames") or [])
    if "Taiwan Province" not in excluded_provinces:
        raise RuntimeError("China coverage must explicitly keep Taiwan outside CardBal scope")

    relations.sort(key=lambda row: int(str(row["cityCode"])))
    return relations, reference_only, {str(key): str(value) for key, value in aliases.items()}


def shapely_polygon_tools() -> tuple[Any, Any, Any, Any]:
    try:
        import shapely
        from shapely import make_valid
        from shapely.geometry import mapping, shape
        from shapely.ops import unary_union
    except ModuleNotFoundError as error:
        raise RuntimeError(
            "China land clipping requires tools/boundaries/requirements.txt"
        ) from error
    if shapely.__version__ != "2.1.2":
        raise RuntimeError(
            f"Expected Shapely 2.1.2 for deterministic land clipping, found {shapely.__version__}"
        )
    return shape, mapping, make_valid, unary_union


def polygonal_shapely_geometry(geometry: Any, make_valid: Any, unary_union: Any) -> Any:
    geometry = make_valid(geometry)
    if geometry.geom_type in {"Polygon", "MultiPolygon"}:
        return geometry
    polygon_parts = []
    for child in getattr(geometry, "geoms", []):
        polygonal_child = polygonal_shapely_geometry(child, make_valid, unary_union)
        if not polygonal_child.is_empty:
            polygon_parts.append(polygonal_child)
    return unary_union(polygon_parts) if polygon_parts else geometry.buffer(0)


def load_natural_earth_land(destination: Path) -> tuple[Any, Any, Any, Any, Any, Any]:
    shape, mapping, make_valid, unary_union = shapely_polygon_tools()
    payload = download_verified_json(
        NATURAL_EARTH_LAND_URL,
        destination,
        NATURAL_EARTH_LAND_SHA256,
        "Natural Earth 1:10m land",
    )
    if payload.get("type") != "FeatureCollection" or not isinstance(payload.get("features"), list):
        raise RuntimeError("Unexpected Natural Earth land FeatureCollection")
    if len(payload["features"]) != 11:
        raise RuntimeError(
            f"Expected 11 Natural Earth land features, found {len(payload['features'])}"
        )
    land_parts = [
        polygonal_shapely_geometry(shape(feature["geometry"]), make_valid, unary_union)
        for feature in payload["features"]
    ]
    land = polygonal_shapely_geometry(unary_union(land_parts), make_valid, unary_union)
    if land.is_empty:
        raise RuntimeError("Natural Earth land union is empty")
    # Marine containment deliberately fills inland-lake holes so this mask
    # measures only coastal overshoot after quantization. Catalog components
    # preserve the source holes independently.
    land_outer_parts = geometry_parts(mapping(land))
    marine_containment_mask = polygonal_shapely_geometry(
        shape(
            {
                "type": "MultiPolygon",
                "coordinates": [[outer] for outer, _holes in land_outer_parts],
            }
        ),
        make_valid,
        unary_union,
    )
    return land, marine_containment_mask, shape, mapping, make_valid, unary_union


def polygon_part_size_kilometers(part: PolygonPart) -> tuple[float, float]:
    bbox = parts_bbox([part])
    mean_latitude = (bbox[1] + bbox[3]) / 2.0
    return (
        (bbox[2] - bbox[0]) * 111.32 * abs(math.cos(math.radians(mean_latitude))),
        (bbox[3] - bbox[1]) * 110.574,
    )


def validate_nominatim_relation(result: dict[str, Any], relation: dict[str, Any]) -> None:
    relation_id = str(relation["relationID"])
    geometry = result.get("geojson") or {}
    if (
        result.get("osm_type") != "relation"
        or str(result.get("osm_id") or "") != relation_id
        or (result.get("category") or result.get("class")) != "boundary"
        or result.get("type") != "administrative"
        or geometry.get("type") not in {"Polygon", "MultiPolygon"}
    ):
        raise RuntimeError(f"Nominatim returned an invalid administrative relation for {relation_id}")
    actual_admin_level = int((result.get("extratags") or {}).get("admin_level") or 0)
    expected_admin_level = relation.get("adminLevel")
    if expected_admin_level is not None and actual_admin_level != int(expected_admin_level):
        raise RuntimeError(
            f"OSM admin level changed for relation {relation_id}: "
            f"expected {expected_admin_level}, got {actual_admin_level}"
        )
    allowed_admin_levels = {3, 4, 5, 6} if relation.get("referenceOnly") else {4, 5, 6}
    if actual_admin_level not in allowed_admin_levels:
        raise RuntimeError(f"Unsupported OSM admin level {actual_admin_level} for relation {relation_id}")


def boundary_shapely_geometry(
    boundary: dict[str, Any],
    shape: Any,
    make_valid: Any,
    unary_union: Any,
) -> Any:
    components = boundary.get("components")
    if components is None:
        # Retain helper compatibility with version-1 catalogs while generators
        # and clients migrate to the component-preserving version-2 schema.
        components = [
            {"outer": ring, "holes": []}
            for ring in boundary.get("polygons", [])
        ]
    polygons = [
        polygonal_shapely_geometry(
            shape(
                {
                    "type": "Polygon",
                    "coordinates": [component["outer"], *component.get("holes", [])],
                }
            ),
            make_valid,
            unary_union,
        )
        for component in components
    ]
    return polygonal_shapely_geometry(unary_union(polygons), make_valid, unary_union)


def approximate_geometry_area_square_kilometers(geometry: Any) -> float:
    latitude = float(geometry.centroid.y)
    return float(geometry.area) * 111.32 * 110.574 * abs(math.cos(math.radians(latitude)))


def build_china_boundaries(
    registry_path: Path,
    coverage_path: Path,
    manifest_path: Path,
    natural_earth_land_path: Path,
    nominatim_cache_directory: Path,
    delay_seconds: float,
) -> tuple[
    list[dict[str, Any]],
    dict[str, str],
    dict[str, Any],
    set[str],
    dict[str, dict[str, float]],
]:
    relations, reference_only, aliases = load_china_relation_manifest(
        registry_path,
        coverage_path,
        manifest_path,
    )
    source_rows = relations + [
        {
            "relationID": row["relationID"],
            "englishName": row["name"],
            "registryName": row["nativeName"],
            "referenceOnly": True,
        }
        for row in reference_only
    ]
    relation_ids = [str(row["relationID"]) for row in source_rows]
    results_by_id = NominatimClient(
        delay_seconds,
        nominatim_cache_directory,
    ).lookup_relations(relation_ids)
    (
        land,
        marine_containment_mask,
        shape,
        mapping,
        make_valid,
        unary_union,
    ) = load_natural_earth_land(natural_earth_land_path)
    buffered_marine_containment_mask = marine_containment_mask.buffer(
        OUTPUT_QUANTIZATION_CONTAINMENT_BUFFER_DEGREES
    )

    boundaries: list[dict[str, Any]] = []
    city_mapping: dict[str, str] = {}
    reference_only_boundary_ids: set[str] = set()
    raw_area_total = 0.0
    clipped_area_total = 0.0
    raw_component_count = 0
    clipped_component_count = 0
    preserved_large_component_count = 0
    boundaries_reduced_by_land_clip = 0
    final_component_count = 0
    maximum_post_quantization_marine_residual_square_kilometers = 0.0
    maximum_outside_quantization_envelope_square_kilometers = 0.0
    coastal_validation: dict[str, dict[str, float]] = {}

    for index, relation in enumerate(source_rows, start=1):
        relation_id = str(relation["relationID"])
        city_code = str(relation.get("cityCode") or "")
        print(
            f"China land clip {index}/{len(source_rows)}: "
            f"{city_code or 'reference'} R{relation_id}",
            flush=True,
        )
        result = results_by_id[relation_id]
        validate_nominatim_relation(result, relation)
        raw_geometry = polygonal_shapely_geometry(
            shape(result["geojson"]),
            make_valid,
            unary_union,
        )
        clipped_geometry = polygonal_shapely_geometry(
            raw_geometry.intersection(land),
            make_valid,
            unary_union,
        )
        if raw_geometry.is_empty or clipped_geometry.is_empty:
            raise RuntimeError(f"China relation {relation_id} has no land geometry")
        raw_area = float(raw_geometry.area)
        clipped_area = float(clipped_geometry.area)
        if clipped_area > raw_area + max(1e-12, raw_area * 1e-9):
            raise RuntimeError(f"Land clipping enlarged China relation {relation_id}")
        outside_land_area = float(clipped_geometry.difference(land).area)
        if outside_land_area > max(1e-12, clipped_area * 1e-9):
            raise RuntimeError(
                f"China relation {relation_id} retains {outside_land_area} square degrees outside land"
            )
        if raw_area - clipped_area > max(1e-12, raw_area * 1e-9):
            boundaries_reduced_by_land_clip += 1

        raw_parts = geometry_parts(mapping(raw_geometry))
        clipped_parts = geometry_parts(mapping(clipped_geometry))
        boundary_id = f"cn:relation:{relation_id}"
        simplified_boundary = make_boundary(
            boundary_id=boundary_id,
            country_code="CN",
            name=str(relation["englishName"]),
            native_name=str(relation["registryName"]),
            parts=clipped_parts,
            tolerance=CHINA_RDP_TOLERANCE,
            coordinate_decimals=CHINA_COORDINATE_DECIMALS,
        )
        simplified_geometry = boundary_shapely_geometry(
            simplified_boundary,
            shape,
            make_valid,
            unary_union,
        )
        rdp_marine_overshoot = polygonal_shapely_geometry(
            simplified_geometry.difference(marine_containment_mask),
            make_valid,
            unary_union,
        )
        # RDP can replace a concave coast with a short chord over water. Clip a
        # second time, then quantize without another lossy simplification pass.
        output_geometry = polygonal_shapely_geometry(
            simplified_geometry.intersection(land),
            make_valid,
            unary_union,
        )
        output_parts = geometry_parts(mapping(output_geometry))
        boundary = make_boundary(
            boundary_id=boundary_id,
            country_code="CN",
            name=str(relation["englishName"]),
            native_name=str(relation["registryName"]),
            parts=output_parts,
            tolerance=0.0,
            coordinate_decimals=CHINA_COORDINATE_DECIMALS,
        )
        final_geometry = boundary_shapely_geometry(
            boundary,
            shape,
            make_valid,
            unary_union,
        )
        post_quantization_marine_residual = polygonal_shapely_geometry(
            final_geometry.difference(marine_containment_mask),
            make_valid,
            unary_union,
        )
        outside_quantization_envelope = polygonal_shapely_geometry(
            final_geometry.difference(buffered_marine_containment_mask),
            make_valid,
            unary_union,
        )
        post_quantization_residual_square_kilometers = (
            0.0
            if post_quantization_marine_residual.is_empty
            else approximate_geometry_area_square_kilometers(post_quantization_marine_residual)
        )
        outside_quantization_envelope_square_kilometers = (
            0.0
            if outside_quantization_envelope.is_empty
            else approximate_geometry_area_square_kilometers(outside_quantization_envelope)
        )
        if outside_quantization_envelope_square_kilometers > 1e-8:
            raise RuntimeError(
                f"China relation {relation_id} extends materially beyond the post-quantization land envelope"
            )
        large_component_count = sum(
            1
            for part in clipped_parts
            if any(size >= 10.0 for size in polygon_part_size_kilometers(part))
        )
        if len(boundary["components"]) < large_component_count:
            raise RuntimeError(
                f"China relation {relation_id} lost a land component at least 10 km in one dimension"
            )
        boundaries.append(boundary)
        if city_code:
            city_mapping[city_code] = boundary_id
        else:
            reference_only_boundary_ids.add(boundary_id)

        raw_area_total += raw_area
        clipped_area_total += clipped_area
        raw_component_count += len(raw_parts)
        clipped_component_count += len(clipped_parts)
        final_component_count += len(boundary["components"])
        preserved_large_component_count += large_component_count
        maximum_post_quantization_marine_residual_square_kilometers = max(
            maximum_post_quantization_marine_residual_square_kilometers,
            post_quantization_residual_square_kilometers,
        )
        maximum_outside_quantization_envelope_square_kilometers = max(
            maximum_outside_quantization_envelope_square_kilometers,
            outside_quantization_envelope_square_kilometers,
        )
        if city_code in CHINA_COASTAL_VALIDATION_CITY_CODES:
            rdp_overshoot_square_kilometers = (
                0.0
                if rdp_marine_overshoot.is_empty
                else approximate_geometry_area_square_kilometers(rdp_marine_overshoot)
            )
            coastal_validation[city_code] = {
                "rawAreaSquareDegrees": round(raw_area, 6),
                "landAreaSquareDegrees": round(clipped_area, 6),
                "removedPercent": round((raw_area - clipped_area) / raw_area * 100.0, 3),
                "preSimplificationOutsideLandAreaSquareDegrees": round(outside_land_area, 12),
                "rdpMarineOvershootBeforeFinalClipSquareKilometers": round(
                    rdp_overshoot_square_kilometers,
                    9,
                ),
                "postQuantizationMarineResidualSquareKilometers": round(
                    post_quantization_residual_square_kilometers,
                    9,
                ),
                "outsideQuantizationEnvelopeSquareKilometers": round(
                    outside_quantization_envelope_square_kilometers,
                    12,
                ),
            }

    if len(boundaries) != EXPECTED_CHINA_REFERENCE_BOUNDARY_COUNT:
        raise RuntimeError(
            f"Expected {EXPECTED_CHINA_REFERENCE_BOUNDARY_COUNT} China reference boundaries, "
            f"found {len(boundaries)}"
        )
    if len(city_mapping) != EXPECTED_CHINA_REGISTRY_CITY_COUNT:
        raise RuntimeError(
            f"Expected {EXPECTED_CHINA_REGISTRY_CITY_COUNT} mapped China city codes, "
            f"found {len(city_mapping)}"
        )
    if len(reference_only_boundary_ids) != EXPECTED_CHINA_REFERENCE_ONLY_COUNT:
        raise RuntimeError("China reference-only boundary count changed")
    if set(coastal_validation) != set(CHINA_COASTAL_VALIDATION_CITY_CODES):
        raise RuntimeError("China coastal validation set is incomplete")
    for city_code, city_name in CHINA_COASTAL_VALIDATION_CITY_CODES.items():
        metrics = coastal_validation[city_code]
        if metrics["preSimplificationOutsideLandAreaSquareDegrees"] != 0.0:
            raise RuntimeError(f"{city_name} retains geometry outside Natural Earth land")
        if metrics["outsideQuantizationEnvelopeSquareKilometers"] != 0.0:
            raise RuntimeError(f"{city_name} exceeds the post-quantization land envelope")
        if metrics["removedPercent"] <= 0.0:
            raise RuntimeError(f"{city_name} did not exercise the land-only clipping path")

    stats = {
        "registryCityCount": len(relations),
        "displayedCityCount": EXPECTED_CHINA_DISPLAYED_CITY_COUNT,
        "excludedCityBoundaryCount": len(CHINA_EXCLUDED_CITY_BOUNDARY_CODES),
        "mappedCityCount": len(city_mapping),
        "reviewedAliasCodeCount": len(aliases),
        "usedBoundaryCount": len(set(city_mapping.values())),
        "referenceBoundaryCount": len(boundaries),
        "referenceOnlyBoundaryCount": len(reference_only_boundary_ids),
        "rawPolygonComponentCount": raw_component_count,
        "landPolygonComponentCount": clipped_component_count,
        "outputPolygonComponentCount": final_component_count,
        "preservedAtLeast10KilometerDimensionComponentCount": preserved_large_component_count,
        "boundariesReducedByLandClip": boundaries_reduced_by_land_clip,
        "postQuantizationContainmentBufferDegrees": OUTPUT_QUANTIZATION_CONTAINMENT_BUFFER_DEGREES,
        "maximumPostQuantizationMarineResidualSquareKilometers": round(
            maximum_post_quantization_marine_residual_square_kilometers,
            9,
        ),
        "maximumOutsideQuantizationEnvelopeSquareKilometers": round(
            maximum_outside_quantization_envelope_square_kilometers,
            12,
        ),
        "totalRemovedAreaPercent": round(
            (raw_area_total - clipped_area_total) / raw_area_total * 100.0,
            3,
        ),
    }
    return (
        boundaries,
        city_mapping,
        stats,
        reference_only_boundary_ids,
        coastal_validation,
    )


def find_single_feature(feature_collection: dict[str, Any], shape_name: str) -> dict[str, Any]:
    matches = [
        feature
        for feature in feature_collection["features"]
        if str((feature.get("properties") or {}).get("shapeName") or "") == shape_name
    ]
    if len(matches) != 1:
        raise RuntimeError(f"Expected exactly one geoBoundaries feature named {shape_name!r}, found {len(matches)}")
    return matches[0]


def is_korea_metropolitan_adm2_shape(shape_name: str) -> bool:
    return (
        shape_name.endswith("-gu")
        or "-gu [" in shape_name
        or shape_name in KOREA_METROPOLITAN_ADM2_GUN_SHAPE_NAMES
    )


def korea_reference_display_name(shape_name: str) -> str:
    for suffix in ("-si", "-gun"):
        if shape_name.endswith(suffix):
            return shape_name.removesuffix(suffix)
    return shape_name


def reviewed_korea_mode_area(code: int, name: str) -> str | None:
    if code in KOREA_MODE_EXPLICIT_AREA_BY_CODE:
        return KOREA_MODE_EXPLICIT_AREA_BY_CODE[code]
    for marker, area_key in KOREA_MODE_AREA_NAME_MARKERS:
        if marker in name:
            return area_key
    return None


def build_korea_boundaries(
    adm1: dict[str, Any],
    adm2: dict[str, Any],
    stations_path: Path,
    modes_path: Path,
) -> tuple[list[dict[str, Any]], dict[str, str], dict[str, str], dict[str, int]]:
    modes_payload = load_json(modes_path)
    if modes_payload.get("schemaVersion") != 1:
        raise RuntimeError("Unsupported Korean transport-mode catalog")
    mode_rows = list(modes_payload.get("modes") or []) + list(
        modes_payload.get("supplementaryModes") or []
    )
    available_mode_codes: set[str] = set()
    classified_mode_mapping: dict[str, str] = {}
    for row in mode_rows:
        code = row.get("code")
        name = str(row.get("nameKo") or "").strip()
        if not isinstance(code, int) or not name:
            raise RuntimeError("Malformed Korean transport-mode row")
        code_key = str(code)
        if code_key in available_mode_codes:
            raise RuntimeError(f"Duplicate Korean transport-mode code {code}")
        available_mode_codes.add(code_key)
        if area_key := reviewed_korea_mode_area(code, name):
            classified_mode_mapping[code_key] = area_key
    if len(KOREA_MODE_TO_AREA) != EXPECTED_KOREA_MODE_MAPPING_COUNT:
        raise RuntimeError(
            "Reviewed Korean mode mapping count changed: "
            f"expected {EXPECTED_KOREA_MODE_MAPPING_COUNT}, found {len(KOREA_MODE_TO_AREA)}"
        )
    if len(set(KOREA_MODE_TO_AREA.values())) != EXPECTED_KOREA_MODE_AREA_COUNT:
        raise RuntimeError(
            "Reviewed Korean mode-area count changed: "
            f"expected {EXPECTED_KOREA_MODE_AREA_COUNT}, "
            f"found {len(set(KOREA_MODE_TO_AREA.values()))}"
        )
    missing_mode_codes = set(KOREA_MODE_TO_AREA) - available_mode_codes
    if missing_mode_codes:
        raise RuntimeError(
            f"Reviewed Korean mode codes are absent from the bundled catalog: "
            f"{sorted(missing_mode_codes, key=int)}"
        )
    if classified_mode_mapping != KOREA_MODE_TO_AREA:
        raise RuntimeError(
            "Bundled Korean transport-mode names no longer match the reviewed exact-city "
            "crosswalk"
        )

    boundary_ids_by_area: dict[str, str] = {}
    boundaries: list[dict[str, Any]] = []
    emitted_boundary_ids: set[str] = set()
    for area_key, spec in KOREA_AREA_SPECS.items():
        source = adm1 if spec["level"] == "ADM1" else adm2
        feature = find_single_feature(source, spec["shapeName"])
        properties = feature["properties"]
        boundary_id = f"kr:{properties['shapeID']}"
        boundary_ids_by_area[area_key] = boundary_id
        emitted_boundary_ids.add(boundary_id)
        boundaries.append(
            make_boundary(
                boundary_id=boundary_id,
                country_code="KR",
                name=spec["name"],
                native_name=area_key.split("|", 1)[-1],
                parts=geometry_parts(feature["geometry"]),
                tolerance=KOREA_RDP_TOLERANCE,
            )
        )

    adm1_reference_names = (
        KOREA_CITY_ADM1_REFERENCE_SHAPE_NAMES
        | KOREA_WHOLE_AREA_ADM1_REFERENCE_SHAPE_NAMES
    )
    adm1_reference_features = [
        feature
        for feature in adm1["features"]
        if str((feature.get("properties") or {}).get("shapeName") or "")
        in adm1_reference_names
    ]
    if len(adm1_reference_features) != len(adm1_reference_names):
        raise RuntimeError(
            "Korean ADM1 city reference mismatch: "
            f"expected {len(adm1_reference_names)}, found {len(adm1_reference_features)}"
        )

    if len(adm2["features"]) != EXPECTED_KOREA_ADM2_FEATURE_COUNT:
        raise RuntimeError(
            "Korean ADM2 feature-count mismatch: "
            f"expected {EXPECTED_KOREA_ADM2_FEATURE_COUNT}, found {len(adm2['features'])}"
        )
    metropolitan_adm2_features = [
        feature
        for feature in adm2["features"]
        if is_korea_metropolitan_adm2_shape(
            str((feature.get("properties") or {}).get("shapeName") or "")
        )
    ]
    if len(metropolitan_adm2_features) != EXPECTED_KOREA_METROPOLITAN_ADM2_FEATURE_COUNT:
        raise RuntimeError(
            "Korean metropolitan ADM2 feature-count mismatch: "
            f"expected {EXPECTED_KOREA_METROPOLITAN_ADM2_FEATURE_COUNT}, "
            f"found {len(metropolitan_adm2_features)}"
        )
    adm2_reference_features = [
        feature
        for feature in adm2["features"]
        if not is_korea_metropolitan_adm2_shape(
            str((feature.get("properties") or {}).get("shapeName") or "")
        )
        and str((feature.get("properties") or {}).get("shapeName") or "")
        not in KOREA_CITY_REFERENCE_EXCLUDED_ADM2_SHAPE_NAMES
    ]

    for feature in adm1_reference_features + adm2_reference_features:
        properties = feature["properties"]
        boundary_id = f"kr:{properties['shapeID']}"
        if boundary_id in emitted_boundary_ids:
            continue
        emitted_boundary_ids.add(boundary_id)
        shape_name = str(properties["shapeName"])
        boundaries.append(
            make_boundary(
                boundary_id=boundary_id,
                country_code="KR",
                name=korea_reference_display_name(shape_name),
                native_name=shape_name,
                parts=geometry_parts(feature["geometry"]),
                tolerance=KOREA_RDP_TOLERANCE,
            )
        )

    if len(boundaries) != EXPECTED_KOREA_CITY_REFERENCE_BOUNDARY_COUNT:
        raise RuntimeError(
            "Korean city reference boundary-count mismatch: "
            f"expected {EXPECTED_KOREA_CITY_REFERENCE_BOUNDARY_COUNT}, found {len(boundaries)}"
        )

    mode_mapping = {
        mode_code: boundary_ids_by_area[area_key]
        for mode_code, area_key in sorted(KOREA_MODE_TO_AREA.items(), key=lambda item: int(item[0]))
    }

    with stations_path.open(encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        locations = [
            (row["location_code"], row["province_name"], row["district_name"])
            for row in reader
        ]
    actual_aliases: dict[str, str] = {}
    for location_code, ctpv_name, sgg_name in locations:
        location_code = str(location_code).upper()
        ctpv_name = str(ctpv_name or "")
        if ctpv_name == "경기도":
            sgg_name = str(sgg_name or "")
            municipality_match = re.match(r"^(.+?시)", sgg_name)
            if not municipality_match:
                raise RuntimeError(
                    f"Korean alias {location_code} has no usable Gyeonggi municipality: {sgg_name!r}"
                )
            area_key = f"경기도|{municipality_match.group(1)}"
        else:
            area_key = ctpv_name
        if area_key not in boundary_ids_by_area:
            raise RuntimeError(
                f"Korean alias {location_code} has unsupported administrative area {area_key!r}"
            )
        boundary_id = boundary_ids_by_area[area_key]
        previous = actual_aliases.setdefault(location_code, boundary_id)
        if previous != boundary_id:
            raise RuntimeError(
                f"Korean aliases disagree on area for {location_code}"
            )

    location_mapping = dict(sorted(actual_aliases.items()))
    visit_boundary_count = len(set(mode_mapping.values()) | set(location_mapping.values()))
    if visit_boundary_count != EXPECTED_KOREA_VISIT_BOUNDARY_COUNT:
        raise RuntimeError(
            "Korean visit boundary-count mismatch: "
            f"expected {EXPECTED_KOREA_VISIT_BOUNDARY_COUNT}, found {visit_boundary_count}"
        )
    stats = {
        "mappedModeCodeCount": len(mode_mapping),
        "mappedLocationCodeCount": len(location_mapping),
        "officialAliasRowCount": len(locations),
        "usedBoundaryCount": visit_boundary_count,
        "referenceBoundaryCount": len(boundaries),
        "referenceOnlyBoundaryCount": len(boundaries) - visit_boundary_count,
    }
    return boundaries, mode_mapping, location_mapping, stats


def build_mongolia_boundaries(
    adm1_payload: dict[str, Any],
    adm2_payload: dict[str, Any],
    station_database: Path,
) -> tuple[
    list[dict[str, Any]],
    dict[str, str],
    dict[str, str],
    dict[str, Any],
]:
    """Build one Ulaanbaatar outline plus station-backed Töv municipalities."""

    adm1_features = adm1_payload.get("features")
    if not isinstance(adm1_features, list) or len(adm1_features) != EXPECTED_MONGOLIA_ADM1_FEATURE_COUNT:
        raise RuntimeError(
            "Unexpected MNG_ADM1 feature count: "
            f"expected {EXPECTED_MONGOLIA_ADM1_FEATURE_COUNT}, "
            f"got {len(adm1_features) if isinstance(adm1_features, list) else 'invalid'}"
        )
    adm2_features = adm2_payload.get("features")
    if not isinstance(adm2_features, list) or len(adm2_features) != EXPECTED_MONGOLIA_ADM2_FEATURE_COUNT:
        raise RuntimeError(
            "Unexpected MNG_ADM2 feature count: "
            f"expected {EXPECTED_MONGOLIA_ADM2_FEATURE_COUNT}, "
            f"got {len(adm2_features) if isinstance(adm2_features, list) else 'invalid'}"
        )

    adm1_by_name = {
        str((feature.get("properties") or {}).get("shapeName") or "").strip(): feature
        for feature in adm1_features
    }
    try:
        ulaanbaatar_feature = adm1_by_name["Ulaanbaatar"]
        tov_feature = adm1_by_name["Töv"]
    except KeyError as error:
        raise RuntimeError(f"MNG_ADM1 is missing {error.args[0]}") from error

    ulaanbaatar_properties = ulaanbaatar_feature.get("properties") or {}
    ulaanbaatar_shape_id = str(ulaanbaatar_properties.get("shapeID") or "").strip()
    tov_shape_id = str((tov_feature.get("properties") or {}).get("shapeID") or "").strip()
    if not ulaanbaatar_shape_id or not tov_shape_id:
        raise RuntimeError("Mongolia city parents require stable ADM1 shape IDs")
    ulaanbaatar_boundary_id = f"mn:adm1:{ulaanbaatar_shape_id}"
    tov_boundary_id = f"mn:adm1:{tov_shape_id}"
    ulaanbaatar_parts = geometry_parts(ulaanbaatar_feature["geometry"])
    tov_parts = geometry_parts(tov_feature["geometry"])
    ulaanbaatar_boundary = make_boundary(
        boundary_id=ulaanbaatar_boundary_id,
        country_code="MN",
        name="Ulaanbaatar",
        native_name="Улаанбаатар",
        parts=ulaanbaatar_parts,
        tolerance=MONGOLIA_RDP_TOLERANCE,
        coordinate_decimals=COORDINATE_DECIMALS,
    )
    subdivision_code = str(ulaanbaatar_properties.get("shapeISO") or "").strip()
    if subdivision_code:
        ulaanbaatar_boundary["subdivisionCode"] = subdivision_code

    adm2_by_id = {
        str((feature.get("properties") or {}).get("shapeID") or "").strip(): feature
        for feature in adm2_features
    }
    missing_shape_ids = set(MONGOLIA_CITY_SPECS) - set(adm2_by_id)
    if missing_shape_ids:
        raise RuntimeError(
            f"MNG_ADM2 is missing reviewed Töv municipalities: {sorted(missing_shape_ids)}"
        )

    boundaries = [ulaanbaatar_boundary]
    city_parts_by_id = {ulaanbaatar_boundary_id: ulaanbaatar_parts}
    city_to_province = {ulaanbaatar_boundary_id: ulaanbaatar_boundary_id}
    for shape_id, spec in sorted(MONGOLIA_CITY_SPECS.items()):
        feature = adm2_by_id[shape_id]
        parts = geometry_parts(feature["geometry"])
        boundary_id = f"mn:adm2:{shape_id}"
        boundaries.append(
            make_boundary(
                boundary_id=boundary_id,
                country_code="MN",
                name=spec["name"],
                native_name=spec["nativeName"],
                parts=parts,
                tolerance=MONGOLIA_RDP_TOLERANCE,
                coordinate_decimals=COORDINATE_DECIMALS,
            )
        )
        city_parts_by_id[boundary_id] = parts
        city_to_province[boundary_id] = tov_boundary_id

    with sqlite3.connect(station_database) as connection:
        rows = connection.execute(
            """
            SELECT station_id, latitude, longitude
            FROM stations
            ORDER BY station_id
            """
        ).fetchall()
    if not rows:
        raise RuntimeError("The Ulaanbaatar transit database contains no stations")
    unique_station_ids = {str(row[0]) for row in rows}
    if len(unique_station_ids) != len(rows):
        raise RuntimeError("The Ulaanbaatar transit database contains duplicate station IDs")
    invalid_coordinate_count = sum(
        not (-90.0 <= float(latitude) <= 90.0 and -180.0 <= float(longitude) <= 180.0)
        for _, latitude, longitude in rows
    )
    if invalid_coordinate_count:
        raise RuntimeError(
            f"The Ulaanbaatar transit database has {invalid_coordinate_count} invalid coordinates"
        )

    station_mapping: dict[str, str] = {}
    station_counts: Counter[str] = Counter()
    nearest_fallback_count = 0
    for station_id, latitude, longitude in rows:
        point = (float(longitude), float(latitude))
        matches = [
            boundary_id
            for boundary_id, parts in city_parts_by_id.items()
            if point_in_parts(point, parts)
        ]
        if len(matches) > 1:
            raise RuntimeError(
                f"Mongolia station {station_id} overlaps city boundaries {sorted(matches)}"
            )
        if matches:
            selected_id = matches[0]
        else:
            # The pinned ADM1 and ADM2 vintages disagree narrowly around
            # Terelj. Only stations that the ADM1 layer places in Töv may use
            # the reviewed nearest-soum repair.
            if not point_in_parts(point, tov_parts):
                continue
            nearest = min(
                (
                    (point_to_parts_distance(point, parts), boundary_id)
                    for boundary_id, parts in city_parts_by_id.items()
                    if city_to_province[boundary_id] == tov_boundary_id
                ),
                key=lambda value: (value[0], value[1]),
            )
            if nearest[0] > MONGOLIA_NEAREST_FALLBACK_DEGREES:
                continue
            selected_id = nearest[1]
            nearest_fallback_count += 1
        station_mapping[str(station_id)] = selected_id
        station_counts[selected_id] += 1

    mapped_boundary_ids = set(station_mapping.values())
    expected_boundary_ids = {boundary["id"] for boundary in boundaries}
    unresolved_station_count = len(rows) - len(station_mapping)
    if len(boundaries) != EXPECTED_MONGOLIA_CITY_BOUNDARY_COUNT:
        raise RuntimeError("Mongolia city boundary count changed")
    if mapped_boundary_ids != expected_boundary_ids:
        raise RuntimeError(
            "Every emitted Mongolia city must contain a bundled station: "
            f"missing={sorted(expected_boundary_ids - mapped_boundary_ids)}"
        )
    if len(station_mapping) != EXPECTED_MONGOLIA_MAPPED_STATION_COUNT:
        raise RuntimeError(
            "Mongolia mapped station count changed: "
            f"expected {EXPECTED_MONGOLIA_MAPPED_STATION_COUNT}, got {len(station_mapping)}"
        )
    if nearest_fallback_count != EXPECTED_MONGOLIA_NEAREST_FALLBACK_STATION_COUNT:
        raise RuntimeError(
            "Mongolia nearest-boundary fallback count changed: "
            f"expected {EXPECTED_MONGOLIA_NEAREST_FALLBACK_STATION_COUNT}, "
            f"got {nearest_fallback_count}"
        )
    if unresolved_station_count:
        raise RuntimeError(
            f"Mongolia has {unresolved_station_count} stations without a city"
        )

    stats = {
        "inputStationCount": len(rows),
        "mappedStationCount": len(station_mapping),
        "nearestBoundaryFallbackStationCount": nearest_fallback_count,
        "nearestBoundaryFallbackMaximumDegrees": MONGOLIA_NEAREST_FALLBACK_DEGREES,
        "unresolvedCityStationCount": 0,
        "referenceBoundaryCount": len(boundaries),
        "usedBoundaryCount": len(mapped_boundary_ids),
        "stationCountsByBoundary": dict(sorted(station_counts.items())),
    }
    return boundaries, dict(sorted(station_mapping.items())), city_to_province, stats


def build_catalog(args: argparse.Namespace) -> dict[str, Any]:
    generated_at = args.generated_at or utc_now()
    japan_coverage = json.loads(args.japan_coverage.read_text(encoding="utf-8"))
    if japan_coverage.get("version") != 1:
        raise RuntimeError(
            f"Unsupported Japan transit coverage version {japan_coverage.get('version')!r}"
        )
    china_coverage = json.loads(args.china_coverage.read_text(encoding="utf-8"))
    if china_coverage.get("version") != 1:
        raise RuntimeError(
            f"Unsupported China transit coverage version {china_coverage.get('version')!r}"
        )
    with tempfile.TemporaryDirectory(prefix="cardbal-east-asia-boundaries-") as temporary_directory:
        temporary_path = Path(temporary_directory)
        source_cache_directory = args.source_cache_directory or temporary_path / "source-cache"
        source_cache_directory.mkdir(parents=True, exist_ok=True)
        geo = {
            asset_key: download_geoboundaries_asset(
                asset_key,
                source_cache_directory / "geoboundaries" / f"{asset_key}.geojson",
            )
            for asset_key in GEBOUNDARIES_ASSETS
        }

        japan_boundaries, japan_mapping, japan_stats = join_japanese_stations(
            args.japan_database,
            geo["JPN_ADM2"],
            geo["JPN_ADM1"],
            japan_coverage,
        )
        korea_boundaries, korea_mode_mapping, korea_location_mapping, korea_stats = build_korea_boundaries(
            geo["KOR_ADM1"],
            geo["KOR_ADM2"],
            args.korea_stations,
            args.korea_modes,
        )
        (
            mongolia_boundaries,
            mongolia_station_mapping,
            mongolia_city_to_province,
            mongolia_stats,
        ) = build_mongolia_boundaries(
            geo["MNG_ADM1"],
            geo["MNG_ADM2"],
            args.mongolia_database,
        )
        (
            china_boundaries,
            china_mapping,
            china_stats,
            china_reference_only_ids,
            china_coastal_validation,
        ) = build_china_boundaries(
            args.china_city_registry,
            args.china_coverage,
            args.china_relation_manifest,
            source_cache_directory / "natural-earth" / "ne_10m_land.geojson",
            source_cache_directory / "nominatim-china",
            args.nominatim_delay,
        )

    boundaries = japan_boundaries + china_boundaries + korea_boundaries + mongolia_boundaries
    boundaries.sort(key=lambda boundary: (boundary["countryCode"], boundary["id"]))
    referenced_ids = (
        set(japan_mapping.values())
        | set(china_mapping.values())
        | set(korea_mode_mapping.values())
        | set(korea_location_mapping.values())
        | set(mongolia_station_mapping.values())
    )
    emitted_ids = {boundary["id"] for boundary in boundaries}
    missing_ids = referenced_ids - emitted_ids
    unused_china_ids = {
        boundary["id"]
        for boundary in boundaries
        if boundary["countryCode"] == "CN" and boundary["id"] not in referenced_ids
    }
    unexpected_unused_china_ids = unused_china_ids - china_reference_only_ids
    missing_reference_only_china_ids = china_reference_only_ids - unused_china_ids
    if missing_ids or unexpected_unused_china_ids or missing_reference_only_china_ids:
        raise RuntimeError(
            f"Boundary reference mismatch: missing={sorted(missing_ids)}, "
            f"unexpectedUnusedChina={sorted(unexpected_unused_china_ids)}, "
            f"missingReferenceOnlyChina={sorted(missing_reference_only_china_ids)}"
        )

    catalog = {
        "version": 2,
        "generatedAt": generated_at,
        "attribution": [
            "geoBoundaries (www.geoboundaries.org)",
            "© OpenStreetMap contributors, ODbL 1.0 (www.openstreetmap.org/copyright)",
            "Made with Natural Earth. Free vector and raster map data @ naturalearthdata.com.",
        ],
        "sources": {
            "geoBoundaries": {
                "repository": "https://github.com/wmgeolab/geoBoundaries",
                "commit": GEBOUNDARIES_COMMIT,
                "commitDate": GEBOUNDARIES_COMMIT_DATE,
                "projectLicense": "CC BY 4.0",
                "citation": "Runfola et al. (2020), geoBoundaries, PLOS ONE 15(4): e0231866",
                "assets": {
                    asset_key: {
                        "path": asset["relativePath"],
                        "sha256": asset["sha256"],
                    }
                    for asset_key, asset in GEBOUNDARIES_ASSETS.items()
                },
                "underlyingDataLicenses": {
                    "JPN_ADM1": "Open Data Commons Open Database License 1.0",
                    "JPN_ADM2": "OpenStreetMap/Wambacher, CC BY-SA 2.0",
                    "KOR_ADM1": "Natural Earth, Public Domain",
                    "KOR_ADM2": "citypopulation.de, CC BY 3.0",
                    "MNG_ADM1": "OpenStreetMap/Wambacher, Open Data Commons Open Database License 1.0",
                    "MNG_ADM2": "National Statistical Office of Mongolia/OCHA ROAP, CC BY 3.0 IGO",
                },
            },
            "openStreetMapChina": {
                "service": "Nominatim",
                "endpoint": NOMINATIM_LOOKUP_URL,
                "dataCopyright": "© OpenStreetMap contributors",
                "dataLicense": "ODbL 1.0",
                "copyrightURL": "https://www.openstreetmap.org/copyright",
                "polygonThresholdDegrees": NOMINATIM_POLYGON_THRESHOLD,
                "maximumLookupBatchSize": NOMINATIM_LOOKUP_BATCH_SIZE,
                "retrievedAt": generated_at,
                "reviewedRelationManifest": {
                    "path": str(args.china_relation_manifest.relative_to(REPO_ROOT)),
                    "sha256": CHINA_RELATION_MANIFEST_SHA256,
                    "registryRelationCount": EXPECTED_CHINA_REGISTRY_CITY_COUNT,
                    "referenceOnlyRelationCount": EXPECTED_CHINA_REFERENCE_ONLY_COUNT,
                    "overpassQuerySnapshotSHA256": CHINA_OVERPASS_QUERY_SNAPSHOT_SHA256,
                },
            },
            "naturalEarthLand": {
                "repository": "https://github.com/nvkelso/natural-earth-vector",
                "commit": NATURAL_EARTH_COMMIT,
                "path": NATURAL_EARTH_LAND_PATH,
                "sha256": NATURAL_EARTH_LAND_SHA256,
                "scale": "1:10m",
                "license": "Public Domain",
                "termsURL": "https://www.naturalearthdata.com/about/terms-of-use/",
            },
            "localLookups": {
                "japan": "build/stations/jp_stations.sqlite exact non-pseudo coordinates, scoped by data/boundaries/JapanTransitCoverage.json",
                "china": "build/stations/TUnionCityCodes.json exact peer-level city codes, filtered at runtime by ChinaTransitCoverage.json participation status, plus reviewed aliases and reference-only Macau",
                "korea": "build/stations/korean_stations.tsv from iebb/korean-stations plus explicit verified transport-mode codes",
                "mongolia": "build/stations/ulaanbaatar_transit.sqlite generated from the service used by com.uscc.ubbus",
            },
        },
        "generation": {
            "coordinateOrder": "longitude,latitude",
            "polygonRepresentation": "polygon components with one outer ring and zero or more interior hole rings",
            "quantizationDecimals": {
                "JP": COORDINATE_DECIMALS,
                "CN": CHINA_COORDINATE_DECIMALS,
                "KR": COORDINATE_DECIMALS,
                "MN": COORDINATE_DECIMALS,
            },
            "rdpToleranceDegrees": {
                "JP": JAPAN_RDP_TOLERANCE,
                "CN": CHINA_RDP_TOLERANCE,
                "KR": KOREA_RDP_TOLERANCE,
                "MN": MONGOLIA_RDP_TOLERANCE,
            },
            "japanSpatialJoin": {
                "source": "pinned simplified JPN ADM2 polygons",
                "lookupKey": "uppercase five-character jp_stations.hex_code without 0x prefix",
                "nearestFallbackMaximumDegrees": JAPAN_NEAREST_FALLBACK_DEGREES,
                "referenceScope": "only ADM2 municipalities referenced by a bundled non-pseudo station code; stationless municipalities are not emitted",
                "coverageEvaluatedAt": japan_coverage.get("evaluatedAt"),
                "supportedPrefectureCodes": [
                    prefecture["code"]
                    for prefecture in japan_coverage["supportedPrefectures"]
                ],
                "omittedPrefectureCodes": [
                    prefecture["code"]
                    for prefecture in japan_coverage["omittedPrefectures"]
                ],
            },
            "koreaCityReference": {
                "source": "pinned mixed KOR ADM1 and ADM2 polygons",
                "referenceScope": "eight metropolitan or special cities at ADM1, other municipalities at ADM2, and whole Jeju at ADM1; exact station locations win, then reviewed exact-city KOTRIS modes provide fallback evidence",
                "modeFallbackScope": "city-specific KOTRIS modes only; national, airport, capital-region, province-wide, and other multi-city modes are excluded",
                "excludedNestedMetropolitanADM2Count": EXPECTED_KOREA_METROPOLITAN_ADM2_FEATURE_COUNT,
                "excludedWholeAreaADM2ShapeNames": sorted(
                    KOREA_CITY_REFERENCE_EXCLUDED_ADM2_SHAPE_NAMES
                ),
            },
            "mongoliaCityReference": {
                "source": "pinned MNG ADM1 Ulaanbaatar municipality plus reviewed station-backed MNG ADM2 Töv municipalities",
                "referenceScope": "one non-stacked Ulaanbaatar outline plus Sergelen, Erdene, and Bayandelger; every emitted city contains a bundled station",
                "lookupKey": "decimal station_id from build/stations/ulaanbaatar_transit.sqlite",
                "nearestFallback": "Töv-classified Terelj stops within 0.02 degrees of Erdene are assigned to Erdene across the pinned ADM1/ADM2 seam",
                "cardCrosswalk": "U-Money's seven-digit BCD station field is not transformed into eight- or nine-digit UB Smart Bus IDs without verified real-card evidence",
            },
            "chinaCityReference": {
                "referenceScope": "the source catalog retains all 368 exact bundled T-Union peer-level cities plus reference-only Macau; CardBal displays the 352 current independent participation boundaries plus Macau, and Taiwan is outside scope",
                "visitEligibility": "current exact T-Union boundaries and 53 explicitly reviewed non-stacked historical aliases; nine province-wide, historical multi-city, or composite codes resolve only at Province level",
                "landClipOrder": "Nominatim administrative geometry intersected with pinned Natural Earth land before local RDP, then intersected again after RDP before final quantization",
                "postQuantizationContainment": "every output ring must stay within a 0.000008-degree land envelope; this bounds coordinate-rounding drift to about 0.9 meters at the equator",
                "smallIslandRendering": "generated geometry removes detached secondary components smaller than 10 km in both dimensions; the client performs no component filtering",
                "coastalValidation": {
                    CHINA_COASTAL_VALIDATION_CITY_CODES[city_code]: metrics
                    for city_code, metrics in sorted(china_coastal_validation.items())
                },
            },
            "counts": {
                "boundaries": len(boundaries),
                "JP": japan_stats,
                "CN": china_stats,
                "KR": korea_stats,
                "MN": mongolia_stats,
            },
        },
        "boundaries": boundaries,
        "japanStationToBoundary": japan_mapping,
        "chinaCityToBoundary": dict(sorted(china_mapping.items(), key=lambda item: int(item[0]))),
        "koreaModeToBoundary": korea_mode_mapping,
        "koreaLocationToBoundary": korea_location_mapping,
        "mongoliaStationToBoundary": mongolia_station_mapping,
        "mongoliaCityToProvince": dict(sorted(mongolia_city_to_province.items())),
    }
    from tools.boundaries.optimize import (
        optimize_catalog,
        prune_city_catalog_to_supported_boundaries,
    )

    catalog = prune_city_catalog_to_supported_boundaries(catalog, china_coverage)
    return optimize_catalog(catalog, "city", generated_at=generated_at)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--japan-database", type=Path, default=DEFAULT_JAPAN_DATABASE)
    parser.add_argument("--japan-coverage", type=Path, default=DEFAULT_JAPAN_COVERAGE)
    parser.add_argument("--china-city-registry", type=Path, default=DEFAULT_CHINA_CITY_REGISTRY)
    parser.add_argument("--china-coverage", type=Path, default=DEFAULT_CHINA_COVERAGE)
    parser.add_argument("--china-relation-manifest", type=Path, default=DEFAULT_CHINA_RELATION_MANIFEST)
    parser.add_argument("--korea-stations", type=Path, default=DEFAULT_KOREA_STATIONS)
    parser.add_argument("--korea-modes", type=Path, default=DEFAULT_KOREA_MODES)
    parser.add_argument("--mongolia-database", type=Path, default=DEFAULT_MONGOLIA_DATABASE)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument(
        "--source-cache-directory",
        type=Path,
        help="Optional verified source/lookup cache; useful for deterministic repeat builds",
    )
    parser.add_argument(
        "--generated-at",
        help="Override the catalog timestamp for a byte-for-byte deterministic verification build",
    )
    parser.add_argument(
        "--nominatim-delay",
        type=float,
        default=DEFAULT_NOMINATIM_DELAY_SECONDS,
        help="Seconds between Nominatim requests; values below 1.0 are clamped to 1.0",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    for input_path in (
        args.japan_database,
        args.japan_coverage,
        args.china_city_registry,
        args.china_coverage,
        args.china_relation_manifest,
        args.korea_stations,
        args.korea_modes,
        args.mongolia_database,
    ):
        if not input_path.is_file():
            raise FileNotFoundError(input_path)
    catalog = build_catalog(args)
    encoded = json.dumps(catalog, ensure_ascii=False, separators=(",", ":")).encode("utf-8") + b"\n"
    if len(encoded) > MAX_OUTPUT_BYTES:
        raise RuntimeError(
            f"Generated catalog is {len(encoded):,} bytes, exceeding the {MAX_OUTPUT_BYTES:,}-byte target"
        )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(encoded)
    source_counts = catalog["generation"]["sourceCounts"]
    optimized_counts = catalog["generation"]["boundaryOptimization"]["counts"]
    print(
        f"Wrote {args.output} ({len(encoded):,} bytes; "
        f"{optimized_counts['boundaries']} supported boundaries; "
        f"JP hex codes {source_counts['JP']['mappedUniqueHexCodes']}/{source_counts['JP']['inputUniqueHexCodes']}; "
        f"CN cities {source_counts['CN']['mappedCityCount']}; "
        f"KR modes {source_counts['KR']['mappedModeCodeCount']}; "
        f"MN stations {source_counts['MN']['mappedStationCount']})"
    )


if __name__ == "__main__":
    main()
