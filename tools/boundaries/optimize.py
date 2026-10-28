#!/usr/bin/env python3
"""Optimize CardBal's generated East Asia boundary catalogs.

This is a generated-data pass, not a runtime renderer helper.  It accepts both
the legacy schema-v1 ``polygons`` representation and schema-v2 ``components``,
then always emits schema v2.  The pass:

* makes every boundary polygonal and valid;
* removes secondary components whose bounding box is smaller than 10 x 10 km;
* resolves same-country, same-catalog overlaps with the smaller-area boundary
  winning (the boundary id is the deterministic tie breaker);
* preserves repaired polygon masks without moving territory between boundary
  ids, then emits a separate simplified, deduplicated reference-line LOD; and
* writes holes explicitly as ``components: [{"outer": ..., "holes": ...}]``.

City and province catalogs are optimized separately.  Their geometries are
expected to overlap each other because they represent different map levels.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import math
from collections import defaultdict
from pathlib import Path
from typing import Any, Iterable, Sequence


from tools.paths import BOUNDARIES
DEFAULT_CITY_CATALOG = BOUNDARIES / "EastAsiaCityBoundaries.json"
DEFAULT_PROVINCE_CATALOG = BOUNDARIES / "EastAsiaProvinceBoundaries.json"
DEFAULT_CHINA_COVERAGE = BOUNDARIES / "ChinaTransitCoverage.json"

EXPECTED_SHAPELY_VERSION = "2.1.2"
ALGORITHM_VERSION = 2
EARTH_RADIUS_KM = 6_371.0088
KM_PER_LATITUDE_DEGREE = 110.574
KM_PER_LONGITUDE_DEGREE_AT_EQUATOR = 111.320
DEFAULT_QUANTIZATION_DECIMALS = {"CN": 5, "JP": 4, "KR": 4, "MN": 4}
REFERENCE_LINE_TOLERANCE_MULTIPLIER = 2.0
REFERENCE_LINE_MAX_PATHS_PER_BATCH = 256
REFERENCE_LINE_MAX_VERTICES_PER_BATCH = 2_000
MAXIMUM_BOUNDARY_OUTSIDE_SOURCE_AREA_RATIO = 0.001
DEFAULT_MAXIMUM_OVERLAP_AREA_SQUARE_DEGREES = 2e-7
MAXIMUM_SERIALIZED_POLYGON_VERTEX_INCREASE_RATIO = 1.10
MINIMUM_BOUNDARY_RETAINED_SOURCE_AREA_RATIO = 0.90
REFERENCE_LINE_GRID_DEGREES = {
    "city": {"CN": 4.0, "JP": 2.0, "KR": 1.0, "MN": 2.0},
    "province": {"CN": 10.0, "JP": 5.0, "KR": 3.0, "MN": 5.0},
}
MAXIMUM_REFERENCE_LINE_VERTICES = {
    "city": {"CN": 55_000, "JP": 30_000, "KR": 2_000, "MN": 2_000},
    "province": {"CN": 6_000, "JP": 5_000, "KR": 2_000, "MN": 4_000},
}
DEFAULT_TOLERANCE_DEGREES = {
    "city": {"CN": 0.02, "JP": 0.01, "KR": 0.009, "MN": 0.015},
    "province": {"CN": 0.025, "JP": 0.015, "KR": 0.012, "MN": 0.02},
}


def require_shapely() -> dict[str, Any]:
    try:
        import shapely
        from shapely import (
            coverage_is_valid,
            line_merge,
            make_valid,
            orient_polygons,
            set_precision,
        )
        from shapely.geometry import GeometryCollection, MultiPolygon, Polygon
        from shapely.ops import unary_union
        from shapely.strtree import STRtree
    except ModuleNotFoundError as error:
        raise RuntimeError(
            "Boundary optimization requires Shapely 2.1.2; install "
            "tools/boundaries/requirements.txt"
        ) from error
    if shapely.__version__ != EXPECTED_SHAPELY_VERSION:
        raise RuntimeError(
            f"Expected Shapely {EXPECTED_SHAPELY_VERSION} for deterministic output, "
            f"found {shapely.__version__}"
        )
    return {
        "shapely": shapely,
        "coverage_is_valid": coverage_is_valid,
        "line_merge": line_merge,
        "make_valid": make_valid,
        "orient_polygons": orient_polygons,
        "set_precision": set_precision,
        "GeometryCollection": GeometryCollection,
        "MultiPolygon": MultiPolygon,
        "Polygon": Polygon,
        "unary_union": unary_union,
        "STRtree": STRtree,
    }


def load_json(path: Path) -> dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise RuntimeError(f"{path} must contain a JSON object")
    if payload.get("version") not in {1, 2}:
        raise RuntimeError(f"Unsupported catalog version in {path}: {payload.get('version')!r}")
    boundaries = payload.get("boundaries")
    if not isinstance(boundaries, list) or not boundaries:
        raise RuntimeError(f"{path} contains no boundaries")
    return payload


def canonical_sha256(value: Any) -> str:
    encoded = json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def mapping_payload(catalog: dict[str, Any]) -> dict[str, Any]:
    """Return top-level lookup payloads that optimization must not alter."""

    metadata_keys = {
        "version",
        "generatedAt",
        "attribution",
        "sources",
        "generation",
        "boundaries",
        "referenceLines",
    }
    return {key: value for key, value in catalog.items() if key not in metadata_keys}


def normalized_province_join_name(value: Any, *, label: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise RuntimeError(f"{label} must be a nonempty string")
    return value.strip().casefold()


def china_province_coverage_name(boundary: dict[str, Any]) -> str:
    """Return the formal China coverage join name without altering display names.

    Older catalogs and compact test fixtures used ``name`` as both the display
    value and the ChinaTransitCoverage join key.  New catalogs keep ``name``
    concise and expose the formal join value as ``coverageName``.
    """

    join_field = "coverageName" if "coverageName" in boundary else "name"
    return normalized_province_join_name(
        boundary.get(join_field),
        label=f"China province {boundary.get('id')!r} {join_field}",
    )


def unique_china_province_coverage_names(
    province_boundaries: Sequence[dict[str, Any]],
) -> set[str]:
    names_by_key: dict[str, str] = {}
    for boundary in province_boundaries:
        if boundary.get("countryCode") != "CN":
            continue
        join_name = china_province_coverage_name(boundary)
        boundary_id = str(boundary.get("id", ""))
        if join_name in names_by_key:
            raise RuntimeError(
                "China province coverage names must be unique: "
                f"{join_name!r} is shared by {names_by_key[join_name]!r} "
                f"and {boundary_id!r}"
            )
        names_by_key[join_name] = boundary_id
    return set(names_by_key)


def prune_city_catalog_to_supported_boundaries(
    catalog: dict[str, Any],
    china_coverage: dict[str, Any],
) -> dict[str, Any]:
    """Retain only city geometries addressable by the app's station/card data."""

    output = copy.deepcopy(catalog)
    china_mapping = output.get("chinaCityToBoundary") or {}
    excluded_china_codes = set(
        ((china_coverage.get("tUnion") or {}).get("excludedCityBoundaryCodes") or [])
    )
    supported_china_ids = {
        boundary_id
        for city_code, boundary_id in china_mapping.items()
        if city_code not in excluded_china_codes
    }
    supported_china_ids.update(
        (china_coverage.get("referenceBoundaryToProvince") or {}).keys()
    )
    supported_ids = (
        supported_china_ids
        | set((output.get("japanStationToBoundary") or {}).values())
        | set((output.get("koreaModeToBoundary") or {}).values())
        | set((output.get("koreaLocationToBoundary") or {}).values())
        | set((output.get("mongoliaStationToBoundary") or {}).values())
    )
    original_boundaries = output.get("boundaries") or []
    output["boundaries"] = [
        boundary for boundary in original_boundaries if boundary.get("id") in supported_ids
    ]
    emitted_ids = {boundary.get("id") for boundary in output["boundaries"]}
    if emitted_ids != supported_ids:
        raise RuntimeError(
            "Supported city boundary pruning mismatch: "
            f"missing={sorted(supported_ids - emitted_ids)}, "
            f"unexpected={sorted(emitted_ids - supported_ids)}"
        )
    dangling_china_targets = set(china_mapping.values()) - emitted_ids
    expected_dangling_china_targets = {
        china_mapping[city_code]
        for city_code in excluded_china_codes
        if city_code in china_mapping
    }
    if dangling_china_targets != expected_dangling_china_targets:
        raise RuntimeError(
            "China city mappings contain unexpected dangling boundary targets: "
            f"expected={sorted(expected_dangling_china_targets)}, "
            f"actual={sorted(dangling_china_targets)}"
        )
    if (
        len(output["boundaries"]) == len(original_boundaries)
        and (output.get("generation") or {}).get("supportedBoundaryPruning")
    ):
        return output
    output.pop("referenceLines", None)
    generation = copy.deepcopy(output.get("generation") or {})
    generation.pop("boundaryOptimization", None)
    generation.pop("referenceLineRepresentation", None)
    generation["supportedBoundaryPruning"] = {
        "inputBoundaryCount": len(original_boundaries),
        "outputBoundaryCount": len(output["boundaries"]),
        "CN": len(supported_china_ids),
        "JP": len(set((output.get("japanStationToBoundary") or {}).values())),
        "KR": len(
            set((output.get("koreaModeToBoundary") or {}).values())
            | set((output.get("koreaLocationToBoundary") or {}).values())
        ),
        "MN": len(set((output.get("mongoliaStationToBoundary") or {}).values())),
        "intentionalDanglingChinaMappingTargetCount": len(dangling_china_targets),
        "intentionalDanglingChinaCityCodes": sorted(
            excluded_china_codes,
            key=lambda value: (
                (0, int(value)) if str(value).isdigit() else (1, str(value))
            ),
        ),
        "scope": "only boundaries referenced by current T-Union participation or station mappings",
    }
    output["generation"] = generation
    return output


