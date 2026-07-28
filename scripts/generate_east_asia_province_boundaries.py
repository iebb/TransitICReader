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
import urllib.request
from collections import Counter
from pathlib import Path
from typing import Any

from generate_east_asia_city_boundaries import (
    GEBOUNDARIES_COMMIT,
    GEBOUNDARIES_COMMIT_DATE,
    GEBOUNDARIES_MEDIA_ROOT,
    USER_AGENT,
    geometry_parts,
    make_boundary,
    sha256_file,
    utc_now,
)


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT = REPO_ROOT / "CardBal/Resources/EastAsiaProvinceBoundaries.json"
RDP_TOLERANCE_DEGREES = 0.005
MAX_OUTPUT_BYTES = 800 * 1024

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


def download_asset(asset_key: str, destination: Path) -> dict[str, Any]:
    asset = ASSETS[asset_key]
    url = f"{GEBOUNDARIES_MEDIA_ROOT}/{asset['relativePath']}"
    request = urllib.request.Request(
        url,
        headers={"User-Agent": USER_AGENT, "Accept": "application/geo+json"},
    )
    with urllib.request.urlopen(request, timeout=180) as response, destination.open("wb") as output:
        while chunk := response.read(1024 * 1024):
            output.write(chunk)

    actual_hash = sha256_file(destination)
    if actual_hash != asset["sha256"]:
        raise RuntimeError(
            f"geoBoundaries checksum mismatch for {asset_key}: "
            f"expected {asset['sha256']}, got {actual_hash}"
        )

    payload = json.loads(destination.read_text(encoding="utf-8"))
    features = payload.get("features")
    if payload.get("type") != "FeatureCollection" or not isinstance(features, list):
        raise RuntimeError(f"Unexpected geoBoundaries payload for {asset_key}")
    if len(features) != asset["sourceFeatureCount"]:
        raise RuntimeError(
            f"Unexpected {asset_key} feature count: "
            f"expected {asset['sourceFeatureCount']}, got {len(features)}"
        )
    return payload


def build_catalog() -> dict[str, Any]:
    boundaries: list[dict[str, Any]] = []
    with tempfile.TemporaryDirectory(prefix="cardbal-east-asia-provinces-") as directory:
        temporary_path = Path(directory)
        for asset_key, asset in ASSETS.items():
            country_code = str(asset["countryCode"])
            payload = download_asset(asset_key, temporary_path / f"{asset_key}.geojson")
            for feature in payload["features"]:
                properties = feature.get("properties") or {}
                source_name = str(properties.get("shapeName") or "").strip()
                if (country_code, source_name) in EXCLUDED_NAMES:
                    continue
                shape_id = str(properties.get("shapeID") or "").strip()
                if not source_name or not shape_id:
                    raise RuntimeError(f"{asset_key} contains an unnamed or unidentified ADM1 feature")
                display_name = NAME_OVERRIDES.get((country_code, source_name), source_name)
                boundary = make_boundary(
                    boundary_id=f"{country_code.lower()}:adm1:{shape_id}",
                    country_code=country_code,
                    name=display_name,
                    native_name=display_name,
                    parts=geometry_parts(feature["geometry"]),
                    tolerance=RDP_TOLERANCE_DEGREES,
                )
                subdivision_code = str(properties.get("shapeISO") or "").strip()
                if subdivision_code and subdivision_code not in {"CHN", "JPN", "KOR"}:
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

    return {
        "version": 1,
        "generatedAt": utc_now(),
        "attribution": ["geoBoundaries (www.geoboundaries.org)"],
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
            }
        },
        "generation": {
            "coordinateOrder": "longitude,latitude",
            "polygonRepresentation": "outer rings only; holes omitted",
            "rdpToleranceDegrees": RDP_TOLERANCE_DEGREES,
            "excluded": [{"countryCode": "CN", "name": "Taiwan Province"}],
            "nameOverrides": [
                {"countryCode": country_code, "source": source_name, "display": display_name}
                for (country_code, source_name), display_name in sorted(NAME_OVERRIDES.items())
            ],
            "counts": dict(sorted(counts.items())),
        },
        "boundaries": boundaries,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    catalog = build_catalog()
    encoded = json.dumps(catalog, ensure_ascii=False, separators=(",", ":")).encode("utf-8") + b"\n"
    if len(encoded) > MAX_OUTPUT_BYTES:
        raise RuntimeError(
            f"Generated catalog is {len(encoded):,} bytes, exceeding the {MAX_OUTPUT_BYTES:,}-byte target"
        )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(encoded)
    print(
        f"Wrote {args.output} ({len(encoded):,} bytes; "
        + ", ".join(f"{country} {count}" for country, count in catalog["generation"]["counts"].items())
        + ")"
    )


if __name__ == "__main__":
    main()
