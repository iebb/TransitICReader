"""Select and submit the latest TestFlight and Play internal builds for store review.

``select`` performs read-only store inspections. It pins the latest eligible iOS
build and Play internal release, requires one marketing version when both stores
are selected, and resolves release notes: RELEASE_NOTES_JSON when set, otherwise
docs/release-notes/<version>.json when it exists, otherwise each store keeps its
existing notes. Google Play receives only the en-GB text, as its en-US listing.
The selection contains identifiers and notes only, never credentials.

``submit`` loads credentials only for the selected stores, checks that the pinned
Play build is still current, submits the pinned iOS build to App Review, then
promotes the pinned Play internal release to production. The result file is
rewritten after each store step, so a partial failure remains recorded.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import functools
import importlib.util
import json
import os
from pathlib import Path
import re
import sys
from typing import Any, Mapping

from tools.release.app_store import AppStoreAPI, ReleaseError as AppleError, inspect_release, submit_release
from tools.release.versions import paired_store_builds


ROOT = Path(__file__).resolve().parents[2]
NOTES_DIR = Path("docs/release-notes")
PLAY_MODULE = ROOT / "android/tools/play_release.py"
SCHEMA = 1
PLATFORMS = {"both": ("ios", "android"), "ios": ("ios",), "android": ("android",)}
# The Play listing is currently en-US only; it carries the committed en-GB text.
PLAY_NOTES_LOCALES = {"en-GB": "en-US"}
VERSION = re.compile(r"[0-9]+(?:\.[0-9]+){0,2}")
MAX_VERSION_CODE = 2_100_000_000


class ReviewError(RuntimeError):
    """A review request cannot safely proceed; the message is safe for CI logs."""


@functools.cache
def load_play():
    # play_release.py is a standalone script, not a package module.
    spec = importlib.util.spec_from_file_location("cardbal_play_release", PLAY_MODULE)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def read_text(path: Path) -> str | None:
    try:
        return path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return None
    except (OSError, UnicodeDecodeError):
        raise ReviewError(f"Could not read {path} as UTF-8 text.") from None


def write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def write_json(path: Path, document: dict) -> None:
    try:
        write_text(path, json.dumps(document, ensure_ascii=False, indent=2) + "\n")
    except OSError:
        raise ReviewError(f"Could not write {path}.") from None


def checked_notes(notes: Any, source: str) -> dict[str, str]:
    if not isinstance(notes, dict) or not notes or any(
        not isinstance(locale, str) or not locale.strip() or not isinstance(text, str) or not text.strip()
        for locale, text in notes.items()
    ):
        raise ReviewError(f"{source} must map nonempty locale strings to nonempty release notes.")
    return notes


def parse_notes(text: str, source: str) -> dict[str, str]:
    def unique(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        notes = dict(pairs)
        if len(notes) != len(pairs):
            raise ReviewError(f"{source} repeats a locale.")
        return notes

    try:
        notes = json.loads(text, object_pairs_hook=unique)
    except ValueError:
        raise ReviewError(f"{source} must be JSON mapping locales to release notes.") from None
    return checked_notes(notes, source)


def committed_notes(version: str) -> tuple[dict[str, str] | None, str | None]:
    relative = (NOTES_DIR / f"{version}.json").as_posix()
    text = read_text(ROOT / relative)
    return (None, None) if text is None else (parse_notes(text, relative), relative)


def asc_app_id(environ: Mapping[str, str]) -> str:
    value = environ.get("ASC_APP_ID", "")
    if not re.fullmatch(r"[0-9]+", value):
        raise ReviewError("ASC_APP_ID must be the numeric App Store Connect app ID.")
    return value


def apple_call(call, *args, **kwargs):
    try:
        return call(*args, **kwargs)
    except AppleError as error:
        raise ReviewError(f"App Store Connect: {error}") from None


def play_inspect() -> dict:
    play = load_play()
    try:
        session = play.authorized_session(None)
        try:
            return play.PlayRelease(session).inspect()
        finally:
            session.close()
    except play.ReleaseError as error:
        raise ReviewError(f"Google Play: {error}") from None


def play_notes(notes: dict[str, str] | None) -> dict[str, str] | None:
    mapped = {target: notes[locale] for locale, target in PLAY_NOTES_LOCALES.items() if notes and locale in notes}
    if not mapped:
        return None
    play = load_play()
    try:
        play.release_notes_payload(mapped)
    except play.ReleaseError as error:
        raise ReviewError(f"Google Play: {error}") from None
    return mapped


def select(platforms: tuple[str, ...], environ: Mapping[str, str] = os.environ) -> dict:
    # Validate operator input before any store access or credential use.
    override = environ.get("RELEASE_NOTES_JSON", "")
    override = parse_notes(override, "RELEASE_NOTES_JSON") if override.strip() else None
    app_id = asc_app_id(environ) if "ios" in platforms else None
    api = apple = google = None
    if "ios" in platforms:
        api = AppStoreAPI(allow_writes=False)
        # The first inspection only identifies the version whose notes apply.
        apple = apple_call(inspect_release, api, app_id)
    if "android" in platforms:
        google = play_inspect()
    if apple and google:
        try:
            paired_store_builds(apple, google)
        except ValueError as error:
            raise ReviewError(str(error)) from None
    version = apple["build"]["version"] if apple else google["version"]
    if not isinstance(version, str) or not VERSION.fullmatch(version):
        raise ReviewError("The selected marketing version is not numeric.")
    notes, source = (override, "RELEASE_NOTES_JSON") if override else committed_notes(version)
    selection = {"schema": SCHEMA, "status": "selected",
                 "selected_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
                 "platforms": list(platforms), "version": version,
                 "release_notes_source": source, "blockers": []}
    if apple:
        plan = apple_call(inspect_release, api, app_id, notes=notes) if notes else apple
        if plan["build"]["id"] != apple["build"]["id"]:
            raise ReviewError("The latest eligible TestFlight build changed during selection; rerun select.")
        if plan["blockers"]:
            selection.update(status="blocked", blockers=plan["blockers"])
        build = plan["build"]
        selection["ios"] = {"app_id": app_id, "build_id": build["id"], "build_number": build["build_number"],
                            "version": build["version"], "release_notes": notes, "plan": plan}
    if google:
        selection["android"] = {"package": google.get("package"), "version": google["version"],
                                "version_code": int(google["version_code"]), "release_notes": play_notes(notes)}
    return selection


def optional_notes(value: Any, source: str) -> None:
    if value is not None:
        checked_notes(value, source)


def load_selection(path: Path) -> dict:
    text = read_text(path)
    if text is None:
        raise ReviewError(f"{path} does not exist; run select first.")
    try:
        selection = json.loads(text)
    except ValueError:
        raise ReviewError(f"{path} is not valid JSON; rerun select.") from None
    if not isinstance(selection, dict) or selection.get("schema") != SCHEMA:
        raise ReviewError("Unsupported selection file; rerun select.")
    if selection.get("status") != "selected":
        raise ReviewError("The selection has unresolved blockers; resolve them and rerun select.")
    platforms = selection.get("platforms")
    if not isinstance(platforms, list) or tuple(platforms) not in PLATFORMS.values():
        raise ReviewError("The selection names no valid platforms; rerun select.")
    version = selection.get("version")
    if not isinstance(version, str) or not VERSION.fullmatch(version):
        raise ReviewError("The selection has no numeric marketing version; rerun select.")
    if "ios" in platforms:
        ios = selection.get("ios")
        if (not isinstance(ios, dict) or not isinstance(ios.get("app_id"), str) or not re.fullmatch(r"[0-9]+", ios["app_id"])
                or not isinstance(ios.get("build_id"), str) or not ios["build_id"] or ios.get("version") != version):
            raise ReviewError("The selection's iOS build is incomplete; rerun select.")
        optional_notes(ios.get("release_notes"), "Selected iOS release notes")
    if "android" in platforms:
        android = selection.get("android")
        code = android.get("version_code") if isinstance(android, dict) else None
        if (not isinstance(android, dict) or android.get("version") != version or isinstance(code, bool)
                or not isinstance(code, int) or not 1 <= code <= MAX_VERSION_CODE):
            raise ReviewError("The selection's Play build is incomplete; rerun select.")
        optional_notes(android.get("release_notes"), "Selected Play release notes")
    return selection


def submit(selection: dict, output: Path, environ: Mapping[str, str] = os.environ) -> dict:
    platforms = selection["platforms"]
    app_id = asc_app_id(environ) if "ios" in platforms else None
    if app_id and app_id != selection["ios"]["app_id"]:
        raise ReviewError("ASC_APP_ID differs from the App Store app in the selection; rerun select.")
    result = {"schema": SCHEMA, "status": "in_progress", "version": selection["version"],
              "platforms": platforms, **{platform: {"status": "pending"} for platform in platforms}}
    write_json(output, result)
    known = (AppleError, ReviewError) + ((load_play().ReleaseError,) if "android" in platforms else ())
    session = client = None
    current = platforms[-1]
    try:
        if "android" in platforms:
            # Load Play credentials and recheck the pinned build before changing either store.
            play, android = load_play(), selection["android"]
            session = play.authorized_session(None)
            client = play.PlayRelease(session)
            latest = client.inspect()
            if (latest["version"], int(latest["version_code"])) != (android["version"], android["version_code"]):
                raise ReviewError("The latest Play internal build changed since selection; rerun select.")
        if "ios" in platforms:
            current, ios = "ios", selection["ios"]
            plan = submit_release(AppStoreAPI(allow_writes=True), app_id, notes=ios["release_notes"],
                                  expected_build_id=ios["build_id"])
            result["ios"] = {"status": "succeeded", "outcome": plan.get("result", plan["action"]), "details": plan}
            write_json(output, result)
        if "android" in platforms:
            current = "android"
            metadata = client.promote(android["version"], android["version_code"],
                                      release_notes=android["release_notes"])
            result["android"] = {"status": "succeeded", "outcome": metadata.get("action"), "details": metadata}
    except Exception as error:
        # Store errors are written to be log-safe; other messages may not be.
        message = str(error) if isinstance(error, known) else f"Unexpected {type(error).__name__}; inspect the store consoles before retrying."
        result[current] = {"status": "failed", "error": message}
        if not isinstance(error, known):
            raise
    finally:
        for platform in platforms:
            if result[platform]["status"] == "pending":
                result[platform] = {"status": "not_attempted"}
        succeeded = [platform for platform in platforms if result[platform]["status"] == "succeeded"]
        result["status"] = ("succeeded" if len(succeeded) == len(platforms)
                            else "partial" if succeeded else "failed")
        write_json(output, result)
        if session is not None:
            session.close()
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    choose = commands.add_parser("select", help="read-only: pin the latest test builds and release notes")
    choose.add_argument("--platforms", required=True, choices=tuple(PLATFORMS))
    choose.add_argument("--output", required=True, type=Path)
    send = commands.add_parser("submit", help="submit the pinned builds; this changes store state")
    send.add_argument("--selection-file", required=True, type=Path)
    send.add_argument("--output", required=True, type=Path)
    args = parser.parse_args(argv)
    try:
        if args.command == "select":
            selection = select(PLATFORMS[args.platforms])
            write_json(args.output, selection)
            if selection["blockers"]:
                print("Store review is blocked: " + " ".join(selection["blockers"]), file=sys.stderr)
                return 2
            pinned = [f"iOS build {selection['ios']['build_number']} ({selection['ios']['build_id']})"] if "ios" in selection else []
            pinned += [f"Android code {selection['android']['version_code']}"] if "android" in selection else []
            print(f"Selected {selection['version']}: {', '.join(pinned)}; release notes: "
                  f"{selection['release_notes_source'] or 'existing store notes kept'}.")
            return 0
        result = submit(load_selection(args.selection_file), args.output)
        for platform in result["platforms"]:
            outcome = result[platform]
            line = f"{platform}: {outcome['status']}" + (f" ({outcome['outcome']})" if outcome.get("outcome") else "")
            print(line + (f": {outcome['error']}" if outcome.get("error") else ""),
                  file=sys.stdout if outcome["status"] == "succeeded" else sys.stderr)
        return 0 if result["status"] == "succeeded" else 1
    except ReviewError as error:
        print(f"Store review failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
