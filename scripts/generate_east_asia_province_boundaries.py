#!/usr/bin/env python3
"""Build CardBal's compact, offline East Asia province-boundary catalog.

Province geometry is kept separate from the city catalog so it can remain a
quiet cartographic layer beneath visited-city highlights. Taiwan is excluded:
CardBal has no supported Taiwanese transit-card path, so drawing it as part of
the China overlay would imply coverage the app does not provide. Mongolia is
likewise pruned to ADM1 regions containing stations in the bundled bus snapshot.
"""

from __future__ import annotations

import argparse
import json
import sqlite3
import tempfile
from collections import Counter
from contextlib import closing
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
    bbox_contains,
    download_verified_json,
    geometry_parts,
    load_natural_earth_land,
    make_boundary,
    parts_area,
    parts_bbox,
    point_in_parts,
    polygonal_shapely_geometry,
    utc_now,
)


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT = REPO_ROOT / "CardBal/Resources/EastAsiaProvinceBoundaries.json"
DEFAULT_CITY_CATALOG = REPO_ROOT / "CardBal/Resources/EastAsiaCityBoundaries.json"
DEFAULT_CHINA_COVERAGE = REPO_ROOT / "CardBal/Resources/ChinaTransitCoverage.json"
DEFAULT_MONGOLIA_DATABASE = REPO_ROOT / "CardBal/Resources/ulaanbaatar_transit.sqlite"
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
    "MNG_ADM1": {
        "countryCode": "MN",
        "relativePath": "MNG/ADM1/geoBoundaries-MNG-ADM1_simplified.geojson",
        "sha256": "4e692ea5cff967b716e59975768d1560ade8c9844fbe6831bd4d9e6a7123f7aa",
        "sourceFeatureCount": 22,
        "license": "Open Data Commons Open Database License 1.0",
    },
}

EXCLUDED_NAMES = {("CN", "Taiwan Province")}
CHINA_NAME_OVERRIDES = {
    ("CN", "Guangzhou Province"): "Guangdong Province",
    ("CN", "Ningxia Ningxia Hui Autonomous Region"): "Ningxia Hui Autonomous Region",
}
CHINA_NATIVE_NAMES = {
    "Anhui Province": "安徽省",
    "Beijing Municipality": "北京市",
    "Chongqing Municipality": "重庆市",
    "Fujian Province": "福建省",
    "Gansu Province": "甘肃省",
    "Guangdong Province": "广东省",
    "Guangxi Zhuang Autonomous Region": "广西壮族自治区",
    "Guizhou Province": "贵州省",
    "Hainan Province": "海南省",
    "Hebei Province": "河北省",
    "Heilongjiang Province": "黑龙江省",
    "Henan Province": "河南省",
    "Hong Kong Special Administrative Region": "香港特別行政區",
    "Hubei Province": "湖北省",
    "Hunan Province": "湖南省",
    "Inner Mongolia Autonomous Region": "内蒙古自治区",
    "Jiangsu Province": "江苏省",
    "Jiangxi Province": "江西省",
    "Jilin Province": "吉林省",
    "Liaoning Province": "辽宁省",
    "Macau Special Administrative Region": "澳門特別行政區",
    "Ningxia Hui Autonomous Region": "宁夏回族自治区",
    "Qinghai Province": "青海省",
    "Shaanxi Province": "陕西省",
    "Shandong Province": "山东省",
    "Shanghai Municipality": "上海市",
    "Shanxi Province": "山西省",
    "Sichuan Province": "四川省",
    "Tianjin Municipality": "天津市",
    "Tibet Autonomous Region": "西藏自治区",
    "Xinjiang Uyghur Autonomous Region": "新疆维吾尔自治区",
    "Yunnan Province": "云南省",
    "Zhejiang Province": "浙江省",
}
CHINA_CONCISE_NAMES = {
    formal_name: formal_name.removesuffix(" Province")
    .removesuffix(" Municipality")
    .removesuffix(" Special Administrative Region")
    .removesuffix(" Zhuang Autonomous Region")
    .removesuffix(" Hui Autonomous Region")
    .removesuffix(" Uyghur Autonomous Region")
    .removesuffix(" Autonomous Region")
    for formal_name in CHINA_NATIVE_NAMES
}

