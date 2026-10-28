"""Upload an already signed IPA using Apple's installed upload tool."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ipa", type=Path, required=True)
    args = parser.parse_args()
    if not args.ipa.is_file():
        parser.error("The signed IPA does not exist.")
    for name in ("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_PRIVATE_KEY"):
        if not os.environ.get(name):
            parser.error(f"{name} is required.")
    with tempfile.TemporaryDirectory(prefix="cardbal-upload-", dir=os.environ.get("RUNNER_TEMP")) as directory:
        key = Path(directory) / f"AuthKey_{os.environ['ASC_KEY_ID']}.p8"
        key.write_text(os.environ["ASC_PRIVATE_KEY"], encoding="utf-8")
        key.chmod(0o600)
        env = os.environ.copy()
        env["API_PRIVATE_KEYS_DIR"] = directory
        help_result = subprocess.run(["xcrun", "altool", "--help"], capture_output=True, text=True, check=True)
        help_text = help_result.stdout + help_result.stderr
        if "--upload-package" in help_text:
            command = ["xcrun", "altool", "--upload-package", str(args.ipa),
                       "--api-key", env["ASC_KEY_ID"], "--api-issuer", env["ASC_ISSUER_ID"],
                       "--p8-file-path", str(key)]
        else:
            command = ["xcrun", "altool", "--upload-app", "-f", str(args.ipa), "--type", "ios",
                       "--apiKey", env["ASC_KEY_ID"], "--apiIssuer", env["ASC_ISSUER_ID"]]
        subprocess.run(command, env=env, check=True)
    print("Uploaded to App Store Connect. Apple must finish processing before Release can select this build.")


if __name__ == "__main__":
    main()
