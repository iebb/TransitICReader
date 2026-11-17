"""Publish the macOS app and the Android APKs of one version in one GitHub release.

Each version has a single release tagged v<version>. The macOS app is built on
push and the APKs once Google Play internal has the version, so whichever
platform arrives first creates the release and the other adds its files.
Published files are never replaced. After each upload the release notes and
SHA256SUMS.txt are rewritten to cover every platform on the release.
Versions released before this scheme have separate macos-v / android-v tags.
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
PLATFORMS = ("macos", "android")
TITLES = {"macos": "macOS", "android": "Android"}
STORE_LOCALES = ("en-GB", "zh-Hans", "ja", "ko")


def release_tag(version: str) -> str:
    return f"v{version}"


def legacy_tag(platform: str, version: str) -> str:
    return f"{platform}-v{version}"


def asset_names(platform: str, version: str) -> list[str]:
    if platform == "macos":
        return [f"CardBal-{version}-macOS.zip"]
    return [f"CardBal-{version}-android.apk", f"CardBal-{version}-android-git-signed.apk"]


def platforms_present(names, version: str) -> list[str]:
    names = set(names)
    return [p for p in PLATFORMS if names & set(asset_names(p, version))]


def section(text: str, title: str) -> str:
    lines = text.strip().splitlines()
    if lines and lines[0].startswith("# "):
        lines[0] = "#" + lines[0]
    else:
        lines = [f"## {title}", ""] + lines
    return "\n".join(lines)


def platform_notes(platform: str, version: str, notes: Path = NOTES) -> str:
    if platform == "macos":
        path = notes / f"macos-{version}.md"
        if not path.is_file() or not path.read_text(encoding="utf-8").strip():
            raise ValueError(f"Version {version} has no macOS release notes; add {path.relative_to(ROOT)}.")
        return section(path.read_text(encoding="utf-8"), TITLES[platform])
    path, store = notes / f"android-{version}.md", notes / f"{version}.json"
    text = path.read_text(encoding="utf-8") if path.is_file() else ""
    if not text.strip() and store.is_file():
        locales = json.loads(store.read_text(encoding="utf-8"))
        text = "\n\n".join(locales[key] for key in STORE_LOCALES if locales.get(key))
    apk, git_signed = asset_names("android", version)
    text = text.rstrip() + f"""

### Which APK?

- `{apk}` is signed by Google Play. It updates, and is updated by, the Google Play app.
- `{git_signed}` is built from this release's source on GitHub and signed by the developer. It installs as a separate app, CardBal (GitHub), beside the Google Play app, with its own saved cards, and has no analytics.
"""
    return section(text, TITLES[platform])


def release_notes(platforms, version: str, notes: Path = NOTES) -> str:
    body = "\n\n".join(platform_notes(p, version, notes) for p in PLATFORMS if p in platforms)
    return body + f"\n\n`{CHECKSUMS}` lists the SHA-256 checksum of every download.\n"


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


def published(platform: str, version: str) -> bool:
    if fetch_release(legacy_tag(platform, version)):
        return True
    release = fetch_release(release_tag(version))
    names = [asset["name"] for asset in release["assets"]] if release else []
    return platform in platforms_present(names, version)


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
        (scratch / "notes.md").write_text(release_notes(platforms_present(names, version), version))
        gh("release", "upload", tag, str(scratch / CHECKSUMS), "--clobber")
        gh("release", "edit", tag, "--notes-file", str(scratch / "notes.md"))
        if sorted(a["name"] for a in fetch_release(tag)["assets"] if a["name"] != CHECKSUMS) == names:
            return
    raise RuntimeError(f"Release {tag} kept changing; rerun to settle its notes and checksums.")


def publish(platform: str, version: str, target: str, files: list[Path]) -> None:
    expected = asset_names(platform, version)
    if sorted(f.name for f in files) != sorted(expected):
        raise ValueError(f"{TITLES[platform]} release files must be {', '.join(expected)}.")
    if published(platform, version):
        raise RuntimeError(f"{TITLES[platform]} {version} is already released; refusing to replace it.")
    tag = release_tag(version)
    local = {f.name: sha256(f) for f in files}
    with tempfile.TemporaryDirectory() as directory:
        scratch = Path(directory)
        (scratch / "notes.md").write_text(release_notes([platform], version))
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
    print(f"Published {TITLES[platform]} {version} in release {tag}.")


def main(argv=None) -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("status", "notes", "publish"):
        command = commands.add_parser(name)
        command.add_argument("--version", required=True)
        command.add_argument("--platform", choices=PLATFORMS, required=True)
    commands.choices["notes"].add_argument("--output", type=Path, required=True)
    commands.choices["publish"].add_argument("--target", required=True)
    commands.choices["publish"].add_argument("files", nargs="+", type=Path)
    args = parser.parse_args(argv)
    try:
        if args.command == "status":
            print("true" if published(args.platform, args.version) else "false")
        elif args.command == "notes":
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(release_notes([args.platform], args.version))
        else:
            publish(args.platform, args.version, args.target, args.files)
    except (ValueError, RuntimeError) as error:
        sys.exit(str(error))


if __name__ == "__main__":
    main()