# English province labels are deliberately concise: the database table and UI
# already establish that these are province-level regions. Native labels retain
# Japan's actual administrative suffix (都, 道, 府, or 県).
JAPAN_NAMES_BY_SUBDIVISION_CODE = {
    "JP-01": ("Hokkaido", "北海道"),
    "JP-02": ("Aomori", "青森県"),
    "JP-03": ("Iwate", "岩手県"),
    "JP-04": ("Miyagi", "宮城県"),
    "JP-05": ("Akita", "秋田県"),
    "JP-06": ("Yamagata", "山形県"),
    "JP-07": ("Fukushima", "福島県"),
    "JP-08": ("Ibaraki", "茨城県"),
    "JP-09": ("Tochigi", "栃木県"),
    "JP-10": ("Gunma", "群馬県"),
    "JP-11": ("Saitama", "埼玉県"),
    "JP-12": ("Chiba", "千葉県"),
    "JP-13": ("Tokyo", "東京都"),
    "JP-14": ("Kanagawa", "神奈川県"),
    "JP-15": ("Niigata", "新潟県"),
    "JP-16": ("Toyama", "富山県"),
    "JP-17": ("Ishikawa", "石川県"),
    "JP-18": ("Fukui", "福井県"),
    "JP-19": ("Yamanashi", "山梨県"),
    "JP-20": ("Nagano", "長野県"),
    "JP-21": ("Gifu", "岐阜県"),
    "JP-22": ("Shizuoka", "静岡県"),
    "JP-23": ("Aichi", "愛知県"),
    "JP-24": ("Mie", "三重県"),
    "JP-25": ("Shiga", "滋賀県"),
    "JP-26": ("Kyoto", "京都府"),
    "JP-27": ("Osaka", "大阪府"),
    "JP-28": ("Hyogo", "兵庫県"),
    "JP-29": ("Nara", "奈良県"),
    "JP-30": ("Wakayama", "和歌山県"),
    "JP-31": ("Tottori", "鳥取県"),
    "JP-32": ("Shimane", "島根県"),
    "JP-33": ("Okayama", "岡山県"),
    "JP-34": ("Hiroshima", "広島県"),
    "JP-35": ("Yamaguchi", "山口県"),
    "JP-36": ("Tokushima", "徳島県"),
    "JP-37": ("Kagawa", "香川県"),
    "JP-38": ("Ehime", "愛媛県"),
    "JP-39": ("Kochi", "高知県"),
    "JP-40": ("Fukuoka", "福岡県"),
    "JP-41": ("Saga", "佐賀県"),
    "JP-42": ("Nagasaki", "長崎県"),
    "JP-43": ("Kumamoto", "熊本県"),
    "JP-44": ("Oita", "大分県"),
    "JP-45": ("Miyazaki", "宮崎県"),
    "JP-46": ("Kagoshima", "鹿児島県"),
    "JP-47": ("Okinawa", "沖縄県"),
}

KOREA_NAMES_BY_SUBDIVISION_CODE = {
    "KR-11": ("Seoul", "서울특별시"),
    "KR-26": ("Busan", "부산광역시"),
    "KR-27": ("Daegu", "대구광역시"),
    "KR-28": ("Incheon", "인천광역시"),
    "KR-29": ("Gwangju", "광주광역시"),
    "KR-30": ("Daejeon", "대전광역시"),
    "KR-31": ("Ulsan", "울산광역시"),
    "KR-41": ("Gyeonggi", "경기도"),
    "KR-42": ("Gangwon", "강원특별자치도"),
    "KR-43": ("North Chungcheong", "충청북도"),
    "KR-44": ("South Chungcheong", "충청남도"),
    "KR-45": ("Jeonbuk", "전북특별자치도"),
    "KR-46": ("South Jeolla", "전라남도"),
    "KR-47": ("North Gyeongsang", "경상북도"),
    "KR-48": ("South Gyeongsang", "경상남도"),
    "KR-49": ("Jeju", "제주특별자치도"),
    "KR-50": ("Sejong", "세종특별자치시"),
}

MONGOLIA_NAMES_BY_SUBDIVISION_CODE = {
    "MN-035": ("Orkhon", "Орхон аймаг"),
    "MN-037": ("Darkhan-Uul", "Дархан-Уул аймаг"),
    "MN-039": ("Khentii", "Хэнтий аймаг"),
    "MN-041": ("Khövsgöl", "Хөвсгөл аймаг"),
    "MN-043": ("Khovd", "Ховд аймаг"),
    "MN-046": ("Uvs", "Увс аймаг"),
    "MN-047": ("Töv", "Төв аймаг"),
    "MN-049": ("Selenge", "Сэлэнгэ аймаг"),
    "MN-051": ("Sükhbaatar", "Сүхбаатар аймаг"),
    "MN-053": ("Ömnögovi", "Өмнөговь аймаг"),
    "MN-055": ("Övörkhangai", "Өвөрхангай аймаг"),
    "MN-057": ("Zavkhan", "Завхан аймаг"),
    "MN-059": ("Dundgovi", "Дундговь аймаг"),
    "MN-061": ("Dornod", "Дорнод аймаг"),
    "MN-063": ("Dornogovi", "Дорноговь аймаг"),
    "MN-064": ("Govisümber", "Говьсүмбэр аймаг"),
    "MN-065": ("Govi-Altai", "Говь-Алтай аймаг"),
    "MN-067": ("Bulgan", "Булган аймаг"),
    "MN-069": ("Bayankhongor", "Баянхонгор аймаг"),
    "MN-071": ("Bayan-Ölgii", "Баян-Өлгий аймаг"),
    "MN-073": ("Arkhangai", "Архангай аймаг"),
    "MN-1": ("Ulaanbaatar", "Улаанбаатар"),
}

