#!/bin/bash
# Build and export a signed IPA. Store upload is a separate workflow step.
set -euo pipefail

: "${RELEASE_VERSION:?RELEASE_VERSION is required}"
: "${IOS_BUILD_NUMBER:?IOS_BUILD_NUMBER is required}"
: "${IOS_CERTIFICATE_P12_BASE64:?IOS_CERTIFICATE_P12_BASE64 is required}"
: "${IOS_CERTIFICATE_PASSWORD:?IOS_CERTIFICATE_PASSWORD is required}"
: "${IOS_PROVISION_PROFILE_BASE64:?IOS_PROVISION_PROFILE_BASE64 is required}"

root="$(cd -- "$(dirname -- "$0")/../.." && pwd)"
cd "$root"
umask 077
private_dir="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/cardbal-signing.XXXXXX")"
keychain="$private_dir/signing.keychain-db"
export CARDBAL_SIGNING_TEMP="$private_dir"
profile_uuid=""
cleanup() {
    if [ -f "$private_dir/original-keychains.json" ]; then
        python3 - <<'PY' || true
import json, os, pathlib, subprocess
p = pathlib.Path(os.environ['CARDBAL_SIGNING_TEMP'])
subprocess.run(['security', 'list-keychains', '-d', 'user', '-s', *json.loads((p / 'original-keychains.json').read_text())], check=True)
PY
    fi
    security delete-keychain "$keychain" >/dev/null 2>&1 || true
    if [ -n "$profile_uuid" ]; then
        profile_index=0
        for profile_dir in "$HOME/Library/MobileDevice/Provisioning Profiles" "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"; do
            if [ -f "$private_dir/profile-installed-$profile_index" ]; then
                if [ -f "$private_dir/original-profile-$profile_index" ]; then
                    cp "$private_dir/original-profile-$profile_index" "$profile_dir/$profile_uuid.mobileprovision"
                else
                    rm -f "$profile_dir/$profile_uuid.mobileprovision"
                fi
            fi
            profile_index=$((profile_index + 1))
        done
    fi
    rm -rf "$private_dir"
}
trap cleanup EXIT

python3 - <<'PY'
import base64, datetime, json, os, pathlib, plistlib, secrets, shlex, subprocess
p = pathlib.Path(os.environ['CARDBAL_SIGNING_TEMP'])
(p / 'original-keychains.json').write_text(json.dumps(shlex.split(subprocess.check_output(['security', 'list-keychains', '-d', 'user'], text=True))))
for variable, filename in [('IOS_CERTIFICATE_P12_BASE64', 'distribution.p12'),
                           ('IOS_PROVISION_PROFILE_BASE64', 'appstore.mobileprovision')]:
    (p / filename).write_bytes(base64.b64decode(os.environ[variable], validate=True))
(p / 'keychain-password').write_text(secrets.token_urlsafe(32))
profile = plistlib.loads(subprocess.check_output(['security', 'cms', '-D', '-i', str(p / 'appstore.mobileprovision')], stderr=subprocess.DEVNULL))
assert profile['TeamIdentifier'] == ['7P8CLHDH5G'], 'Profile team does not match CardBal'
assert profile['Entitlements']['application-identifier'] == '7P8CLHDH5G.ad.neko.cardbal', 'Profile app does not match CardBal'
assert not profile['Entitlements'].get('get-task-allow'), 'An App Store distribution profile is required'
assert not profile.get('ProvisionedDevices') and not profile.get('ProvisionsAllDevices'), 'An App Store profile is required'
assert profile['ExpirationDate'] > datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None), 'Provisioning profile expired'
(p / 'uuid').write_text(profile['UUID'])
out = pathlib.Path('build/ios')
out.mkdir(parents=True, exist_ok=True)
(out / 'ExportOptions.plist').write_bytes(plistlib.dumps({
    'method': 'app-store-connect', 'destination': 'export', 'teamID': '7P8CLHDH5G',
    'signingStyle': 'manual', 'signingCertificate': 'Apple Distribution',
    'provisioningProfiles': {'ad.neko.cardbal': profile['UUID']},
    'manageAppVersionAndBuildNumber': False, 'testFlightInternalTestingOnly': False,
    'iCloudContainerEnvironment': 'Production', 'uploadSymbols': True,
}))
PY
profile_uuid="$(cat "$private_dir/uuid")"
keychain_password="$(cat "$private_dir/keychain-password")"
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$private_dir/distribution.p12" -k "$keychain" -P "$IOS_CERTIFICATE_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
security set-key-partition-list -S apple-tool:,apple: -k "$keychain_password" "$keychain" >/dev/null
security list-keychains -d user -s "$keychain" "$HOME/Library/Keychains/login.keychain-db"
profile_index=0
for profile_dir in "$HOME/Library/MobileDevice/Provisioning Profiles" "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"; do
    mkdir -p "$profile_dir"
    if [ -f "$profile_dir/$profile_uuid.mobileprovision" ]; then
        cp "$profile_dir/$profile_uuid.mobileprovision" "$private_dir/original-profile-$profile_index"
    fi
    touch "$private_dir/profile-installed-$profile_index"
    cp "$private_dir/appstore.mobileprovision" "$profile_dir/$profile_uuid.mobileprovision"
    profile_index=$((profile_index + 1))
done

bash ci_scripts/ci_post_clone.sh
# Xcode logs script-phase environments. Signing inputs have already been
# imported, so keep their contents out of the build process environment.
unset IOS_CERTIFICATE_P12_BASE64 IOS_CERTIFICATE_PASSWORD IOS_PROVISION_PROFILE_BASE64
unset FIREBASE_GOOGLE_SERVICE_INFO_PLIST_BASE64
unset OCTOPUS_ENQUIRY_BASE_URL
xcodebuild -project CardBal.xcodeproj -scheme CardBal -configuration Release \
    -destination 'generic/platform=iOS' -archivePath build/ios/CardBal.xcarchive \
    -derivedDataPath build/ios/DerivedData archive \
    "MARKETING_VERSION=$RELEASE_VERSION" "CURRENT_PROJECT_VERSION=$IOS_BUILD_NUMBER" \
    CARDBAL_CODE_SIGN_STYLE=Manual 'CARDBAL_CODE_SIGN_IDENTITY=Apple Distribution' \
    "CARDBAL_PROVISIONING_PROFILE=$profile_uuid" \
    "OTHER_CODE_SIGN_FLAGS=--keychain $keychain"
# Xcode's native rsync must also find the native peer, rather than a Homebrew
# rsync with incompatible extended-attribute options during IPA packaging.
PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH" xcodebuild -exportArchive -archivePath build/ios/CardBal.xcarchive \
    -exportOptionsPlist build/ios/ExportOptions.plist -exportPath build/ios/export
test -f build/ios/export/CardBal.ipa
