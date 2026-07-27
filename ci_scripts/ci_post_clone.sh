#!/bin/sh

set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
firebase_plist="$repo_root/CardBal/Resources/GoogleService-Info.plist"

if [ -z "${FIREBASE_GOOGLE_SERVICE_INFO_PLIST_BASE64:-}" ]; then
    echo "error: FIREBASE_GOOGLE_SERVICE_INFO_PLIST_BASE64 is required for Xcode Cloud builds." >&2
    exit 1
fi

umask 077
mkdir -p "$(dirname -- "$firebase_plist")"
printf '%s' "$FIREBASE_GOOGLE_SERVICE_INFO_PLIST_BASE64" | /usr/bin/base64 -D > "$firebase_plist"
/usr/bin/plutil -lint "$firebase_plist"