JEONNAM_GWANGJU_SOURCE_CODES = frozenset({"KR-29", "KR-46"})
JEONNAM_GWANGJU_BOUNDARY_ID = "kr:province:jeonnam-gwangju"
JEONNAM_GWANGJU_NAME = "Jeonnam-Gwangju"
JEONNAM_GWANGJU_NATIVE_NAME = "전남광주통합특별시"
JEONNAM_GWANGJU_STATUTORY_ENGLISH_NAME = (
    "Jeonnam-Gwangju Special Metropolitan City"
)
EXPECTED_OUTPUT_COUNTS = {"CN": 33, "JP": 47, "KR": 16, "MN": 22}
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


def normalized_province_names(
    country_code: str,
    source_name: str,
    subdivision_code: str,
) -> tuple[str, str, str | None]:
    """Return concise English, local-script, and optional coverage-registry names."""

    if country_code == "CN":
        coverage_name = CHINA_NAME_OVERRIDES.get(
            (country_code, source_name),
            source_name,
        )
        try:
            return (
                CHINA_CONCISE_NAMES[coverage_name],
                CHINA_NATIVE_NAMES[coverage_name],
                coverage_name,
            )
        except KeyError as error:
            raise RuntimeError(
                f"China province {source_name!r} has no reviewed local name"
            ) from error

    mappings = {
        "JP": JAPAN_NAMES_BY_SUBDIVISION_CODE,
        "KR": KOREA_NAMES_BY_SUBDIVISION_CODE,
        "MN": MONGOLIA_NAMES_BY_SUBDIVISION_CODE,
    }
    try:
        name, native_name = mappings[country_code][subdivision_code]
    except KeyError as error:
        raise RuntimeError(
            f"{country_code} province {source_name!r} ({subdivision_code!r}) "
            "has no reviewed local name"
        ) from error
    return name, native_name, None


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
    native_name: str,
    coverage_name: str,
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
        native_name=native_name,
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
        native_name=native_name,
        parts=geometry_parts(mapping(output_geometry)),
        tolerance=0.0,
        coordinate_decimals=CHINA_COORDINATE_DECIMALS,
    )
    if subdivision_code:
        boundary["subdivisionCode"] = subdivision_code
    boundary["coverageName"] = coverage_name

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
    mongolia_spatial_features: list[dict[str, Any]] = []
    encountered_subdivision_codes: dict[str, set[str]] = {
        "JP": set(),
        "KR": set(),
        "MN": set(),
    }
    encountered_china_coverage_names: set[str] = set()
    jeonnam_gwangju_source_geometries: list[Any] = []
    jeonnam_gwangju_source_boundary_ids: list[str] = []
    jeonnam_gwangju_source_geometry: Any | None = None
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
                subdivision_code = str(properties.get("shapeISO") or "").strip()
                if subdivision_code in {"CHN", "JPN", "KOR"}:
                    subdivision_code = ""
                boundary_id = f"{country_code.lower()}:adm1:{shape_id}"
                display_name, native_name, coverage_name = normalized_province_names(
                    country_code,
                    source_name,
                    subdivision_code,
                )
                if country_code == "CN":
                    if coverage_name is None:
                        raise RuntimeError(f"China province {source_name!r} has no coverage name")
                    encountered_china_coverage_names.add(coverage_name)
                else:
                    encountered_subdivision_codes[country_code].add(subdivision_code)
                if (
                    country_code == "KR"
                    and subdivision_code in JEONNAM_GWANGJU_SOURCE_CODES
                ):
                    jeonnam_gwangju_source_geometries.append(shape(feature["geometry"]))
                    jeonnam_gwangju_source_boundary_ids.append(boundary_id)
                    continue
                if country_code == "CN":
                    boundary, metrics = build_china_province_boundary(
                        feature=feature,
                        boundary_id=boundary_id,
                        display_name=display_name,
                        native_name=native_name,
                        coverage_name=coverage_name,
                        subdivision_code=subdivision_code,
                        land=land,
                        marine_containment_mask=marine_containment_mask,
                        buffered_marine_containment_mask=buffered_marine_containment_mask,
                        shape=shape,
                        mapping=mapping,
                        make_valid=make_valid,
                        unary_union=unary_union,
                    )
                    china_validation[coverage_name] = metrics
                else:
                    parts = geometry_parts(feature["geometry"])
                    boundary = make_boundary(
                        boundary_id=boundary_id,
                        country_code=country_code,
                        name=display_name,
                        native_name=native_name,
                        parts=parts,
                        tolerance=RDP_TOLERANCE_DEGREES,
                    )
                    if country_code == "MN":
                        mongolia_spatial_features.append(
                            {
                                "id": boundary_id,
                                "name": display_name,
                                "parts": parts,
                                "bbox": parts_bbox(parts),
                                "area": parts_area(parts),
                            }
                        )
                if subdivision_code and country_code != "CN":
                    boundary["subdivisionCode"] = subdivision_code
                boundaries.append(boundary)

            if country_code == "KR":
                if len(jeonnam_gwangju_source_geometries) != len(
                    JEONNAM_GWANGJU_SOURCE_CODES
                ):
                    raise RuntimeError(
                        "Jeonnam-Gwangju merge did not resolve both predecessor boundaries"
                    )
                jeonnam_gwangju_source_geometry = polygonal_shapely_geometry(
                    unary_union(jeonnam_gwangju_source_geometries),
                    make_valid,
                    unary_union,
                )
                if jeonnam_gwangju_source_geometry.is_empty:
                    raise RuntimeError("Jeonnam-Gwangju dissolved geometry is empty")
                merged_boundary = make_boundary(
                    boundary_id=JEONNAM_GWANGJU_BOUNDARY_ID,
                    country_code="KR",
                    name=JEONNAM_GWANGJU_NAME,
                    native_name=JEONNAM_GWANGJU_NATIVE_NAME,
                    parts=geometry_parts(mapping(jeonnam_gwangju_source_geometry)),
                    tolerance=RDP_TOLERANCE_DEGREES,
                )
                # The two predecessor polygons share a boundary. Dissolving them
                # must remove that line rather than representing the new region as
                # two stacked province masks.
                merged_geometry = boundary_shapely_geometry(
                    merged_boundary,
                    shape,
                    make_valid,
                    unary_union,
                )
                for predecessor_geometry in jeonnam_gwangju_source_geometries:
                    if not merged_geometry.covers(predecessor_geometry.representative_point()):
                        raise RuntimeError(
                            "Jeonnam-Gwangju output does not cover a predecessor region"
                        )
                boundaries.append(merged_boundary)

    expected_subdivision_codes = {
        "JP": set(JAPAN_NAMES_BY_SUBDIVISION_CODE),
        "KR": set(KOREA_NAMES_BY_SUBDIVISION_CODE),
        "MN": set(MONGOLIA_NAMES_BY_SUBDIVISION_CODE),
    }
    if encountered_subdivision_codes != expected_subdivision_codes:
        raise RuntimeError(
            "Province local-name catalogs do not match pinned source subdivisions: "
            f"expected={expected_subdivision_codes}, actual={encountered_subdivision_codes}"
        )
    if encountered_china_coverage_names != set(CHINA_NATIVE_NAMES):
        raise RuntimeError(
            "China local-name catalog does not match pinned source provinces"
        )

    with closing(sqlite3.connect(args.mongolia_database)) as connection:
        mongolia_station_rows = connection.execute(
            """
            SELECT station_id, latitude, longitude
            FROM stations
            ORDER BY station_id
            """
        ).fetchall()
    if not mongolia_station_rows:
        raise RuntimeError("The Ulaanbaatar transit database contains no stations")
    mongolia_station_mapping: dict[str, str] = {}
    mongolia_station_counts: Counter[str] = Counter()
    for station_id, latitude, longitude in mongolia_station_rows:
        point = (float(longitude), float(latitude))
        matches = [
            feature
            for feature in mongolia_spatial_features
            if bbox_contains(feature["bbox"], point)
            and point_in_parts(point, feature["parts"])
        ]
        if len(matches) != 1:
            raise RuntimeError(
                f"Mongolia station {station_id} matched {len(matches)} ADM1 boundaries"
            )
        selected = min(matches, key=lambda feature: (feature["area"], feature["id"]))
        mongolia_station_mapping[str(station_id)] = str(selected["id"])
        mongolia_station_counts[str(selected["name"])] += 1
    if len(mongolia_station_mapping) != len(mongolia_station_rows):
        raise RuntimeError("Mongolia stations do not have unique station IDs")

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
        boundary["coverageName"]
        for boundary in boundaries
        if boundary["countryCode"] == "CN"
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
            "koreaAdministrativeReorganization": {
                "lawTitle": "전남광주통합특별시 설치를 위한 특별법",
                "actNumber": "21446",
                "enactedDate": "2026-03-05",
                "effectiveDate": "2026-07-01",
                "officialLawURL": (
                    "https://www.law.go.kr/LSW/lsInfoP.do?ancYnChk=&chrClsCd="
                    "010202&efYd=20260701&lsiSeq=284111&urlMode=lsInfoP"
                ),
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
                "MN": COORDINATE_DECIMALS,
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
            "nameNormalization": {
                "english": "concise base labels without redundant province-level suffixes",
                "native": "reviewed local-script administrative names",
                "chinaCoverageJoin": "coverageName retains the canonical T-Union registry province label",
            },
            "nameOverrides": [
                {"countryCode": country_code, "source": source_name, "display": display_name}
                for (country_code, source_name), display_name in sorted(
                    CHINA_NAME_OVERRIDES.items()
                )
            ],
            "administrativeChanges": [
                {
                    "kind": "provinceMerge",
                    "newBoundaryID": JEONNAM_GWANGJU_BOUNDARY_ID,
                    "name": JEONNAM_GWANGJU_NAME,
                    "nativeName": JEONNAM_GWANGJU_NATIVE_NAME,
                    "statutoryEnglishName": JEONNAM_GWANGJU_STATUTORY_ENGLISH_NAME,
                    "mergedFromSubdivisionCodes": sorted(
                        JEONNAM_GWANGJU_SOURCE_CODES
                    ),
                    "mergedFromBoundaryIDs": sorted(
                        jeonnam_gwangju_source_boundary_ids
                    ),
                    "effectiveDate": "2026-07-01",
                    "legalSourceURL": (
                        "https://www.law.go.kr/LSW/lsInfoP.do?ancYnChk=&chrClsCd="
                        "010202&efYd=20260701&lsiSeq=284111&urlMode=lsInfoP"
                    ),
                    "supportedCityIDs": [],
                    "supportedCityResolution": (
                        "majority polygon intersection with the dissolved KR-29/KR-46 "
                        "predecessor geometry"
                    ),
                }
            ],
            "counts": dict(sorted(counts.items())),
            "mongoliaStationSpatialJoin": {
                "source": "pinned MNG ADM1 polygons",
                "lookupKey": "decimal station_id from CardBal/Resources/ulaanbaatar_transit.sqlite",
                "inputStationCount": len(mongolia_station_rows),
                "mappedStationCount": len(mongolia_station_mapping),
                "stationCountsByProvince": dict(sorted(mongolia_station_counts.items())),
                "usedProvinceCount": len(mongolia_station_counts),
            },
        },
        "boundaries": boundaries,
        "mongoliaStationToBoundary": mongolia_station_mapping,
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
    if jeonnam_gwangju_source_geometry is None:
        raise RuntimeError("Jeonnam-Gwangju predecessor geometry was not retained")
    jeonnam_gwangju_supported_city_ids: list[str] = []
    for city_boundary in city_catalog.get("boundaries") or []:
        if city_boundary.get("countryCode") != "KR":
            continue
        city_geometry = boundary_shapely_geometry(
            city_boundary,
            shape,
            make_valid,
            unary_union,
        )
        if city_geometry.is_empty or float(city_geometry.area) <= 0.0:
            raise RuntimeError(
                f"Korean city {city_boundary.get('id')!r} has empty geometry"
            )
        intersection = city_geometry.intersection(jeonnam_gwangju_source_geometry)
        overlap_ratio = (
            0.0 if intersection.is_empty else float(intersection.area) / float(city_geometry.area)
        )
        if overlap_ratio > 0.5:
            jeonnam_gwangju_supported_city_ids.append(str(city_boundary["id"]))
    jeonnam_gwangju_supported_city_ids.sort()
    if not jeonnam_gwangju_supported_city_ids:
        raise RuntimeError(
            "No supported Korean cities resolved to the Jeonnam-Gwangju merge"
        )
    catalog["generation"]["administrativeChanges"][0][
        "supportedCityIDs"
    ] = jeonnam_gwangju_supported_city_ids
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
    parser.add_argument("--mongolia-database", type=Path, default=DEFAULT_MONGOLIA_DATABASE)
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
    for input_path in (args.city_catalog, args.china_coverage, args.mongolia_database):
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
