"""Prepare a reusable Developer ID identity for CardBal's Mac Catalyst release."""
from __future__ import annotations

import base64
import json
import os
from pathlib import Path
import plistlib
import subprocess

from tools.release.app_store import AppStoreAPI, ReleaseError

TEAM = "7P8CLHDH5G"
BUNDLE = "ad.neko.cardbal"
FILES = {"key.pem", "request.csr", "certificate.cer", "certificate-id", "profile.provisionprofile"}
MAGIC = b"CardBalMacSigning1\n"


def encrypt_bundle(files: dict[str, bytes], password: str) -> bytes:
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    from cryptography.hazmat.primitives.kdf.scrypt import Scrypt
    salt, nonce = os.urandom(16), os.urandom(12)
    key = Scrypt(salt=salt, length=32, n=2**15, r=8, p=1).derive(password.encode())
    payload = json.dumps({name: base64.b64encode(data).decode() for name, data in files.items()}).encode()
    return MAGIC + salt + nonce + AESGCM(key).encrypt(nonce, payload, MAGIC)


def decrypt_bundle(data: bytes, password: str) -> dict[str, bytes]:
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    from cryptography.hazmat.primitives.kdf.scrypt import Scrypt
    if not data.startswith(MAGIC):
        raise ReleaseError("Unrecognized Mac signing backup.")
    data = data[len(MAGIC):]
    salt, nonce, ciphertext = data[:16], data[16:28], data[28:]
    key = Scrypt(salt=salt, length=32, n=2**15, r=8, p=1).derive(password.encode())
    payload = json.loads(AESGCM(key).decrypt(nonce, ciphertext, MAGIC))
    if not isinstance(payload, dict) or set(payload) - FILES:
        raise ReleaseError("Unexpected files in Mac signing backup.")
    return {name: base64.b64decode(value, validate=True) for name, value in payload.items()}


def backup(directory: Path, password: str) -> None:
    files = {name: (directory / name).read_bytes() for name in FILES if (directory / name).is_file()}
    if files:
        (directory / "signing-backup.enc").write_bytes(encrypt_bundle(files, password))


def prepare(directory: Path, api: AppStoreAPI) -> tuple[str, str]:
    password = os.environ.get("IOS_CERTIFICATE_PASSWORD", "")
    if not password:
        raise ReleaseError("IOS_CERTIFICATE_PASSWORD must protect the Mac signing backup.")
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    encoded = os.environ.get("MACOS_SIGNING_BUNDLE_BASE64", "").strip()
    if encoded:
        for name, data in decrypt_bundle(base64.b64decode(encoded, validate=True), password).items():
            (directory / name).write_bytes(data)
    try:
        if not (directory / "certificate.cer").exists():
            if not (directory / "key.pem").exists():
                subprocess.run(["openssl", "req", "-new", "-newkey", "rsa:2048", "-nodes",
                                "-keyout", str(directory / "key.pem"), "-out", str(directory / "request.csr"),
                                "-subj", "/CN=CardBal Developer ID"], check=True, capture_output=True)
            # Preserve a recoverable key even if Apple's certificate/profile request fails.
            backup(directory, password)
            certificate = api.request("POST", "/v1/certificates", data={"data": {
                "type": "certificates", "attributes": {
                    "certificateType": "DEVELOPER_ID_APPLICATION_G2",
                    "csrContent": (directory / "request.csr").read_text(),
                },
            }})["data"]
            (directory / "certificate.cer").write_bytes(base64.b64decode(
                certificate["attributes"]["certificateContent"], validate=True))
            (directory / "certificate-id").write_text(certificate["id"])
        subject = subprocess.check_output([
            "openssl", "x509", "-inform", "DER", "-in", str(directory / "certificate.cer"),
            "-noout", "-subject", "-nameopt", "RFC2253",
        ], text=True)
        if f"OU={TEAM}" not in subject or "Developer ID Application:" not in subject:
            raise ReleaseError("Developer ID certificate does not belong to CardBal's team.")
        subprocess.run(["openssl", "x509", "-inform", "DER", "-in", str(directory / "certificate.cer"),
                        "-noout", "-checkend", "86400"], check=True, capture_output=True)
        if not (directory / "profile.provisionprofile").exists():
            bundles, _ = api.collection("/v1/bundleIds", {"filter[identifier]": BUNDLE, "limit": 200})
            bundles = [row for row in bundles if row["attributes"]["identifier"] == BUNDLE]
            if len(bundles) != 1:
                raise ReleaseError("CardBal must have exactly one registered bundle identifier.")
            certificate_id = (directory / "certificate-id").read_text().strip()
            profile = api.request("POST", "/v1/profiles", data={"data": {
                "type": "profiles",
                "attributes": {"name": "CardBal Mac Developer ID " + certificate_id,
                               "profileType": "MAC_CATALYST_APP_DIRECT"},
                "relationships": {
                    "bundleId": {"data": {"type": "bundleIds", "id": bundles[0]["id"]}},
                    "certificates": {"data": [{"type": "certificates", "id": certificate_id}]},
                },
            }})["data"]
            (directory / "profile.provisionprofile").write_bytes(base64.b64decode(
                profile["attributes"]["profileContent"], validate=True))
        profile = plistlib.loads(subprocess.check_output([
            "security", "cms", "-D", "-i", str(directory / "profile.provisionprofile"),
        ], stderr=subprocess.DEVNULL))
        entitlements = profile["Entitlements"]
        app_id = entitlements.get("com.apple.application-identifier") or entitlements.get("application-identifier")
        if profile["TeamIdentifier"] != [TEAM] or not app_id or not app_id.endswith("." + BUNDLE):
            raise ReleaseError("Mac provisioning profile does not belong to CardBal.")
        if entitlements.get("get-task-allow") or entitlements.get("com.apple.security.get-task-allow"):
            raise ReleaseError("Mac release profile permits debugging.")
        fingerprint = subprocess.check_output([
            "openssl", "x509", "-inform", "DER", "-in", str(directory / "certificate.cer"),
            "-noout", "-fingerprint", "-sha1",
        ], text=True).strip().split("=", 1)[1].replace(":", "")
        (directory / "profile-uuid").write_text(profile["UUID"])
        return profile["UUID"], fingerprint
    finally:
        backup(directory, password)


def main() -> None:
    os.umask(0o077)
    directory = Path(os.environ["MACOS_SIGNING_DIR"])
    try:
        uuid, fingerprint = prepare(directory, AppStoreAPI(allow_writes=True))
    except Exception as error:
        raise SystemExit(f"Mac signing preparation failed: {error}") from error
    with open(os.environ["GITHUB_ENV"], "a") as output:
        output.write(f"MACOS_PROFILE_UUID={uuid}\nMACOS_SIGNING_CERTIFICATE={fingerprint}\n")
    print("Prepared CardBal Developer ID certificate and Mac Catalyst direct-distribution profile.")


if __name__ == "__main__":
    main()
