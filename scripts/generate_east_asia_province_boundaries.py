#!/usr/bin/env python3
"""Build CardBal's compact, offline East Asia province-boundary catalog.

Province geometry is kept separate from the city catalog so it can remain a
quiet cartographic layer beneath visited-city highlights. Taiwan is excluded:
CardBal has no supported Taiwanese transit-card path, so drawing it as part of
the China overlay would imply coverage the app does not provide.
"""

from __future__ import annotations

import argparse
import json
import tempfile
from collections import Counter
from pathlib import Path
from typing import Any

from generate_east_asia_city_boundaries import (
    CHINA_COORDINATE_DECIMALS,
    COORDINATE_DECIMALS,
    GEBOUNDARIES_COMMIT,
    GEBOUNDARIES_COMMIT_DATE,
    GEBOUNDARIES_MEDIA_ROOT,
    NATURAL_EARTH_COMMIT,
    NATURAL_EARTH_LAND_PATH,
    NATURAL_EARTH_LAND_SHA256,
    OUTPUT_QUANTIZATION_CONTAINMENT_BUFFER_DEGREES,
    approximate_geometry_area_square_kilometers,
    boundary_shapely_geometry,
    download_verified_json,
    geometry_parts,
    load_natural_earth_land,
    make_boundary,
    polygonal_shapely_geometry,
    utc_now,
)


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT = REPO_ROOT / "CardBal/Resources/EastAsiaProvinceBoundaries.json"
DEFAULT_CITY_CATALOG = REPO_ROOT / "CardBal/Resources/EastAsiaCityBoundaries.json"
DEFAULT_CHINA_COVERAGE = REPO_ROOT / "CardBal/Resources/ChinaTransitCoverage.json"
RDP_TOLERANCE_DEGREES = 0.005
MAX_OUTPUT_BYTES = 1_200 * 1024

ASSETS: dict[str, dict[str, Any]] = {
    "CHN_ADM1": {
        "countryCode": "CN",
        "relativePath": "CHN/ADM1/geoBoundaries-CHN-ADM1_simplified.geojson",
        "sha256": "bc4afc7eacf4351ae5b3ae7a612327987ce1123cb5deb8574fb49107091c6623",
        "sourceFeatureCount": 34,
        "license": "Public Domain",
    },
    "JPN_ADM1": {
        "countryCode": "JP",
        "relativePath": "JPN/ADM1/geoBoundaries-JPN-ADM1_simplified.geojson",
        "sha256": "f18eeeb978d992a7147f636642932913731c231f298cb514bf7a3bd41a1aacc0",
        "sourceFeatureCount": 47,
        "license": "Open Data Commons Open Database License 1.0",
    },
    "KOR_ADM1": {
        "countryCode": "KR",
        "relativePath": "KOR/ADM1/geoBoundaries-KOR-ADM1_simplified.geojson",
        "sha256": "7d774c8bb1ee65dde693431985423616fd059ffbe1c1bb497b5fed4f47bcac01",
        "sourceFeatureCount": 17,
        "license": "Public Domain",
    },
}

EXCLUDED_NAMES = {("CN", "Taiwan Province")}
NAME_OVERRIDES = {
    ("CN", "Guangzhou Province"): "Guangdong Province",
    ("CN", "Ningxia Ningxia Hui Autonomous Region"): "Ningxia Hui Autonomous Region",
}
EXPECTED_OUTPUT_COUNTS = {"CN": 33, "JP": 47, "KR": 17}
CHINA_COASTAL_VALIDATION_PROVINCES = frozenset(
    {
        "Fujian Province",
        "Guangdong Province",
        "Guangxi Zhuang Autonomous Region",
        "Hainan Province",
        "Hebei Province",
        "Hong Kong Special Administrative Region",
        "Jiangsu Province",
        "Liaoning Province",
        "Macau Special Administrative Region",
        "Shandong Province",
        "Shanghai Municipality",
        "Tianjin Municipality",
        "Zhejiang Province",
    }
)


