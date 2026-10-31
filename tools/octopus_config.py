"""Bundle the optional Octopus endpoint from the build environment or ignored .env."""
import argparse
import os
import plistlib
from pathlib import Path
from urllib.parse import urlsplit

KEY = "OCTOPUS_ENQUIRY_BASE_URL"


def configured_value(root):
    value = os.environ.get(KEY)
    if value is None:
        dotenv = root / ".env"
        if dotenv.is_file():
            for line in dotenv.read_text().splitlines():
                name, separator, candidate = line.partition("=")
                if separator and name.strip() == KEY:
                    value = candidate.strip().strip("\"'")
    if value is None:
        # CI prepares this ignored file before clearing secrets from Xcode's
        # environment. Explicit environment/.env settings still take precedence.
        prepared = root / "ios/CardBal/Resources/OctopusEnquiryConfig.plist"
        if prepared.is_file():
            value = plistlib.loads(prepared.read_bytes()).get(KEY)
    value = (value or "").strip().rstrip("/")
    if value:
        parts = urlsplit(value)
        if (parts.scheme != "https" or not parts.hostname or parts.username
                or parts.password or parts.query or parts.fragment):
            raise ValueError(f"{KEY} must be an HTTPS URL without credentials, query, or fragment")
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    value = configured_value(Path(__file__).resolve().parents[1])
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(plistlib.dumps({KEY: value}))


if __name__ == "__main__":
    main()
