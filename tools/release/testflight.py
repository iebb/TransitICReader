"""Upload an already signed IPA using Apple's installed upload tool.

ASC_KEY_TYPE selects the App Store Connect API key: team (the default) needs
ASC_ISSUER_ID; individual keys ignore any ASC_ISSUER_ID left from a team key and
need an altool that supports --api-key-subject.
"""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

KEY_TYPES = ("team", "individual")


def key_type(environ) -> str:
    value = environ.get("ASC_KEY_TYPE") or "team"
    if value not in KEY_TYPES:
        raise ValueError("ASC_KEY_TYPE must be team or individual.")
    return value


def check_credentials(environ, kind: str) -> None:
    required = ("ASC_KEY_ID", "ASC_PRIVATE_KEY") + (("ASC_ISSUER_ID",) if kind == "team" else ())
    for name in required:
        if not environ.get(name):
            raise ValueError(f"{name} is required for {kind} API keys.")


def require_altool_support(help_text: str, kind: str) -> None:
    if kind == "individual" and "--api-key-subject" not in help_text:
        raise ValueError("ASC_KEY_TYPE=individual requires an altool that supports --api-key-subject; "
                         "use a newer Xcode with individual API key support.")


def upload_command(help_text: str, ipa: Path, kind: str, key_id: str, issuer: str, key: Path) -> list[str]:
    # altool rejects --api-key without an issuer argument, so individual keys pass an
    # empty issuer, never a leftover team issuer, and mark the user subject for the
    # non-ApiKey_ named key file. altool then signs sub=user with an empty iss.
    subject = ["--api-key-subject", "user"] if kind == "individual" else []
    issuer = issuer if kind == "team" else ""
    if "--upload-package" in help_text:
        return ["xcrun", "altool", "--upload-package", str(ipa),
                "--api-key", key_id, "--api-issuer", issuer, *subject, "--p8-file-path", str(key)]
    return ["xcrun", "altool", "--upload-app", "-f", str(ipa), "--type", "ios",
            "--apiKey", key_id, "--apiIssuer", issuer, *subject]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ipa", type=Path, required=True)
    args = parser.parse_args()
    if not args.ipa.is_file():
        parser.error("The signed IPA does not exist.")
    try:
        kind = key_type(os.environ)
        check_credentials(os.environ, kind)
        help_result = subprocess.run(["xcrun", "altool", "--help"], capture_output=True, text=True, check=True)
        help_text = help_result.stdout + help_result.stderr
        require_altool_support(help_text, kind)
    except ValueError as error:
        parser.error(str(error))
    with tempfile.TemporaryDirectory(prefix="cardbal-upload-", dir=os.environ.get("RUNNER_TEMP")) as directory:
        key = Path(directory) / f"AuthKey_{os.environ['ASC_KEY_ID']}.p8"
        key.write_text(os.environ["ASC_PRIVATE_KEY"], encoding="utf-8")
        key.chmod(0o600)
        env = os.environ.copy()
        env["API_PRIVATE_KEYS_DIR"] = directory
        command = upload_command(help_text, args.ipa, kind, env["ASC_KEY_ID"], env.get("ASC_ISSUER_ID", ""), key)
        subprocess.run(command, env=env, check=True)
    print(f"Uploaded to App Store Connect with a {kind} API key. "
          "Apple must finish processing before Submit for review can select this build.")


if __name__ == "__main__":
    main()
