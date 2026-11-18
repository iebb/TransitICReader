"""Publish the macOS app and the Android APKs of one version in one GitHub release.

Each version has a single release tagged v<version> with up to three downloads:
the macOS app and the git-signed APK, both built on push, and the Play-signed
APK, added once Google Play internal has the version. Whichever download is
ready first creates the release; later ones are added to it. Published files
are never replaced. After each upload the release notes and SHA256SUMS.txt are
rewritten to cover every download on the release. Release notes files are
optional. Versions released before this scheme have separate macos-v /
android-v tags.
"""
import argparse
import hashlib
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
NOTES = ROOT / "docs/release-notes"
CHECKSUMS = "SHA256SUMS.txt"
ASSETS = ("macos", "android-play", "android-git-signed")
STORE_LOCALES = ("en-GB", "zh-Hans", "ja", "ko")
MAC_REQUIREMENTS = "CardBal requires macOS 13 Ventura or later and a compatible external USB NFC / CCID reader."
APK_NOTES = {
    "android-play": "is signed by Google Play. It updates, and is updated by, the Google Play app.",
    "android-git-signed": "is built from this release's source on GitHub and signed by the developer. It installs "
                          "as a separate app, CardBal (GitHub), beside the Google Play app, with its own saved "
                          "cards, and has no analytics.",
}


def release_tag(version: str) -> str:
    return f"v{version}"


def legacy_tag(asset: str, version: str) -> str:
    return f"{asset.split('-')[0]}-v{version}"


def asset_name(asset: str, version: str) -> str:
    return {"macos": f"CardBal-{version}-macOS.zip",
            "android-play": f"CardBal-{version}-android.apk",
            "android-git-signed": f"CardBal-{version}-android-git-signed.apk"}[asset]


def asset_of(name: str, version: str) -> str:
    for asset in ASSETS:
        if asset_name(asset, version) == name:
            return asset
    expected = ", ".join(asset_name(a, version) for a in ASSETS)
    raise ValueError(f"{name} is not a CardBal {version} download; expected one of {expected}.")


def assets_present(names, version: str) -> list[str]:
    names = set(names)
    return [a for a in ASSETS if asset_name(a, version) in names]


def note_file(path: Path) -> str:
    return path.read_text(encoding="utf-8").strip() if path.is_file() else ""


def store_notes(version: str, notes: Path) -> str:
    store = notes / f"{version}.json"
    if not store.is_file():
        return ""
    locales = json.loads(store.read_text(encoding="utf-8"))
    return "\n\n".join(locales[key] for key in STORE_LOCALES if locales.get(key))


def section(text: str, title: str) -> str:
    lines = text.strip().splitlines()
    if lines and lines[0].startswith("# "):
        lines[0] = "#" + lines[0]
    else:
        lines = [f"## {title}", ""] + lines
    return "\n".join(lines)


def mac_notes(version: str, notes: Path) -> str:
    text = note_file(notes / f"macos-{version}.md")
    if not text:
        download = f"Download `{asset_name('macos', version)}`, open it, and move CardBal to Applications."
        text = "\n\n".join(filter(None, [store_notes(version, notes), MAC_REQUIREMENTS, download]))
    return section(text, "macOS")


def android_notes(assets, version: str, notes: Path) -> str:
    text = note_file(notes / f"android-{version}.md") or store_notes(version, notes)
    apks = [a for a in ASSETS if a in assets and a in APK_NOTES]
    heading = "### Which APK?" if len(apks) > 1 else "### APK"
    choices = "\n".join(f"- `{asset_name(a, version)}` {APK_NOTES[a]}" for a in apks)
    return section("\n\n".join(filter(None, [text, f"{heading}\n\n{choices}"])), "Android")


def release_notes(assets, version: str, notes: Path = NOTES) -> str:
    parts = []
    if "macos" in assets:
        parts.append(mac_notes(version, notes))
    if any(a in APK_NOTES for a in assets):
        parts.append(android_notes(assets, version, notes))
    return "\n\n".join(parts) + f"\n\n`{CHECKSUMS}` lists the SHA-256 checksum of every download.\n"


def checksum_text(digests: dict[str, str]) -> str:
    return "".join(f"{digests[name]}  {name}\n" for name in sorted(digests))


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def gh(*args: str, check: bool = True) -> subprocess.CompletedProcess:
    result = subprocess.run(["gh", *args], capture_output=True, text=True)
    if check and result.returncode:
        raise RuntimeError(f"gh {' '.join(args)} failed: {result.stderr.strip()}")
    return result


