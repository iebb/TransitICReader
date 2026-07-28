#!/usr/bin/env python3
"""Build CardBal's compact, offline East Asia city-boundary catalog.

The output deliberately contains only boundary polygons referenced by one of
the three lookup tables.  Coordinates use GeoJSON order everywhere:

* ``center``: ``[longitude, latitude]``
* ``bbox``: ``[minLongitude, minLatitude, maxLongitude, maxLatitude]``
* ``polygons``: an array of outer rings, with each point represented as
  ``[longitude, latitude]``. Polygon holes are intentionally omitted.

The geoBoundaries inputs are pinned to a commit and verified against the Git
LFS object SHA-256 values. China city boundaries are administrative relations
returned by Nominatim from OpenStreetMap, requested serially at roughly one
request per second and persisted in the generated catalog.
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


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_JAPAN_DATABASE = REPO_ROOT / "CardBal/Resources/jp_stations.sqlite"
DEFAULT_CHINA_DATABASE = REPO_ROOT / "CardBal/Resources/tunion_stations.sqlite"
DEFAULT_KOREA_STATIONS = REPO_ROOT / "CardBal/Resources/korean_stations.tsv"
DEFAULT_OUTPUT = REPO_ROOT / "CardBal/Resources/EastAsiaCityBoundaries.json"

GEBOUNDARIES_COMMIT = "9469f09592ced973a3448cf66b6100b741b64c0d"
GEBOUNDARIES_COMMIT_DATE = "2023-12-13T04:03:07Z"
GEBOUNDARIES_MEDIA_ROOT = (
    "https://media.githubusercontent.com/media/wmgeolab/geoBoundaries/"
    f"{GEBOUNDARIES_COMMIT}/releaseData/gbOpen"
)
GEBOUNDARIES_ASSETS = {
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
}

USER_AGENT = (
    "CardBal-EastAsiaBoundaryGenerator/1.0 "
    "(https://github.com/iebb/TransitICReader; offline asset generation)"
)
NOMINATIM_SEARCH_URL = "https://nominatim.openstreetmap.org/search"
NOMINATIM_POLYGON_THRESHOLD = 0.0025
DEFAULT_NOMINATIM_DELAY_SECONDS = 1.1

# Exact administrative relations selected for the 39 city IDs present when
# this catalog was introduced. This prevents a future change in Nominatim
# ranking from silently substituting a similarly named city or lower-level
# feature while still allowing OSM to update each relation's geometry.
EXPECTED_CHINA_OSM_RELATIONS = {
    "1000": "912940",
    "1121": "912999",
    "2210": "2769604",
    "2220": "2764565",
    "2610": "2755608",
    "2900": "913067",
    "3010": "2131524",
    "3020": "4430942",
    "3030": "3218572",
    "3040": "3429666",
    "3050": "4430941",
    "3060": "4430899",
    "3310": "3221112",
    "3320": "3478607",
    "3330": "3289341",
    "3350": "3308626",
    "3370": "3316522",
    "3380": "3411720",
    "3450": "3477550",
    "3610": "3288965",
    "3620": "3262036",
    "3750": "3231588",
    "3910": "3263977",
    "3930": "3242930",
    "4210": "3169865",
    "4510": "3486449",
    "4520": "3469133",
    "4930": "3246491",
    "5510": "3202711",
    "5810": "3287346",
    "5880": "3464719",
    "6020": "3464319",
    "6510": "2110264",
    "6900": "913069",
    "7010": "2782246",
    "7310": "2723597",
    "7910": "3226004",
    "8210": "2701949",
    "8810": "2752472",
}

COORDINATE_DECIMALS = 4
JAPAN_RDP_TOLERANCE = 0.002
CHINA_RDP_TOLERANCE = 0.001
KOREA_RDP_TOLERANCE = 0.0015
JAPAN_GRID_SIZE = 0.5
JAPAN_NEAREST_FALLBACK_DEGREES = 0.02
MAX_OUTPUT_BYTES = 3 * 1024 * 1024

KOREA_AREA_SPECS = {
    "서울특별시": {"name": "Seoul", "level": "ADM1", "shapeName": "Seoul"},
    "인천광역시": {"name": "Incheon", "level": "ADM1", "shapeName": "Incheon"},
    "부산광역시": {"name": "Busan", "level": "ADM1", "shapeName": "Busan"},
    "대구광역시": {"name": "Daegu", "level": "ADM1", "shapeName": "Daegu"},
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
}

# Exact alias administrative evidence is authoritative for the atlas. A mode
# code alone is not: several KOTRIS modes span multiple capital-area cities.
KOREA_MODE_TO_AREA: dict[str, str] = {}


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


def download_geoboundaries_asset(asset_key: str, destination: Path) -> dict[str, Any]:
    asset = GEBOUNDARIES_ASSETS[asset_key]
    url = f"{GEBOUNDARIES_MEDIA_ROOT}/{asset['relativePath']}"
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "application/geo+json"})
    with urllib.request.urlopen(request, timeout=180) as response, destination.open("wb") as output:
        while chunk := response.read(1024 * 1024):
            output.write(chunk)
    actual_hash = sha256_file(destination)
    if actual_hash != asset["sha256"]:
        raise RuntimeError(
            f"geoBoundaries checksum mismatch for {asset_key}: expected {asset['sha256']}, got {actual_hash}"
        )
    payload = load_json(destination)
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


def simplify_ring(ring: Ring, tolerance: float) -> Ring:
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
        rounded = [round(point[0], COORDINATE_DECIMALS), round(point[1], COORDINATE_DECIMALS)]
        if not quantized or rounded != quantized[-1]:
            quantized.append(rounded)
    if len(quantized) < 3:
        quantized = []
        for point in deduplicated:
            rounded = [round(point[0], COORDINATE_DECIMALS), round(point[1], COORDINATE_DECIMALS)]
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
) -> dict[str, Any]:
    bbox = parts_bbox(parts)
    rings = []
    for outer, _holes in parts:
        try:
            rings.append(simplify_ring(outer, tolerance))
        except ValueError:
            # Some source multipolygons include microscopic slivers that become
            # fewer than three distinct points at the output quantization.
            # Omitting only those degenerate pieces preserves useful parts.
            continue
    if not rings:
        raise ValueError(f"Boundary {boundary_id} contains no usable rings after simplification")
    rings.sort(key=lambda ring: abs(ring_signed_area(ring)), reverse=True)
    return {
        "id": boundary_id,
        "countryCode": country_code,
        "name": normalized_boundary_name(name),
        "nativeName": normalized_boundary_name(native_name),
        "center": parts_centroid(parts),
        "bbox": [round(value, COORDINATE_DECIMALS) for value in bbox],
        "polygons": rings,
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


def prepare_japan_features(feature_collection: dict[str, Any]) -> tuple[list[dict[str, Any]], dict[tuple[int, int], list[int]]]:
    features: list[dict[str, Any]] = []
    index: dict[tuple[int, int], list[int]] = defaultdict(list)
    for source_feature in feature_collection["features"]:
        properties = source_feature.get("properties", {})
        shape_id = str(properties.get("shapeID", ""))
        shape_name = normalized_boundary_name(properties.get("shapeName"))
        if not shape_id:
            continue
        parts = geometry_parts(source_feature["geometry"])
        feature = {
            "id": f"jp:{shape_id}",
            "name": shape_name,
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
) -> tuple[list[dict[str, Any]], dict[str, str], dict[str, int]]:
    features, spatial_index = prepare_japan_features(feature_collection)
    matches_by_hex_code: dict[str, Counter[str]] = defaultdict(Counter)
    native_names: dict[str, Counter[str]] = defaultdict(Counter)
    matched_rows = 0
    nearest_fallback_rows = 0
    input_rows = 0

    connection = sqlite3.connect(database_path)
    try:
        rows = connection.execute(
            """
            SELECT hex_code, longitude, latitude, address
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

    for hex_code_value, longitude_value, latitude_value, address_value in rows:
        input_rows += 1
        hex_code = str(hex_code_value).strip().upper()
        point = (float(longitude_value), float(latitude_value))
        candidates = spatial_index.get(grid_cell(*point), [])
        contained = [
            feature_index
            for feature_index in candidates
            if bbox_contains(features[feature_index]["bbox"], point)
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
        boundary_records.append(
            make_boundary(
                boundary_id=feature["id"],
                country_code="JP",
                name=feature["name"],
                native_name=native_name,
                parts=feature["parts"],
                tolerance=JAPAN_RDP_TOLERANCE,
            )
        )

    station_mapping = dict(sorted(station_mapping.items()))
    stats = {
        "inputNonPseudoRows": input_rows,
        "inputUniqueHexCodes": len(input_hex_codes),
        "matchedRows": matched_rows,
        "mappedUniqueHexCodes": len(station_mapping),
        "unmappedUniqueHexCodes": len(input_hex_codes - set(station_mapping)),
        "nearestBoundaryFallbackRows": nearest_fallback_rows,
        "ambiguousUniqueHexCodes": ambiguous_hex_codes,
        "usedBoundaryCount": len(boundary_records),
    }
    return boundary_records, station_mapping, stats


class NominatimClient:
    def __init__(self, delay_seconds: float):
        self.delay_seconds = max(delay_seconds, 1.0)
        self.last_request_started = 0.0

    def _rate_limit(self) -> None:
        elapsed = time.monotonic() - self.last_request_started
        if elapsed < self.delay_seconds:
            time.sleep(self.delay_seconds - elapsed)

    def search_city(self, city_name: str) -> list[dict[str, Any]]:
        parameters = {
            "q": f"{city_name}, 中国",
            "format": "jsonv2",
            "countrycodes": "cn",
            "addressdetails": "1",
            "namedetails": "1",
            "extratags": "1",
            "polygon_geojson": "1",
            "polygon_threshold": str(NOMINATIM_POLYGON_THRESHOLD),
            "limit": "10",
            "dedupe": "1",
        }
        url = f"{NOMINATIM_SEARCH_URL}?{urllib.parse.urlencode(parameters)}"
        last_error: Exception | None = None
        for attempt in range(4):
            self._rate_limit()
            request = urllib.request.Request(
                url,
                headers={"User-Agent": USER_AGENT, "Accept": "application/json", "Accept-Language": "en,zh"},
            )
            self.last_request_started = time.monotonic()
            try:
                with urllib.request.urlopen(request, timeout=180) as response:
                    payload = json.loads(response.read().decode("utf-8"))
                if not isinstance(payload, list):
                    raise RuntimeError(f"Unexpected Nominatim payload for {city_name}")
                return payload
            except Exception as error:
                last_error = error
                time.sleep((attempt + 1) * 3.0)
        raise RuntimeError(f"Nominatim lookup failed for {city_name}: {last_error}")


def normalized_chinese_city_name(value: str) -> str:
    return value.strip().replace(" ", "").removesuffix("市")


def select_china_admin_boundary(city_name: str, results: list[dict[str, Any]]) -> dict[str, Any]:
    expected = normalized_chinese_city_name(city_name)
    candidates = []
    for result in results:
        geometry = result.get("geojson") or {}
        namedetails = result.get("namedetails") or {}
        address = result.get("address") or {}
        candidate_names = {
            str(result.get("name") or ""),
            str(namedetails.get("name") or ""),
            str(namedetails.get("name:zh") or ""),
            str(namedetails.get("official_name") or ""),
        }
        exact_name = any(normalized_chinese_city_name(name) == expected for name in candidate_names if name)
        admin_level = str((result.get("extratags") or {}).get("admin_level") or "")
        if not (
            exact_name
            and (result.get("category") or result.get("class")) == "boundary"
            and result.get("type") == "administrative"
            and result.get("osm_type") == "relation"
            and address.get("country_code") == "cn"
            and admin_level in {"4", "5"}
            and geometry.get("type") in {"Polygon", "MultiPolygon"}
        ):
            continue
        score = (
            1 if str(result.get("name") or "") == city_name else 0,
            1 if result.get("addresstype") == "city" else 0,
            float(result.get("importance") or 0.0),
        )
        candidates.append((score, result))
    if not candidates:
        summary = [
            {
                "name": result.get("name"),
                "osm_type": result.get("osm_type"),
                "osm_id": result.get("osm_id"),
                "category": result.get("category") or result.get("class"),
                "type": result.get("type"),
                "admin_level": (result.get("extratags") or {}).get("admin_level"),
            }
            for result in results
        ]
        raise RuntimeError(f"No exact OSM administrative relation found for {city_name}: {summary}")
    return max(candidates, key=lambda item: item[0])[1]


def load_china_cities(database_path: Path) -> list[tuple[str, str]]:
    connection = sqlite3.connect(database_path)
    try:
        rows = connection.execute(
            """
            SELECT city_id, city_name
            FROM tunion_stations
            GROUP BY city_id, city_name
            ORDER BY CAST(city_id AS INTEGER), city_name
            """
        ).fetchall()
    finally:
        connection.close()
    city_ids = {str(row[0]) for row in rows}
    if len(rows) != len(city_ids):
        raise RuntimeError("A T-Union city ID resolves to more than one city name")
    return [(str(city_id), str(city_name)) for city_id, city_name in rows]


def build_china_boundaries(
    database_path: Path,
    delay_seconds: float,
) -> tuple[list[dict[str, Any]], dict[str, str], dict[str, int], list[dict[str, Any]]]:
    cities = load_china_cities(database_path)
    current_city_ids = {city_id for city_id, _city_name in cities}
    if current_city_ids != set(EXPECTED_CHINA_OSM_RELATIONS):
        raise RuntimeError(
            "T-Union city IDs changed; review and pin the exact OSM administrative relation set before regenerating"
        )
    client = NominatimClient(delay_seconds)
    boundaries = []
    city_mapping: dict[str, str] = {}
    source_relations = []
    for index, (city_id, city_name) in enumerate(cities, start=1):
        print(f"Nominatim {index}/{len(cities)}: {city_id} {city_name}", flush=True)
        result = select_china_admin_boundary(city_name, client.search_city(city_name))
        osm_id = str(result["osm_id"])
        if osm_id != EXPECTED_CHINA_OSM_RELATIONS[city_id]:
            raise RuntimeError(
                f"Nominatim selected relation {osm_id} for {city_id} {city_name}; "
                f"expected reviewed relation {EXPECTED_CHINA_OSM_RELATIONS[city_id]}"
            )
        boundary_id = f"cn:relation:{osm_id}"
        if boundary_id in city_mapping.values():
            raise RuntimeError(f"Two T-Union city IDs selected the same OSM relation: {boundary_id}")
        namedetails = result.get("namedetails") or {}
        native_name = str(namedetails.get("name:zh") or result.get("name") or city_name)
        english_name = str(namedetails.get("name:en") or namedetails.get("int_name") or result.get("name") or city_name)
        parts = geometry_parts(result["geojson"])
        boundaries.append(
            make_boundary(
                boundary_id=boundary_id,
                country_code="CN",
                name=english_name,
                native_name=native_name,
                parts=parts,
                tolerance=CHINA_RDP_TOLERANCE,
            )
        )
        city_mapping[city_id] = boundary_id
        source_relations.append(
            {
                "cityID": city_id,
                "osmType": "relation",
                "osmID": osm_id,
                "adminLevel": str((result.get("extratags") or {}).get("admin_level") or ""),
            }
        )
    stats = {"inputCityCount": len(cities), "mappedCityCount": len(city_mapping), "usedBoundaryCount": len(boundaries)}
    return boundaries, city_mapping, stats, source_relations


def find_single_feature(feature_collection: dict[str, Any], shape_name: str) -> dict[str, Any]:
    matches = [
        feature
        for feature in feature_collection["features"]
        if str((feature.get("properties") or {}).get("shapeName") or "") == shape_name
    ]
    if len(matches) != 1:
        raise RuntimeError(f"Expected exactly one geoBoundaries feature named {shape_name!r}, found {len(matches)}")
    return matches[0]


def build_korea_boundaries(
    adm1: dict[str, Any],
    adm2: dict[str, Any],
    stations_path: Path,
) -> tuple[list[dict[str, Any]], dict[str, str], dict[str, str], dict[str, int]]:
    boundary_ids_by_area: dict[str, str] = {}
    boundaries = []
    for area_key, spec in KOREA_AREA_SPECS.items():
        source = adm1 if spec["level"] == "ADM1" else adm2
        feature = find_single_feature(source, spec["shapeName"])
        properties = feature["properties"]
        boundary_id = f"kr:{properties['shapeID']}"
        boundary_ids_by_area[area_key] = boundary_id
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
    stats = {
        "mappedModeCodeCount": len(mode_mapping),
        "mappedLocationCodeCount": len(location_mapping),
        "officialAliasRowCount": len(locations),
        "usedBoundaryCount": len(boundaries),
    }
    return boundaries, mode_mapping, location_mapping, stats


def build_catalog(args: argparse.Namespace) -> dict[str, Any]:
    generated_at = utc_now()
    with tempfile.TemporaryDirectory(prefix="cardbal-east-asia-boundaries-") as temporary_directory:
        temporary_path = Path(temporary_directory)
        geo = {
            asset_key: download_geoboundaries_asset(asset_key, temporary_path / f"{asset_key}.geojson")
            for asset_key in GEBOUNDARIES_ASSETS
        }

        japan_boundaries, japan_mapping, japan_stats = join_japanese_stations(
            args.japan_database,
            geo["JPN_ADM2"],
        )
        korea_boundaries, korea_mode_mapping, korea_location_mapping, korea_stats = build_korea_boundaries(
            geo["KOR_ADM1"],
            geo["KOR_ADM2"],
            args.korea_stations,
        )
        china_boundaries, china_mapping, china_stats, china_source_relations = build_china_boundaries(
            args.china_database,
            args.nominatim_delay,
        )

    boundaries = japan_boundaries + china_boundaries + korea_boundaries
    boundaries.sort(key=lambda boundary: (boundary["countryCode"], boundary["id"]))
    referenced_ids = (
        set(japan_mapping.values())
        | set(china_mapping.values())
        | set(korea_mode_mapping.values())
        | set(korea_location_mapping.values())
    )
    emitted_ids = {boundary["id"] for boundary in boundaries}
    if referenced_ids != emitted_ids:
        raise RuntimeError(
            f"Boundary reference mismatch: missing={sorted(referenced_ids - emitted_ids)}, "
            f"unused={sorted(emitted_ids - referenced_ids)}"
        )

    return {
        "version": 1,
        "generatedAt": generated_at,
        "attribution": [
            "geoBoundaries (www.geoboundaries.org)",
            "© OpenStreetMap contributors, ODbL 1.0 (www.openstreetmap.org/copyright)",
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
                    "JPN_ADM2": "OpenStreetMap/Wambacher, CC BY-SA 2.0",
                    "KOR_ADM1": "Natural Earth, Public Domain",
                    "KOR_ADM2": "citypopulation.de, CC BY 3.0",
                },
            },
            "openStreetMapChina": {
                "service": "Nominatim",
                "endpoint": NOMINATIM_SEARCH_URL,
                "dataCopyright": "© OpenStreetMap contributors",
                "dataLicense": "ODbL 1.0",
                "copyrightURL": "https://www.openstreetmap.org/copyright",
                "polygonThresholdDegrees": NOMINATIM_POLYGON_THRESHOLD,
                "retrievedAt": generated_at,
                "relations": china_source_relations,
            },
            "localLookups": {
                "japan": "CardBal/Resources/jp_stations.sqlite, non-pseudo coordinates",
                "china": "CardBal/Resources/tunion_stations.sqlite, distinct city_id/city_name pairs",
                "korea": "CardBal/Resources/korean_stations.tsv from iebb/korean-stations plus explicit verified transport-mode codes",
            },
        },
        "generation": {
            "coordinateOrder": "longitude,latitude",
            "polygonRepresentation": "outer rings only; holes omitted",
            "quantizationDecimals": COORDINATE_DECIMALS,
            "rdpToleranceDegrees": {
                "JP": JAPAN_RDP_TOLERANCE,
                "CN": CHINA_RDP_TOLERANCE,
                "KR": KOREA_RDP_TOLERANCE,
            },
            "japanSpatialJoin": {
                "source": "pinned simplified JPN ADM2 polygons",
                "lookupKey": "uppercase five-character jp_stations.hex_code without 0x prefix",
                "nearestFallbackMaximumDegrees": JAPAN_NEAREST_FALLBACK_DEGREES,
            },
            "counts": {
                "boundaries": len(boundaries),
                "JP": japan_stats,
                "CN": china_stats,
                "KR": korea_stats,
            },
        },
        "boundaries": boundaries,
        "japanStationToBoundary": japan_mapping,
        "chinaCityToBoundary": dict(sorted(china_mapping.items(), key=lambda item: int(item[0]))),
        "koreaModeToBoundary": korea_mode_mapping,
        "koreaLocationToBoundary": korea_location_mapping,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--japan-database", type=Path, default=DEFAULT_JAPAN_DATABASE)
    parser.add_argument("--china-database", type=Path, default=DEFAULT_CHINA_DATABASE)
    parser.add_argument("--korea-stations", type=Path, default=DEFAULT_KOREA_STATIONS)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument(
        "--nominatim-delay",
        type=float,
        default=DEFAULT_NOMINATIM_DELAY_SECONDS,
        help="Seconds between Nominatim requests; values below 1.0 are clamped to 1.0",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    for input_path in (args.japan_database, args.china_database, args.korea_stations):
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
    counts = catalog["generation"]["counts"]
    print(
        f"Wrote {args.output} ({len(encoded):,} bytes; {counts['boundaries']} boundaries; "
        f"JP hex codes {counts['JP']['mappedUniqueHexCodes']}/{counts['JP']['inputUniqueHexCodes']}; "
        f"CN cities {counts['CN']['mappedCityCount']}; KR modes {counts['KR']['mappedModeCodeCount']})"
    )


if __name__ == "__main__":
    main()
