"""Load checked-in wallets into an installed Debug app on a simulator/emulator."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess

from tools.paths import ROOT

DATA = ROOT / "data/development"


def wallet(selection):
    names = ["owner-wallet", "mock-wallet"] if selection == "all" else [f"{selection}-wallet"]
    cards = []
    for name in names:
        backup = json.loads((DATA / f"{name}.json").read_text())
        if backup.get("faceAssets") or any(c.get("faceImageFileName") or c.get("isUsingImage") for c in backup["cards"]):
            raise ValueError("Development samples must not contain artwork")
        cards.extend(backup["cards"])
    ids = [c["id"] for c in cards]
    if len(ids) != len(set(ids)):
        raise ValueError("Sample wallet contains duplicate card IDs")
    return {"version": 2, "cards": cards, "faceAssets": {}}


def run(*args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, **kwargs).stdout


def launch_ios(device, bundle, backup):
    # simctl only addresses simulators; a physical iPhone cannot be targeted.
    container = Path(run("xcrun", "simctl", "get_app_container", device, bundle, "data", text=True).strip())
    # A stopped app has nothing to terminate; simctl returns nonzero in that case.
    subprocess.run(["xcrun", "simctl", "terminate", device, bundle], capture_output=True)
    environment = dict(os.environ)
    if backup is not None:
        path = container / "Library/Application Support/CardBal/development/sample-wallet.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(backup, ensure_ascii=False))
        environment["SIMCTL_CHILD_CARDBAL_SAMPLE_BACKUP"] = str(path)
        environment["SIMCTL_CHILD_CARDBAL_PREVIEW_TAB"] = "1"
    else:
        environment.pop("SIMCTL_CHILD_CARDBAL_SAMPLE_BACKUP", None)
    run("xcrun", "simctl", "launch", device, bundle, env=environment)


def launch_android(device, package, backup):
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_.]*", package):
        raise ValueError("Invalid application ID")
    prefix = ["adb", "-s", device]
    if run(*prefix, "shell", "getprop", "ro.kernel.qemu", text=True).strip() != "1":
        raise ValueError("Select an Android emulator, not a physical device")
    if backup is not None:
        # run-as only succeeds for debuggable apps. No root or release-app access.
        run(*prefix, "shell", "run-as", package, "mkdir", "-p", "files/development")
        run(*prefix, "shell", "-T", "run-as", package, "sh", "-c",
            "'cat > files/development/sample-wallet.json'",
            input=json.dumps(backup, ensure_ascii=False).encode())
    run(*prefix, "shell", "am", "force-stop", package)
    arguments = [*prefix, "shell", "am", "start", "-W", "-n", f"{package}/ad.neko.cardbal.android.MainActivity"]
    if backup is not None:
        arguments.extend(["--ez", "cardbal.developmentSamples", "true"])
    output = run(*arguments, text=True)
    if "Error:" in output:
        raise RuntimeError(output.strip())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("platform", choices=["ios", "android"])
    parser.add_argument("--device", required=True, help="Booted simulator UDID (or booted) / adb emulator serial")
    parser.add_argument("--set", choices=["owner", "mock", "all"], default="all")
    parser.add_argument("--normal", action="store_true", help="Launch the normal wallet without changing it")
    parser.add_argument("--app-id", help="Override the installed app's bundle/application ID")
    args = parser.parse_args()
    backup = None if args.normal else wallet(args.set)
    if args.platform == "ios":
        launch_ios(args.device, args.app_id or "ad.neko.cardbal", backup)
    else:
        launch_android(args.device, args.app_id or "ad.neko.cardbal.android", backup)
    print("Opened normal wallet" if backup is None else f"Opened separate development wallet: {len(backup['cards'])} cards ({args.set})")


if __name__ == "__main__":
    main()