def prune_province_catalog_to_supported_boundaries(
    catalog: dict[str, Any],
    city_catalog: dict[str, Any],
    china_coverage: dict[str, Any],
    *,
    tools: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Retain only provinces containing generated supported city geometry."""

    if tools is None:
        tools = require_shapely()
    output = copy.deepcopy(catalog)
    province_boundaries = output.get("boundaries") or []
    city_boundaries = city_catalog.get("boundaries") or []
    if not province_boundaries or not city_boundaries:
        raise RuntimeError("Province pruning requires non-empty province and city catalogs")

    raw_supported_china_names = china_coverage.get("supportedProvinceNames", [])
    supported_china_names: set[str] = set()
    for name in raw_supported_china_names:
        normalized_name = normalized_province_join_name(
            name,
            label="ChinaTransitCoverage supportedProvinceNames entry",
        )
        if normalized_name in supported_china_names:
            raise RuntimeError(
                "ChinaTransitCoverage supportedProvinceNames must be unique: "
                f"duplicate {normalized_name!r}"
            )
        supported_china_names.add(normalized_name)
    emitted_china_names = unique_china_province_coverage_names(province_boundaries)
    if supported_china_names != emitted_china_names:
        raise RuntimeError(
            "China supported province names do not match the generated province catalog: "
            f"missing={sorted(supported_china_names - emitted_china_names)}, "
            f"unexpected={sorted(emitted_china_names - supported_china_names)}"
        )

    supported_japan_codes = {
        str(boundary["subdivisionCode"])
        for boundary in city_boundaries
        if boundary.get("countryCode") == "JP" and boundary.get("subdivisionCode")
    }
    if not supported_japan_codes:
        raise RuntimeError("Supported Japan city boundaries have no subdivision codes")

    korea_provinces = [
        boundary for boundary in province_boundaries if boundary.get("countryCode") == "KR"
    ]
    korea_province_geometries = [boundary_geometry(boundary, tools) for boundary in korea_provinces]
    supported_korea_ids: set[str] = set()
    for city_boundary in city_boundaries:
        if city_boundary.get("countryCode") != "KR":
            continue
        city_boundary_id = str(city_boundary.get("id", ""))
        source_feature_id = city_boundary_id.removeprefix("kr:")
        exact_adm1_id = f"kr:adm1:{source_feature_id}"
        if any(
            province_boundary.get("id") == exact_adm1_id
            for province_boundary in korea_provinces
        ):
            supported_korea_ids.add(exact_adm1_id)
            continue
        city_geometry = boundary_geometry(city_boundary, tools)
        matches = []
        for province_boundary, province_geometry in zip(
            korea_provinces,
            korea_province_geometries,
        ):
            intersection = city_geometry.intersection(province_geometry)
            intersection_area = 0.0 if intersection.is_empty else float(intersection.area)
            if intersection_area <= 0.0:
                continue
            matches.append(
                (
                    -(intersection_area / float(city_geometry.area)),
                    geometry_area_square_kilometers(province_geometry),
                    str(province_boundary["id"]),
                )
            )
        if not matches:
            raise RuntimeError(
                f"Supported Korean city {city_boundary.get('id')} does not intersect a province"
            )
        matches.sort()
        supported_korea_ids.add(matches[0][2])
    if not supported_korea_ids:
        raise RuntimeError("Supported Korea city boundaries resolved to no provinces")

    mongolia_province_ids = {
        str(boundary["id"])
        for boundary in province_boundaries
        if boundary.get("countryCode") == "MN"
    }
    station_mapped_mongolia_ids = set(
        str(boundary_id)
        for boundary_id in (output.get("mongoliaStationToBoundary") or {}).values()
    )
    supported_mongolia_city_ids = {
        str(boundary["id"])
        for boundary in city_boundaries
        if boundary.get("countryCode") == "MN"
    }
    mongolia_city_to_province = {
        str(city_id): str(province_id)
        for city_id, province_id in (
            city_catalog.get("mongoliaCityToProvince") or {}
        ).items()
    }
    supported_mongolia_ids = set(mongolia_city_to_province.values())
    if (
        not mongolia_province_ids
        or not station_mapped_mongolia_ids
        or not supported_mongolia_city_ids
        or not supported_mongolia_ids
    ):
        raise RuntimeError("Mongolia province pruning requires mapped city data")
    if not station_mapped_mongolia_ids.issubset(mongolia_province_ids):
        raise RuntimeError(
            "Mongolia station mappings reference an unknown ADM1 province boundary"
        )
    if set(mongolia_city_to_province) != supported_mongolia_city_ids:
        raise RuntimeError(
            "Mongolia city-to-province mapping does not cover every emitted city"
        )
    if not supported_mongolia_ids.issubset(mongolia_province_ids):
        raise RuntimeError(
            "Mongolia city-to-province mapping references an unknown province"
        )

    retained_boundaries = []
    for boundary in province_boundaries:
        country_code = boundary.get("countryCode")
        if country_code == "CN":
            keep = china_province_coverage_name(boundary) in supported_china_names
        elif country_code == "JP":
            keep = boundary.get("subdivisionCode") in supported_japan_codes
        elif country_code == "KR":
            keep = boundary.get("id") in supported_korea_ids
        elif country_code == "MN":
            keep = boundary.get("id") in supported_mongolia_ids
        else:
            keep = False
        if keep:
            retained_boundaries.append(boundary)

    retained_counts = {
        country_code: sum(
            boundary.get("countryCode") == country_code for boundary in retained_boundaries
        )
        for country_code in ("CN", "JP", "KR", "MN")
    }
    expected_counts = {
        "CN": len(supported_china_names),
        "JP": len(supported_japan_codes),
        "KR": len(supported_korea_ids),
        "MN": len(supported_mongolia_ids),
    }
    if retained_counts != expected_counts:
        raise RuntimeError(
            f"Supported province pruning mismatch: expected={expected_counts}, "
            f"actual={retained_counts}"
        )

    output["boundaries"] = retained_boundaries
    if (
        len(retained_boundaries) == len(province_boundaries)
        and (output.get("generation") or {}).get("supportedBoundaryPruning")
    ):
        return output
    output.pop("referenceLines", None)
    generation = copy.deepcopy(output.get("generation") or {})
    generation.pop("boundaryOptimization", None)
    generation.pop("referenceLineRepresentation", None)
    generation["supportedBoundaryPruning"] = {
        "inputBoundaryCount": len(province_boundaries),
        "outputBoundaryCount": len(retained_boundaries),
        **retained_counts,
        "scope": "only provinces containing current T-Union or station-mapped transit coverage",
    }
    output["generation"] = generation
    return output


def polygonal_geometry(geometry: Any, tools: dict[str, Any]) -> Any:
    """Repair a geometry and discard non-polygonal make-valid fragments."""

    geometry = tools["make_valid"](geometry)
    if geometry.is_empty:
        return tools["Polygon"]()
    if geometry.geom_type in {"Polygon", "MultiPolygon"}:
        return geometry
    parts = []
    for child in getattr(geometry, "geoms", []):
        polygonal_child = polygonal_geometry(child, tools)
        if not polygonal_child.is_empty:
            parts.append(polygonal_child)
    if not parts:
        return tools["Polygon"]()
    return tools["unary_union"](parts)


def validate_ring(value: Any, label: str) -> list[tuple[float, float]]:
    if not isinstance(value, list):
        raise RuntimeError(f"{label} must be an array")
    coordinates: list[tuple[float, float]] = []
    for point in value:
        if not isinstance(point, list) or len(point) != 2:
            raise RuntimeError(f"{label} contains a non-coordinate value")
        longitude, latitude = float(point[0]), float(point[1])
        if not math.isfinite(longitude) or not math.isfinite(latitude):
            raise RuntimeError(f"{label} contains a non-finite coordinate")
        coordinate = (longitude, latitude)
        if not coordinates or coordinate != coordinates[-1]:
            coordinates.append(coordinate)
    if coordinates and coordinates[0] != coordinates[-1]:
        coordinates.append(coordinates[0])
    if len(coordinates) < 4 or len(set(coordinates[:-1])) < 3:
        raise RuntimeError(f"{label} is a degenerate polygon ring")
    return coordinates


def boundary_geometry(boundary: dict[str, Any], tools: dict[str, Any]) -> Any:
    boundary_id = str(boundary.get("id", ""))
    if not boundary_id:
        raise RuntimeError("Every boundary must have a nonempty id")
    polygons = []
    components = boundary.get("components")
    if components is not None:
        if not isinstance(components, list) or not components:
            raise RuntimeError(f"Boundary {boundary_id} has no schema-v2 components")
        for component_index, component in enumerate(components):
            if not isinstance(component, dict):
                raise RuntimeError(f"Boundary {boundary_id} has a malformed component")
            outer = validate_ring(
                component.get("outer"),
                f"Boundary {boundary_id} component {component_index} outer ring",
            )
            hole_values = component.get("holes", [])
            if not isinstance(hole_values, list):
                raise RuntimeError(f"Boundary {boundary_id} component holes must be an array")
            holes = [
                validate_ring(
                    hole,
                    f"Boundary {boundary_id} component {component_index} hole {hole_index}",
                )
                for hole_index, hole in enumerate(hole_values)
            ]
            polygons.append(
                polygonal_geometry(tools["Polygon"](outer, holes), tools)
            )
    else:
        legacy_polygons = boundary.get("polygons")
        if not isinstance(legacy_polygons, list) or not legacy_polygons:
            raise RuntimeError(f"Boundary {boundary_id} has neither components nor polygons")
        polygons = [
            polygonal_geometry(
                tools["Polygon"](
                    validate_ring(ring, f"Boundary {boundary_id} polygon {polygon_index}")
                ),
                tools,
            )
            for polygon_index, ring in enumerate(legacy_polygons)
        ]
    geometry = polygonal_geometry(tools["unary_union"](polygons), tools)
    if geometry.is_empty or geometry.area <= 0.0:
        raise RuntimeError(f"Boundary {boundary_id} has no usable polygonal geometry")
    return geometry


def geometry_polygons(geometry: Any) -> list[Any]:
    if geometry.is_empty:
        return []
    if geometry.geom_type == "Polygon":
        return [geometry]
    if geometry.geom_type == "MultiPolygon":
        return list(geometry.geoms)
    raise RuntimeError(f"Expected polygonal geometry, found {geometry.geom_type}")


def geometry_vertex_count(geometry: Any) -> int:
    return sum(
        len(polygon.exterior.coords)
        + sum(len(interior.coords) for interior in polygon.interiors)
        for polygon in geometry_polygons(geometry)
    )


def geometry_hole_count(geometry: Any) -> int:
    return sum(len(polygon.interiors) for polygon in geometry_polygons(geometry))


def spherical_ring_area_square_kilometers(coordinates: Iterable[Sequence[float]]) -> float:
    points = list(coordinates)
    if len(points) < 4:
        return 0.0
    total = 0.0
    for left, right in zip(points, points[1:]):
        left_longitude = math.radians(float(left[0]))
        right_longitude = math.radians(float(right[0]))
        longitude_delta = right_longitude - left_longitude
        if longitude_delta > math.pi:
            longitude_delta -= math.tau
        elif longitude_delta < -math.pi:
            longitude_delta += math.tau
        total += longitude_delta * (
            2.0
            + math.sin(math.radians(float(left[1])))
            + math.sin(math.radians(float(right[1])))
        )
    return abs(total) * EARTH_RADIUS_KM * EARTH_RADIUS_KM / 2.0


def geometry_area_square_kilometers(geometry: Any) -> float:
    total = 0.0
    for polygon in geometry_polygons(geometry):
        polygon_area = spherical_ring_area_square_kilometers(polygon.exterior.coords)
        polygon_area -= sum(
            spherical_ring_area_square_kilometers(interior.coords)
            for interior in polygon.interiors
        )
        total += max(0.0, polygon_area)
    return total


def component_dimensions_km(polygon: Any) -> tuple[float, float]:
    min_longitude, min_latitude, max_longitude, max_latitude = polygon.bounds
    middle_latitude = (min_latitude + max_latitude) / 2.0
    width = (
        (max_longitude - min_longitude)
        * KM_PER_LONGITUDE_DEGREE_AT_EQUATOR
        * max(0.0, math.cos(math.radians(middle_latitude)))
    )
    height = (max_latitude - min_latitude) * KM_PER_LATITUDE_DEGREE
    return width, height


def polygon_sort_key(polygon: Any) -> tuple[Any, ...]:
    return (
        -float(polygon.area),
        *(round(float(value), 12) for value in polygon.bounds),
        polygon.wkb_hex,
    )


def drop_small_secondary_components(
    geometry: Any,
    minimum_width_km: float,
    minimum_height_km: float,
    tools: dict[str, Any],
) -> tuple[Any, dict[str, float | int]]:
    polygons = sorted(geometry_polygons(geometry), key=polygon_sort_key)
    retained = [polygons[0]]
    dropped = []
    for polygon in polygons[1:]:
        width_km, height_km = component_dimensions_km(polygon)
        if width_km < minimum_width_km and height_km < minimum_height_km:
            dropped.append(polygon)
        else:
            retained.append(polygon)
    result = polygonal_geometry(tools["unary_union"](retained), tools)
    return result, {
        "inputComponents": len(polygons),
        "retainedComponents": len(retained),
        "droppedComponents": len(dropped),
        "droppedVertices": sum(geometry_vertex_count(polygon) for polygon in dropped),
        "droppedAreaSquareKilometers": sum(
            geometry_area_square_kilometers(polygon) for polygon in dropped
        ),
    }


def catalog_quantization_decimals(catalog: dict[str, Any], country_code: str) -> int:
    configured = (catalog.get("generation") or {}).get("quantizationDecimals")
    if isinstance(configured, dict) and country_code in configured:
        decimals = int(configured[country_code])
    elif isinstance(configured, int):
        decimals = configured
    else:
        decimals = DEFAULT_QUANTIZATION_DECIMALS.get(country_code, 5)
    if not 0 <= decimals <= 10:
        raise RuntimeError(f"Invalid quantization precision for {country_code}: {decimals}")
    return decimals


def apply_precision(geometry: Any, decimals: int, tools: dict[str, Any]) -> Any:
    geometry = tools["set_precision"](
        geometry,
        grid_size=10.0 ** -decimals,
        mode="valid_output",
    )
    return polygonal_geometry(geometry, tools)


def repair_country_overlaps(
    indexes: list[int],
    geometries: list[Any],
    boundary_ids: list[str],
    tools: dict[str, Any],
) -> tuple[list[Any], dict[str, Any]]:
    """Subtract prior smaller winners without a quadratic all-pairs scan."""

    local_geometries = [geometries[index] for index in indexes]
    local_tree = tools["STRtree"](local_geometries)
    areas = {
        index: geometry_area_square_kilometers(geometries[index]) for index in indexes
    }
    precedence = sorted(indexes, key=lambda index: (areas[index], boundary_ids[index]))
    rank = {index: position for position, index in enumerate(precedence)}
    local_by_global = {index: local for local, index in enumerate(indexes)}
    output_by_index: dict[int, Any] = {}
    removed_square_degrees = 0.0
    changed_boundaries = 0

    for index in precedence:
        geometry = geometries[index]
        candidate_indexes = []
        for local_candidate in local_tree.query(geometry):
            candidate = indexes[int(local_candidate)]
            if rank[candidate] < rank[index] and candidate in output_by_index:
                candidate_indexes.append(candidate)
        if candidate_indexes:
            claimed = tools["unary_union"](
                [output_by_index[candidate] for candidate in sorted(candidate_indexes)]
            )
            repaired = polygonal_geometry(geometry.difference(claimed), tools)
        else:
            repaired = geometry
        if repaired.is_empty or repaired.area <= 0.0:
            raise RuntimeError(
                f"Overlap repair removed all geometry from {boundary_ids[index]}; "
                "the input likely contains duplicate boundary ids or geometries"
            )
        removed = max(0.0, float(geometry.area) - float(repaired.area))
        if removed > 0.0:
            changed_boundaries += 1
            removed_square_degrees += removed
        output_by_index[index] = repaired

    # Keep catalog order.  The unused mapping is deliberately asserted so a
    # future index refactor cannot silently mix local and catalog positions.
    if len(local_by_global) != len(indexes):
        raise AssertionError("Country boundary indexes are not unique")
    outputs = [output_by_index[index] for index in indexes]

    # Fixed-precision overlay can leave sub-grid polygon slivers at multi-way
    # junctions.  Reapply the same deterministic precedence to the actual
    # repaired outputs.  Difference can only shrink a loser, so this converges
    # without changing which boundary owns an overlap.
    cleanup_passes = 0
    local_rank = {local: rank[index] for local, index in enumerate(indexes)}
    for cleanup_pass in range(1, 7):
        tree = tools["STRtree"](outputs)
        changed = False
        next_outputs = list(outputs)
        for loser in sorted(range(len(outputs)), key=lambda local: local_rank[local]):
            winners = []
            for raw_candidate in tree.query(outputs[loser]):
                candidate = int(raw_candidate)
                if local_rank[candidate] >= local_rank[loser]:
                    continue
                intersection = outputs[loser].intersection(outputs[candidate])
                if not intersection.is_empty and intersection.area > 0.0:
                    winners.append(candidate)
            if not winners:
                continue
            claimed = tools["unary_union"]([outputs[candidate] for candidate in sorted(winners)])
            repaired = polygonal_geometry(outputs[loser].difference(claimed), tools)
            if repaired.is_empty or repaired.area <= 0.0:
                raise RuntimeError(
                    f"Overlap cleanup removed all geometry from {boundary_ids[indexes[loser]]}"
                )
            next_outputs[loser] = repaired
            changed = True
        outputs = next_outputs
        cleanup_passes = cleanup_pass
        metrics = pairwise_overlap_metrics(
            outputs,
            [boundary_ids[index] for index in indexes],
            tools,
        )
        if metrics["maximumAreaSquareDegrees"] <= 1e-15:
            break
        if not changed:
            break
    return outputs, {
        "changedBoundaryCount": changed_boundaries,
        "removedAreaSquareDegrees": round(removed_square_degrees, 12),
        "winnerOrder": "ascending spherical area square kilometers, then boundary id",
        "numericalCleanupPasses": cleanup_passes,
    }


def pairwise_overlap_metrics(
    geometries: list[Any],
    boundary_ids: list[str],
    tools: dict[str, Any],
) -> dict[str, Any]:
    tree = tools["STRtree"](geometries)
    positive_pairs = 0
    total_area = 0.0
    maximum_area = 0.0
    maximum_pair: list[str] = []
    for left_index, left in enumerate(geometries):
        for raw_right_index in tree.query(left):
            right_index = int(raw_right_index)
            if right_index <= left_index:
                continue
            intersection = left.intersection(geometries[right_index])
            area = 0.0 if intersection.is_empty else float(intersection.area)
            if area <= 0.0:
                continue
            positive_pairs += 1
            total_area += area
            if area > maximum_area:
                maximum_area = area
                maximum_pair = [boundary_ids[left_index], boundary_ids[right_index]]
    return {
        "positiveAreaPairCount": positive_pairs,
        "totalAreaSquareDegrees": round(total_area, 15),
        "maximumAreaSquareDegrees": round(maximum_area, 15),
        "maximumAreaBoundaryIDs": maximum_pair,
    }


def canonical_number(value: float, decimals: int) -> int | float:
    rounded = round(float(value), decimals)
    if rounded == 0.0:
        return 0
    return rounded


def canonical_ring(coordinates: Iterable[Sequence[float]], decimals: int) -> list[list[int | float]]:
    points: list[tuple[int | float, int | float]] = []
    for coordinate in coordinates:
        point = (
            canonical_number(float(coordinate[0]), decimals),
            canonical_number(float(coordinate[1]), decimals),
        )
        if not points or point != points[-1]:
            points.append(point)
    if points and points[0] == points[-1]:
        points.pop()
    if len(set(points)) < 3:
        raise RuntimeError("Output quantization collapsed a polygon ring")
    smallest_index = min(range(len(points)), key=lambda index: (points[index], index))
    points = points[smallest_index:] + points[:smallest_index]
    points.append(points[0])
    return [[longitude, latitude] for longitude, latitude in points]


def canonical_line(
    coordinates: Iterable[Sequence[float]],
    decimals: int,
) -> list[list[int | float]] | None:
    """Quantize a generated reference path with deterministic direction/order."""

    points: list[tuple[int | float, int | float]] = []
    for coordinate in coordinates:
        point = (
            canonical_number(float(coordinate[0]), decimals),
            canonical_number(float(coordinate[1]), decimals),
        )
        if not points or point != points[-1]:
            points.append(point)
    if len(set(points)) < 2:
        return None

    if points[0] == points[-1]:
        points.pop()
        if len(set(points)) < 3:
            return None
        candidates: list[list[tuple[int | float, int | float]]] = []
        for values in (points, list(reversed(points))):
            smallest = min(values)
            for index, point in enumerate(values):
                if point == smallest:
                    candidates.append(values[index:] + values[:index])
        points = min(candidates)
        points.append(points[0])
    else:
        reverse = list(reversed(points))
        if reverse < points:
            points = reverse
    return [[longitude, latitude] for longitude, latitude in points]


def geometry_lines(geometry: Any) -> list[Any]:
    if geometry.is_empty:
        return []
    if geometry.geom_type in {"LineString", "LinearRing"}:
        return [geometry]
    if hasattr(geometry, "geoms"):
        return [line for value in geometry.geoms for line in geometry_lines(value)]
    return []


def split_reference_line(
    line: list[list[int | float]],
    maximum_vertices: int,
) -> list[list[list[int | float]]]:
    """Split a long stroke without introducing visible connector segments."""

    if len(line) <= maximum_vertices:
        return [line]
    chunks = []
    start = 0
    while start < len(line) - 1:
        end = min(len(line), start + maximum_vertices)
        chunk = line[start:end]
        if len(chunk) >= 2:
            chunks.append(chunk)
        if end == len(line):
            break
        start = end - 1
    return chunks


def build_reference_line_batches(
    *,
    catalog_kind: str,
    serialized_geometries: list[Any],
    country_indexes: dict[str, list[int]],
    quantization_decimals_by_country: dict[str, int],
    tolerances_by_country: dict[str, float],
    tools: dict[str, Any],
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    """Generate deduplicated, simplified, spatially bounded map strokes.

    Polygon components remain the source of truth for hit testing and visited
    masks.  These lines are a generated display LOD: shared borders occur once,
    and the client can hand each bounded batch directly to MapKit.
    """

    output_batches: list[dict[str, Any]] = []
    country_metadata: dict[str, Any] = {}
    for country_code in sorted(country_indexes):
        decimals = quantization_decimals_by_country[country_code]
        tolerance = (
            tolerances_by_country[country_code] * REFERENCE_LINE_TOLERANCE_MULTIPLIER
        )
        grid_degrees = REFERENCE_LINE_GRID_DEGREES[catalog_kind][country_code]
        country_geometries = [
            serialized_geometries[index] for index in country_indexes[country_code]
        ]
        network = tools["line_merge"](
            tools["unary_union"]([geometry.boundary for geometry in country_geometries])
        )

        canonical_paths: dict[
            tuple[tuple[int | float, int | float], ...],
            list[list[int | float]],
        ] = {}
        for source_line in geometry_lines(network):
            simplified = source_line.simplify(tolerance, preserve_topology=True)
            for line in geometry_lines(simplified):
                encoded = canonical_line(line.coords, decimals)
                if encoded is None:
                    continue
                for chunk in split_reference_line(
                    encoded,
                    REFERENCE_LINE_MAX_VERTICES_PER_BATCH,
                ):
                    key = tuple((point[0], point[1]) for point in chunk)
                    canonical_paths[key] = chunk
        paths = [canonical_paths[key] for key in sorted(canonical_paths)]
        if not paths:
            raise RuntimeError(
                f"Generated {catalog_kind} {country_code} reference line network is empty"
            )

        spatial_paths: dict[tuple[int, int], list[list[list[int | float]]]] = defaultdict(list)
        for path in paths:
            longitudes = [float(point[0]) for point in path]
            latitudes = [float(point[1]) for point in path]
            bucket = (
                math.floor(((min(longitudes) + max(longitudes)) / 2.0) / grid_degrees),
                math.floor(((min(latitudes) + max(latitudes)) / 2.0) / grid_degrees),
            )
            spatial_paths[bucket].append(path)

        country_batches = 0
        country_vertices = 0
        for (longitude_bucket, latitude_bucket), bucket_paths in sorted(spatial_paths.items()):
            current: list[list[list[int | float]]] = []
            current_vertices = 0
            bucket_batch_index = 0

            def flush() -> None:
                nonlocal current, current_vertices, bucket_batch_index, country_batches
                if not current:
                    return
                output_batches.append(
                    {
                        "countryCode": country_code,
                        "bucket": (
                            f"{longitude_bucket}:{latitude_bucket}:"
                            f"{bucket_batch_index}"
                        ),
                        "lines": current,
                    }
                )
                country_batches += 1
                bucket_batch_index += 1
                current = []
                current_vertices = 0

            for path in bucket_paths:
                path_vertices = len(path)
                if current and (
                    len(current) >= REFERENCE_LINE_MAX_PATHS_PER_BATCH
                    or current_vertices + path_vertices
                    > REFERENCE_LINE_MAX_VERTICES_PER_BATCH
                ):
                    flush()
                current.append(path)
                current_vertices += path_vertices
                country_vertices += path_vertices
            flush()

        maximum_vertices = MAXIMUM_REFERENCE_LINE_VERTICES[catalog_kind][country_code]
        if country_vertices > maximum_vertices:
            raise RuntimeError(
                f"Generated {catalog_kind} {country_code} reference line network has "
                f"{country_vertices:,} vertices, exceeding the {maximum_vertices:,}-vertex budget"
            )
        country_metadata[country_code] = {
            "batches": country_batches,
            "paths": len(paths),
            "vertices": country_vertices,
            "toleranceDegrees": tolerance,
            "gridDegrees": grid_degrees,
        }

    return output_batches, {
        "representation": (
            "deduplicated shared-border linework, simplified and spatially batched at generation time"
        ),
        "toleranceMultiplier": REFERENCE_LINE_TOLERANCE_MULTIPLIER,
        "maximumPathsPerBatch": REFERENCE_LINE_MAX_PATHS_PER_BATCH,
        "maximumVerticesPerBatch": REFERENCE_LINE_MAX_VERTICES_PER_BATCH,
        "countries": country_metadata,
        "counts": {
            "batches": len(output_batches),
            "paths": sum(value["paths"] for value in country_metadata.values()),
            "vertices": sum(value["vertices"] for value in country_metadata.values()),
        },
    }


def geometry_components(
    geometry: Any,
    decimals: int,
    tools: dict[str, Any],
) -> list[dict[str, Any]]:
    geometry = tools["orient_polygons"](geometry, exterior_cw=False)
    components = []
    for polygon in sorted(geometry_polygons(geometry), key=polygon_sort_key):
        holes = [
            canonical_ring(interior.coords, decimals) for interior in polygon.interiors
        ]
        holes.sort(
            key=lambda ring: (
                -abs(ring_signed_area(ring)),
                ring,
            )
        )
        components.append(
            {
                "outer": canonical_ring(polygon.exterior.coords, decimals),
                "holes": holes,
            }
        )
    if not components:
        raise RuntimeError("Cannot encode empty boundary geometry")
    return components


def ring_signed_area(ring: list[list[int | float]]) -> float:
    return sum(
        float(left[0]) * float(right[1]) - float(right[0]) * float(left[1])
        for left, right in zip(ring, ring[1:])
    ) / 2.0


def output_boundary_geometry(boundary: dict[str, Any], tools: dict[str, Any]) -> Any:
    """Strictly validate serialized components without silently repairing them."""

    boundary_id = str(boundary["id"])
    polygons = []
    for component_index, component in enumerate(boundary.get("components", [])):
        outer = validate_ring(
            component.get("outer"),
            f"Output boundary {boundary_id} component {component_index} outer ring",
        )
        holes = [
            validate_ring(
                hole,
                f"Output boundary {boundary_id} component {component_index} hole {hole_index}",
            )
            for hole_index, hole in enumerate(component.get("holes", []))
        ]
        polygon = tools["Polygon"](outer, holes)
        if polygon.is_empty or polygon.area <= 0.0 or not polygon.is_valid:
            raise RuntimeError(
                f"Output boundary {boundary_id} component {component_index} is invalid or empty"
            )
        polygons.append(polygon)
    if not polygons:
        raise RuntimeError(f"Output boundary {boundary_id} has no components")
    geometry = tools["unary_union"](polygons)
    if geometry.is_empty or geometry.area <= 0.0 or not geometry.is_valid:
        raise RuntimeError(f"Output boundary {boundary_id} is invalid or empty")
    return geometry


def encode_boundary_geometry(
    boundary: dict[str, Any],
    geometry: Any,
    decimals: int,
    tools: dict[str, Any],
) -> dict[str, Any]:
    geometry = apply_precision(geometry, decimals, tools)
    if geometry.is_empty or geometry.area <= 0.0:
        raise RuntimeError(f"Output quantization removed boundary {boundary.get('id')}")
    encoded = {
        key: copy.deepcopy(value)
        for key, value in boundary.items()
        if key not in {"polygons", "components", "center", "bbox"}
    }
    encoded["center"] = [
        canonical_number(geometry.centroid.x, decimals),
        canonical_number(geometry.centroid.y, decimals),
    ]
    encoded["bbox"] = [canonical_number(value, decimals) for value in geometry.bounds]
    encoded["components"] = geometry_components(geometry, decimals, tools)
    return encoded


def _optimize_catalog(
    *,
    catalog: dict[str, Any],
    catalog_kind: str,
    tolerances_by_country: dict[str, float],
    minimum_component_width_km: float,
    minimum_component_height_km: float,
    maximum_overlap_area_square_degrees: float,
    generated_at: str | None,
    tools: dict[str, Any],
) -> tuple[dict[str, Any], dict[str, Any]]:
    """Return an optimized schema-v2 copy of an in-memory catalog.

    Generator code can call this function directly without writing an
    intermediate file and without importing either generator module.
    """

    source = copy.deepcopy(catalog)
    if source.get("version") not in {1, 2}:
        raise RuntimeError(f"Unsupported catalog version: {source.get('version')!r}")
    if not isinstance(source.get("boundaries"), list) or not source["boundaries"]:
        raise RuntimeError("Catalog contains no boundaries")
    input_payload_sha256 = canonical_sha256(source)
    source_mapping_hash = canonical_sha256(mapping_payload(source))
    output = copy.deepcopy(source)
    boundaries = source["boundaries"]
    boundary_ids = [str(boundary.get("id", "")) for boundary in boundaries]
    if len(boundary_ids) != len(set(boundary_ids)):
        raise RuntimeError("Catalog contains duplicate boundary ids")

    country_indexes: dict[str, list[int]] = defaultdict(list)
    geometries: list[Any] = []
    filter_stats: list[dict[str, float | int]] = []
    input_vertices = 0
    input_holes = 0
    for index, boundary in enumerate(boundaries):
        country_code = str(boundary.get("countryCode", ""))
        if not country_code:
            raise RuntimeError(f"Boundary {boundary_ids[index]} has no countryCode")
        country_indexes[country_code].append(index)
        geometry = boundary_geometry(boundary, tools)
        input_vertices += geometry_vertex_count(geometry)
        input_holes += geometry_hole_count(geometry)
        decimals = catalog_quantization_decimals(source, country_code)
        geometry = apply_precision(geometry, decimals, tools)
        geometry, stats = drop_small_secondary_components(
            geometry,
            minimum_component_width_km,
            minimum_component_height_km,
            tools,
        )
        geometries.append(geometry)
        filter_stats.append(stats)

    serialization_decimals_by_country = {
        country_code: min(10, catalog_quantization_decimals(source, country_code) + 1)
        for country_code in country_indexes
    }

    optimized_geometries: list[Any | None] = [None] * len(geometries)
    country_metadata: dict[str, Any] = {}
    for country_code in sorted(country_indexes):
        if country_code not in tolerances_by_country:
            raise RuntimeError(
                f"No {catalog_kind} simplification tolerance configured for {country_code}"
            )
        indexes = country_indexes[country_code]
        repaired, overlap_repair = repair_country_overlaps(
            indexes,
            geometries,
            boundary_ids,
            tools,
        )
        local_ids = [boundary_ids[index] for index in indexes]
        final_country = []
        post_filter_stats = []
        for local_index, value in enumerate(repaired):
            value = polygonal_geometry(
                value.intersection(geometries[indexes[local_index]]),
                tools,
            )
            if value.is_empty or value.area <= 0.0:
                raise RuntimeError(
                    f"Overlap repair removed all geometry from "
                    f"{boundary_ids[indexes[local_index]]}"
                )
            value, stats = drop_small_secondary_components(
                value,
                minimum_component_width_km,
                minimum_component_height_km,
                tools,
            )
            final_country.append(value)
            post_filter_stats.append(stats)

        # The polygon masks intentionally retain the generated source detail.
        # Only the separately emitted reference-line network is simplified.
        # This avoids moving territory between small neighboring municipalities.
        local_positions = list(range(len(final_country)))
        final_country, post_precision_repair = repair_country_overlaps(
            local_positions,
            final_country,
            local_ids,
            tools,
        )
        overlap_metrics = pairwise_overlap_metrics(final_country, local_ids, tools)
        if overlap_metrics["maximumAreaSquareDegrees"] > maximum_overlap_area_square_degrees:
            raise RuntimeError(
                f"{catalog_kind} {country_code} retains positive-area overlap: "
                f"{overlap_metrics}"
            )

        input_footprint = polygonal_geometry(
            tools["unary_union"]([geometries[index] for index in indexes]),
            tools,
        )
        output_footprint = polygonal_geometry(tools["unary_union"](final_country), tools)
        outside_input = polygonal_geometry(output_footprint.difference(input_footprint), tools)
        outside_input_area = 0.0 if outside_input.is_empty else float(outside_input.area)
        maximum_boundary_outside_area = 0.0
        maximum_boundary_outside_id = ""
        maximum_boundary_outside_ratio = 0.0
        minimum_boundary_retained_ratio = 1.0
        minimum_boundary_retained_id = ""
        for local_index, value in enumerate(final_country):
            source_geometry = geometries[indexes[local_index]]
            outside_area = float(value.difference(source_geometry).area)
            if outside_area > maximum_boundary_outside_area:
                maximum_boundary_outside_area = outside_area
                maximum_boundary_outside_id = local_ids[local_index]
            outside_ratio = outside_area / float(source_geometry.area)
            maximum_boundary_outside_ratio = max(
                maximum_boundary_outside_ratio,
                outside_ratio,
            )
            retained_ratio = float(value.intersection(source_geometry).area) / float(
                source_geometry.area
            )
            if retained_ratio < minimum_boundary_retained_ratio:
                minimum_boundary_retained_ratio = retained_ratio
                minimum_boundary_retained_id = local_ids[local_index]
        if maximum_boundary_outside_ratio > MAXIMUM_BOUNDARY_OUTSIDE_SOURCE_AREA_RATIO:
            raise RuntimeError(
                f"{catalog_kind} {country_code} reassigned area outside a boundary's "
                f"source footprint: {maximum_boundary_outside_area:.15g} square degrees "
                f"for {maximum_boundary_outside_id} "
                f"({maximum_boundary_outside_ratio:.6%} of its source)"
            )
        if minimum_boundary_retained_ratio < MINIMUM_BOUNDARY_RETAINED_SOURCE_AREA_RATIO:
            raise RuntimeError(
                f"{catalog_kind} {country_code} retained only "
                f"{minimum_boundary_retained_ratio:.6%} of source boundary "
                f"{minimum_boundary_retained_id}"
            )

        for index, geometry in zip(indexes, final_country):
            optimized_geometries[index] = geometry
        country_metadata[country_code] = {
            "boundaryCount": len(indexes),
            "inputVertices": sum(geometry_vertex_count(geometries[index]) for index in indexes),
            "outputVertices": sum(geometry_vertex_count(value) for value in final_country),
            "inputHoles": sum(geometry_hole_count(geometries[index]) for index in indexes),
            "outputHoles": sum(geometry_hole_count(value) for value in final_country),
            "overlapRepair": overlap_repair,
            "postPrecisionOverlapRepair": post_precision_repair,
            "pairwiseOverlap": overlap_metrics,
            "outsideInputFootprintAreaSquareDegrees": round(outside_input_area, 15),
            "maximumBoundaryOutsideSourceAreaSquareDegrees": round(
                maximum_boundary_outside_area,
                15,
            ),
            "maximumBoundaryOutsideSourceAreaBoundaryID": maximum_boundary_outside_id,
            "maximumBoundaryOutsideSourceAreaRatio": round(
                maximum_boundary_outside_ratio,
                12,
            ),
            "minimumBoundaryRetainedSourceAreaRatio": round(
                minimum_boundary_retained_ratio,
                12,
            ),
            "minimumBoundaryRetainedSourceAreaBoundaryID": minimum_boundary_retained_id,
            "coverageIsValid": bool(tools["coverage_is_valid"](final_country)),
            "postRepairDroppedComponents": sum(
                int(stats["droppedComponents"]) for stats in post_filter_stats
            ),
        }

    if any(geometry is None for geometry in optimized_geometries):
        raise AssertionError("A boundary was omitted from optimization")

    output_boundaries = [
        encode_boundary_geometry(
            boundary,
            geometry_value,
            serialization_decimals_by_country[str(boundary["countryCode"])],
            tools,
        )
        for boundary, geometry_value in zip(boundaries, optimized_geometries)
        if geometry_value is not None
    ]

    # Revalidate in ordinary floating precision, matching what MapKit receives.
    # Coordinate serialization can otherwise turn a fixed-precision shared edge
    # into a tiny positive-area sliver.  Subtract those slivers and re-encode;
    # this pass only shrinks the deterministic lower-precedence owner.
    serialized_overlap_cleanup_passes = 0
    for cleanup_pass in range(1, 5):
        serialized_geometries = [
            output_boundary_geometry(boundary, tools) for boundary in output_boundaries
        ]
        requires_cleanup = False
        cleaned_geometries = list(serialized_geometries)
        for country_code in sorted(country_indexes):
            indexes = country_indexes[country_code]
            country_geometries = [serialized_geometries[index] for index in indexes]
            local_ids = [boundary_ids[index] for index in indexes]
            metrics = pairwise_overlap_metrics(country_geometries, local_ids, tools)
            if metrics["maximumAreaSquareDegrees"] <= maximum_overlap_area_square_degrees:
                continue
            requires_cleanup = True
            repaired, _metadata = repair_country_overlaps(
                list(range(len(country_geometries))),
                country_geometries,
                local_ids,
                tools,
            )
            for index, geometry in zip(indexes, repaired):
                cleaned_geometries[index] = geometry
        if not requires_cleanup:
            break
        output_boundaries = [
            encode_boundary_geometry(
                boundary,
                geometry,
                serialization_decimals_by_country[str(boundary["countryCode"])],
                tools,
            )
            for boundary, geometry in zip(boundaries, cleaned_geometries)
        ]
        serialized_overlap_cleanup_passes = cleanup_pass

    # Validate the actual rounded schema-v2 payload rather than only the
    # higher-precision intermediate Shapely geometries.
    serialized_geometries = [
        output_boundary_geometry(boundary, tools) for boundary in output_boundaries
    ]
    serialized_country_metadata: dict[str, Any] = {}
    for country_code in sorted(country_indexes):
        indexes = country_indexes[country_code]
        country_geometries = [serialized_geometries[index] for index in indexes]
        overlap_metrics = pairwise_overlap_metrics(
            country_geometries,
            [boundary_ids[index] for index in indexes],
            tools,
        )
        if overlap_metrics["maximumAreaSquareDegrees"] > maximum_overlap_area_square_degrees:
            raise RuntimeError(
                f"Serialized {catalog_kind} {country_code} boundaries overlap: "
                f"{overlap_metrics}"
            )
        serialized_coverage_is_valid = bool(tools["coverage_is_valid"](country_geometries))
        input_country_vertices = sum(
            geometry_vertex_count(geometries[index]) for index in indexes
        )
        serialized_country_vertices = sum(
            geometry_vertex_count(value) for value in country_geometries
        )
        maximum_country_vertices = math.ceil(
            input_country_vertices * MAXIMUM_SERIALIZED_POLYGON_VERTEX_INCREASE_RATIO
        )
        if serialized_country_vertices > maximum_country_vertices:
            raise RuntimeError(
                f"Serialized {catalog_kind} {country_code} masks have "
                f"{serialized_country_vertices:,} vertices, exceeding the generated "
                f"{maximum_country_vertices:,}-vertex budget"
            )
        serialized_outside_values = [
            (
                float(geometry.difference(geometries[index]).area),
                float(geometry.difference(geometries[index]).area)
                / float(geometries[index].area),
                boundary_ids[index],
            )
            for index, geometry in zip(indexes, country_geometries)
        ]
        maximum_boundary_outside_area = max(value[0] for value in serialized_outside_values)
        maximum_boundary_outside_ratio_value = max(
            serialized_outside_values,
            key=lambda value: (value[1], value[2]),
        )
        maximum_boundary_outside_ratio = maximum_boundary_outside_ratio_value[1]
        maximum_boundary_outside_id = maximum_boundary_outside_ratio_value[2]
        serialized_retained_values = [
            (
                float(geometry.intersection(geometries[index]).area)
                / float(geometries[index].area),
                boundary_ids[index],
            )
            for index, geometry in zip(indexes, country_geometries)
        ]
        minimum_boundary_retained_ratio, minimum_boundary_retained_id = min(
            serialized_retained_values
        )
        if maximum_boundary_outside_ratio > MAXIMUM_BOUNDARY_OUTSIDE_SOURCE_AREA_RATIO:
            raise RuntimeError(
                f"Serialized {catalog_kind} {country_code} geometry extends outside an "
                f"individual source boundary for {maximum_boundary_outside_id} "
                f"({maximum_boundary_outside_ratio:.6%} of its source)"
            )
        if minimum_boundary_retained_ratio < MINIMUM_BOUNDARY_RETAINED_SOURCE_AREA_RATIO:
            raise RuntimeError(
                f"Serialized {catalog_kind} {country_code} retained only "
                f"{minimum_boundary_retained_ratio:.6%} of source boundary "
                f"{minimum_boundary_retained_id}"
            )
        serialized_country_metadata[country_code] = {
            "vertices": serialized_country_vertices,
            "maximumVertexBudget": maximum_country_vertices,
            "components": sum(len(geometry_polygons(value)) for value in country_geometries),
            "holes": sum(geometry_hole_count(value) for value in country_geometries),
            "coverageIsValid": serialized_coverage_is_valid,
            "maximumBoundaryOutsideSourceAreaSquareDegrees": round(
                maximum_boundary_outside_area,
                15,
            ),
            "maximumBoundaryOutsideSourceAreaRatio": round(
                maximum_boundary_outside_ratio,
                12,
            ),
            "maximumBoundaryOutsideSourceAreaBoundaryID": maximum_boundary_outside_id,
            "minimumBoundaryRetainedSourceAreaRatio": round(
                minimum_boundary_retained_ratio,
                12,
            ),
            "minimumBoundaryRetainedSourceAreaBoundaryID": minimum_boundary_retained_id,
            "pairwiseOverlap": overlap_metrics,
        }

    reference_line_batches, reference_line_metadata = build_reference_line_batches(
        catalog_kind=catalog_kind,
        serialized_geometries=serialized_geometries,
        country_indexes=country_indexes,
        quantization_decimals_by_country=serialization_decimals_by_country,
        tolerances_by_country=tolerances_by_country,
        tools=tools,
    )

    output["version"] = 2
    if generated_at is not None:
        output["generatedAt"] = generated_at
    output["boundaries"] = output_boundaries
    output["referenceLines"] = reference_line_batches
    generation = copy.deepcopy(output.get("generation") or {})
    if "sourceCounts" not in generation and "counts" in generation:
        generation["sourceCounts"] = copy.deepcopy(generation["counts"])
    emitted_country_counts = {
        country_code: len(indexes)
        for country_code, indexes in sorted(country_indexes.items())
    }
    generation["counts"] = {
        "boundaries": len(output_boundaries),
        **emitted_country_counts,
    }
    generation["quantizationDecimals"] = {
        country_code: serialization_decimals_by_country[country_code]
        for country_code in sorted(serialization_decimals_by_country)
    }
    generation["polygonRepresentation"] = (
        "schema v2 components; each component has one outer ring and an array of preserved holes"
    )
    generation["referenceLineRepresentation"] = reference_line_metadata["representation"]
    generation["boundaryOptimization"] = {
        "algorithmVersion": ALGORITHM_VERSION,
        "shapelyVersion": EXPECTED_SHAPELY_VERSION,
        "inputPayloadSHA256": input_payload_sha256,
        "mappingPayloadSHA256": source_mapping_hash,
        "catalogKind": catalog_kind,
        "overlapScope": "same country within this catalog; city and province levels remain separate",
        "overlapWinner": "smaller spherical-area boundary, then lexical boundary id",
        "serializedOverlapCleanupPasses": serialized_overlap_cleanup_passes,
        "simplification": (
            "polygon masks retain repaired source geometry; only the deduplicated "
            "reference-line display LOD is simplified"
        ),
        "inputFootprintContainment": (
            "output is clamped to the bundled input footprint; upstream Natural Earth land "
            "containment is not independently revalidated by this optimizer"
        ),
        "settings": {
            "referenceLineBaseToleranceDegreesByCountry": {
                country_code: tolerances_by_country[country_code]
                for country_code in sorted(country_indexes)
            },
            "minimumSecondaryComponentWidthKilometers": minimum_component_width_km,
            "minimumSecondaryComponentHeightKilometers": minimum_component_height_km,
            "maximumPairwiseOverlapAreaSquareDegrees": maximum_overlap_area_square_degrees,
            "maximumBoundaryOutsideSourceAreaRatio": (
                MAXIMUM_BOUNDARY_OUTSIDE_SOURCE_AREA_RATIO
            ),
            "maximumSerializedPolygonVertexIncreaseRatio": (
                MAXIMUM_SERIALIZED_POLYGON_VERTEX_INCREASE_RATIO
            ),
            "minimumBoundaryRetainedSourceAreaRatio": (
                MINIMUM_BOUNDARY_RETAINED_SOURCE_AREA_RATIO
            ),
        },
        "counts": {
            "boundaries": len(boundaries),
            "inputVertices": input_vertices,
            "serializedOutputVertices": sum(
                values["vertices"] for values in serialized_country_metadata.values()
            ),
            "inputHoles": input_holes,
            "serializedOutputHoles": sum(
                values["holes"] for values in serialized_country_metadata.values()
            ),
            "preOverlapDroppedSecondaryComponents": sum(
                int(stats["droppedComponents"]) for stats in filter_stats
            ),
            "preOverlapDroppedSecondaryVertices": sum(
                int(stats["droppedVertices"]) for stats in filter_stats
            ),
        },
        "boundaryPayloadSHA256": canonical_sha256(output_boundaries),
        "referenceLinePayloadSHA256": canonical_sha256(reference_line_batches),
        "referenceLines": reference_line_metadata,
        "countries": {
            country_code: {
                **country_metadata[country_code],
                "serialized": serialized_country_metadata[country_code],
            }
            for country_code in sorted(country_metadata)
        },
    }
    output["generation"] = generation

    if [boundary["id"] for boundary in output_boundaries] != boundary_ids:
        raise AssertionError("Boundary ids or ordering changed during optimization")
    output_mapping_hash = canonical_sha256(mapping_payload(output))
    if output_mapping_hash != source_mapping_hash:
        raise AssertionError("A top-level station/city mapping changed during optimization")

    return output, generation["boundaryOptimization"]


def optimize_catalog(
    catalog: dict[str, Any],
    kind: str,
    *,
    tolerance_degrees: float | dict[str, float] | None = None,
    minimum_secondary_component_width_km: float = 10.0,
    minimum_secondary_component_height_km: float = 10.0,
    maximum_overlap_area_square_degrees: float = DEFAULT_MAXIMUM_OVERLAP_AREA_SQUARE_DEGREES,
    generated_at: str | None = None,
) -> dict[str, Any]:
    """Optimize an in-memory city or province catalog and return a copy.

    This is the generator-facing entry point.  It has no dependency on either
    generator module; Shapely is loaded lazily when the function is called.
    """

    if kind not in DEFAULT_TOLERANCE_DEGREES:
        raise RuntimeError(f"Catalog kind must be 'city' or 'province', found {kind!r}")
    tolerances_by_country = dict(DEFAULT_TOLERANCE_DEGREES[kind])
    if isinstance(tolerance_degrees, dict):
        tolerances_by_country.update(
            {str(country_code): float(value) for country_code, value in tolerance_degrees.items()}
        )
    elif tolerance_degrees is not None:
        tolerances_by_country = {
            country_code: float(tolerance_degrees) for country_code in tolerances_by_country
        }
    for country_code, tolerance in tolerances_by_country.items():
        if not math.isfinite(tolerance) or tolerance <= 0.0:
            raise RuntimeError(
                f"tolerance_degrees[{country_code!r}] must be finite and positive"
            )
    for name, value, allow_zero in (
        ("minimum_secondary_component_width_km", minimum_secondary_component_width_km, True),
        ("minimum_secondary_component_height_km", minimum_secondary_component_height_km, True),
        ("maximum_overlap_area_square_degrees", maximum_overlap_area_square_degrees, True),
    ):
        if not math.isfinite(value) or value < 0.0 or (not allow_zero and value == 0.0):
            raise RuntimeError(f"{name} must be finite and {'nonnegative' if allow_zero else 'positive'}")

    existing = (catalog.get("generation") or {}).get("boundaryOptimization")
    if existing is not None:
        expected_settings = {
            "referenceLineBaseToleranceDegreesByCountry": {
                country_code: tolerances_by_country[country_code]
                for country_code in sorted(tolerances_by_country)
            },
            "minimumSecondaryComponentWidthKilometers": minimum_secondary_component_width_km,
            "minimumSecondaryComponentHeightKilometers": minimum_secondary_component_height_km,
            "maximumPairwiseOverlapAreaSquareDegrees": maximum_overlap_area_square_degrees,
            "maximumBoundaryOutsideSourceAreaRatio": (
                MAXIMUM_BOUNDARY_OUTSIDE_SOURCE_AREA_RATIO
            ),
            "maximumSerializedPolygonVertexIncreaseRatio": (
                MAXIMUM_SERIALIZED_POLYGON_VERTEX_INCREASE_RATIO
            ),
            "minimumBoundaryRetainedSourceAreaRatio": (
                MINIMUM_BOUNDARY_RETAINED_SOURCE_AREA_RATIO
            ),
        }
        if (
            existing.get("algorithmVersion") != ALGORITHM_VERSION
            or existing.get("catalogKind") != kind
            or existing.get("settings") != expected_settings
        ):
            raise RuntimeError(
                "Catalog is already generated with different boundary-optimization settings; "
                "regenerate it from the pinned upstream sources instead of applying another "
                "lossy optimization pass"
            )
        if catalog.get("version") != 2:
            raise RuntimeError("An optimized boundary catalog must use schema version 2")
        boundaries = catalog.get("boundaries") or []
        if not boundaries or any(
            not boundary.get("components") or "polygons" in boundary
            for boundary in boundaries
        ):
            raise RuntimeError("Optimized boundary catalog has invalid schema-v2 components")
        if canonical_sha256(mapping_payload(catalog)) != existing.get("mappingPayloadSHA256"):
            raise RuntimeError("Optimized boundary catalog lookup mappings changed")
        if canonical_sha256(boundaries) != existing.get("boundaryPayloadSHA256"):
            raise RuntimeError("Optimized boundary catalog geometry changed")
        batches = catalog.get("referenceLines") or []
        if canonical_sha256(batches) != existing.get("referenceLinePayloadSHA256"):
            raise RuntimeError("Optimized boundary catalog reference lines changed")
        actual_reference_counts = {
            "batches": len(batches),
            "paths": sum(len(batch.get("lines") or []) for batch in batches),
            "vertices": sum(
                len(line)
                for batch in batches
                for line in (batch.get("lines") or [])
            ),
        }
        expected_reference_counts = ((existing.get("referenceLines") or {}).get("counts"))
        if not batches or actual_reference_counts != expected_reference_counts:
            raise RuntimeError(
                "Optimized boundary catalog reference-line metadata does not match its payload"
            )
        result = copy.deepcopy(catalog)
        if generated_at is not None:
            result["generatedAt"] = generated_at
        return result

    result, _metadata = _optimize_catalog(
        catalog=catalog,
        catalog_kind=kind,
        tolerances_by_country=tolerances_by_country,
        minimum_component_width_km=minimum_secondary_component_width_km,
        minimum_component_height_km=minimum_secondary_component_height_km,
        maximum_overlap_area_square_degrees=maximum_overlap_area_square_degrees,
        generated_at=generated_at,
        tools=require_shapely(),
    )
    return result


def write_catalog(path: Path, catalog: dict[str, Any]) -> int:
    encoded = json.dumps(catalog, ensure_ascii=False, separators=(",", ":")).encode("utf-8") + b"\n"
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary_path = path.with_name(f".{path.name}.tmp")
    try:
        temporary_path.write_bytes(encoded)
        temporary_path.replace(path)
    finally:
        if temporary_path.exists():
            temporary_path.unlink()
    return len(encoded)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--city-input", type=Path, default=DEFAULT_CITY_CATALOG)
    parser.add_argument("--province-input", type=Path, default=DEFAULT_PROVINCE_CATALOG)
    parser.add_argument("--china-coverage", type=Path, default=DEFAULT_CHINA_COVERAGE)
    parser.add_argument("--city-output", type=Path, default=DEFAULT_CITY_CATALOG)
    parser.add_argument("--province-output", type=Path, default=DEFAULT_PROVINCE_CATALOG)
    parser.add_argument(
        "--city-tolerance-degrees",
        type=float,
        help=(
            "Override every country city tolerance; defaults are "
            "CN=0.02, JP=0.01, KR=0.009, MN=0.015"
        ),
    )
    parser.add_argument(
        "--province-tolerance-degrees",
        type=float,
        help=(
            "Override every country province tolerance; defaults are "
            "CN=0.025, JP=0.015, KR=0.012, MN=0.02"
        ),
    )
    parser.add_argument(
        "--minimum-secondary-component-width-km",
        type=float,
        default=10.0,
    )
    parser.add_argument(
        "--minimum-secondary-component-height-km",
        type=float,
        default=10.0,
    )
    parser.add_argument(
        "--maximum-overlap-area-square-degrees",
        type=float,
        default=DEFAULT_MAXIMUM_OVERLAP_AREA_SQUARE_DEGREES,
        help="Maximum accepted numerical overlap after serialized output validation",
    )
    parser.add_argument(
        "--generated-at",
        help="Optional top-level timestamp override for reproducible verification output",
    )
    return parser.parse_args()


def validate_args(args: argparse.Namespace) -> None:
    for label in ("city", "province"):
        tolerance = getattr(args, f"{label}_tolerance_degrees")
        if tolerance is not None and (not math.isfinite(tolerance) or tolerance <= 0.0):
            raise RuntimeError(f"{label} tolerance must be finite and positive")
    for name in (
        "minimum_secondary_component_width_km",
        "minimum_secondary_component_height_km",
        "maximum_overlap_area_square_degrees",
    ):
        value = getattr(args, name)
        if not math.isfinite(value) or value < 0.0:
            raise RuntimeError(f"{name.replace('_', ' ')} must be finite and nonnegative")
    for input_path in (args.city_input, args.province_input):
        if not input_path.is_file():
            raise RuntimeError(f"Input catalog does not exist: {input_path}")
    if not args.china_coverage.is_file():
        raise RuntimeError(f"China coverage catalog does not exist: {args.china_coverage}")


def main() -> None:
    args = parse_args()
    validate_args(args)
    tools = require_shapely()
    china_coverage = json.loads(args.china_coverage.read_text(encoding="utf-8"))
    if not isinstance(china_coverage, dict) or china_coverage.get("version") != 1:
        raise RuntimeError("Unsupported China transit coverage catalog")
    optimized_catalogs: dict[str, dict[str, Any]] = {}
    for catalog_kind, input_path, output_path, tolerance in (
        ("city", args.city_input, args.city_output, args.city_tolerance_degrees),
        (
            "province",
            args.province_input,
            args.province_output,
            args.province_tolerance_degrees,
        ),
    ):
        tolerances_by_country = dict(DEFAULT_TOLERANCE_DEGREES[catalog_kind])
        if tolerance is not None:
            tolerances_by_country = {
                country_code: tolerance for country_code in tolerances_by_country
            }
        source_catalog = load_json(input_path)
        if catalog_kind == "city":
            source_catalog = prune_city_catalog_to_supported_boundaries(
                source_catalog,
                china_coverage,
            )
        else:
            source_catalog = prune_province_catalog_to_supported_boundaries(
                source_catalog,
                optimized_catalogs["city"],
                china_coverage,
                tools=tools,
            )
        catalog = optimize_catalog(
            source_catalog,
            catalog_kind,
            tolerance_degrees=tolerances_by_country,
            minimum_secondary_component_width_km=(
                args.minimum_secondary_component_width_km
            ),
            minimum_secondary_component_height_km=(
                args.minimum_secondary_component_height_km
            ),
            maximum_overlap_area_square_degrees=(
                args.maximum_overlap_area_square_degrees
            ),
            generated_at=args.generated_at,
        )
        metadata = catalog["generation"]["boundaryOptimization"]
        optimized_catalogs[catalog_kind] = catalog
        byte_count = write_catalog(output_path, catalog)
        counts = metadata["counts"]
        print(
            f"Wrote {output_path} ({byte_count:,} bytes; {counts['boundaries']:,} boundaries; "
            f"{counts['inputVertices']:,} -> {counts['serializedOutputVertices']:,} vertices)"
        )


if __name__ == "__main__":
    main()
