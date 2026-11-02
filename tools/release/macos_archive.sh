#!/bin/bash
set -euo pipefail

: "${RELEASE_VERSION:?RELEASE_VERSION is required}"
: "${MACOS_BUILD_NUMBER:?MACOS_BUILD_NUMBER is required}"
: "${MACOS_SIGNING_DIR:?MACOS_SIGNING_DIR is required}"
: "${MACOS_PROFILE_UUID:?MACOS_PROFILE_UUID is required}"
: "${MACOS_SIGNING_CERTIFICATE:?MACOS_SIGNING_CERTIFICATE is required}"

root="$(cd -- "$(dirname -- "$0")/../.." && pwd)"
cd "$root"
umask 077
keychain="$MACOS_SIGNING_DIR/signing.keychain-db"
# Xcode versions differ in which directory they search for installed profiles.
profile_dirs=("$HOME/Library/MobileDevice/Provisioning Profiles" "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles")
cleanup() {
    if [ -f "$MACOS_SIGNING_DIR/keychains.json" ]; then
        python3 - <<'PY' || true
import json, os, pathlib, subprocess
directory = pathlib.Path(os.environ['MACOS_SIGNING_DIR'])
subprocess.run(['security', 'list-keychains', '-d', 'user', '-s',
                *json.loads((directory / 'keychains.json').read_text())], check=True)
PY
    fi
    security delete-keychain "$keychain" >/dev/null 2>&1 || true
    for index in "${!profile_dirs[@]}"; do
        profile="${profile_dirs[$index]}/$MACOS_PROFILE_UUID.provisionprofile"
        if [ -f "$MACOS_SIGNING_DIR/prior-profile-$index" ]; then
            cp "$MACOS_SIGNING_DIR/prior-profile-$index" "$profile"
        elif [ -f "$MACOS_SIGNING_DIR/installed-profile-$index" ]; then
            rm -f "$profile"
        fi
    done
}
trap cleanup EXIT

python3 - <<'PY'
import json, os, pathlib, plistlib, secrets, shlex, subprocess
p = pathlib.Path(os.environ['MACOS_SIGNING_DIR'])
(p / 'keychains.json').write_text(json.dumps(shlex.split(
    subprocess.check_output(['security', 'list-keychains', '-d', 'user'], text=True))))
(p / 'keychain-password').write_text(secrets.token_urlsafe(32))
(p / 'p12-password').write_text(secrets.token_urlsafe(32))
out = pathlib.Path('build/macos')
out.mkdir(parents=True, exist_ok=True)
(out / 'ExportOptions.plist').write_bytes(plistlib.dumps({
    'method': 'developer-id', 'destination': 'export', 'teamID': '7P8CLHDH5G',
    'signingStyle': 'manual', 'signingCertificate': os.environ['MACOS_SIGNING_CERTIFICATE'],
    'provisioningProfiles': {'ad.neko.cardbal': os.environ['MACOS_PROFILE_UUID']},
    'manageAppVersionAndBuildNumber': False, 'iCloudContainerEnvironment': 'Production',
}))
PY
openssl x509 -inform DER -in "$MACOS_SIGNING_DIR/certificate.cer" -out "$MACOS_SIGNING_DIR/certificate.pem"
# `security import` rejects OpenSSL 3's default AES/SHA-256 PKCS#12 encoding.
openssl pkcs12 -export -inkey "$MACOS_SIGNING_DIR/key.pem" -in "$MACOS_SIGNING_DIR/certificate.pem" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
    -out "$MACOS_SIGNING_DIR/identity.p12" -passout "file:$MACOS_SIGNING_DIR/p12-password"
keychain_password="$(cat "$MACOS_SIGNING_DIR/keychain-password")"
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$MACOS_SIGNING_DIR/identity.p12" -k "$keychain" \
    -P "$(cat "$MACOS_SIGNING_DIR/p12-password")" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
security set-key-partition-list -S apple-tool:,apple: -k "$keychain_password" "$keychain" >/dev/null
python3 - "$keychain" <<'PY'
import json, os, pathlib, subprocess, sys
prior = json.loads((pathlib.Path(os.environ['MACOS_SIGNING_DIR']) / 'keychains.json').read_text())
subprocess.run(['security', 'list-keychains', '-d', 'user', '-s', sys.argv[1], *prior], check=True)
PY
for index in "${!profile_dirs[@]}"; do
    profile="${profile_dirs[$index]}/$MACOS_PROFILE_UUID.provisionprofile"
    mkdir -p "${profile_dirs[$index]}"
    if [ -f "$profile" ]; then cp "$profile" "$MACOS_SIGNING_DIR/prior-profile-$index"; fi
    touch "$MACOS_SIGNING_DIR/installed-profile-$index"
    cp "$MACOS_SIGNING_DIR/profile.provisionprofile" "$profile"
done

# Private values must not enter Xcode's script-phase environment logs.
unset ASC_PRIVATE_KEY IOS_CERTIFICATE_PASSWORD MACOS_SIGNING_BUNDLE_BASE64 MACOS_SIGNING_BUNDLE_PASSWORD
xcodebuild -project CardBal.xcodeproj -scheme CardBal -configuration Release \
    -destination 'generic/platform=macOS,variant=Mac Catalyst' \
    -archivePath build/macos/CardBal.xcarchive -derivedDataPath build/macos/DerivedData archive \
    "MARKETING_VERSION=$RELEASE_VERSION" "CURRENT_PROJECT_VERSION=$MACOS_BUILD_NUMBER" \
    CARDBAL_CODE_SIGN_STYLE=Manual "CARDBAL_CODE_SIGN_IDENTITY=$MACOS_SIGNING_CERTIFICATE" \
    "CARDBAL_PROVISIONING_PROFILE=$MACOS_PROFILE_UUID" ENABLE_HARDENED_RUNTIME=YES \
    ONLY_ACTIVE_ARCH=NO 'ARCHS=arm64 x86_64' "OTHER_CODE_SIGN_FLAGS=--keychain $keychain --timestamp"
PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH" xcodebuild -exportArchive \
    -archivePath build/macos/CardBal.xcarchive -exportOptionsPlist build/macos/ExportOptions.plist \
    -exportPath build/macos/export
app="build/macos/export/CardBal.app"
codesign --verify --deep --strict --verbose=2 "$app"
archs=" $(lipo -archs "$app/Contents/MacOS/CardBal") "
case "$archs" in *" arm64 "*) ;; *) echo "Mac app lacks arm64: $archs" >&2; exit 1;; esac
case "$archs" in *" x86_64 "*) ;; *) echo "Mac app lacks x86_64: $archs" >&2; exit 1;; esac
ditto -c -k --sequesterRsrc --keepParent "$app" build/macos/CardBal-notarization.zip