def fetch_release(tag: str):
    result = gh("api", f"repos/{{owner}}/{{repo}}/releases/tags/{tag}", check=False)
    if result.returncode == 0:
        return json.loads(result.stdout)
    if "Not Found" in result.stderr or "404" in result.stderr:
        return None
    raise RuntimeError(f"Could not read release {tag}: {result.stderr.strip()}")


def published(asset: str, version: str) -> bool:
    if fetch_release(legacy_tag(asset, version)):
        return True
    release = fetch_release(release_tag(version))
    return bool(release) and asset_name(asset, version) in {a["name"] for a in release["assets"]}


def remote_digest(tag: str, asset: dict, scratch: Path) -> str:
    digest = asset.get("digest") or ""
    if digest.startswith("sha256:"):
        return digest.removeprefix("sha256:")
    gh("release", "download", tag, "--pattern", asset["name"], "--dir", str(scratch), "--clobber")
    return sha256(scratch / asset["name"])


def refresh(tag: str, version: str, local: dict[str, str], scratch: Path) -> None:
    """Rewrite notes and checksums until they describe every file on the release."""
    for _ in range(3):
        assets = [a for a in fetch_release(tag)["assets"] if a["name"] != CHECKSUMS]
        digests = {a["name"]: local.get(a["name"]) or remote_digest(tag, a, scratch) for a in assets}
        names = sorted(digests)
        (scratch / CHECKSUMS).write_text(checksum_text(digests))
        (scratch / "notes.md").write_text(release_notes(assets_present(names, version), version))
        gh("release", "upload", tag, str(scratch / CHECKSUMS), "--clobber")
        gh("release", "edit", tag, "--notes-file", str(scratch / "notes.md"))
        if sorted(a["name"] for a in fetch_release(tag)["assets"] if a["name"] != CHECKSUMS) == names:
            return
    raise RuntimeError(f"Release {tag} kept changing; rerun to settle its notes and checksums.")


def publish(version: str, target: str, files: list[Path]) -> None:
    assets = [asset_of(f.name, version) for f in files]
    if not assets or len(set(assets)) != len(assets):
        raise ValueError("Give each CardBal download to publish once.")
    for asset, file in zip(assets, files):
        if published(asset, version):
            raise RuntimeError(f"{file.name} is already released; refusing to replace it.")
    tag = release_tag(version)
    local = {f.name: sha256(f) for f in files}
    with tempfile.TemporaryDirectory() as directory:
        scratch = Path(directory)
        (scratch / "notes.md").write_text(release_notes(assets, version))
        if fetch_release(tag) is None:
            created = gh("release", "create", tag, "--target", target, "--title", f"CardBal {version}",
                         "--notes-file", str(scratch / "notes.md"), *map(str, files), check=False)
            if created.returncode and fetch_release(tag) is None:
                raise RuntimeError(f"Could not create release {tag}: {created.stderr.strip()}")
            if created.returncode:
                gh("release", "upload", tag, *map(str, files))
        else:
            gh("release", "upload", tag, *map(str, files))
        refresh(tag, version, local, scratch)
    print(f"Published {', '.join(f.name for f in files)} in release {tag}.")


def main(argv=None) -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    status = commands.add_parser("status", help="Print true if a download is already released")
    status.add_argument("--asset", choices=ASSETS, required=True)
    notes = commands.add_parser("notes", help="Write the release notes for the given downloads")
    notes.add_argument("--output", type=Path, required=True)
    release = commands.add_parser("publish", help="Add downloads to the version's release")
    release.add_argument("--target", required=True)
    for command in (status, notes, release):
        command.add_argument("--version", required=True)
    for command in (notes, release):
        command.add_argument("files", nargs="+", type=Path)
    args = parser.parse_args(argv)
    try:
        if args.command == "status":
            print("true" if published(args.asset, args.version) else "false")
        elif args.command == "notes":
            assets = [asset_of(f.name, args.version) for f in args.files]
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(release_notes(assets, args.version))
        else:
            publish(args.version, args.target, args.files)
    except (ValueError, RuntimeError) as error:
        sys.exit(str(error))


if __name__ == "__main__":
    main()
