#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: tools/ios/build-and-run.sh [DEVICE_UDID]

Build, install and launch CardBal, then stream this app’s logs until Ctrl+C.
Select a device by its UDID argument or DEVICE_ID environment variable.
Build output stays in build/ios/DerivedData. Requires Xcode and idevicesyslog.

Environment:
  CONFIGURATION              Build configuration (default: Debug).
  SCHEME                     Xcode scheme (default: CardBal).
  DEVELOPMENT_TEAM           Optional signing-team override; defaults to project.
  PRODUCT_BUNDLE_IDENTIFIER  Optional bundle-ID override; defaults to project.
EOF
}

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
esac
[[ $# -le 1 ]] || { usage >&2; exit 2; }

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"
CONFIGURATION="${CONFIGURATION:-Debug}"
ios_select_device "${1:-}"
ios_require_command idevicesyslog
ios_build_and_launch
printf 'Streaming %s logs on %s (Ctrl+C to stop)...\n' "$ios_process_name" "$DEVICE_ID"
exec idevicesyslog --udid "$DEVICE_ID" --process "$ios_process_name" --exit
