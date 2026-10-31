#!/bin/sh

set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
firebase_plist="$repo_root/ios/CardBal/Resources/GoogleService-Info.plist"

python3 "$repo_root/tools/octopus_config.py" --output "$repo_root/ios/CardBal/Resources/OctopusEnquiryConfig.plist"

if [ -z "${FIREBASE_GOOGLE_SERVICE_INFO_PLIST_BASE64:-}" ]; then
    echo "Firebase configuration is absent; building with analytics disabled."
    exit 0
fi

umask 077
mkdir -p "$(dirname -- "$firebase_plist")"
printf '%s' "$FIREBASE_GOOGLE_SERVICE_INFO_PLIST_BASE64" | /usr/bin/base64 -D > "$firebase_plist"
/usr/bin/plutil -lint "$firebase_plist"
