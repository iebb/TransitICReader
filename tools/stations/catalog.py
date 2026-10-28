#!/usr/bin/env python3
"""Resolve CardBal's pinned CSV station catalog, or an explicit local checkout."""
from __future__ import annotations

import json
import argparse
import os
import re
import subprocess
import shutil
import hashlib
import tempfile
from pathlib import Path

from tools.paths import ROOT, CSV_LOCK
LOCK_PATH = CSV_LOCK
DEFAULT_CHECKOUT = ROOT / ".external/card-stations"
OMITTED_OUTPUTS = {"JPStationCodes.json", "jp_stations_coverage.json", "ulaanbaatar_stations.tsv", "ulaanbaatar_routes.tsv", "ulaanbaatar_route_stations.tsv"}


def git(path: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(path), *args], check=True, text=True, capture_output=True).stdout.strip()


def resolve_source(source_root: Path | None = None) -> Path:
    override = source_root or os.environ.get("CARDBAL_STATIONS_SOURCE")
    if override:
        source = Path(override).expanduser().resolve()
        if not (source / "build.py").is_file() or not (source / "schema.json").is_file():
            raise RuntimeError(f"Not a card-stations source checkout: {source}")
        return source
    lock = json.loads(LOCK_PATH.read_text(encoding="utf-8"))
    revision = lock["revision"]
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise RuntimeError("card-stations lock must contain a full commit SHA")
    source = DEFAULT_CHECKOUT
    source.parent.mkdir(parents=True, exist_ok=True)
    if not source.exists():
        subprocess.run(["git", "init", "-b", "master", str(source)], check=True, stdout=subprocess.DEVNULL)
        git(source, "remote", "add", "origin", lock["repository"])
    # Compare the stored URL: get-url expands user-wide insteadOf rewrites.
    if git(source, "config", "--get", "remote.origin.url") != lock["repository"]:
        raise RuntimeError(f"Unexpected card-stations origin in {source}")
    if git(source, "status", "--porcelain"):
        raise RuntimeError(f"Pinned card-stations checkout has local changes: {source}. Use --csv-source to build explicit local edits.")
    head = subprocess.run(["git", "-C", str(source), "rev-parse", "HEAD"], capture_output=True, text=True)
    if head.returncode or head.stdout.strip() != revision:
        git(source, "fetch", "--depth", "1", "origin", revision)
        git(source, "checkout", "--detach", revision)
    return source


def build_sources(python: str, output: Path, source_root: Path | None = None) -> dict:
    source = resolve_source(source_root)
    subprocess.run([python, str(source / "build.py"), "--source", str(source), "--output", str(output)], check=True)
    manifest_path = output / "card-stations-manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest["outputs"] = {name: digest for name, digest in manifest["outputs"].items() if name not in OMITTED_OUTPUTS}
    for name in manifest["outputs"]:
        manifest["outputs"][name] = hashlib.sha256((output / name).read_bytes()).hexdigest()
    manifest["repository"] = "https://github.com/iebb/card-stations"
    manifest["revision"] = git(source, "rev-parse", "HEAD")
    manifest["local_changes"] = bool(git(source, "status", "--porcelain"))
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return manifest


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--python", default=os.sys.executable)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="cardbal-csv-assets-") as directory:
        staging = Path(directory)
        manifest = build_sources(args.python, staging, args.source)
        args.output.mkdir(parents=True, exist_ok=True)
        for path in sorted(staging.iterdir()):
            # Publish only the compatibility outputs used by app packaging.
            # Historical maintenance snapshots live separately in data/maintenance.
            if path.name in OMITTED_OUTPUTS:
                continue
            destination = args.output / path.name
            if not destination.is_file() or destination.read_bytes() != path.read_bytes():
                shutil.copyfile(path, destination)
        print(f"Built card-stations {manifest['revision']} ({manifest['source_sha256']})")


if __name__ == "__main__":
    main()
