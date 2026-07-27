#!/usr/bin/env python3

"""Vendor a dated nationwide MOLIT settlement-operator bus-stop snapshot.

The official sample UI warns that more than five requests per minute may be
temporarily blocked, so selector requests are deliberately serialized.  Each
response is cached outside the repository and can be resumed safely.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import tempfile
import time
import urllib.parse
import urllib.request
from collections import defaultdict
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[1]
SITE_ROOT = REPO_ROOT / "cloudflare" / "korean-trip-visualizer"
DEFAULT_SEOUL = SITE_ROOT / "scripts/sources/molit_seoul_settlement_stops_20250801.json"
DEFAULT_OUTPUT = SITE_ROOT / "scripts/sources/molit_national_settlement_stops_20250801.json"
BASE = "https://tbo.stcis.go.kr/tsdw/open-api"
REFERER = f"{BASE}/api-search?gn=BusStop"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--snapshot-date", default="20250801")
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--merge-seoul", type=Path, default=DEFAULT_SEOUL)
    parser.add_argument(
        "--cache-dir",
        type=Path,
        default=Path(tempfile.gettempdir()) / "cardbal-molit-settlement-cache",
    )
    parser.add_argument("--interval", type=float, default=13.0)
    parser.add_argument("--sido", nargs="*", help="Optional province-code subset")
    return parser.parse_args()


def request_json(url: str, form: dict[str, str] | None = None) -> Any:
    data = urllib.parse.urlencode(form).encode() if form else None
    request = urllib.request.Request(
        url,
        data=data,
        headers={"User-Agent": "Mozilla/5.0 CardBal research", "Referer": REFERER},
    )
    with urllib.request.urlopen(request, timeout=45) as response:
        return json.load(response)


def atomic_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, ensure_ascii=False, separators=(",", ":"))
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        temporary.replace(path)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise


def main() -> None:
    args = parse_args()
    args.cache_dir.mkdir(parents=True, exist_ok=True)
    code_map = request_json(f"{BASE}/code-map")
    sido_map = code_map["sido"]
    selected_sido = args.sido or sorted(sido_map)

    observations: defaultdict[str, list[dict[str, str]]] = defaultdict(list)
    requests_made = 0
    cached_responses = 0

    if args.merge_seoul and args.merge_seoul.exists() and "11" in selected_sido:
        seoul = json.loads(args.merge_seoul.read_text(encoding="utf-8"))
        for record in seoul["records"]:
            for district in record["districts"]:
                observations[record["sttnId"]].append(
                    {
                        "name": record["name"],
                        "ctpvCode": "11",
                        "ctpvName": sido_map["11"],
                        "sggCode": district["sggCode"],
                        "sggName": district["sggName"],
                    }
                )
        selected_sido = [code for code in selected_sido if code != "11"]
        print(f"merged Seoul: {len(seoul['records'])} unique stops", flush=True)

    districts: list[tuple[str, str, str, str]] = []
    for sido in selected_sido:
        sgg_map = request_json(f"{BASE}/{sido}/sgg")
        districts.extend((sido, sido_map[sido], sgg, name) for sgg, name in sgg_map.items())

    for index, (sido, sido_name, sgg, sgg_name) in enumerate(districts, start=1):
        cache = args.cache_dir / f"{args.snapshot_date}-{sido}-{sgg}.json"
        if cache.exists():
            response = json.loads(cache.read_text(encoding="utf-8"))
            cached_responses += 1
        else:
            started = time.monotonic()
            response = request_json(
                f"{BASE}/getSttnOrRte/list",
                {
                    "type": "sttn",
                    "ymd": args.snapshot_date,
                    "sido": sido,
                    "sgg": sgg,
                },
            )
            atomic_json(cache, response)
            requests_made += 1
            remaining = args.interval - (time.monotonic() - started)
            if remaining > 0:
                time.sleep(remaining)
        if not isinstance(response, list):
            raise RuntimeError(f"Unexpected selector response for {sido}/{sgg}: {response!r}")
        for item in response:
            station_id = str(item["value"])
            observations[station_id].append(
                {
                    "name": str(item["text"]).strip(),
                    "ctpvCode": sido,
                    "ctpvName": sido_name,
                    "sggCode": sgg,
                    "sggName": sgg_name,
                }
            )
        print(
            f"[{index}/{len(districts)}] {sido_name} {sgg_name}: {len(response)} stops",
            flush=True,
        )

    records = []
    ambiguous = []
    for station_id, entries in sorted(observations.items()):
        names = sorted({entry["name"] for entry in entries})
        districts_for_stop = sorted(
            {
                (
                    entry["ctpvCode"],
                    entry["ctpvName"],
                    entry["sggCode"],
                    entry["sggName"],
                )
                for entry in entries
            }
        )
        if len(names) != 1:
            ambiguous.append({"sttnId": station_id, "names": names})
            continue
        records.append(
            {
                "sttnId": station_id,
                "name": names[0],
                "districts": [
                    {
                        "ctpvCode": ctpv_code,
                        "ctpvName": ctpv_name,
                        "sggCode": sgg_code,
                        "sggName": sgg_name,
                    }
                    for ctpv_code, ctpv_name, sgg_code, sgg_name in districts_for_stop
                ],
            }
        )

    payload = {
        "schemaVersion": 2,
        "source": {
            "title": "국토교통부_버스정류장",
            "publisher": "국토교통부",
            "catalogURL": "https://www.data.go.kr/data/15142032/openapi.do",
            "samplePageURL": REFERER,
            "codeMapEndpoint": f"{BASE}/code-map",
            "selectorEndpoint": f"{BASE}/getSttnOrRte/list",
            "access": "Anonymous official sample UI backend; no service key used",
            "sampleWarning": "Maximum 25 sample result rows; more than 5 calls within 1 minute may cause temporary blocking",
            "requestIntervalSeconds": args.interval,
            "networkRequestsMade": requests_made,
            "cachedResponsesUsed": cached_responses,
            "retrievedAtUTC": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
        },
        "snapshotDate": args.snapshot_date,
        "provinces": [
            {"ctpvCode": code, "ctpvName": sido_map[code]}
            for code in sorted(set(args.sido or sido_map))
        ],
        "recordCount": len(records),
        "ambiguousIds": ambiguous,
        "records": records,
    }
    atomic_json(args.output, payload)
    print(
        json.dumps(
            {
                "output": str(args.output),
                "records": len(records),
                "ambiguousIds": len(ambiguous),
                "networkRequestsMade": requests_made,
                "cachedResponsesUsed": cached_responses,
            },
            ensure_ascii=False,
            indent=2,
        ),
        flush=True,
    )


if __name__ == "__main__":
    main()
