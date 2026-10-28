#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: tools/ios/archive.sh

Archive CardBal for a generic iOS device into build/ios/archives/CardBal.xcarchive.
DerivedData stays in build/ios/DerivedData. Run from any working directory.

Environment:
  CONFIGURATION              Build configuration (default: Release).
  SCHEME                     Xcode scheme (default: CardBal).
  DEVELOPMENT_TEAM           Optional signing-team override; defaults to project.
  PRODUCT_BUNDLE_IDENTIFIER  Optional bundle-ID override; defaults to project.
EOF
}

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
esac
[[ $# -eq 0 ]] || { usage >&2; exit 2; }

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"
CONFIGURATION="${CONFIGURATION:-Release}"
ios_require_command xcodebuild
archive_path="$ios_build_root/archives/CardBal.xcarchive"
mkdir -p "$(dirname -- "$archive_path")"
ios_xcodebuild -destination 'generic/platform=iOS' -archivePath "$archive_path" \
    -allowProvisioningUpdates archive
printf 'Archive completed: %s\n' "$archive_path"