def download_asset(asset_key: str, destination: Path) -> dict[str, Any]:
    asset = ASSETS[asset_key]
    url = f"{GEBOUNDARIES_MEDIA_ROOT}/{asset['relativePath']}"
    payload = download_verified_json(
        url,
        destination,
        asset["sha256"],
        f"geoBoundaries {asset_key}",
    )
    features = payload.get("features")
    if payload.get("type") != "FeatureCollection" or not isinstance(features, list):
        raise RuntimeError(f"Unexpected geoBoundaries payload for {asset_key}")
    if len(features) != asset["sourceFeatureCount"]:
        raise RuntimeError(
            f"Unexpected {asset_key} feature count: "
            f"expected {asset['sourceFeatureCount']}, got {len(features)}"
        )
    return payload


def build_china_province_boundary(
    *,
    feature: dict[str, Any],
    boundary_id: str,
    display_name: str,
    subdivision_code: str,
    land: Any,
    marine_containment_mask: Any,
    buffered_marine_containment_mask: Any,
    shape: Any,
    mapping: Any,
    make_valid: Any,
    unary_union: Any,
) -> tuple[dict[str, Any], dict[str, float]]:
    raw_geometry = polygonal_shapely_geometry(
        shape(feature["geometry"]),
        make_valid,
        unary_union,
    )
    clipped_geometry = polygonal_shapely_geometry(
        raw_geometry.intersection(land),
        make_valid,
        unary_union,
    )
    if raw_geometry.is_empty or clipped_geometry.is_empty:
        raise RuntimeError(f"China province {display_name} has no land geometry")

    raw_area = float(raw_geometry.area)
    clipped_area = float(clipped_geometry.area)
    if clipped_area > raw_area + max(1e-12, raw_area * 1e-9):
        raise RuntimeError(f"Land clipping enlarged China province {display_name}")
    pre_simplification_outside_land_area = float(clipped_geometry.difference(land).area)
    if pre_simplification_outside_land_area > max(1e-12, clipped_area * 1e-9):
        raise RuntimeError(
            f"China province {display_name} retains geometry outside Natural Earth land"
        )

    simplified_boundary = make_boundary(
        boundary_id=boundary_id,
        country_code="CN",
        name=display_name,
        native_name=display_name,
        parts=geometry_parts(mapping(clipped_geometry)),
        tolerance=RDP_TOLERANCE_DEGREES,
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

    # RDP can bridge a concave coast with a short chord over water. Intersect a
    # second time, then quantize without another simplification pass so Province
    # fills cannot recreate that chord in the bundled component geometry.
    output_geometry = polygonal_shapely_geometry(
        simplified_geometry.intersection(land),
        make_valid,
        unary_union,
    )
    boundary = make_boundary(
        boundary_id=boundary_id,
        country_code="CN",
        name=display_name,
        native_name=display_name,
        parts=geometry_parts(mapping(output_geometry)),
        tolerance=0.0,
        coordinate_decimals=CHINA_COORDINATE_DECIMALS,
    )
    if subdivision_code:
        boundary["subdivisionCode"] = subdivision_code

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
            f"China province {display_name} extends materially beyond the "
            f"{OUTPUT_QUANTIZATION_CONTAINMENT_BUFFER_DEGREES:.6f}-degree land envelope"
        )

    rdp_marine_overshoot_square_kilometers = (
        0.0
        if rdp_marine_overshoot.is_empty
        else approximate_geometry_area_square_kilometers(rdp_marine_overshoot)
    )
    return boundary, {
        "rawAreaSquareDegrees": round(raw_area, 6),
        "landAreaSquareDegrees": round(clipped_area, 6),
        "removedPercent": round((raw_area - clipped_area) / raw_area * 100.0, 3),
        "preSimplificationOutsideLandAreaSquareDegrees": round(
            pre_simplification_outside_land_area,
            12,
        ),
        "rdpMarineOvershootBeforeFinalClipSquareKilometers": round(
            rdp_marine_overshoot_square_kilometers,
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


def build_catalog(args: argparse.Namespace) -> dict[str, Any]:
    generated_at = args.generated_at or utc_now()
    boundaries: list[dict[str, Any]] = []
    china_validation: dict[str, dict[str, float]] = {}
    with tempfile.TemporaryDirectory(prefix="cardbal-east-asia-provinces-") as directory:
        temporary_path = Path(directory)
        source_cache_directory = args.source_cache_directory or temporary_path / "source-cache"
        source_cache_directory.mkdir(parents=True, exist_ok=True)
        (
            land,
            marine_containment_mask,
            shape,
            mapping,
            make_valid,
            unary_union,
        ) = load_natural_earth_land(
            source_cache_directory / "natural-earth" / "ne_10m_land.geojson"
        )
        buffered_marine_containment_mask = marine_containment_mask.buffer(
            OUTPUT_QUANTIZATION_CONTAINMENT_BUFFER_DEGREES
        )
        for asset_key, asset in ASSETS.items():
            country_code = str(asset["countryCode"])
            payload = download_asset(
                asset_key,
                source_cache_directory / "geoboundaries" / f"{asset_key}.geojson",
            )
            for feature in payload["features"]:
                properties = feature.get("properties") or {}
                source_name = str(properties.get("shapeName") or "").strip()
                if (country_code, source_name) in EXCLUDED_NAMES:
                    continue
                shape_id = str(properties.get("shapeID") or "").strip()
                if not source_name or not shape_id:
                    raise RuntimeError(f"{asset_key} contains an unnamed or unidentified ADM1 feature")
                display_name = NAME_OVERRIDES.get((country_code, source_name), source_name)
                subdivision_code = str(properties.get("shapeISO") or "").strip()
                if subdivision_code in {"CHN", "JPN", "KOR"}:
                    subdivision_code = ""
                boundary_id = f"{country_code.lower()}:adm1:{shape_id}"
                if country_code == "CN":
                    boundary, metrics = build_china_province_boundary(
                        feature=feature,
                        boundary_id=boundary_id,
                        display_name=display_name,
                        subdivision_code=subdivision_code,
                        land=land,
                        marine_containment_mask=marine_containment_mask,
                        buffered_marine_containment_mask=buffered_marine_containment_mask,
                        shape=shape,
                        mapping=mapping,
                        make_valid=make_valid,
                        unary_union=unary_union,
                    )
                    china_validation[display_name] = metrics
                else:
                    boundary = make_boundary(
                        boundary_id=boundary_id,
                        country_code=country_code,
                        name=display_name,
                        native_name=display_name,
                        parts=geometry_parts(feature["geometry"]),
                        tolerance=RDP_TOLERANCE_DEGREES,
                    )
                if subdivision_code and country_code != "CN":
                    boundary["subdivisionCode"] = subdivision_code
                boundaries.append(boundary)

    boundaries.sort(key=lambda boundary: (boundary["countryCode"], boundary["name"], boundary["id"]))
    counts = Counter(boundary["countryCode"] for boundary in boundaries)
    if dict(sorted(counts.items())) != EXPECTED_OUTPUT_COUNTS:
        raise RuntimeError(
            f"Province count mismatch: expected {EXPECTED_OUTPUT_COUNTS}, got {dict(sorted(counts.items()))}"
        )
    if any(
        boundary["countryCode"] == "CN" and "taiwan" in boundary["name"].casefold()
        for boundary in boundaries
    ):
        raise RuntimeError("Taiwan must not be emitted in CardBal's province overlay")
    if set(china_validation) != {
        boundary["name"] for boundary in boundaries if boundary["countryCode"] == "CN"
    }:
        raise RuntimeError("China province land-validation set is incomplete")
    missing_coastal_validation = CHINA_COASTAL_VALIDATION_PROVINCES - set(china_validation)
    if missing_coastal_validation:
        raise RuntimeError(
            f"China coastal validation provinces are missing: {sorted(missing_coastal_validation)}"
        )
    if any(
        metrics["outsideQuantizationEnvelopeSquareKilometers"] != 0.0
        for metrics in china_validation.values()
    ):
        raise RuntimeError("A China province exceeds the post-quantization land envelope")

    catalog = {
        "version": 2,
        "generatedAt": generated_at,
        "attribution": [
            "geoBoundaries (www.geoboundaries.org)",
            "Made with Natural Earth. Free vector and raster map data @ naturalearthdata.com.",
        ],
        "sources": {
            "geoBoundaries": {
                "repository": "https://github.com/wmgeolab/geoBoundaries",
                "commit": GEBOUNDARIES_COMMIT,
                "commitDate": GEBOUNDARIES_COMMIT_DATE,
                "projectLicense": "CC BY 4.0",
                "assets": {
                    asset_key: {
                        "path": asset["relativePath"],
                        "sha256": asset["sha256"],
                        "underlyingLicense": asset["license"],
                    }
                    for asset_key, asset in ASSETS.items()
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
        },
        "generation": {
            "coordinateOrder": "longitude,latitude",
            "polygonRepresentation": "polygon components with one outer ring and zero or more interior hole rings",
            "rdpToleranceDegrees": RDP_TOLERANCE_DEGREES,
            "quantizationDecimals": {
                "CN": CHINA_COORDINATE_DECIMALS,
                "JP": COORDINATE_DECIMALS,
                "KR": COORDINATE_DECIMALS,
            },
            "chinaProvinceLandClip": {
                "order": "geoBoundaries ADM1 intersected with pinned Natural Earth land before local RDP, then intersected again after RDP before final quantization",
                "postQuantizationContainmentBufferDegrees": OUTPUT_QUANTIZATION_CONTAINMENT_BUFFER_DEGREES,
                "maximumPostQuantizationMarineResidualSquareKilometers": max(
                    metrics["postQuantizationMarineResidualSquareKilometers"]
                    for metrics in china_validation.values()
                ),
                "maximumOutsideQuantizationEnvelopeSquareKilometers": max(
                    metrics["outsideQuantizationEnvelopeSquareKilometers"]
                    for metrics in china_validation.values()
                ),
                "coastalValidation": {
                    name: china_validation[name]
                    for name in sorted(CHINA_COASTAL_VALIDATION_PROVINCES)
                },
            },
            "excluded": [{"countryCode": "CN", "name": "Taiwan Province"}],
            "nameOverrides": [
                {"countryCode": country_code, "source": source_name, "display": display_name}
                for (country_code, source_name), display_name in sorted(NAME_OVERRIDES.items())
            ],
            "counts": dict(sorted(counts.items())),
        },
        "boundaries": boundaries,
    }
    from optimize_east_asia_boundary_catalogs import (
        load_json,
        optimize_catalog,
        prune_city_catalog_to_supported_boundaries,
        prune_province_catalog_to_supported_boundaries,
    )

    china_coverage = json.loads(args.china_coverage.read_text(encoding="utf-8"))
    if china_coverage.get("version") != 1:
        raise RuntimeError(
            f"Unsupported China transit coverage version {china_coverage.get('version')!r}"
        )
    city_catalog = prune_city_catalog_to_supported_boundaries(
        load_json(args.city_catalog),
        china_coverage,
    )
    catalog = prune_province_catalog_to_supported_boundaries(
        catalog,
        city_catalog,
        china_coverage,
    )
    return optimize_catalog(catalog, "province", generated_at=generated_at)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--city-catalog", type=Path, default=DEFAULT_CITY_CATALOG)
    parser.add_argument("--china-coverage", type=Path, default=DEFAULT_CHINA_COVERAGE)
    parser.add_argument(
        "--source-cache-directory",
        type=Path,
        help="Optional verified source cache; useful for deterministic repeat builds",
    )
    parser.add_argument(
        "--generated-at",
        help="Override the catalog timestamp for a byte-for-byte deterministic verification build",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    for input_path in (args.city_catalog, args.china_coverage):
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
    country_metadata = catalog["generation"]["boundaryOptimization"]["countries"]
    print(
        f"Wrote {args.output} ({len(encoded):,} bytes; "
        + ", ".join(
            f"{country} {country_metadata[country]['boundaryCount']}"
            for country in sorted(country_metadata)
        )
        + ")"
    )


if __name__ == "__main__":
    main()
